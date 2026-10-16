import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/sdk_service.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/test_environment.dart';

void main() {
  setUpAll(() async {
    expect(await layoutFontFile.exists(), isTrue);
    await (FontLoader('Layout Noto CJK')..addFont(
          Future.value(
            ByteData.sublistView(await layoutFontFile.readAsBytes()),
          ),
        ))
        .load();
    expect(await materialIconsFontFile.exists(), isTrue);
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(await materialIconsFontFile.readAsBytes()),
          ),
        ))
        .load();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.5, 2.0]) {
      testWidgets(
        'instance table keeps long configuration names and actions reachable at $brightness/$scale with real fonts',
        (tester) async {
          tester.view.physicalSize = const Size(900, 560);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final verified = await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              final runtime = await CouncilRuntime.create(
                modelCount: 1,
                sourceSystemone: true,
              );
              final store = LaunchInstances(
                catalog: runtime.catalog,
                file: File('${runtime.root.path}/instances.json'),
              );
              final startup = StartupModelSet(
                file: File('${runtime.root.path}/startup.json'),
              );
              try {
                await startup.load();
                final original = await store.save(
                  name: List.filled(6, '很长的实例名称与参数配置').join(' · '),
                  artifactId: runtime.library.state.artifacts.single.id,
                  engineId: EngineCatalog.officialId,
                  configuration: EngineLaunchConfiguration(
                    argumentText: '-np 4',
                  ),
                );
                await store.copy(original.id);
                await tester.pumpWidget(
                  MaterialApp(
                    theme: ThemeData(
                      brightness: brightness,
                      fontFamily: 'Layout Noto CJK',
                    ),
                    home: Builder(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(scale)),
                        child: Scaffold(
                          body: SizedBox(
                            width: 620,
                            child: InstancesPage(
                              instances: store,
                              startupSet: startup,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                expect(
                  tester.widget<DataTable>(find.byType(DataTable)).rows,
                  hasLength(2),
                );
                final more = find.byKey(
                  ValueKey('instance-more:${original.id}'),
                );
                await tester.ensureVisible(more);
                await tester.tap(more);
                await tester.pumpAndSettle();
                final copied = store.changes.firstWhere(
                  (_) => store.definitions.length == 3,
                );
                await tester.tap(find.text('复制').last);
                await copied.timeout(const Duration(seconds: 5));
                await tester.pumpAndSettle();
                expect(
                  tester.widget<DataTable>(find.byType(DataTable)).rows,
                  hasLength(3),
                );
                expect(tester.takeException(), isNull);
                expect(runtime.io.requests, isEmpty);
                return true;
              } finally {
                await tester.pumpWidget(const SizedBox.shrink());
                await store.close();
                await runtime.close();
              }
            }, _NetworkBoundary()),
          );
          expect(verified, isTrue);
        },
      );
    }
  }
  test('configured inference concurrency uses text overrides without treating a request queue as inference slots', () {
    expect(EngineLaunchConfiguration().inferenceConcurrency, 1);
    expect(
      EngineLaunchConfiguration(argumentText: '-np 4').inferenceConcurrency,
      4,
    );
    expect(
      EngineLaunchConfiguration(argumentText: '--parallel=0')
          .inferenceConcurrency,
      isNull,
    );
    expect(
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--queue-size': '256'},
      ).inferenceConcurrency,
      isNull,
    );
    expect(
      EngineLaunchConfiguration(argumentText: '--ctx-size=8192 -np 2')
          .contextLength,
      8192,
    );
  });
  testWidgets(
    'instance table searches all saved configurations and changes only the selected autostart entry',
    (tester) async {
      final verified = await tester.runAsync(() async {
        final runtime = await HttpOverrides.runWithHttpOverrides(
          () => CouncilRuntime.create(modelCount: 1, sourceSystemone: true),
          _NetworkBoundary(),
        );
        final store = LaunchInstances(
          catalog: runtime.catalog,
          file: File('${runtime.root.path}/instances.json'),
        );
        final startup = StartupModelSet(
          file: File('${runtime.root.path}/startup.json'),
        );
        try {
          await startup.load();
          for (var index = 0; index < 63; index++) {
            await store.save(
              name: '实例 ${index.toString().padLeft(2, '0')}',
              artifactId: runtime.library.state.artifacts.single.id,
              engineId: EngineCatalog.officialId,
              configuration: EngineLaunchConfiguration(
                formValues: {
                  ...EngineLaunchConfiguration.initialValues,
                  '--ctx-size': index == 62 ? '32768' : '4096',
                },
                argumentText: index == 62 ? '-np 4' : '',
              ),
            );
          }
          final target = store.definitions.last;
          final processCount = runtime.engine.state.instances.length;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: InstancesPage(instances: store, startupSet: startup),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DataTable), findsOneWidget);
          expect(
            tester.widget<DataTable>(find.byType(DataTable)).rows,
            hasLength(20),
          );
          for (final label in [
            '实例名称',
            '模型名字',
            '对应模型',
            '引擎',
            '上下文',
            '并发',
            '自启动',
            '状态',
            '操作',
          ]) {
            expect(find.text(label), findsWidgets);
          }
          expect(find.text('实例 62'), findsNothing);
          await tester.enterText(
            find.byKey(const Key('instances-search')),
            '实例 62',
          );
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(DataTable),
              matching: find.text('实例 62'),
            ),
            findsOneWidget,
          );
          expect(find.text('32768'), findsOneWidget);
          expect(find.text('4'), findsOneWidget);
          final toggle = find.byKey(
            ValueKey('instance-autostart:${target.id}'),
          );
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!startup.contains(target.id)) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Autostart selection did not save');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await tester.pump();
          }
          await tester.pump();
          final reopened = StartupModelSet(file: startup.file);
          await reopened.load();
          expect(reopened.entries.map((entry) => entry.instanceId), [
            target.id,
          ]);
          expect(runtime.engine.state.instances, hasLength(processCount));
          expect(
            store.definitions.expand((entry) => store.runsFor(entry.id)),
            isEmpty,
          );
          final more = find.byKey(ValueKey('instance-more:${target.id}'));
          await tester.ensureVisible(more);
          await tester.tap(more);
          await tester.pumpAndSettle();
          final copied = store.changes.firstWhere(
            (_) => store.definitions.length == 64,
          );
          await tester.tap(find.text('复制').last);
          await copied.timeout(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          final copy = store.definitions.singleWhere(
            (entry) => entry.name == '${target.name} 副本',
          );
          expect(copy.configuration.toJson(), target.configuration.toJson());
          expect(startup.contains(copy.id), isFalse);
          expect(store.find(target.id)!.publicName, target.publicName);
          expect(runtime.io.requests, isEmpty);
          expect(tester.takeException(), isNull);
          return true;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await store.close();
          await runtime.close();
        }
      });
      expect(verified, isTrue);
    },
  );
}

class _NetworkBoundary extends HttpOverrides {}
