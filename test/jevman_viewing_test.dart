import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:ghost_model_deck/benchmark_game_work.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/jevman_benchmark.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';
import 'package:ghost_model_deck/jevman_viewer.dart';
import 'package:ghost_model_deck/benchmark_page.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pending replay seek establishes the playback position before play resumes', () async {
    final root = await Directory.systemTemp.createTemp('gmd-replay-seek-play-');
    addTearDown(() => root.delete(recursive: true));
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
    );
    final installation = Directory(
      '${root.path}/node/${JevmanRuntime.archiveRoot}',
    );
    await Directory('${installation.path}/bin').create(recursive: true);
    await File('${original.path}/bin/node')
        .copy('${installation.path}/bin/node');
    await File('${original.path}/LICENSE').copy('${installation.path}/LICENSE');
    expect(
      (await Process.run('/bin/chmod', [
        '700',
        '${installation.path}/bin/node',
      ])).exitCode,
      0,
    );
    final work = BenchmarkGameWork(
      root,
      loadAsset: (path) async =>
          ByteData.sublistView(await File(path).readAsBytes()),
    );
    addTearDown(work.close);
    await work.prepare(DecisionCancellation());
    final recording = JevmanRecording.parse(
      jsonDecode(
        await File('benchmarks/sources/jevman/public/demo/kev-4b-demo.json')
            .readAsString(),
      ),
    );
    final view = await work.openReplay(recording, identity: work.identity);
    addTearDown(view.close);
    expect(view.frame.index, 0);
    const target = 2000;
    expect(recording.frames.length, greaterThan(target));
    // The published trace's target is over 30 seconds into the recording.
    // A next frame within the unchanged 5-second observation cannot reach it
    // from the old zero anchor merely through wall time.
    expect(
      recording.frames.take(target).fold<double>(0, (sum, dt) => sum + dt),
      greaterThan(30),
    );
    // Queueing seek is asynchronous. Calling play synchronously here is the
    // exact public ordering; no process delay or substitute simulator is used.
    final seeking = view.seek(target);
    view.play();
    await seeking.timeout(const Duration(seconds: 5));
    expect(view.frame.index, target);
    final resumed = Completer<int>();
    void nextFrame() {
      if (!resumed.isCompleted) {
        resumed.complete(view.frame.index);
      }
    }

    view.addListener(nextFrame);
    late int index;
    try {
      index = await resumed.future.timeout(const Duration(seconds: 5));
    } finally {
      view.removeListener(nextFrame);
      view.pause();
    }
    expect(
      index,
      greaterThanOrEqualTo(target),
      reason: 'Play requested during a pending seek must continue from that seek, without jumping back to the previous zero anchor.',
    );
  });
  testWidgets(
    'live viewer reattaches the same actual game and departure does not stop its public HTTP work',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkGameWork work;
      late Future<BenchmarkRun> game;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        final root = Directory('${fixture.runtime.root.path}/view-live');
        final original = Directory(
          '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
        );
        final installation = Directory(
          '${root.path}/node/${JevmanRuntime.archiveRoot}',
        );
        await Directory('${installation.path}/bin').create(recursive: true);
        await File('${original.path}/bin/node')
            .copy('${installation.path}/bin/node');
        await File('${original.path}/LICENSE')
            .copy('${installation.path}/LICENSE');
        expect(
          (await Process.run('/bin/chmod', [
            '700',
            '${installation.path}/bin/node',
          ])).exitCode,
          0,
        );
        work = BenchmarkGameWork(
          root,
          loadAsset: (path) async =>
              ByteData.sublistView(await File(path).readAsBytes()),
        );
        await work.prepare(DecisionCancellation());
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${root.path}/history'),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${root.path}/question-cache'),
        );
        final first = work.changes.firstWhere(
          (event) => event['type'] == 'frame' && (event['frame'] as int) >= 3,
        );
        // Complete fixed plan, explicitly cancelled after finite lifecycle
        // observations; this fixture is not real model benchmark acceptance.
        game = runner.runJevman(
          work: work,
          modelNames: ['native-kev', 'quick'],
        );
        await first.timeout(const Duration(seconds: 5));
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await work.waitForViewersClosed();
          runner.cancel();
          await game;
          await runner.close();
          await work.close();
          await resources.close();
          await fixture.close();
        });
      });
      final pid = work.activeProcessId;
      expect(pid, isNotNull);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: JevmanViewer(work: work)),
          ),
        );
      });
      await tester.pump();
      expect(find.byKey(const Key('jevman-maze')), findsOneWidget);
      expect(find.text('第 1 局 · 实时观战'), findsOneWidget);
      expect(find.byKey(const Key('jevman-replay-play')), findsNothing);
      final previousFrame = work.latestFrame!['frame'] as int;
      await tester.runAsync(() async {
        final progressed = work.changes.firstWhere(
          (event) =>
              event['type'] == 'frame' &&
              (event['frame'] as int) > previousFrame,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await progressed.timeout(const Duration(seconds: 5));
        expect(work.activeProcessId, pid);
        expect(work.activeViewerProcessIds, isEmpty);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: JevmanViewer(work: work)),
          ),
        );
      });
      await tester.pump();
      expect(find.byKey(const Key('jevman-maze')), findsOneWidget);
      expect(work.activeProcessId, pid);
      expect(work.latestFrame!['frame'] as int, greaterThan(previousFrame));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(
                resources: resources,
                runner: runner,
                gameWork: work,
              ),
            ),
          ),
        );
        await _waitFor(tester, find.byKey(const Key('benchmark-result-1')));
        // Await actual public discovery before dismantling the page later;
        // a history/current snapshot can appear before that request completes.
        await _waitFor(
          tester,
          find.byKey(const Key('benchmark-select-native-kev')),
        );
      });
      await tester.ensureVisible(find.byKey(const Key('benchmark-result-1')));
      await tester.tap(find.byKey(const Key('benchmark-result-1')));
      await tester.pump();
      expect(
        find.byKey(const Key('benchmark-game-watch')),
        findsNothing,
        reason: 'A queued second object cannot watch the first object under its own report.',
      );
      await tester.ensureVisible(find.byKey(const Key('benchmark-result-0')));
      await tester.tap(find.byKey(const Key('benchmark-result-0')));
      await tester.pump();
      expect(find.byKey(const Key('benchmark-game-watch')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('benchmark-game-watch')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-game-watch')));
        await _waitFor(tester, find.byKey(const Key('jevman-live-target')));
      });
      expect(find.text('实际参赛对象：native-kev · HTTP'), findsOneWidget);
      await tester.runAsync(() async {
        runner.cancel();
        final terminal = await game;
        expect(terminal.summary['complete'], isFalse);
        expect(terminal.status, BenchmarkRunStatus.cancelled);
        expect(terminal.evaluations.first.items, hasLength(1));
        await _waitFor(tester, find.byKey(const Key('jevman-live-ended')));
      });
      expect(find.textContaining('评测已取消'), findsOneWidget);
      expect(find.textContaining('部分录像'), findsWidgets);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('关闭观看'));
        await tester.pump();
      });
      await tester.runAsync(() async {
        final terminal = runner.current!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(
                resources: resources,
                runner: runner,
                gameWork: work,
              ),
            ),
          ),
        );
        await _waitFor(
          tester,
          find.byKey(Key('benchmark-history-${terminal.id}')),
        );
      });
      final id = runner.current!.id;
      await tester.ensureVisible(find.byKey(Key('benchmark-history-$id')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-$id')));
        await tester.pump();
        await _waitFor(tester, find.byKey(const Key('benchmark-detail-items')));
      });
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-items')),
      );
      final gameId =
          runner.current!.evaluations.first.items.single['id'] as String;
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-detail-items')));
        await _waitFor(tester, find.byKey(Key('benchmark-item-$gameId')));
      });
      await tester.ensureVisible(find.byKey(Key('benchmark-item-$gameId')));
      await tester.tap(find.byKey(Key('benchmark-item-$gameId')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(Key('benchmark-game-replay-$gameId')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-game-replay-$gameId')));
        await _waitFor(tester, find.byKey(const Key('jevman-replay-verdict')));
      });
      expect(find.textContaining('部分录像 / 中断局'), findsOneWidget);
      expect(find.byKey(const Key('jevman-maze')), findsOneWidget);
      expect(find.textContaining('独立重放核对失败'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('关闭观看'));
        await tester.pump();
        await work.waitForViewersClosed();
      });
      expect(work.activeViewerProcessIds, isEmpty);
      expect(runner.current!.id, id);
      expect(runner.current!.status, BenchmarkRunStatus.cancelled);
    },
  );
  testWidgets(
    'historical viewer exposes original replay controls and releases its session on departure',
    (tester) async {
      late BenchmarkGameWork work;
      late JevmanRecording recording;
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd-viewer-widget-');
        final original = Directory(
          '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
        );
        final installation = Directory(
          '${root.path}/node/${JevmanRuntime.archiveRoot}',
        );
        await Directory('${installation.path}/bin').create(recursive: true);
        await File('${original.path}/bin/node')
            .copy('${installation.path}/bin/node');
        await File('${original.path}/LICENSE')
            .copy('${installation.path}/LICENSE');
        expect(
          (await Process.run('/bin/chmod', [
            '700',
            '${installation.path}/bin/node',
          ])).exitCode,
          0,
        );
        work = BenchmarkGameWork(
          root,
          loadAsset: (path) async =>
              ByteData.sublistView(await File(path).readAsBytes()),
        );
        await work.prepare(DecisionCancellation());
        recording = JevmanRecording.parse(
          jsonDecode(
            await File('benchmarks/sources/jevman/public/demo/kev-4b-demo.json')
                .readAsString(),
          ),
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await work.close();
          await root.delete(recursive: true);
        });
      });
      await tester.runAsync(() async {
        final opened = work.changes.firstWhere(
          (event) => event['type'] == 'viewerOpened',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: JevmanViewer(
                work: work,
                recording: recording.toJson(),
                identity: work.identity,
                complete: true,
                gameIndex: 7,
              ),
            ),
          ),
        );
        await opened.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(find.text('第 7 局 · 历史录像'), findsOneWidget);
      expect(find.byKey(const Key('jevman-maze')), findsOneWidget);
      expect(find.textContaining('独立重放核对一致'), findsOneWidget);
      expect(find.byKey(const Key('jevman-replay-play')), findsOneWidget);
      expect(find.byKey(const Key('jevman-replay-speed')), findsOneWidget);
      expect(find.byKey(const Key('jevman-replay-position')), findsOneWidget);
      expect(work.activeViewerProcessIds, hasLength(1));
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await work.waitForViewersClosed();
      });
      expect(work.activeViewerProcessIds, isEmpty);
      expect(work.status, BenchmarkGamePreparationStatus.ready);
      for (final entry in [
        (null, work.identity, '该局录像缺失'),
        ({'version': 99}, work.identity, 'version 1'),
        (recording.toJson(), {...work.identity, 'pin': 'wrong'}, '游戏版本不匹配'),
      ]) {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: JevmanViewer(
                  key: UniqueKey(),
                  work: work,
                  recording: entry.$1,
                  identity: entry.$2,
                  complete: false,
                  gameIndex: 8,
                ),
              ),
            ),
          );
          await _waitFor(tester, find.byKey(const Key('jevman-view-error')));
        });
        expect(find.textContaining(entry.$3), findsOneWidget);
        expect(find.byKey(const Key('jevman-maze')), findsNothing);
        expect(work.activeViewerProcessIds, isEmpty);
      }
    },
  );
  test('history replay seeks original frames and closes only its own Node instance', () async {
    final root = await Directory.systemTemp.createTemp('gmd-game-viewing-');
    addTearDown(() => root.delete(recursive: true));
    final original = Directory(
      '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
    );
    final installation = Directory(
      '${root.path}/node/${JevmanRuntime.archiveRoot}',
    );
    await Directory('${installation.path}/bin').create(recursive: true);
    await File('${original.path}/bin/node')
        .copy('${installation.path}/bin/node');
    await File('${original.path}/LICENSE').copy('${installation.path}/LICENSE');
    expect(
      (await Process.run('/bin/chmod', [
        '700',
        '${installation.path}/bin/node',
      ])).exitCode,
      0,
    );
    final work = BenchmarkGameWork(
      root,
      loadAsset: (path) async =>
          ByteData.sublistView(await File(path).readAsBytes()),
    );
    addTearDown(work.close);
    await work.prepare(DecisionCancellation());
    // Published upstream trace: no substitute simulator or inference client.
    final recording = JevmanRecording.parse(
      jsonDecode(
        await File('benchmarks/sources/jevman/public/demo/kev-4b-demo.json')
            .readAsString(),
      ),
    );
    final view = await work.openReplay(recording, identity: work.identity);
    addTearDown(view.close);
    expect(view.verdict['ok'], isTrue);
    expect(view.frame.index, 0);
    expect(view.frame.state['score'], 0);
    expect(view.frame.state['maze'], isNotEmpty);
    final pid = view.activeProcessId;
    expect(pid, isNotNull);
    await view.seek(recording.frames.length);
    expect(view.frame.index, recording.frames.length);
    expect(view.frame.state['score'], recording.finalScore);
    expect(view.frame.state['score'], 1480);
    expect((view.verdict['result'] as Map)['score'], 1480);
    await view.seek(0);
    expect(view.frame.state['score'], 0);
    final moved = Completer<void>();
    void onFrame() {
      if (view.frame.index > 0 && !moved.isCompleted) {
        moved.complete();
      }
    }

    view.addListener(onFrame);
    view.setSpeed(2);
    view.play();
    expect(view.playing, isTrue);
    await moved.future.timeout(const Duration(seconds: 5));
    view.pause();
    expect(view.playing, isFalse);
    expect(view.speed, 2);
    view.removeListener(onFrame);
    await Future.wait([view.seek(200), view.seek(10)]);
    expect(view.frame.index, 10);
    await view.close();
    expect(view.activeProcessId, isNull);
    expect(work.status, BenchmarkGamePreparationStatus.ready);
    final second = await work.openReplay(recording, identity: work.identity);
    addTearDown(second.close);
    expect(second.activeProcessId, isNot(pid));
    expect(second.verdict['ok'], isTrue);
    await second.close();
    await expectLater(
      work.openReplay(
        recording,
        identity: {...work.identity, 'pin': 'different'},
      ),
      throwsFormatException,
    );
    final opening = work.openReplay(recording, identity: work.identity);
    final rejected = expectLater(opening, throwsStateError);
    await work.close();
    await rejected;
    expect(work.activeViewerProcessIds, isEmpty);
  });
}

class _Network extends HttpOverrides {}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      fail('Viewer action did not complete within 5 seconds');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}
