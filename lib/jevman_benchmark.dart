import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'jevman_runtime.dart';
import 'jev_playground.dart';

/// The game runtime IPC owns its Node child. Replay has no model client and can
/// therefore never perform inference while checking an original recording.
class JevmanGameBridge {
  JevmanGameBridge({
    required this.runtime,
    required this.bundle,
    required this.bundleSha256,
  });

  final JevmanRuntime runtime;
  final File bundle;
  final String bundleSha256;
  Process? _process;
  Completer<void>? _operation;
  Future<void>? _closing;
  DecisionCancellation? _playCancellation;
  String _cancellationStatus = 'cancelled';
  final _changes = StreamController<Map<String, Object?>>.broadcast();
  Map<String, Object?>? _latestFrame;
  Map<String, Object?>? _activeTarget;
  int? get activeProcessId => _process?.pid;
  Stream<Map<String, Object?>> get changes => _changes.stream;
  Map<String, Object?>? get latestFrame => _latestFrame;
  Map<String, Object?>? get activeTarget => _activeTarget;

  /// Exactly 100 original real-time games. The application supplies its existing
  /// metadata-only source lock; every decision still traverses a public client.
  Future<Map<String, Object?>> play({
    required JevPlayground client,
    required String model,
    required DecisionCancellation cancellation,
    required bool Function() isCurrent,
    JevPlaygroundMode channel = JevPlaygroundMode.http,
    FutureOr<void> Function(Map<String, Object?> game)? onGameCommitted,
  }) async {
    if (_closing != null) throw StateError('Game bridge is closed');
    if (_operation != null) throw StateError('Game bridge is active');
    final operation = Completer<void>();
    _operation = operation;
    _activeTarget = Map<String, Object?>.unmodifiable({
      'model': model,
      'channel': channel.name,
    });
    _changes.add({'type': 'started', ..._activeTarget!});
    final token = DecisionCancellation();
    _playCancellation = token;
    _cancellationStatus = 'cancelled';
    final unlink = cancellation.listen(token.cancel);
    final evidence = <Map<String, Object?>>[];
    final requests = <Future<void>>{};
    final gameRequests = <int, List<Future<void>>>{};
    var commits = Future<void>.value();
    Object? commitError;
    StackTrace? commitStack;
    Map<String, Object?>? result;
    var observedStatus = 'failed';
    Process? process;
    StreamSubscription<String>? lines;
    var exited = false;
    final readDone = Completer<void>();
    void send(Map<String, Object?> message) {
      if (exited || process == null) return;
      process.stdin.writeln(jsonEncode(message));
    }

    final cancelChild = token.listen(() {
      send({'type': 'cancel', 'status': _cancellationStatus});
    });
    void invalidTarget() {
      _cancellationStatus = 'targetUnavailable';
      token.cancel();
    }

    Future<void> answer(Map<String, Object?> message) async {
      final id = message['id'];
      final phase = message['phase'];
      final body = message['body'];
      if (id is! int ||
          (phase != 'warmup' && phase != 'game') ||
          body is! Map<String, Object?> ||
          body['questions'] is! Map<String, Object?>) {
        throw const FormatException('Malformed original game request');
      }
      final timeout = Duration(seconds: phase == 'warmup' ? 30 : 2);
      if (message['timeoutMs'] != timeout.inMilliseconds) {
        throw const FormatException('Original game deadline mismatch');
      }
      final call = DecisionCancellation();
      final remove = token.listen(call.cancel);
      final watch = Stopwatch()..start();
      final deadline = Timer(timeout, call.cancel);
      final document = <String, Object?>{
        'model': model,
        'state': body['state'],
        'questions': body['questions'],
      };
      final row = <String, Object?>{
        'id': id,
        'phase': phase,
        'game': message['game'],
        'channel': channel.name,
        'request': document,
      };
      evidence.add(row);
      try {
        if (!isCurrent()) invalidTarget();
        if (token.isCancelled) return;
        final discovery = await client.discover(channel, cancellation: call);
        if (!client
            .modelsFromDiscovery(discovery)
            .any((entry) => entry.id == model)) {
          invalidTarget();
          return;
        }
        if (!isCurrent()) invalidTarget();
        if (token.isCancelled) return;
        final remaining = timeout - watch.elapsed;
        if (remaining <= Duration.zero || call.isCancelled) {
          send({'id': id, 'status': 504, 'error': 'endpoint timed out'});
          row['status'] = 'timedOut';
          return;
        }
        final reply = await client.run(
          channel,
          jsonEncode(document),
          cancellation: call,
          timeout: remaining,
          validateBeforeSend: false,
        );
        row['result'] = reply.toJson();
        row['elapsed_us'] = watch.elapsedMicroseconds;
        if (!isCurrent()) invalidTarget();
        if (token.isCancelled) return;
        send({
          'id': id,
          'status': reply.status == JevPlaygroundStatus.success
              ? 200
              : reply.status == JevPlaygroundStatus.timedOut || call.isCancelled
              ? 504
              : (reply.httpStatus ?? 0) >= 400
              ? reply.httpStatus!
              : 502,
          'output': reply.output,
          'error': reply.status == JevPlaygroundStatus.success
              ? null
              : reply.message,
          'elapsedMs': watch.elapsedMicroseconds / 1000,
        });
      } catch (error) {
        row['error'] = error.toString();
        row['elapsed_us'] = watch.elapsedMicroseconds;
        if (!token.isCancelled) {
          send({
            'id': id,
            'status': call.isCancelled ? 504 : 502,
            'error': call.isCancelled ? 'endpoint timed out' : error.toString(),
          });
        }
      } finally {
        row['elapsed_us'] ??= watch.elapsedMicroseconds;
        if (!row.containsKey('result') &&
            !row.containsKey('error') &&
            !row.containsKey('status')) {
          row['status'] = token.isCancelled ? _cancellationStatus : 'failed';
        }
        deadline.cancel();
        remove();
      }
    }

    try {
      if (token.isCancelled) {
        observedStatus = 'cancelled';
        return _emptyResult(model, channel, 'cancelled');
      }
      process = await _start('play');
      _process = process;
      final stderr = process.stderr.transform(utf8.decoder).join();
      lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              try {
                final value = jsonDecode(line);
                if (value is! Map<String, Object?> ||
                    value['type'] is! String) {
                  throw const FormatException('Malformed Jevman runtime event');
                }
                if (value['type'] == 'request') {
                  late Future<void> pending;
                  pending = answer(value)
                      .catchError((Object error) {
                        _cancellationStatus = 'failed';
                        token.cancel();
                      })
                      .whenComplete(() => requests.remove(pending));
                  requests.add(pending);
                  final gameIndex = value['game'];
                  if (gameIndex is int) {
                    gameRequests.putIfAbsent(gameIndex, () => []).add(pending);
                  }
                } else if (value['type'] == 'game') {
                  final game = value['game'];
                  if (game is! Map<String, Object?> || game['index'] is! int) {
                    throw const FormatException(
                      'Malformed original game commit',
                    );
                  }
                  final index = game['index'] as int;
                  // Copy this game's outstanding calls now. Later games can keep
                  // running without joining this immutable persistence boundary.
                  final pending = List<Future<void>>.of(
                    gameRequests[index] ?? [],
                  );
                  commits = commits
                      .then((_) async {
                        await Future.wait(pending);
                        final committed = JevmanRecording._seal({
                          ...game,
                          'calls': [
                            for (final row in evidence)
                              if (row['phase'] == 'game' &&
                                  row['game'] == index)
                                row,
                          ],
                        }) as Map<String, Object?>;
                        _changes.add({
                          'type': 'game',
                          'game': committed,
                          'model': model,
                          'channel': channel.name,
                        });
                        if (onGameCommitted != null) {
                          await onGameCommitted(committed);
                        }
                      })
                      .catchError((Object error, StackTrace stack) {
                        commitError ??= error;
                        commitStack ??= stack;
                        _cancellationStatus = 'failed';
                        token.cancel();
                      });
                } else if (value['type'] == 'result') {
                  if (value['result'] is! Map<String, Object?>) {
                    throw const FormatException(
                      'Malformed Jevman runtime result',
                    );
                  }
                  result = value['result'] as Map<String, Object?>;
                } else {
                  final sealed = JevmanRecording._seal({
                    ...value,
                    'model': model,
                    'channel': channel.name,
                  }) as Map<String, Object?>;
                  if (value['type'] == 'frame') _latestFrame = sealed;
                  _changes.add(sealed);
                }
              } catch (error) {
                _cancellationStatus = 'failed';
                token.cancel();
                if (!readDone.isCompleted) readDone.completeError(error);
              }
            },
            onError: (Object error) {
              token.cancel();
              if (!readDone.isCompleted) readDone.completeError(error);
            },
            onDone: () {
              if (!readDone.isCompleted) readDone.complete();
            },
          );
      // A start line always precedes cancellation so the child can seal even a
      // cancellation accepted during process admission and before warmup.
      send({'type': 'start', 'model': model});
      if (token.isCancelled || _closing != null) {
        token.cancel();
        send({'type': 'cancel', 'status': _cancellationStatus});
      }
      final exit = await process.exitCode;
      exited = true;
      await readDone.future;
      await Future.wait(requests.toList());
      await commits;
      if (commitError != null) {
        Error.throwWithStackTrace(commitError!, commitStack!);
      }
      final errors = await stderr;
      if (exit != 0 || result == null) {
        throw ProcessException(
          runtime.prepared!.nodePath,
          ['play'],
          errors,
          exit,
        );
      }
      final value = result!;
      final games = value['games'];
      if (games is! List ||
          value['expectedGames'] != 100 ||
          value['complete'] is! bool) {
        throw const FormatException('Malformed complete-game scale');
      }
      for (final game in games) {
        if (game is! Map<String, Object?>) {
          throw const FormatException('Malformed game result');
        }
        JevmanRecording.parse(game['recording']);
      }
      if (value['complete'] == true &&
          (games.length != 100 || value['status'] != 'completed')) {
        throw const FormatException('Incomplete game run claimed completion');
      }
      if (token.isCancelled && value['complete'] == true) {
        value['status'] = _cancellationStatus;
        value['complete'] = false;
        value['summary'] = null;
        value['originalSummary'] = null;
      }
      observedStatus = value['status'] as String;
      return JevmanRecording._seal({
        ...value,
        'model': model,
        'channel': channel.name,
        'calls': evidence,
      }) as Map<String, Object?>;
    } finally {
      token.cancel();
      if (process != null) {
        if (!exited) process.kill(ProcessSignal.sigterm);
        await process.exitCode;
      }
      await lines?.cancel();
      await Future.wait(requests.toList());
      await commits;
      cancelChild();
      unlink();
      _playCancellation = null;
      _process = null;
      _latestFrame = null;
      _activeTarget = null;
      _changes.add({
        'type': 'ended',
        'model': model,
        'channel': channel.name,
        'status': observedStatus,
      });
      _operation = null;
      operation.complete();
    }
  }

  Map<String, Object?> _emptyResult(
    String model,
    JevPlaygroundMode channel,
    String status,
  ) => JevmanRecording._seal({
    'status': status,
    'complete': false,
    'expectedGames': 100,
    'model': model,
    'channel': channel.name,
    'games': <Object?>[],
    'summary': null,
    'originalSummary': null,
    'calls': <Object?>[],
  }) as Map<String, Object?>;

  Future<Process> _start(String mode) async {
    final prepared = runtime.prepared;
    if (prepared == null) throw StateError('Node runtime is not prepared');
    for (final entry in {
      bundle.path: bundleSha256,
      prepared.nodePath: JevmanRuntime.nodeSha256,
    }.entries) {
      if (await FileSystemEntity.type(entry.key, followLinks: false) !=
              FileSystemEntityType.file ||
          (await sha256.bind(File(entry.key).openRead()).first).toString() !=
              entry.value) {
        throw const FormatException('Jevman executable SHA256 mismatch');
      }
    }
    if (_closing != null) throw StateError('Game bridge is closing');
    return Process.start(
      prepared.nodePath,
      [bundle.absolute.path, mode],
      includeParentEnvironment: false,
      environment: {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );
  }

  Future<Map<String, Object?>> replay(JevmanRecording recording) async {
    if (_closing != null) throw StateError('Game bridge is closed');
    if (_operation != null) throw StateError('Game bridge is active');
    final operation = Completer<void>();
    _operation = operation;
    Process? process;
    var exited = false;
    try {
      final prepared = runtime.prepared;
      if (prepared == null) throw StateError('Node runtime is not prepared');
      for (final entry in {
        bundle.path: bundleSha256,
        prepared.nodePath: JevmanRuntime.nodeSha256,
      }.entries) {
        if (await FileSystemEntity.type(entry.key, followLinks: false) !=
                FileSystemEntityType.file ||
            (await sha256.bind(File(entry.key).openRead()).first).toString() !=
                entry.value) {
          throw const FormatException('Jevman executable SHA256 mismatch');
        }
      }
      if (_closing != null) throw StateError('Game bridge is closing');
      process = await Process.start(
        prepared.nodePath,
        [bundle.absolute.path, 'replay'],
        includeParentEnvironment: false,
        environment: {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
      );
      _process = process;
      if (_closing != null) process.kill(ProcessSignal.sigterm);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(jsonEncode({'recording': recording.toJson()}));
      await process.stdin.close();
      final exit = await process.exitCode;
      exited = true;
      final output = await stdout;
      final errors = await stderr;
      if (exit != 0) {
        throw ProcessException(prepared.nodePath, ['replay'], errors, exit);
      }
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, Object?> || decoded['ok'] is! bool) {
        throw const FormatException('Malformed original replay verdict');
      }
      return JevmanRecording._seal(decoded) as Map<String, Object?>;
    } finally {
      if (process != null) {
        if (!exited) process.kill(ProcessSignal.sigterm);
        await process.exitCode;
      }
      _process = null;
      _operation = null;
      operation.complete();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_playCancellation != null) {
      _cancellationStatus = 'interrupted';
      _playCancellation?.cancel();
    } else {
      _process?.kill(ProcessSignal.sigterm);
    }
    await _operation?.future;
    await _changes.close();
  }
}

