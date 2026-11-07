import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_logs.dart';
import 'package:ghost_model_deck/jev_debug.dart';

class _Source implements EngineLogSource {
  @override
  final engineLogs = EngineLogBuffer(limit: 3);
}

Future<void> _emit(
  EngineLogBuffer buffer,
  String engine,
  String message,
) async {
  buffer.capture(
    Stream.value(utf8.encode(message)),
    engine: engine,
    instance: 'model-$engine',
    channel: 'stderr',
    redact: (value) => value,
  );
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'chunks preserve UTF-8 and redact complete lines before retaining',
    () async {
      final buffer = EngineLogBuffer();
      addTearDown(buffer.close);
      final bytes = utf8.encode(
        '加载完成\r\nraw private-key authorization: Bearer other-key\n尾行',
      );
      buffer.capture(
        Stream.fromIterable(bytes.map((byte) => [byte])),
        engine: 'Splash',
        instance: 'h2o',
        channel: 'stdout',
        redact: (line) =>
            sealDebugJson({
                  'credentials': [
                    {'api_key': 'private-key'},
                  ],
                  'message': line,
                })['message']
                as String,
      );
      await Future<void>.delayed(Duration.zero);
      expect(buffer.entries.map((entry) => entry.message), [
        '加载完成',
        'raw [redacted] authorization: [redacted]',
        '尾行',
      ]);
      expect(
        buffer.entries.every(
          (entry) => entry.instance == 'h2o' && entry.channel == 'stdout',
        ),
        isTrue,
      );
    },
  );

  test(
    'bounded buffers discard oversized lines whole and ignore late output',
    () async {
      final buffer = EngineLogBuffer(limit: 2);
      final stream = StreamController<List<int>>();
      buffer.capture(
        stream.stream,
        engine: 'llama.cpp',
        instance: 'a',
        channel: 'stderr',
        redact: (line) => line,
      );
      stream.add(utf8.encode('${'x' * 20000}secret\nready\rfinal\n'));
      await Future<void>.delayed(Duration.zero);
      expect(buffer.entries.map((entry) => entry.message), ['ready', 'final']);
      await _emit(buffer, 'llama.cpp', '${'x' * 17000}secret');
      expect(buffer.entries.last.message, '[日志行过长，已省略]');
      await buffer.close();
      stream.add(utf8.encode('late\n'));
      await stream.close();
      expect(buffer.entries.last.message, '[日志行过长，已省略]');
    },
  );

  test(
    'mixed feed orders sources, avoids duplicates and follows new providers',
    () async {
      final a = _Source(), b = _Source();
      final feed = EngineLogFeed();
      addTearDown(() async {
        await feed.close();
        await a.engineLogs.close();
        await b.engineLogs.close();
      });
      await _emit(a.engineLogs, 'Splash', 'a1');
      await _emit(b.engineLogs, 'oMLX', 'b1');
      await _emit(a.engineLogs, 'Splash', 'a2');
      feed.attach([b, a]);
      feed.attach([a, b]);
      expect(feed.entries.map((entry) => entry.message), ['a1', 'b1', 'a2']);
      await _emit(b.engineLogs, 'oMLX', 'b2');
      expect(feed.entries.last.message, 'b2');
      feed.attach([b]);
      await _emit(a.engineLogs, 'Splash', 'detached');
      expect(feed.entries.last.message, 'b2');
      feed.attach([a, b]);
      expect(feed.entries.map((entry) => entry.message), [
        'a1',
        'b1',
        'a2',
        'b2',
        'detached',
      ]);
      for (var i = 0; i < 1005; i++) {
        await _emit(b.engineLogs, 'oMLX', '$i');
      }
      expect(feed.entries.length, 1000);
      expect(feed.entries.first.message, '5');
      expect(feed.entries.last.engine, 'oMLX');
      expect(b.engineLogs.entries.length, 3);
    },
  );
}
