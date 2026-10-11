import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'benchmark_game_work.dart';
import 'jevman_benchmark.dart';
import 'jevman_viewing.dart';

/// Observes the app-owned game, or owns one read-only historical Replay.
class JevmanViewer extends StatefulWidget {
  const JevmanViewer({
    super.key,
    required this.work,
    this.recording,
    this.identity,
    this.complete = false,
    this.gameIndex,
  });
  final BenchmarkGameWork work;
  final Object? recording;
  final Map<String, Object?>? identity;
  final bool complete;
  final int? gameIndex;
  @override
  State<JevmanViewer> createState() => _JevmanViewerState();
}

class _JevmanViewerState extends State<JevmanViewer> {
  StreamSubscription<Map<String, Object?>>? _events;
  JevmanReplaySession? _replay;
  JevmanViewFrame? _frame;
  String? _error;
  int? _game;
  Map<String, Object?>? _target;
  String? _ended;
  String? _gameEnded;
  bool _loading = false;
  bool get _historical => widget.identity != null;

  @override
  void initState() {
    super.initState();
    if (_historical) {
      _loading = true;
      unawaited(_open());
    } else {
      _target = widget.work.activeTarget;
      _observe(widget.work.latestFrame);
      _events = widget.work.changes.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          if (event['type'] == 'started') {
            _target = Map<String, Object?>.unmodifiable({
              'model': event['model'],
              'channel': event['channel'],
            });
            _frame = null;
            _game = null;
            _ended = null;
            _gameEnded = null;
          } else if (event['type'] == 'frame') {
            _observe(event);
          } else if (event['model'] == _target?['model'] &&
              event['channel'] == _target?['channel']) {
            if (event['type'] == 'ended') {
              _ended = event['status'] as String;
            } else if (event['type'] == 'game') {
              final game = event['game'];
              if (game is Map && game['index'] == _game) {
                _gameEnded = game['complete'] == true
                    ? '本局已结束 · 完整局'
                    : '本局已结束 · 部分录像';
              }
            }
          }
        });
      });
    }
  }

  void _observe(Map<String, Object?>? value) {
    if (value == null) {
      return;
    }
    try {
      _frame = JevmanViewFrame.parse(value);
      final game = value['game'];
      if (game is! int ||
          value['model'] is! String ||
          value['channel'] is! String) {
        throw const FormatException('当前参赛对象或局号无效');
      }
      _game = game;
      _target = Map<String, Object?>.unmodifiable({
        'model': value['model'],
        'channel': value['channel'],
      });
      _ended = null;
      _gameEnded = null;
    } catch (error) {
      _error = error.toString();
    }
  }

  Future<void> _open() async {
    try {
      if (widget.recording == null) {
        throw const FormatException('该局录像缺失');
      }
      final recording = JevmanRecording.parse(widget.recording);
      final replay = await widget.work.openReplay(
        recording,
        identity: widget.identity!,
      );
      if (!mounted) {
        await replay.close();
        return;
      }
      _replay = replay;
      replay.addListener(_changed);
      setState(() {
        _frame = replay.frame;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {
        _frame = _replay!.frame;
        _error = _replay!.error;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    final replay = _replay;
    if (replay != null) {
      replay.removeListener(_changed);
      unawaited(
        replay.close().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              context: ErrorDescription('关闭本次 Jevman 观看资源'),
            ),
          );
        }),
      );
    }
    super.dispose();
  }

  Future<void> _seek(int frame) async {
    try {
      await _replay!.seek(frame);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final replay = _replay;
    final frame = _frame;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _historical
                ? '第 ${widget.gameIndex} 局 · 历史录像'
                : '第 ${_game ?? "—"} 局 · 实时观战',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (!_historical && _target != null)
            Text(
              '实际参赛对象：${_target!['model']} · ${(_target!['channel'] as String).toUpperCase()}',
              key: const Key('jevman-live-target'),
            ),
          if (!_historical && _gameEnded != null)
            Text(_gameEnded!, key: const Key('jevman-live-game-ended')),
          if (!_historical && _ended != null)
            Text(switch (_ended) {
              'completed' => '评测已完成 · 完整100局',
              'cancelled' => '评测已取消 · 未完成 · 部分录像',
              'interrupted' => '评测已中断 · 未完成 · 部分录像',
              'targetUnavailable' => '评测对象不可用 · 未完成 · 部分录像',
              _ => '评测已失败 · 未完成 · 部分录像',
            }, key: const Key('jevman-live-ended')),
          Text(
            _historical
                ? '${widget.complete ? "原记录：完整局" : "部分录像 / 中断局"} · 仅重放已记录动作，不调用模型。'
                : '只观察当前实际游戏；关闭观看或离页后，后台评测继续。',
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text('观看失败：$_error', key: const Key('jevman-view-error')),
          if (replay != null)
            Text(
              replay.verdict['ok'] == true
                  ? '独立重放核对一致 · 原游戏 verifyGame 重算成绩与终局'
                  : '独立重放核对失败：${replay.verdict['error']}',
              key: const Key('jevman-replay-verdict'),
            ),
          if (replay?.verdict['result'] case final Map result)
            Text(
              '原轨迹重算：决策 ${result['decisions']} · fallback ${result['fallbacks']} · 模型调用 ${result['calls']} · 延迟总计 ${result['latencyMsSum']} ms（fallback 不计作模型回答）',
            ),
          if (frame == null && !_loading && _error == null)
            const Text('等待当前游戏实际帧；观战不会启动新游戏。'),
          if (frame != null) ...[
            Text(
              '帧 ${frame.index} · 分数 ${frame.state['score']} · 生命 ${frame.state['lives']} · 关卡 ${frame.state['level']} · ${_ended != null || _gameEnded != null ? "最后轨迹状态 " : ""}${frame.status}',
              key: const Key('jevman-view-score'),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: AspectRatio(
                  aspectRatio:
                      ((frame.state['maze'] as List).first as String).length /
                      (frame.state['maze'] as List).length,
                  child: CustomPaint(
                    key: const Key('jevman-maze'),
                    painter: _MazePainter(
                      (frame.state['maze'] as List).cast<String>(),
                      (frame.state['pacman'] as Map)['dir'] as String,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (replay != null) ...[
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  key: const Key('jevman-replay-play'),
                  tooltip: replay.playing ? '暂停回放' : '播放回放',
                  onPressed: replay.playing ? replay.pause : replay.play,
                  icon: Icon(replay.playing ? Icons.pause : Icons.play_arrow),
                ),
                TextButton(
                  onPressed: () => _seek(0),
                  child: const Text('回到开头'),
                ),
                DropdownButton<double>(
                  key: const Key('jevman-replay-speed'),
                  value: replay.speed,
                  items: [
                    for (final speed in const [0.25, 0.5, 1.0, 2.0, 4.0])
                      DropdownMenuItem(value: speed, child: Text('$speed×')),
                  ],
                  onChanged: (speed) {
                    if (speed != null) {
                      replay.setSpeed(speed);
                    }
                  },
                ),
                Text(
                  '${replay.positionSeconds.toStringAsFixed(2)} / ${replay.durationSeconds.toStringAsFixed(2)} 秒 · 原逐帧时间',
                ),
              ],
            ),
            Slider(
              key: const Key('jevman-replay-position'),
              value: replay.frame.index.toDouble(),
              min: 0,
              max: math.max(1, replay.recording.frames.length).toDouble(),
              onChanged: (value) => _seek(value.round()),
            ),
            ExpansionTile(
              title: const Text('该帧原调度事件 / 模型与 fallback'),
              children: [
                for (final event in replay.recording.toJson()['events'] as List)
                  if ((event as List)[0] == replay.frame.index ||
                      event[0] == replay.frame.index - 1)
                    Text('${event[1]}'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MazePainter extends CustomPainter {
  _MazePainter(this.rows, this.direction);
  final List<String> rows;
  final String direction;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff101020),
    );
    final cell = math.min(
      size.width / rows.first.length,
      size.height / rows.length,
    );
    const ghosts = {
      'B': Colors.red,
      'K': Colors.pink,
      'I': Colors.cyan,
      'C': Colors.orange,
    };
    for (var y = 0; y < rows.length; y++) {
      for (var x = 0; x < rows[y].length; x++) {
        final symbol = rows[y][x];
        final center = Offset((x + .5) * cell, (y + .5) * cell);
        if (symbol == '#') {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x * cell + 1, y * cell + 1, cell - 2, cell - 2),
              Radius.circular(cell / 5),
            ),
            Paint()..color = const Color(0xff3156be),
          );
        } else if (symbol == '.' || symbol == 'o') {
          canvas.drawCircle(
            center,
            cell * (symbol == 'o' ? .24 : .09),
            Paint()..color = const Color(0xffffdcad),
          );
        } else if (symbol == 'P') {
          final angle = switch (direction) {
            'up' => -math.pi / 2,
            'down' => math.pi / 2,
            'left' => math.pi,
            _ => 0.0,
          };
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: cell * .42),
            angle + .35,
            math.pi * 2 - .7,
            true,
            Paint()..color = Colors.yellow,
          );
        } else if (ghosts.containsKey(symbol.toUpperCase()) || symbol == 'e') {
          final color = symbol == 'e'
              ? Colors.white
              : symbol == symbol.toLowerCase()
              ? Colors.blueAccent
              : ghosts[symbol]!;
          canvas.drawCircle(center, cell * .4, Paint()..color = color);
          canvas.drawCircle(
            center.translate(-cell * .12, -cell * .05),
            cell * .06,
            Paint()..color = Colors.black,
          );
          canvas.drawCircle(
            center.translate(cell * .12, -cell * .05),
            cell * .06,
            Paint()..color = Colors.black,
          );
        } else if (symbol == 'F') {
          canvas.drawCircle(
            center,
            cell * .28,
            Paint()..color = Colors.redAccent,
          );
        } else if (symbol == '-') {
          canvas.drawLine(
            center.translate(-cell / 2, 0),
            center.translate(cell / 2, 0),
            Paint()
              ..color = Colors.pinkAccent
              ..strokeWidth = 2,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MazePainter oldDelegate) =>
      !identical(rows, oldDelegate.rows);
}
