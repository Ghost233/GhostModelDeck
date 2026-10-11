import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_game_work.dart';
import 'package:ghost_model_deck/jevman_runtime.dart';
import 'package:ghost_model_deck/benchmark_page.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  testWidgets('快速切换历史后旧reader关闭，迟到摘要与页读取不能覆盖当前选择', (tester) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _Network();
    addTearDown(() => HttpOverrides.global = previous);
    late PlaygroundRuntime fixture;
    late BenchmarkRunner viewer;
    late BenchmarkResources resources;
    late _HistorySessionObserver store;
    late BenchmarkRun first, second;
    late Map<String, String> files;
    await tester.runAsync(() async {
      fixture = await PlaygroundRuntime.create();
      resources = BenchmarkResources(
        Directory('${fixture.runtime.root.path}/late-summary-cache'),
      );
      final suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      store = _HistorySessionObserver(
        Directory('${fixture.runtime.root.path}/late-summary-history'),
      );
      viewer = BenchmarkRunner(
        client: fixture.playground,
        store: store,
        models: fixture.council.models,
      );
      first = BenchmarkRun.fromJson({
        'schema_version': 1,
        'id': 'old-history-reader',
        'model': 'native-kev',
        'source': 'native',
        'channel': 'http',
        'status': 'interrupted',
        'timeout_us': 30000000,
        'created_at': '2026-10-11T00:00:00.000Z',
        'finished_at': '2026-10-11T00:01:00.000Z',
        'suite': BenchmarkResources.identity,
        'identity': {'model': 'native-kev', 'source': 'native'},
        'summary': {
          'attempted': 400,
          'complete': false,
          'expected': 400,
          'expected_pairs': 200,
          'valid': 0,
          'failures': 400,
          'missing': 0,
        },
        'items': [
          for (final item in suite.items)
            {
              'id': item.id,
              'pair_id': item.pairId,
              'gold': item.gold,
              'category': item.category,
              'difficulty': item.difficulty,
              'status': 'failed',
              'prediction': null,
              'elapsed_us': 0,
              'error': 'No valid reply in this external history fixture.',
              'request': item.request('native-kev'),
              'request_json': jsonEncode(item.request('native-kev')),
              'result': null,
            },
        ],
        'groups': <Object?>[],
      });
      second = BenchmarkRun.fromJson({
        ...first.toJson(),
        'id': 'new-history-reader',
        'created_at': '2026-10-11T00:02:00.000Z',
        'finished_at': '2026-10-11T00:03:00.000Z',
      });
      await store.save(first);
      await store.save(second);
      files = {
        for (final id in [first.id, second.id])
          id: await File('${store.directory.path}/$id.json').readAsString(),
      };
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await viewer.close();
        await resources.close();
        await fixture.close();
      });
    });
    tester.view.physicalSize = const Size(1100, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BenchmarkPage(resources: resources, runner: viewer),
          ),
        ),
      );
      await _wait(tester, find.byKey(Key('benchmark-history-${first.id}')));
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${first.id}')),
      );
      await tester.tap(find.byKey(Key('benchmark-history-${first.id}')));
      await store.firstOpened.future.timeout(const Duration(seconds: 5));
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${second.id}')),
      );
      await tester.tap(find.byKey(Key('benchmark-history-${second.id}')));
      await _wait(tester, find.textContaining('批次：${second.id} ·'));
    });
    expect(find.textContaining('批次：${first.id} ·'), findsNothing);
    expect(find.textContaining('记录读取失败'), findsNothing);
    final old = store.sessions[first.id]!;
    await tester.runAsync(() async {
      await expectLater(
        old.items(evaluationId: first.id, offset: 0),
        throwsStateError,
      );
    });
    await tester.ensureVisible(find.byKey(const Key('benchmark-detail-items')));
    await tester.tap(find.byKey(const Key('benchmark-detail-items')));
    // Supersede a real page RPC with another detail before awaiting its result.
    await tester.tap(find.byKey(const Key('benchmark-detail-groups')));
    await tester.runAsync(() async {
      await _wait(
        tester,
        find.byKey(ValueKey('benchmark-groups-${second.id}')),
      );
      await tester.pump();
    });
    expect(find.byKey(ValueKey('benchmark-items-${second.id}')), findsNothing);
    expect(find.textContaining('批次：${second.id} ·'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await expectLater(
        store.sessions[second.id]!.items(evaluationId: second.id, offset: 0),
        throwsStateError,
      );
      for (final entry in files.entries) {
        expect(
          await File('${store.directory.path}/${entry.key}.json')
              .readAsString(),
          entry.value,
        );
      }
    });
    expect(fixture.runtime.io.requests, isEmpty);
    expect(viewer.running, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史逐题摘要每页20条可往返且只展示当前页，完整60条原文留在文件', (tester) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _Network();
    addTearDown(() => HttpOverrides.global = previous);
    late PlaygroundRuntime fixture;
    late BenchmarkRunner viewer;
    late BenchmarkResources resources;
    late DecideBenchSuite suite;
    late BenchmarkRun history;
    late File original;
    late String originalBytes;
    await tester.runAsync(() async {
      fixture = await PlaygroundRuntime.create();
      resources = BenchmarkResources(
        Directory('${fixture.runtime.root.path}/paging-cache'),
      );
      suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      viewer = BenchmarkRunner(
        client: fixture.playground,
        store: BenchmarkRunStore(
          directory: Directory('${fixture.runtime.root.path}/paging-history'),
        ),
        models: fixture.council.models,
      );
      // A readonly external history fixture represents interruption of the
      // full400 plan. No smaller plan is admitted or scored by the runner.
      history = BenchmarkRun.fromJson({
        'schema_version': 1,
        'id': 'interrupted-paging-history',
        'model': 'native-kev',
        'source': 'native',
        'channel': 'http',
        'status': 'interrupted',
        'timeout_us': 30000000,
        'created_at': '2026-10-11T00:00:00.000Z',
        'finished_at': '2026-10-11T00:01:00.000Z',
        'suite': BenchmarkResources.identity,
        'identity': {'model': 'native-kev', 'source': 'native'},
        'summary': {
          'attempted': 60,
          'complete': false,
          'expected': 400,
          'expected_pairs': 200,
          'valid': 0,
          'failures': 60,
          'missing': 340,
          'correct': 0,
          'pairs_correct': 0,
          'accuracy': null,
          'pair_accuracy': null,
        },
        'items': [
          for (final item in suite.items.take(60))
            {
              'id': item.id,
              'pair_id': item.pairId,
              'gold': item.gold,
              'category': item.category,
              'difficulty': item.difficulty,
              'status': 'failed',
              'prediction': null,
              'elapsed_us': 0,
              'error': 'Interrupted before a valid reply.',
              'request': item.request('native-kev'),
              'request_json': jsonEncode(item.request('native-kev')),
              'result': null,
            },
        ],
        'groups': <Object?>[],
      });
      await viewer.store.save(history);
      original = File('${viewer.store.directory.path}/${history.id}.json');
      originalBytes = await original.readAsString();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await viewer.close();
        await resources.close();
        await fixture.close();
      });
    });
    tester.view.physicalSize = const Size(1100, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BenchmarkPage(resources: resources, runner: viewer),
          ),
        ),
      );
      await _wait(tester, find.byKey(Key('benchmark-history-${history.id}')));
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${history.id}')),
      );
      await tester.tap(find.byKey(Key('benchmark-history-${history.id}')));
      await _wait(tester, find.byKey(const Key('benchmark-coverage')));
    });
    await tester.ensureVisible(find.byKey(const Key('benchmark-detail-items')));
    await tester.tap(find.byKey(const Key('benchmark-detail-items')));
    Future<void> page(int index) async {
      final first = suite.items[index * 20];
      await tester.runAsync(() async {
        await _wait(tester, find.byKey(Key('benchmark-item-${first.id}')));
      });
      final list = tester.widget<ListView>(
        find.byKey(ValueKey('benchmark-items-${history.id}')),
      );
      expect(
        (list.childrenDelegate as SliverChildBuilderDelegate).childCount,
        20,
      );
      expect(
        find.text('第 ${index + 1} / 3 页 · 共 60 条 · 每页 20 条'),
        findsOneWidget,
      );
      expect(find.byKey(Key('benchmark-item-json-${first.id}')), findsNothing);
      expect(
        find.byKey(
          Key('benchmark-item-${suite.items[((index + 1) % 3) * 20].id}'),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('未完成 · 已执行 60 / 400'),
      );
    }

    await page(0);
    for (final index in [1, 2]) {
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-next')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-next')));
      await page(index);
    }
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('benchmark-detail-next')))
          .onPressed,
      isNull,
    );
    for (final index in [1, 0]) {
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-previous')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-previous')));
      await page(index);
    }
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('benchmark-detail-previous')),
          )
          .onPressed,
      isNull,
    );
    expect((await tester.runAsync(original.readAsString))!, originalBytes);
    final document = jsonDecode(originalBytes) as Map;
    expect(document['items'], hasLength(60));
    expect(
      document['items'][59]['request'],
      suite.items[59].request('native-kev'),
    );
    expect(fixture.runtime.io.requests, isEmpty);
    expect(viewer.running, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('评测明细只显示摘要并通过真实文件路径在Finder定位完整记录', (tester) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _Network();
    addTearDown(() => HttpOverrides.global = previous);
    late PlaygroundRuntime fixture;
    late BenchmarkRunner runner;
    late BenchmarkResources resources;
    late DecideBenchSuite suite;
    late BenchmarkRun record;
    late Completer<void> arrived, release;
    await tester.runAsync(() async {
      fixture = await PlaygroundRuntime.create();
      resources = BenchmarkResources(
        Directory('${fixture.runtime.root.path}/summary-files-cache'),
      );
      runner = BenchmarkRunner(
        client: fixture.playground,
        store: BenchmarkRunStore(
          directory: Directory(
            '${fixture.runtime.root.path}/summary-files-history',
          ),
        ),
        models: fixture.council.models,
      );
      suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      arrived = Completer<void>();
      release = Completer<void>();
      var requestCount = 0;
      fixture.runtime.io.respond = (body, raw) async {
        requestCount++;
        if (requestCount == 2) {
          arrived.complete();
          await release.future;
        }
        return raw;
      };
      // Admit the unchanged full400 plan; explicit cancel creates lifecycle
      // evidence, never a product quick run or a smaller benchmark.
      final operation = runner.run(suite: suite, model: 'native-kev');
      await arrived.future.timeout(const Duration(seconds: 20));
      runner.cancel();
      record = await operation.timeout(const Duration(seconds: 10));
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (!release.isCompleted) release.complete();
        await runner.close();
        await resources.close();
        await fixture.close();
      });
    });
    final file = File('${runner.store.directory.path}/${record.id}.json')
        .absolute;
    final before = (await tester.runAsync(file.readAsString))!;
    expect(record.status, BenchmarkRunStatus.cancelled);
    expect(record.summary['expected'], 400);
    const native = MethodChannel('com.ghost233.ghostmodeldeck/native');
    final reveals = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      reveals.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      ),
    );
    tester.view.physicalSize = const Size(1100, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BenchmarkPage(resources: resources, runner: runner),
          ),
        ),
      );
      await _wait(tester, find.byKey(const Key('benchmark-target')));
      await _wait(tester, find.byKey(const Key('benchmark-coverage')));
    });
    await tester.ensureVisible(find.byKey(const Key('benchmark-detail-items')));
    await tester.tap(find.byKey(const Key('benchmark-detail-items')));
    final firstId = suite.items.first.id;
    await tester.runAsync(() async {
      await _wait(tester, find.byKey(Key('benchmark-item-$firstId')));
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(Key('benchmark-item-$firstId')));
    await tester.tap(find.byKey(Key('benchmark-item-$firstId')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('benchmark-item-json-$firstId')), findsNothing);
    expect(find.textContaining('已执行 2 / 400'), findsOneWidget);
    expect(find.text(file.path), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('benchmark-record-reveal')),
    );
    await tester.tap(find.byKey(const Key('benchmark-record-reveal')));
    await tester.pumpAndSettle();
    expect(reveals, hasLength(1));
    expect(reveals.single.method, 'revealInFinder');
    expect(reveals.single.arguments, {'path': file.path});
    expect((await tester.runAsync(file.readAsString))!, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selecting the active original history follows the owned current snapshot without hydrating an appending journal',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner runner;
      late _ObservedJournalStore store;
      late Future<BenchmarkRun> operation;
      late Completer<void> secondRelease, remainingRelease;
      late Completer<BenchmarkRun> firstSaved, secondSaved;
      late StreamSubscription<BenchmarkRun> subscription;
      await tester.runAsync(() async {
        secondRelease = Completer<void>();
        remainingRelease = Completer<void>();
        firstSaved = Completer<BenchmarkRun>();
        secondSaved = Completer<BenchmarkRun>();
        fixture = await PlaygroundRuntime.create();
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/active-original-cache'),
        );
        final suite = await _prepareOriginalJeval(resources);
        expect(suite.tasks, hasLength(11257));
        store = _ObservedJournalStore(
          Directory('${fixture.runtime.root.path}/active-original-history'),
        );
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        var request = 0;
        fixture.runtime.io.respond = (body, raw) async {
          request++;
          if (request == 2) await secondRelease.future;
          if (request >= 3) await remainingRelease.future;
          return raw;
        };
        subscription = runner.changes.listen((record) {
          if (record.summary['attempted'] == 1 && !firstSaved.isCompleted) {
            firstSaved.complete(record);
          }
          if (record.summary['attempted'] == 2 && !secondSaved.isCompleted) {
            secondSaved.complete(record);
          }
        });
        // Full original plan with finite public HTTP lifecycle observations;
        // this is not a complete model benchmark or a product subset.
        operation = runner.runQuestions(suite: suite, model: 'native-kev');
        await firstSaved.future.timeout(const Duration(seconds: 20));
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          store.releaseLength();
          runner.cancel();
          if (!secondRelease.isCompleted) secondRelease.complete();
          if (!remainingRelease.isCompleted) remainingRelease.complete();
          await runner.close();
          await subscription.cancel();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1100, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final id = runner.current!.id;
      late Map firstHeader;
      await tester.runAsync(() async {
        firstHeader = jsonDecode(
          await File('${store.directory.path}/$id.json').readAsString(),
        ) as Map;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(tester, find.byKey(Key('benchmark-history-$id')));
      });
      expect((firstHeader['journal'] as Map)['count'], 1);
      await tester.ensureVisible(find.byKey(Key('benchmark-history-$id')));
      await tester.runAsync(() async {
        store.observe(id);
        await tester.tap(find.byKey(Key('benchmark-history-$id')));
        // load() observation is synchronous. The future fixed Page can skip
        // hydration, so that branch must never wait for a nonexistent IO gate.
        if (store.observedLoads > 0) {
          await store.lengthObserved.future.timeout(const Duration(seconds: 5));
          expect(store.oldLength, (firstHeader['journal'] as Map)['bytes']);
        }
        secondRelease.complete();
        final next = await secondSaved.future.timeout(
          const Duration(seconds: 20),
        );
        expect(next.summary['expected'], 11257);
        final nextHeader = jsonDecode(
          await File('${store.directory.path}/$id.json').readAsString(),
        ) as Map;
        expect((nextHeader['journal'] as Map)['count'], 2);
        expect(
          (nextHeader['journal'] as Map)['bytes'] as int,
          greaterThan((firstHeader['journal'] as Map)['bytes'] as int),
        );
        store.releaseLength();
        if (store.observedLoads > 0) {
          await store.readFinished.future.timeout(const Duration(seconds: 5));
          // Verify the unmodified real Store rejected the old descriptor
          // after legal ordinary append, rather than inventing corrupt rows.
          expect(store.readError, isA<FormatException>());
          expect(store.readError.toString(), contains('原题日志未完整封存或含额外请求'));
        }
        await tester.pump();
      });
      expect(find.textContaining('记录读取失败'), findsNothing);
      expect(
        store.observedLoads,
        0,
        reason: 'The app-owned current snapshot does not require active journal hydration.',
      );
      expect(find.textContaining('批次：$id ·'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('未完成 · 已执行 2 / 11257'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-current-status')))
            .data,
        contains('运行中'),
      );
      final journalPath = File(
        '${store.directory.path}/${(firstHeader['journal'] as Map)['file']}',
      ).absolute.path;
      expect(
        (await tester.runAsync(() => File(journalPath).exists()))!,
        isTrue,
      );
      expect(find.text(journalPath), findsOneWidget);
      const native = MethodChannel('com.ghost233.ghostmodeldeck/native');
      final reveals = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        reveals.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        ),
      );
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-journal-reveal-0')),
      );
      await tester.tap(find.byKey(const Key('benchmark-journal-reveal-0')));
      await tester.pump();
      expect(reveals, hasLength(1));
      expect(reveals.single.method, 'revealInFinder');
      expect(reveals.single.arguments, {'path': journalPath});
      expect(store.observedLoads, 0);
      expect(runner.running, isTrue);
      await tester.runAsync(() async {
        store.stopObserving();
        runner.cancel();
        final cancelled = await operation.timeout(const Duration(seconds: 10));
        final restored = await store.load(id);
        expect(restored.toJson(), cancelled.toJson());
        expect(restored.summary['expected'], 11257);
        expect(
          restored.items
              .take(2)
              .every((row) => (row['result'] as Map)['status'] == 'success'),
          isTrue,
        );
      });
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  testWidgets(
    'selecting a valid saved original history clears the previous read error and preserves both files',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner viewer;
      late BenchmarkRun bad, good;
      late File badJournal, goodJournal, badHeader, goodHeader, source, model;
      late String damaged;
      late List<int> goodBytes,
          badHeaderBytes,
          goodHeaderBytes,
          sourceBytes,
          modelBytes;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/reselection-cache'),
        );
        final suite = await _prepareOriginalJeval(resources);
        expect(suite.tasks, hasLength(11257));
        final store = BenchmarkRunStore(
          directory: Directory(
            '${fixture.runtime.root.path}/reselection-history',
          ),
        );
        final creator = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        final releases = <Completer<void>>[];
        try {
          final records = <BenchmarkRun>[];
          for (var index = 0; index < 2; index++) {
            final arrived = Completer<void>(), release = Completer<void>();
            releases.add(release);
            fixture.runtime.io.respond = (body, raw) async {
              if (!arrived.isCompleted) arrived.complete();
              await release.future;
              return raw;
            };
            final operation = creator.runQuestions(
              suite: suite,
              model: 'native-kev',
            );
            await arrived.future.timeout(const Duration(seconds: 20));
            creator.cancel();
            records.add(await operation.timeout(const Duration(seconds: 10)));
            release.complete();
          }
          bad = records[0];
          good = records[1];
        } finally {
          creator.cancel();
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await creator.close();
        }
        badJournal = File('${store.directory.path}/${bad.id}-0.items.jsonl');
        goodJournal = File('${store.directory.path}/${good.id}-0.items.jsonl');
        badHeader = File('${store.directory.path}/${bad.id}.json');
        goodHeader = File('${store.directory.path}/${good.id}.json');
        final original = await badJournal.readAsString();
        damaged = original.replaceFirst('native-kev', 'native-foo');
        expect(damaged, isNot(original));
        expect(utf8.encode(damaged).length, utf8.encode(original).length);
        await badJournal.writeAsString(damaged, flush: true);
        goodBytes = await goodJournal.readAsBytes();
        badHeaderBytes = await badHeader.readAsBytes();
        goodHeaderBytes = await goodHeader.readAsBytes();
        // Protect the real pinned source without copying its bytes into a
        // user-facing record; the model marker belongs solely to this fixture.
        final sourceManifest = jsonDecode(
          await File('benchmarks/manifests/jeval.json').readAsString(),
        ) as Map;
        source = File(
          '${resources.cacheRoot.path}/jeval/${JevalSuite.pin}/${(sourceManifest['files'] as List).first['path']}',
        );
        sourceBytes = await source.readAsBytes();
        model = await File(
          '${fixture.runtime.root.path}/shared-model-marker.gguf',
        ).writeAsString('protected model marker');
        modelBytes = await model.readAsBytes();
        viewer = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await viewer.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1100, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: viewer),
            ),
          ),
        );
        await _wait(tester, find.byKey(Key('benchmark-history-${bad.id}')));
      });
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${bad.id}')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-${bad.id}')));
        await _wait(tester, find.textContaining('记录读取失败'));
      });
      expect(find.textContaining('原题逐行内容摘要或请求 ID 无效'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${good.id}')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-${good.id}')));
        await _wait(tester, find.textContaining('批次：${good.id} ·'));
      });
      expect(find.textContaining('记录读取失败'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('未完成 · 已执行 1 / 11257'),
      );
      await tester.runAsync(() async {
        expect(await badJournal.readAsString(), damaged);
        expect(await goodJournal.readAsBytes(), goodBytes);
        expect(await badHeader.readAsBytes(), badHeaderBytes);
        expect(await goodHeader.readAsBytes(), goodHeaderBytes);
        expect(await source.readAsBytes(), sourceBytes);
        expect(await model.readAsBytes(), modelBytes);
        await expectLater(viewer.store.load(bad.id), throwsFormatException);
        final destination = File(
          '${fixture.runtime.root.path}/refused-corrupt-history.json',
        );
        await expectLater(
          viewer.store.exportTo(bad.id, destination),
          throwsFormatException,
        );
        expect(await destination.exists(), isFalse);
        await expectLater(viewer.store.delete(bad.id), throwsFormatException);
        expect((await viewer.store.load(good.id)).toJson(), good.toJson());
        expect(await badJournal.readAsString(), damaged);
      });
      expect(viewer.current, isNull);
      expect(fixture.runtime.io.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  testWidgets(
    'starting a new original suite supersedes a pending complete history selection',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      late BenchmarkRun old;
      late Completer<void> arrived, release;
      await tester.runAsync(() async {
        arrived = Completer<void>();
        release = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        final cache = Directory(
          '${fixture.runtime.root.path}/history-switch-cache',
        );
        resources = BenchmarkResources(cache);
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final originals = {
          for (final item in suite.items)
            '${item.state}\n${item.question}': item,
        };
        fixture.runtime.io.respond = (body, raw) async {
          final question = (body['questions'] as Map)['decision'] as Map;
          final item =
              originals['${body['state']}\n${question['instructions']}']!;
          final reply = jsonDecode(raw) as Map;
          reply['answers']['decision'] = {
            'type': 'choice',
            'choice': item.gold,
            'confidence': 1.0,
            'probabilities': {
              for (final option in item.options.keys)
                option: option == item.gold ? 1.0 : 0.0,
            },
          };
          return jsonEncode(reply);
        };
        final store = BenchmarkRunStore(
          directory: Directory(
            '${fixture.runtime.root.path}/history-switch-records',
          ),
        );
        final creator = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        try {
          old = await creator.run(suite: suite, model: 'native-kev');
        } finally {
          await creator.close();
        }
        expect(old.summary['complete'], isTrue);
        expect(old.summary['accuracy'], 1.0);
        expect(fixture.runtime.io.requests, hasLength(400));
        // Real complete old history; the new full11257 plan only reaches its
        // first HTTP request here. This fixture is not full JEVal acceptance.
        final manifest = jsonDecode(
          await File('benchmarks/manifests/jeval.json').readAsString(),
        ) as Map;
        for (final value in manifest['files'] as List) {
          final path = (value as Map)['path'] as String;
          final destination = File(
            '${cache.path}/jeval/${JevalSuite.pin}/$path',
          );
          await destination.parent.create(recursive: true);
          await File('benchmarks/sources/jeval/$path').copy(destination.path);
        }
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: store,
          models: fixture.council.models,
        );
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
          return raw;
        };
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          runner.cancel();
          if (!release.isCompleted) release.complete();
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1100, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(tester, find.byKey(const Key('benchmark-target')));
        await _wait(tester, find.byKey(Key('benchmark-history-${old.id}')));
      });
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('benchmark-suite')));
      // Dropdown registers its result continuation when opening the route.
      // Keep that whole asset-loading interaction in the real async zone.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-suite')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('JEVal').last);
        await tester.pump();
        await _wait(tester, find.byKey(const Key('benchmark-suite-metadata')));
      });
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-select-native-kev')),
      );
      await tester.tap(find.byKey(const Key('benchmark-select-native-kev')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('benchmark-run')))
            .onPressed,
        isNotNull,
        reason:
            'The full JEVal plan must be enabled before selecting old history.',
      );
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${old.id}')),
      );
      await tester.runAsync(() async {
        // A normal history tap starts real file IO. Starting the next suite
        // must supersede that selection even if its read completes later.
        await tester.tap(find.byKey(Key('benchmark-history-${old.id}')));
        await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
        // Scroll/layout must be published before the next normal pointer tap.
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('benchmark-run')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const Key('benchmark-run')));
        // Publish widget asset/platform completions while real preparation
        // runs, retaining the same 20-second first-public-request deadline.
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!arrived.isCompleted && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        if (!arrived.isCompleted) {
          final error = find.byKey(const Key('benchmark-error'));
          fail(
            'First public request did not arrive: resources=${resources.status.name}, '
            'progress=${resources.progress?.currentPath}, '
            'resourceError=${resources.lastError}, current=${runner.current?.id}, '
            'buttonEnabled=${tester.widget<FilledButton>(find.byKey(const Key('benchmark-run'))).onPressed != null}, '
            'pageError=${error.evaluate().isEmpty ? null : tester.widget<Text>(error).data}',
          );
        }
        await tester.pump();
      });
      expect(runner.current, isNotNull);
      final current = runner.current!;
      expect(current.id, isNot(old.id));
      expect(current.suite['id'], 'jeval');
      expect(current.status, BenchmarkRunStatus.running);
      expect(current.summary['expected'], 11257);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(find.textContaining('批次：${current.id} ·'), findsOneWidget);
      expect(find.textContaining('批次：${old.id} ·'), findsNothing);
      final coverage = tester
          .widget<Text>(find.byKey(const Key('benchmark-coverage')))
          .data!;
      expect(coverage, contains('未完成'));
      expect(coverage, contains('/ 11257'));
      expect(coverage, isNot(contains('/ 400')));
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-accuracy'))).data,
        '原 accuracy：未完成，不发布完整分数',
      );
      expect(find.textContaining('100.00%'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-current-status')))
            .data,
        contains('运行中'),
      );
      await tester.runAsync(() async {
        runner.cancel();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (runner.running && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        expect(runner.running, isFalse);
        expect((await runner.store.load(old.id)).toJson(), old.toJson());
        await _wait(tester, find.byKey(Key('benchmark-history-${current.id}')));
      });
      expect(runner.current!.status, BenchmarkRunStatus.cancelled);
      expect(runner.current!.summary['expected'], 11257);
      expect(fixture.runtime.io.requests, hasLength(1));
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${old.id}')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-${old.id}')));
        await _wait(tester, find.textContaining('批次：${old.id} ·'));
      });
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('完整执行 · 已执行 400 / 400'),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-accuracy'))).data,
        contains('100.00%'),
      );
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${current.id}')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-${current.id}')));
        await _wait(tester, find.textContaining('批次：${current.id} ·'));
      });
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('/ 11257'),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-accuracy'))).data,
        '原 accuracy：未完成，不发布完整分数',
      );
      expect(find.textContaining('100.00%'), findsNothing);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'four original suite choices show their fixed metadata and full scale without inference',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/suite-ui-history',
            ),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/suite-ui-cache'),
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pump();
      expect(find.byKey(const Key('benchmark-suite')), findsOneWidget);
      for (final choice in const [
        ('DecideBench', '400', 'choyiny/decidebench', '完整评测 · 400 题'),
        ('JEVal', '11257', 'carlosxiang/JEVal', '完整评测 · 11257 题'),
        ('一致性 JevBench', '10320', 'JevBench/jevbench', '完整评测 · 10320 请求'),
        ('JevAdvBench', '11368', 'JevAdvBench/JevAdvBench', '完整评测 · 11368 请求'),
      ]) {
        await tester.ensureVisible(find.byKey(const Key('benchmark-suite')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-suite')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice.$1).last);
          await tester.pump();
          try {
            await _wait(
              tester,
              find.byKey(const Key('benchmark-suite-metadata')),
            );
          } catch (error) {
            final metadataErrors = find.textContaining('无法读取固定题源元信息');
            fail(
              'Fixed source metadata did not complete for ${choice.$1}: '
              '$error; sourceLabel=${find.text('${choice.$1} 基准评测').evaluate().isNotEmpty}; '
              'metadataLoading=${find.text('读取固定题源元信息…').evaluate().isNotEmpty}; '
              'metadataError=${metadataErrors.evaluate().isEmpty ? null : tester.widget<Text>(metadataErrors.first).data}',
            );
          }
        });
        final metadata = find
            .descendant(
              of: find.byKey(const Key('benchmark-suite-metadata')),
              matching: find.byType(Text),
            )
            .evaluate()
            .map((element) => (element.widget as Text).data ?? '')
            .join('\n');
        expect(metadata, contains(choice.$2));
        expect(metadata, contains(choice.$3));
        expect(find.text(choice.$4), findsOneWidget);
        expect(find.textContaining('快速试跑'), findsNothing);
      }
      expect(fixture.runtime.io.requests, isEmpty);
      expect(runner.running, isFalse);
      expect(resources.preparing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'original question history shows full coverage and source groups without treating them as pairs',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      late Completer<void> arrived, release;
      late BenchmarkRun cancelled;
      await tester.runAsync(() async {
        arrived = Completer<void>();
        release = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/original-report-history',
            ),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/original-report-cache'),
        );
        final suite = await JevalSuite.load(
          Directory('benchmarks/sources/jeval'),
        );
        fixture.runtime.io.respond = (body, response) async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
          return response;
        };
        final operation = runner.runQuestions(
          suite: suite,
          model: 'native-kev',
        );
        await arrived.future.timeout(const Duration(seconds: 20));
        runner.cancel();
        cancelled = await operation.timeout(const Duration(seconds: 10));
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!release.isCompleted) release.complete();
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(tester, find.byKey(const Key('benchmark-target')));
        await _wait(tester, find.byKey(const Key('benchmark-coverage')));
      });
      await tester.pump();
      final coverage = tester
          .widget<Text>(find.byKey(const Key('benchmark-coverage')))
          .data!;
      expect(coverage, contains('已执行 1 / 11257'));
      expect(coverage, contains('失败 1'));
      expect(
        cancelled.toJson()['source_summary'],
        containsPair('accuracy', null),
      );
      expect(
        cancelled.toJson()['source_summary'],
        containsPair('scoreMae', null),
      );
      expect(find.textContaining('原 pair accuracy'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-groups')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-groups')));
      final groupsKey = ValueKey('benchmark-groups-${cancelled.id}');
      final first = cancelled.groups.first;
      final groupId = '${first['dimension']}/${first['group']}';
      await tester.runAsync(() async {
        await _wait(tester, find.byKey(Key('benchmark-group-$groupId')));
      });
      final groups = tester.widget<ListView>(find.byKey(groupsKey));
      expect(
        (groups.childrenDelegate as SliverChildBuilderDelegate).childCount,
        cancelled.groups.length < 20 ? cancelled.groups.length : 20,
      );
      expect(
        find.textContaining('共 ${cancelled.groups.length} 条'),
        findsOneWidget,
      );
      expect(cancelled.groups.map((row) => row['dimension']).toSet(), {
        'source',
        'domain',
        'language',
        'question_type',
        'input_length_group',
      });
      await tester.ensureVisible(find.byKey(Key('benchmark-group-$groupId')));
      await tester.tap(find.byKey(Key('benchmark-group-$groupId')));
      await tester.pump();
      expect(find.byKey(Key('benchmark-group-json-$groupId')), findsNothing);
      // The user moved full JSON out of the UI. Keep the original complete
      // group equality assertion against the real full-data export instead.
      final exported = File(
        '${fixture.runtime.root.path}/original-groups-complete.json',
      );
      final document = (await tester.runAsync(() async {
        await runner.store.exportTo(cancelled.id, exported);
        return jsonDecode(await exported.readAsString()) as Map;
      }))!;
      expect((document['groups'] as List).first, first);
      expect(document['groups'], cancelled.groups);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Jevman page prepares the app owned fixed100 source and its batch survives leaving then cancels with history',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      late BenchmarkGameWork work;
      late Completer<void> arrived, release;
      await tester.runAsync(() async {
        arrived = Completer<void>();
        release = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/page-game-history',
            ),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/page-game-question-cache'),
        );
        final cache = Directory('${fixture.runtime.root.path}/page-game-cache');
        final original = Directory(
          '.tooling/playground-source-preflight-20261009/jevman-runtime-preflight/node/${JevmanRuntime.archiveRoot}',
        );
        final installation = Directory(
          '${cache.path}/node/${JevmanRuntime.archiveRoot}',
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
        work = BenchmarkGameWork(cache);
        fixture.runtime.io.respond = (request, response) async {
          if (!(request['questions'] as Map).containsKey('warmup')) {
            if (!arrived.isCompleted) arrived.complete();
            await release.future;
          }
          return response;
        };
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!release.isCompleted) release.complete();
          runner.cancel();
          await runner.close();
          await work.close();
          await resources.close();
          await fixture.close();
        });
      });
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(
            resources: resources,
            runner: runner,
            gameWork: work,
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('benchmark-suite')));
      await tester.tap(find.byKey(const Key('benchmark-suite')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jevman').last);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => _wait(tester, find.byKey(const Key('benchmark-suite-metadata'))),
      );
      expect(find.text('完整评测 · 100 局'), findsOneWidget);
      expect(work.status.name, 'idle');
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-select-native-kev')),
      );
      await tester.tap(find.byKey(const Key('benchmark-select-native-kev')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('benchmark-run')))
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        await arrived.future.timeout(const Duration(seconds: 20));
        await tester.pump();
      });
      expect(work.status.name, 'ready');
      expect(runner.running, isTrue);
      expect(runner.current!.summary['expected'], 100);
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isTrue);
      final runId = runner.current!.id;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('other engine page'))),
      );
      expect(runner.running, isTrue);
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pump();
      expect(runner.current!.id, runId);
      expect(find.text('完整评测 · 100 局'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('benchmark-cancel')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-cancel')));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (runner.running && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(runner.running, isFalse);
      expect(runner.current!.status, BenchmarkRunStatus.cancelled);
      expect(runner.current!.summary['expected'], 100);
      expect(runner.current!.summary['attempted'], 1);
      expect(runner.current!.summary['complete'], isFalse);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('benchmark-game-latency-distribution')),
            )
            .data,
        contains('P50 不可用 ms · P95 不可用 ms · 耗时样本 0 / 0 次成功调用 · 覆盖率 未知'),
      );
      expect(work.activeProcessId, isNull);
      expect(fixture.council.models.isEvaluationLocked('native-kev'), isFalse);
      final persisted = (await tester.runAsync(
        () => runner.store.load(runId),
      ))!;
      expect(persisted.items.single['index'], 1);
      expect(persisted.items.single['recording'], isNotNull);
      expect(persisted.items.single['calls'], isNotEmpty);
      final destination = File(
        '${fixture.runtime.root.path}/cancelled-game.json',
      );
      await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
      await tester.tap(find.byKey(const Key('benchmark-export')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('benchmark-export-path')),
        destination.path,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-export-save')));
        await _wait(tester, find.byKey(const Key('benchmark-file-status')));
      });
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-file-status')))
            .data,
        '已导出：${destination.path}',
      );
      await tester.runAsync(() async {
        expect(await destination.exists(), isTrue);
        release.complete();
        arrived = Completer<void>();
        release = Completer<void>();
      });
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-select-native-kev')),
      );
      await tester.tap(find.byKey(const Key('benchmark-select-native-kev')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        await arrived.future.timeout(const Duration(seconds: 20));
        await tester.pump();
      });
      expect(runner.running, isTrue);
      expect(runner.current!.id, isNot(runId));
      expect(runner.current!.summary['expected'], 100);
      expect(
        find.byKey(const Key('benchmark-file-status')),
        findsNothing,
        reason: 'An earlier export belongs to its saved batch, not the newly started batch.',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'multi-channel batch survives leaving the page and exports the whole batch from a selected result',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      late Future<BenchmarkRun> pending;
      late Completer<void> held;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/batch-ui-history',
            ),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/batch-ui-sources'),
        );
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        final arrived = Completer<void>();
        held = Completer<void>();
        fixture.runtime.io.respond = (body, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await held.future;
          return raw;
        };
        pending = runner.run(
          suite: suite,
          modelNames: ['native-kev', 'quick', 'hard'],
          channels: [JevPlaygroundMode.http, JevPlaygroundMode.mcp],
        );
        await arrived.future.timeout(const Duration(seconds: 5));
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!held.isCompleted) held.complete();
          await runner.close();
          await pending;
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(resources: resources, runner: runner),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('benchmark-select-hard')),
            )
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(runner.running, isTrue);
      expect(held.isCompleted, isFalse);
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('benchmark-cancel')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-cancel')));
        await pending.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.runAsync(() async {
        await _wait(
          tester,
          find.textContaining('批次：${runner.current!.evaluations.first.id} ·'),
          absent: find.byType(LinearProgressIndicator),
        );
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('benchmark-result-5')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('benchmark-result-5')));
      await tester.tap(find.byKey(const Key('benchmark-result-5')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-current-status')))
            .data,
        contains('hard · MCP'),
      );
      expect(find.textContaining('成功席位覆盖：'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
      await tester.tap(find.byKey(const Key('benchmark-export')));
      await tester.pumpAndSettle();
      final path = '${fixture.runtime.root.path}/whole-batch-export.json';
      await tester.enterText(
        find.byKey(const Key('benchmark-export-path')),
        path,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-export-save')));
        await _wait(tester, find.byKey(const Key('benchmark-file-status')));
      });
      await tester.pumpAndSettle();
      final document = await tester.runAsync(
        () async => jsonDecode(await File(path).readAsString()) as Map,
      );
      expect(document!['id'], runner.current!.id);
      expect(document['evaluations'], hasLength(6));
      expect(runner.current!.status, BenchmarkRunStatus.cancelled);
      expect(held.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'ready native and named councils can be selected together with separate HTTP/MCP channels',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory(
              '${fixture.runtime.root.path}/multi-ui-history',
            ),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/multi-ui-sources'),
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1000, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('benchmark-channels')), findsOneWidget);
      for (final name in ['native-kev', 'quick', 'hard']) {
        final checkbox = find.byKey(Key('benchmark-select-$name'));
        await tester.ensureVisible(checkbox);
        await tester.tap(checkbox);
        await tester.pump();
        expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      }
      await tester.ensureVisible(find.byKey(const Key('benchmark-channels')));
      await tester.tap(find.byKey(const Key('benchmark-channels')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('HTTP / MCP 分别评测').last);
        await tester.pump();
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('benchmark-run')))
            .onPressed,
        isNotNull,
      );
      expect(fixture.runtime.io.requests, isEmpty);
      expect(runner.running, isFalse);
    },
  );
  testWidgets(
    'historical summary corruption is a visible read error without inference or file overwrite',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      late Completer<void> arrived;
      late Completer<void> held;
      late File corruptFile;
      late String corruptedBytes;
      await tester.runAsync(() async {
        arrived = Completer<void>();
        held = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/sources'),
        );
        final suite = await DecideBenchSuite.load(
          Directory('benchmarks/sources/decidebench'),
        );
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await held.future;
          return raw;
        };
        final operation = runner.run(suite: suite, model: 'native-kev');
        await arrived.future.timeout(const Duration(seconds: 5));
        final original = runner.current!.toJson();
        final damaged =
            jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        runner.cancel();
        final cancelled = await operation.timeout(const Duration(seconds: 5));
        expect(cancelled.status, BenchmarkRunStatus.cancelled);
        expect(held.isCompleted, isFalse);
        // Damage only external historical JSON. The source is a real persisted
        // full-suite running snapshot, never a substituted runner/business result.
        damaged['id'] = 'separate-corrupted-history';
        (damaged['summary'] as Map)['attempted'] = 'bad';
        corruptedBytes = jsonEncode(damaged);
        corruptFile = await File(
          '${runner.store.directory.path}/separate-corrupted-history.json',
        ).writeAsString(corruptedBytes);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!held.isCompleted) held.complete();
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BenchmarkPage(resources: resources, runner: runner),
            ),
          ),
        );
        await _wait(
          tester,
          find.textContaining('历史读取失败'),
          absent: find.byType(LinearProgressIndicator),
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('FormatException'), findsOneWidget);
      expect(find.textContaining('评测摘要'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(runner.running, isFalse);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(
        (await tester.runAsync(corruptFile.readAsString))!,
        corruptedBytes,
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      });
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'source HTTP failure after preparation page remount displays the terminal error without model history',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner runner;
      late HttpServer source;
      late Completer<HttpRequest> arrived;
      final requested = <Uri>[];
      await tester.runAsync(() async {
        arrived = Completer<HttpRequest>();
        fixture = await PlaygroundRuntime.create();
        source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        source.listen((request) {
          if (!arrived.isCompleted) arrived.complete(request);
        });
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/failed-after-remount'),
          createHttpClient: () => _SourceRoutingClient(
            Uri.parse('http://127.0.0.1:${source.port}'),
            requested,
          ),
        );
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        fixture.runtime.io.requests.clear();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await resources.close();
          await runner.close();
          await source.close(force: true);
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(resources: resources, runner: runner),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('benchmark-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('native-kev').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      final pending = (await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        final request = await arrived.future.timeout(
          const Duration(seconds: 5),
        );
        await tester.pump();
        return request;
      }))!;
      expect(tester.takeException(), isNull);
      expect(resources.preparing, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('benchmark-cancel')), findsOneWidget);
      await tester.runAsync(() async {
        pending.response.statusCode = HttpStatus.serviceUnavailable;
        pending.response.write('Original source is unavailable');
        await pending.response.close();
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (resources.preparing) {
          if (DateTime.now().isAfter(until)) {
            fail('The source failure did not complete preparation cleanup');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        await tester.pump();
      });
      await tester.pumpAndSettle();
      final terminal = tester
          .widget<Text>(find.byKey(const Key('benchmark-resource-status')))
          .data!;
      expect(terminal, contains('准备失败（未计入模型失败）'));
      expect(terminal, contains('HTTP 503'));
      expect(find.byKey(const Key('benchmark-cancel')), findsNothing);
      expect(requested, [BenchmarkResources.files.first.url]);
      expect(fixture.runtime.io.requests, isEmpty);
      expect(runner.running, isFalse);
      expect(runner.current, isNull);
      expect((await tester.runAsync(runner.store.list))!, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'preparation belongs to resources across page remount and can be cancelled without a model batch',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner runner;
      late HttpServer source;
      late Completer<void> arrived;
      final requested = <Uri>[];
      await tester.runAsync(() async {
        arrived = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        source.listen((request) {
          if (!arrived.isCompleted) arrived.complete();
        });
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/held-sources'),
          createHttpClient: () => _SourceRoutingClient(
            Uri.parse('http://127.0.0.1:${source.port}'),
            requested,
          ),
        );
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        fixture.runtime.io.requests.clear();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await resources.close();
          await runner.close();
          await source.close(force: true);
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(resources: resources, runner: runner),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('benchmark-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('native-kev').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        await arrived.future.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      expect(tester.takeException(), isNull);
      expect(requested, [BenchmarkResources.files.first.url]);
      expect(runner.running, isFalse);
      expect(runner.current, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('benchmark-cancel')),
        findsOneWidget,
        reason: 'The original preparation remains app-owned, visible and cancellable after its page is replaced.',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('benchmark-run')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-resource-status')))
            .data,
        contains('准备'),
      );
      await tester.ensureVisible(find.byKey(const Key('benchmark-cancel')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-cancel')));
        await _wait(tester, find.textContaining('准备已取消'));
      });
      await tester.pumpAndSettle();
      expect(requested, hasLength(1));
      expect(fixture.runtime.io.requests, isEmpty);
      expect(runner.current, isNull);
      expect(runner.running, isFalse);
      expect((await tester.runAsync(runner.store.list))!, isEmpty);
      expect(find.byKey(const Key('benchmark-cancel')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'source preparation failure stays separate from model results and fits the minimum desktop viewport',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkRunner runner;
      late BenchmarkResources resources;
      final requested = <Uri>[];
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        resources = BenchmarkResources(
          Directory('${fixture.runtime.root.path}/empty-sources'),
          createHttpClient: () => _FailedSourceClient(requested),
        );
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        fixture.runtime.io.requests.clear();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(900, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 188),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: BenchmarkPage(
                        resources: resources,
                        runner: runner,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.ensureVisible(find.byKey(const Key('benchmark-target')));
      await tester.tap(find.byKey(const Key('benchmark-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('native-kev').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      await tester.pumpAndSettle();
      final buttonRect = tester.getRect(find.byKey(const Key('benchmark-run')));
      expect(buttonRect.top, greaterThanOrEqualTo(0));
      expect(buttonRect.bottom, lessThanOrEqualTo(560));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        await _wait(tester, find.textContaining('准备失败（未计入模型失败）'));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-resource-status')),
      );
      expect(find.textContaining('准备失败（未计入模型失败）'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-resource-status')))
            .data,
        contains('Original source download unavailable'),
      );
      expect(requested, [BenchmarkResources.files.first.url]);
      expect(runner.running, isFalse);
      expect(runner.current, isNull);
      expect((await tester.runAsync(runner.store.list))!, isEmpty);
      expect(fixture.runtime.io.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'complete original DecideBench report exposes history, item/pair evidence and safe export/delete',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner runner;
      late DecideBenchSuite suite;
      late File protectedFile;
      await tester.runAsync(() async {
        fixture = await PlaygroundRuntime.create();
        final cache = Directory('${fixture.runtime.root.path}/full-sources');
        final checked = Directory(
          '${cache.path}/decidebench/${BenchmarkResources.pin}',
        );
        for (final file in BenchmarkResources.files) {
          final destination = File('${checked.path}/${file.path}');
          await destination.parent.create(recursive: true);
          await File('benchmarks/sources/decidebench/${file.path}')
              .copy(destination.path);
        }
        resources = BenchmarkResources(cache);
        suite = await DecideBenchSuite.load(checked);
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        protectedFile = await File('${cache.path}/keep.txt')
            .writeAsString('source resource must survive history deletion');
        final originals = {
          for (final item in suite.items)
            '${item.state}\n${item.question}': item,
        };
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          final question = (body['questions'] as Map)['decision'] as Map;
          final original =
              originals['${body['state']}\n${question['instructions']}']!;
          final engineReply = jsonDecode(raw) as Map;
          engineReply['answers']['decision'] = {
            'type': 'choice',
            'choice': original.gold,
            'confidence': 1.0,
            'probabilities': {
              for (final key in original.options.keys)
                key: key == original.gold ? 1.0 : 0.0,
            },
          };
          return jsonEncode(engineReply);
        };
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1100, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(resources: resources, runner: runner),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('benchmark-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('native-kev').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        final until = DateTime.now().add(const Duration(minutes: 2));
        while (runner.current?.status != BenchmarkRunStatus.completed ||
            runner.running) {
          if (DateTime.now().isAfter(until)) {
            fail('The full original400 public run did not complete');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.runAsync(() async {
        await _wait(
          tester,
          find.textContaining('批次：${runner.current!.id} ·'),
          absent: find.byType(LinearProgressIndicator),
        );
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final completed = runner.current!;
      expect(fixture.runtime.io.requests, hasLength(400));
      expect(completed.groups, hasLength(200));
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-accuracy'))).data,
        contains('100.00%'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-pair-accuracy')))
            .data,
        contains('100.00%'),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('benchmark-coverage'))).data,
        contains('400 / 400'),
      );
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-items')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-items')));
      final first = suite.items.first;
      await tester.runAsync(() async {
        await _wait(tester, find.byKey(Key('benchmark-item-${first.id}')));
      });
      await tester.ensureVisible(find.byKey(Key('benchmark-item-${first.id}')));
      await tester.tap(find.byKey(Key('benchmark-item-${first.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('benchmark-item-json-${first.id}')), findsNothing);
      final completeFile = File(
        '${fixture.runtime.root.path}/complete400-original-fields.json',
      );
      final document = (await tester.runAsync(() async {
        await runner.store.exportTo(completed.id, completeFile);
        return jsonDecode(await completeFile.readAsString()) as Map;
      }))!;
      expect(document['items'], hasLength(400));
      expect(document['groups'], hasLength(200));
      final itemEvidence = (document['items'] as List).first as Map;
      expect(itemEvidence['request'], first.request('native-kev'));
      expect(itemEvidence['gold'], first.gold);
      expect(itemEvidence['prediction'], first.gold);
      expect(itemEvidence['result']['raw_response'], contains('native-kev'));
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-groups')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-groups')));
      await tester.runAsync(() async {
        await _wait(tester, find.byKey(Key('benchmark-group-${first.pairId}')));
      });
      await tester.ensureVisible(
        find.byKey(Key('benchmark-group-${first.pairId}')),
      );
      await tester.tap(find.byKey(Key('benchmark-group-${first.pairId}')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('benchmark-group-json-${first.pairId}')),
        findsNothing,
      );
      final pair = (document['groups'] as List).firstWhere(
        (row) => row['pair_id'] == first.pairId,
      ) as Map;
      expect(
        pair['members'],
        suite.items
            .where((item) => item.pairId == first.pairId)
            .map((item) => item.id)
            .toList(),
      );
      expect(pair['complete'], isTrue);
      expect(pair['correct'], isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(
          tester,
          find.byKey(Key('benchmark-history-${completed.id}')),
        );
      });
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-${completed.id}')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-${completed.id}')));
        await _wait(
          tester,
          find.textContaining('批次：${completed.id} ·'),
          absent: find.byType(LinearProgressIndicator),
        );
      });
      expect(runner.running, isFalse);
      expect(fixture.runtime.io.requests, hasLength(400));
      final destination = File('${fixture.runtime.root.path}/export-full.json');
      final semantics = tester.ensureSemantics();
      try {
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-export')));
          await tester.pumpAndSettle();
        });
        await tester.enterText(
          find.byKey(const Key('benchmark-export-path')),
          destination.path,
        );
        await tester.runAsync(() async {
          final confirm = find.semantics.byLabel('保存');
          tester.semantics.tap(confirm);
          tester.semantics.tap(confirm);
          await _wait(
            tester,
            find.byKey(const Key('benchmark-file-status')),
            frame: const Duration(milliseconds: 10),
          );
        });
        await tester.pumpAndSettle();
        expect(find.byType(BenchmarkPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        final exported = (await tester.runAsync(destination.readAsString))!;
        expect((jsonDecode(exported)['items'] as List), hasLength(400));
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-export')));
          await tester.pumpAndSettle();
        });
        await tester.runAsync(() async {
          final cancel = find.semantics.byLabel('取消');
          tester.semantics.tap(cancel);
          tester.semantics.tap(cancel);
        });
        await tester.pumpAndSettle();
        expect(find.byType(BenchmarkPage), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-export')));
          await tester.pumpAndSettle();
        });
        await tester.enterText(
          find.byKey(const Key('benchmark-export-path')),
          destination.path,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-export-save')));
          await _wait(
            tester,
            find.textContaining('导出失败'),
            frame: const Duration(milliseconds: 10),
          );
        });
        expect((await tester.runAsync(destination.readAsString))!, exported);
      } finally {
        semantics.dispose();
      }
      await tester.ensureVisible(find.byKey(const Key('benchmark-delete')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-delete')));
        await tester.pumpAndSettle();
      });
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-delete-confirm')));
        await _wait(
          tester,
          find.text('暂无评测历史'),
          frame: const Duration(milliseconds: 10),
        );
      });
      await tester.pumpAndSettle();
      expect((await tester.runAsync(runner.store.list))!, isEmpty);
      expect(
        (await tester.runAsync(protectedFile.readAsString))!,
        'source resource must survive history deletion',
      );
      expect(
        fixture.runtime.engine.state.instances.every(
          (instance) => instance.hasLiveProcess,
        ),
        isTrue,
      );
      expect(fixture.runtime.io.requests, hasLength(400));
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'full DecideBench page prepares original resources and a real public batch survives page disposal',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network();
      addTearDown(() => HttpOverrides.global = previous);
      late PlaygroundRuntime fixture;
      late BenchmarkResources resources;
      late BenchmarkRunner runner;
      late Completer<void> held;
      late Completer<void> arrived;
      await tester.runAsync(() async {
        // The real engine callback and these latches share the runAsync zone;
        // otherwise an IO completion queues into the paused fake widget zone.
        held = Completer<void>();
        arrived = Completer<void>();
        fixture = await PlaygroundRuntime.create();
        final cache = Directory('${fixture.runtime.root.path}/sources');
        final checked = Directory(
          '${cache.path}/decidebench/${BenchmarkResources.pin}',
        );
        for (final file in BenchmarkResources.files) {
          final destination = File('${checked.path}/${file.path}');
          await destination.parent.create(recursive: true);
          await File('benchmarks/sources/decidebench/${file.path}')
              .copy(destination.path);
        }
        resources = BenchmarkResources(cache);
        runner = BenchmarkRunner(
          client: fixture.playground,
          store: BenchmarkRunStore(
            directory: Directory('${fixture.runtime.root.path}/history'),
          ),
          models: fixture.council.models,
        );
        fixture.runtime.io.requests.clear();
        fixture.runtime.io.respond = (body, raw) async {
          if (!arrived.isCompleted) arrived.complete();
          await held.future;
          return raw;
        };
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!held.isCompleted) held.complete();
          await runner.interrupt();
          await runner.close();
          await resources.close();
          await fixture.close();
        });
      });
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: BenchmarkPage(resources: resources, runner: runner),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-target')));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining(BenchmarkResources.pin), findsWidgets);
      expect(find.textContaining('400 题 / 200 对'), findsOneWidget);
      expect(find.textContaining('CC BY 4.0'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('benchmark-timeout')))
            .controller!
            .text,
        '30',
      );
      await tester.ensureVisible(find.byKey(const Key('benchmark-target')));
      await tester.tap(find.byKey(const Key('benchmark-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('native-kev').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('benchmark-run')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-run')));
        await arrived.future.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      expect(
        tester.takeException(),
        isNull,
        reason:
            'Immediately after starting the public batch: resource status=${tester.widget<Text>(find.byKey(const Key('benchmark-resource-status'))).data}, running=${runner.running}, engine requests=${fixture.runtime.io.requests.length}',
      );
      expect(runner.running, isTrue);
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(held.isCompleted, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(runner.running, isTrue);
      expect(held.isCompleted, isFalse);
      await tester.runAsync(() async {
        await tester.pumpWidget(screen());
        await _wait(tester, find.byKey(const Key('benchmark-cancel')));
      });
      expect(
        tester.takeException(),
        isNull,
        reason: 'The application batch survived page disposal and remount discovery.',
      );
      final currentId = runner.current!.id;
      await tester.runAsync(() async {
        await _wait(tester, find.byKey(Key('benchmark-history-$currentId')));
      });
      await tester.ensureVisible(
        find.byKey(Key('benchmark-history-$currentId')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('benchmark-history-$currentId')));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      });
      await tester.ensureVisible(find.byKey(const Key('benchmark-cancel')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-cancel')));
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (runner.running) {
          if (DateTime.now().isAfter(until)) {
            fail('Public benchmark cancellation did not settle');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.runAsync(() async {
        await _wait(
          tester,
          find.textContaining('批次：${runner.current!.id} ·'),
          absent: find.byType(LinearProgressIndicator),
        );
      });
      await tester.pumpAndSettle();
      expect(held.isCompleted, isFalse);
      expect(runner.current!.status, BenchmarkRunStatus.cancelled);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('benchmark-current-status')))
            .data,
        contains('已取消'),
        reason: 'Selecting the active run in history must retain live app-owned progress.',
      );
      expect(runner.current!.summary['complete'], isFalse);
      expect(runner.current!.summary['accuracy'], isNull);
      expect(find.textContaining('未完成'), findsWidgets);
      final persisted = (await tester.runAsync(
        () => runner.store.load(runner.current!.id),
      ))!;
      expect(persisted.status, BenchmarkRunStatus.cancelled);
      expect(persisted.items, hasLength(1));
      expect(fixture.runtime.io.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _wait(
  WidgetTester tester,
  Finder finder, {
  Finder? absent,
  Duration frame = Duration.zero,
}) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  await tester.pump();
  while (finder.evaluate().isEmpty ||
      (absent?.evaluate().isNotEmpty ?? false)) {
    if (DateTime.now().isAfter(until)) {
      fail('Benchmark page action did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(frame);
  }
}

class _Network extends HttpOverrides {}

Future<JevalSuite> _prepareOriginalJeval(BenchmarkResources resources) async {
  final manifest = jsonDecode(
    await File('benchmarks/manifests/jeval.json').readAsString(),
  ) as Map;
  for (final value in manifest['files'] as List) {
    final path = (value as Map)['path'] as String;
    final destination = File(
      '${resources.cacheRoot.path}/jeval/${JevalSuite.pin}/$path',
    );
    await destination.parent.create(recursive: true);
    await File('benchmarks/sources/jeval/$path').copy(destination.path);
  }
  return await resources.prepareQuestions('jeval', DecisionCancellation())
      as JevalSuite;
}

/// Observes the public load boundary; all bytes and validation stay real.
class _HistorySessionObserver extends BenchmarkRunStore {
  _HistorySessionObserver(Directory directory) : super(directory: directory);
  final sessions = <String, BenchmarkHistorySession>{};
  final firstOpened = Completer<void>();
  @override
  BenchmarkHistorySession openHistory(String id) {
    final actual = super.openHistory(id);
    sessions[id] = actual;
    if (!firstOpened.isCompleted) firstOpened.complete();
    return actual;
  }
}

class _ObservedJournalStore extends BenchmarkRunStore {
  _ObservedJournalStore(Directory directory) : super(directory: directory);
  String? _observedId;
  int observedLoads = 0;
  int? oldLength;
  Object? readError;
  final lengthObserved = Completer<void>();
  final _lengthRelease = Completer<void>();
  final readFinished = Completer<void>();

  void observe(String id) => _observedId = id;
  void stopObserving() => _observedId = null;
  void releaseLength() {
    if (!_lengthRelease.isCompleted) _lengthRelease.complete();
  }

  @override
  Future<BenchmarkRun> load(String id) {
    if (id != _observedId) return super.load(id);
    observedLoads++;
    final filesystem = Zone.current;
    final journal = File('${directory.path}/$id-0.items.jsonl');
    final observed = _DelayedLengthFile(journal, (length) async {
      oldLength = length;
      if (!lengthObserved.isCompleted) lengthObserved.complete();
      await _lengthRelease.future;
    });
    final reading = IOOverrides.runZoned(
      () => super.load(id),
      createFile: (path) =>
          path == journal.path ? observed : filesystem.run(() => File(path)),
    );
    return reading.then<BenchmarkRun>(
      (value) {
        readFinished.complete();
        return value;
      },
      onError: (Object error, StackTrace stack) {
        readError = error;
        readFinished.complete();
        Error.throwWithStackTrace(error, stack);
      },
    );
  }
}

/// Delays one genuine length observation, never replacing or truncating data.
class _DelayedLengthFile implements File {
  _DelayedLengthFile(this.delegate, this.observed);
  final File delegate;
  final Future<void> Function(int) observed;
  @override
  String get path => delegate.path;
  @override
  Uri get uri => delegate.uri;
  @override
  Future<int> length() async {
    final result = await delegate.length();
    await observed(result);
    return result;
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      delegate.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      delegate.open(mode: mode);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Only the external download network fails; the resource preparer, app-owned
// runner/store and normal public model-discovery endpoint remain real.
class _FailedSourceClient implements HttpClient {
  _FailedSourceClient(this.requested);
  final List<Uri> requested;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    throw HttpException('Original source download unavailable', uri: url);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SourceRoutingClient implements HttpClient {
  _SourceRoutingClient(this.endpoint, this.requested);
  final Uri endpoint;
  final List<Uri> requested;
  final HttpClient _client = HttpClient();
  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return _client.getUrl(endpoint.resolve(url.path));
  }

  @override
  void close({bool force = false}) => _client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
