import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'jevman_benchmark.dart';
import 'jevman_runtime.dart';

/// A snapshot from the pinned original game, never a second Dart simulation.
class JevmanViewFrame {
  JevmanViewFrame._(this.index, this.status, this.state);
  factory JevmanViewFrame.parse(Map<String, Object?> value) {
    final index = value['frame'];
    final status = value['status'];
    final state = value['state'];
    final maze = state is Map<String, Object?> ? state['maze'] : null;
    final pacman = state is Map<String, Object?> ? state['pacman'] : null;
    if (index is! int ||
        index < 0 ||
        status is! String ||
        state is! Map<String, Object?> ||
        maze is! List ||
        maze.isEmpty ||
        maze.any((row) => row is! String || row.isEmpty) ||
        pacman is! Map ||
        !const {'up', 'down', 'left', 'right'}.contains(pacman['dir']) ||
        maze.any(
          (row) => (row as String).length != (maze.first as String).length,
        )) {
      throw const FormatException('游戏画面状态无效');
    }
    return JevmanViewFrame._(
      index,
      status,
      Map<String, Object?>.unmodifiable(state),
    );
  }
  final int index;
  final String status;
  final Map<String, Object?> state;
}

/// Owns one inference-free Node Replay, separately from the running benchmark.
class JevmanReplaySession extends ChangeNotifier {
  JevmanReplaySession._(this._process, this.recording) {
    var time = 0.0;
    _times = [0, for (final dt in recording.frames) time += dt];
    _stderr = _process.stderr.transform(utf8.decoder).join();
    _lines = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final decoded = jsonDecode(line);
            if (decoded is! Map<String, Object?> || decoded['id'] is! int) {
              throw const FormatException('回放运行时响应无效');
            }
            _pending.remove(decoded['id'])?.complete(decoded);
          } catch (error, stack) {
            _fail(error, stack);
          }
        }, onError: (Object error, StackTrace stack) => _fail(error, stack));
    unawaited(_watchExit());
  }

  static Future<JevmanReplaySession> open({
    required JevmanRuntime runtime,
    required File bundle,
    required String bundleSha256,
    required JevmanRecording recording,
  }) async {
    final prepared = runtime.prepared;
    if (prepared == null) {
      throw StateError('回放运行时尚未准备');
    }
    for (final entry in {
      bundle.path: bundleSha256,
      prepared.nodePath: JevmanRuntime.nodeSha256,
    }.entries) {
      if (await FileSystemEntity.type(entry.key, followLinks: false) !=
              FileSystemEntityType.file ||
          (await sha256.bind(File(entry.key).openRead()).first).toString() !=
              entry.value) {
        throw const FormatException('回放运行时或桥接摘要不匹配');
      }
    }
    final process = await Process.start(
      prepared.nodePath,
      [bundle.absolute.path, 'view'],
      includeParentEnvironment: false,
      environment: {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );
    final session = JevmanReplaySession._(process, recording);
    try {
      final result = await session._request({
        'type': 'open',
        'recording': recording.toJson(),
      });
      if (result['verdict'] is! Map<String, Object?> ||
          (result['verdict'] as Map)['ok'] is! bool) {
        throw const FormatException('独立重放核对结果无效');
      }
      session.verdict = Map<String, Object?>.unmodifiable(
        result['verdict'] as Map<String, Object?>,
      );
      session._frame = JevmanViewFrame.parse(result);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  final Process _process;
  final JevmanRecording recording;
  late final List<double> _times;
  late final Future<String> _stderr;
  late final StreamSubscription<String> _lines;
  late final Map<String, Object?> verdict;
  late JevmanViewFrame _frame;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  var _id = 0;
  bool _closed = false;
  bool _exited = false;
  Future<void>? _closing;
  Future<void>? get closing => _closing;
  Timer? _timer;
  final _clock = Stopwatch();
  double _baseTime = 0;
  double _speed = 1;
  bool _seeking = false;
  Completer<void>? _activeSeek;
  Future<void> _seekQueue = Future<void>.value();
  String? _error;
  VoidCallback? onClosed;
  JevmanViewFrame get frame => _frame;
  bool get playing => _timer != null;
  double get speed => _speed;
  double get positionSeconds => _times[_frame.index];
  double get durationSeconds => _times.last;
  String? get error => _error;
  int? get activeProcessId => _exited ? null : _process.pid;

  Future<void> _watchExit() async {
    final exit = await _process.exitCode;
    _exited = true;
    final stderr = await _stderr;
    if (!_closed) {
      _fail(
        ProcessException('Node Replay', [], stderr, exit),
        StackTrace.current,
      );
    }
  }

  void _fail(Object error, StackTrace stack) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(error, stack);
      }
    }
    _pending.clear();
    if (!_closed) {
      pause();
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> command) async {
    if (_closed || _exited) {
      throw StateError('回放已关闭');
    }
    final id = ++_id;
    final result = Completer<Map<String, Object?>>();
    _pending[id] = result;
    try {
      _process.stdin.writeln(jsonEncode({...command, 'id': id}));
      return await result.future.timeout(const Duration(seconds: 10));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> seek(int index) async {
    pause();
    final next = _seekQueue.then((_) async {
      await _seek(index);
      // Play can be requested while the explicit seek is in flight. Its next
      // tick must use the committed position, without including seek wait time.
      if (playing && !_closed) {
        _baseTime = positionSeconds;
        _clock
          ..reset()
          ..start();
      }
    });
    _seekQueue = next.then<void>((_) {}, onError: (Object _) {});
    await next;
  }

  Future<void> _seek(int index) async {
    if (index < 0 || index > recording.frames.length) {
      throw RangeError.range(index, 0, recording.frames.length);
    }
    if (_seeking) {
      // Explicit slider seeks wait for the previous runtime command; timer
      // ticks skip while busy and never queue a backlog of old playback frames.
      await _activeSeek!.future;
    }
    _seeking = true;
    final done = Completer<void>();
    _activeSeek = done;
    try {
      final response = await _request({'type': 'seek', 'frame': index});
      if (_closed) {
        return;
      }
      if (response['frame'] != index) {
        throw const FormatException('回放运行时返回了错误的定位帧');
      }
      _frame = JevmanViewFrame.parse(response);
      notifyListeners();
    } catch (error) {
      if (!_closed) {
        pause();
        _error = error.toString();
        notifyListeners();
      }
      rethrow;
    } finally {
      _seeking = false;
      _activeSeek = null;
      done.complete();
    }
  }

  void setSpeed(double speed) {
    if (!const [0.25, 0.5, 1.0, 2.0, 4.0].contains(speed)) {
      throw ArgumentError.value(speed);
    }
    final resume = playing;
    pause();
    _speed = speed;
    if (resume) {
      play();
    }
    notifyListeners();
  }

  void play() {
    if (_closed ||
        playing ||
        _error != null ||
        _frame.index == recording.frames.length) {
      return;
    }
    _baseTime = positionSeconds;
    _clock
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_seeking) {
        return;
      }
      final target = _baseTime + _clock.elapsedMicroseconds / 1000000 * _speed;
      var low = 0;
      var high = _times.length - 1;
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (_times[mid] <= target) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      if (low != _frame.index) {
        unawaited(
          _seek(low).then((_) {
            if (_frame.index == recording.frames.length) {
              pause();
            }
          }, onError: (Object _) {}),
        );
      }
    });
    notifyListeners();
  }

  void pause() {
    final wasPlaying = playing;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    if (wasPlaying && !_closed) {
      notifyListeners();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    pause();
    _fail(StateError('回放已关闭'), StackTrace.current);
    await _process.stdin.close();
    if (!_exited) {
      _process.kill(ProcessSignal.sigterm);
    }
    await _process.exitCode;
    _exited = true;
    await _lines.cancel();
    await _stderr;
    onClosed?.call();
    super.dispose();
  }
}