/// The original version-one trace. Full-game validity is independently checked
/// by the pinned upstream verifier; parsing alone never establishes completion.
class JevmanRecording {
  JevmanRecording._(this._document, this.frames, this.finalScore);

  factory JevmanRecording.parse(Object? value) {
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const FormatException('Jevman recording must have version 1');
    }
    final frames = value['frames'];
    final decisions = value['decisions'];
    final events = value['events'];
    final terminal = value['final'];
    if (value['recordedAt'] is! String ||
        DateTime.tryParse(value['recordedAt'] as String) == null ||
        value['model'] is! String ||
        frames is! List ||
        decisions is! List ||
        events is! List ||
        terminal is! Map<String, Object?>) {
      throw const FormatException('Malformed Jevman recording');
    }
    final timing = <double>[];
    for (final step in frames) {
      if (step is! num || !step.isFinite || step < 0.001 || step > 0.05) {
        throw const FormatException('Invalid original game frame duration');
      }
      timing.add(step.toDouble());
    }
    for (final move in decisions) {
      if (move is! List ||
          move.length < 3 ||
          move.length > 4 ||
          move[0] is! int ||
          (move[0] as int) < 0 ||
          (move[0] as int) >= timing.length ||
          move[1] is! String ||
          !const {'up', 'down', 'left', 'right'}.contains(move[2]) ||
          (move.length == 4 && move[3] is! String)) {
        throw const FormatException('Invalid original game direction');
      }
    }
    for (final event in events) {
      if (event is! List ||
          event.length != 2 ||
          event[0] is! int ||
          (event[0] as int) < 0 ||
          (event[0] as int) > timing.length ||
          event[1] is! Map ||
          (event[1] as Map)['type'] is! String) {
        throw const FormatException('Malformed original scheduler event');
      }
    }
    for (final key in ['score', 'lives', 'level', 'frames']) {
      if (terminal[key] is! int || (terminal[key] as int) < 0) {
        throw const FormatException('Malformed original terminal state');
      }
    }
    if (terminal['frames'] != timing.length || (terminal['level'] as int) < 1) {
      throw const FormatException('Original terminal frame count mismatch');
    }
    // JSON round-trip validates the remaining extension fields at the I/O
    // boundary, then recursively seals them without normalizing task content.
    final copy = _seal(jsonDecode(jsonEncode(value))) as Map<String, Object?>;
    return JevmanRecording._(
      copy,
      List<double>.unmodifiable(timing),
      terminal['score'] as int,
    );
  }

  final Map<String, Object?> _document;
  final List<double> frames;
  final int finalScore;
  Map<String, Object?> toJson() => _document;

  static Object? _seal(Object? value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries) entry.key: _seal(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_seal));
    }
    return value;
  }
}
