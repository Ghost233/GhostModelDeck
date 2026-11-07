import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'jev_debug.dart';

abstract interface class EngineLogSource {
  EngineLogBuffer get engineLogs;
}

class EngineLogEntry {
  EngineLogEntry(this.engine, this.instance, this.channel, this.message)
    : sequence = _nextSequence++,
      time = DateTime.now();

  static int _nextSequence = 0;
  final int sequence;
  final DateTime time;
  final String engine;
  final String instance;
  final String channel;
  final String message;
}

/// Each engine retains recent native output even while its page is hidden.
/// Only complete, redacted lines enter the buffer; nothing is written to disk.
class EngineLogBuffer {
  EngineLogBuffer({this.limit = 1000}) : assert(limit > 0);

  final int limit;
  final _entries = ListQueue<EngineLogEntry>();
  final _changes = StreamController<EngineLogEntry>.broadcast();
  List<EngineLogEntry> get entries => List.unmodifiable(_entries);
  Stream<EngineLogEntry> get changes => _changes.stream;

  void capture(
    Stream<List<int>> stream, {
    required String engine,
    required String instance,
    required String channel,
    required String Function(String) redact,
    void Function(List<int>)? onBytes,
  }) {
    void emit(String line) {
      if (_changes.isClosed || line.isEmpty) return;
      final safe =
          sealDebugJson({'message': redact(line)})['message'] as String;
      final entry = EngineLogEntry(engine, instance, channel, safe);
      _entries.add(entry);
      while (_entries.length > limit) {
        _entries.removeFirst();
      }
      _changes.add(entry);
    }

    final decoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_LogLines(emit));
    // The process owns these streams until EOF. Keep draining after the buffer
    // closes so pipe backpressure cannot obstruct process shutdown.
    stream.listen(
      (bytes) {
        onBytes?.call(bytes);
        decoder.add(bytes);
      },
      onDone: decoder.close,
      onError: (Object error) => emit('日志读取失败：$error'),
    );
  }

  Future<void> close() => _changes.close();
}

/// Bound partial lines as well as retained entries. Discard an oversized line
/// whole: emitting fragments could expose credentials spanning two fragments.
class _LogLines extends StringConversionSinkBase {
  _LogLines(this.emit);
  final void Function(String) emit;
  static const maxLength = 16384;
  String _pending = '';
  bool _discarding = false;

  @override
  void addSlice(String chunk, int start, int end, bool isLast) {
    add(chunk.substring(start, end));
    if (isLast) close();
  }

  @override
  void add(String chunk) {
    var start = 0;
    for (var i = 0; i <= chunk.length; i++) {
      if (i < chunk.length &&
          chunk.codeUnitAt(i) != 10 &&
          chunk.codeUnitAt(i) != 13) {
        continue;
      }
      if (!_discarding) {
        if (_pending.length + i - start > maxLength) {
          _pending = '';
          _discarding = true;
        } else {
          _pending += chunk.substring(start, i);
        }
      }
      if (i < chunk.length) {
        _flush();
        start = i + 1;
      }
    }
  }

  void _flush() {
    emit(_discarding ? '[日志行过长，已省略]' : _pending);
    _pending = '';
    _discarding = false;
  }

  @override
  void close() => _flush();
}

/// A bounded merged view, retaining observed output from removed providers too.
class EngineLogFeed {
  final _entries = <EngineLogEntry>[];
  final _subscriptions =
      <EngineLogBuffer, StreamSubscription<EngineLogEntry>>{};
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  List<EngineLogEntry> get entries => List.unmodifiable(_entries);

  void attach(Iterable<EngineLogSource> sources) {
    final buffers = sources.map((source) => source.engineLogs).toSet();
    for (final buffer in _subscriptions.keys.toList()) {
      if (!buffers.contains(buffer)) {
        unawaited(_subscriptions.remove(buffer)!.cancel());
      }
    }
    final additions = <EngineLogEntry>[];
    for (final buffer in buffers) {
      if (_subscriptions.containsKey(buffer)) continue;
      additions.addAll(buffer.entries);
      _subscriptions[buffer] = buffer.changes.listen(
        (entry) => _merge([entry]),
      );
    }
    _merge(additions);
  }

  void _merge(Iterable<EngineLogEntry> additions) {
    if (_changes.isClosed || additions.isEmpty) return;
    final bySequence = {for (final entry in _entries) entry.sequence: entry};
    for (final entry in additions) {
      bySequence[entry.sequence] = entry;
    }
    _entries
      ..clear()
      ..addAll(
        bySequence.values.toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence)),
      );
    if (_entries.length > 1000) _entries.removeRange(0, _entries.length - 1000);
    _changes.add(null);
  }

  Future<void> close() async {
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    await _changes.close();
  }
}
