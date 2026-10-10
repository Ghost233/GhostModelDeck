import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_page.dart';
import 'package:ghost_model_deck/benchmark_resources.dart';
import 'package:ghost_model_deck/benchmark_runner.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/decidebench.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
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
        await _wait(tester, find.textContaining('历史读取失败'));
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
      await tester.pump();
      final first = suite.items.first;
      await tester.ensureVisible(find.byKey(Key('benchmark-item-${first.id}')));
      await tester.tap(find.byKey(Key('benchmark-item-${first.id}')));
      await tester.pumpAndSettle();
      final itemEvidence = jsonDecode(
        tester
            .widget<SelectableText>(
              find.byKey(Key('benchmark-item-json-${first.id}')),
            )
            .data!,
      ) as Map;
      expect(itemEvidence['request'], first.request('native-kev'));
      expect(itemEvidence['gold'], first.gold);
      expect(itemEvidence['prediction'], first.gold);
      expect(itemEvidence['result']['raw_response'], contains('native-kev'));
      await tester.ensureVisible(
        find.byKey(const Key('benchmark-detail-groups')),
      );
      await tester.tap(find.byKey(const Key('benchmark-detail-groups')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(Key('benchmark-group-${first.pairId}')),
      );
      await tester.tap(find.byKey(Key('benchmark-group-${first.pairId}')));
      await tester.pumpAndSettle();
      final pair = jsonDecode(
        tester
            .widget<SelectableText>(
              find.byKey(Key('benchmark-group-json-${first.pairId}')),
            )
            .data!,
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
      await tester.tap(find.byKey(Key('benchmark-history-${completed.id}')));
      await tester.pump();
      expect(runner.running, isFalse);
      expect(fixture.runtime.io.requests, hasLength(400));
      final destination = File('${fixture.runtime.root.path}/export-full.json');
      final semantics = tester.ensureSemantics();
      try {
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.tap(find.byKey(const Key('benchmark-export')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('benchmark-export-path')),
          destination.path,
        );
        await tester.runAsync(() async {
          final confirm = find.semantics.byLabel('保存');
          tester.semantics.tap(confirm);
          tester.semantics.tap(confirm);
          await _wait(tester, find.byKey(const Key('benchmark-file-status')));
        });
        await tester.pumpAndSettle();
        expect(find.byType(BenchmarkPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        final exported = (await tester.runAsync(destination.readAsString))!;
        expect((jsonDecode(exported)['items'] as List), hasLength(400));
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.tap(find.byKey(const Key('benchmark-export')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final cancel = find.semantics.byLabel('取消');
          tester.semantics.tap(cancel);
          tester.semantics.tap(cancel);
        });
        await tester.pumpAndSettle();
        expect(find.byType(BenchmarkPage), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('benchmark-export')));
        await tester.tap(find.byKey(const Key('benchmark-export')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('benchmark-export-path')),
          destination.path,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('benchmark-export-save')));
          await _wait(tester, find.textContaining('导出失败'));
        });
        expect((await tester.runAsync(destination.readAsString))!, exported);
      } finally {
        semantics.dispose();
      }
      await tester.ensureVisible(find.byKey(const Key('benchmark-delete')));
      await tester.tap(find.byKey(const Key('benchmark-delete')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('benchmark-delete-confirm')));
        await _wait(tester, find.text('暂无评测历史'));
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

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(until)) {
      fail('Benchmark page action did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

class _Network extends HttpOverrides {}

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
