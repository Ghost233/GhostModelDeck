import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/settings_page.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/sdk_service.dart';

import 'fixtures/council_runtime.dart';
import 'fixtures/test_environment.dart';

void main() {
  testWidgets(
    'missing instance requires explicit main model and excludes projector',
    (tester) async {
      final verified = await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final runtime = await CouncilRuntime.create(
            modelCount: 1,
            sourceSystemone: true,
          );
          final store = LaunchInstances(
            catalog: runtime.catalog,
            file: File('${runtime.root.path}/rebind.json'),
          );
          try {
            final original = runtime.library.state.artifacts.single;
            final definition = await store.save(
              name: 'Moved model',
              artifactId: original.id,
              engineId: EngineCatalog.officialId,
              configuration: EngineLaunchConfiguration(),
            );
            final source = File(original.files.first.path);
            final moved = await source.copy(
              '${source.parent.path}/Relocated-Q8_0.gguf',
            );
            await source.delete();
            List<int> u32(int n) => (ByteData(
              4,
            )..setUint32(0, n, Endian.little)).buffer.asUint8List();
            List<int> u64(int n) => (ByteData(
              8,
            )..setUint64(0, n, Endian.little)).buffer.asUint8List();
            final key = utf8.encode('general.architecture');
            final projectorBytes = BytesBuilder()
              ..add(ascii.encode('GGUF'))
              ..add(u32(3))
              ..add(u64(0))
              ..add(u64(1))
              ..add(u64(key.length))
              ..add(key)
              ..add(u32(8))
              ..add(u64(4))
              ..add(ascii.encode('clip'));
            await File('${source.parent.path}/mmproj-F16.gguf')
                .writeAsBytes(projectorBytes.takeBytes());
            await runtime.library.scan(
              Directory('${runtime.root.path}/models'),
            );
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(body: InstancesPage(instances: store)),
              ),
            );
            await tester.pumpAndSettle();
            final edit = find.byKey(
              ValueKey('instance-parameters:${definition.id}'),
            );
            await tester.ensureVisible(edit);
            await tester.tap(edit);
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(
              find.byKey(const Key('instance-rebind-dialog')),
              findsOneWidget,
            );
            expect(find.text('mmproj-F16.gguf'), findsNothing);
            final confirm = tester.widget<FilledButton>(
              find.byKey(const Key('instance-rebind-confirm')),
            );
            expect(confirm.onPressed, isNull);
            await tester.tap(find.text('取消').last);
            await tester.pumpAndSettle();
            expect(store.find(definition.id)!.artifactId, original.id);
            await tester.tap(edit);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('instance-rebind-choice')));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(DropdownMenuItem<String>),
                matching: find.text('mmproj-F16.gguf'),
              ),
              findsNothing,
            );
            await tester.tap(find.text(moved.uri.pathSegments.last).last);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('instance-rebind-confirm')));
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(find.text('实例配置'), findsOneWidget);
            expect(store.find(definition.id)!.artifactId, original.id);
            for (var i = 0; i < 100; i++) {
              await tester.pump(const Duration(milliseconds: 16));
              await Future<void>.delayed(const Duration(milliseconds: 5));
              final save = find.widgetWithText(FilledButton, '保存');
              if (save.evaluate().isNotEmpty &&
                  tester.widget<FilledButton>(save).onPressed != null) {
                break;
              }
            }
            final saved = store.changes.firstWhere(
              (_) => store.find(definition.id)!.artifactId != original.id,
            );
            await tester.tap(find.widgetWithText(FilledButton, '保存'));
            await saved.timeout(const Duration(seconds: 5));
            expect(
              store.find(definition.id)!.artifactId,
              runtime.library.state.artifacts
                  .singleWhere((a) => a.files.first.path == moved.path)
                  .id,
            );
            final projector = runtime.library.state.artifacts.singleWhere(
              (a) => a.files.first.path.endsWith('/mmproj-F16.gguf'),
            );
            final wrong = await store.save(
              name: 'Projector bound',
              artifactId: projector.id,
              engineId: EngineCatalog.officialId,
              configuration: EngineLaunchConfiguration(),
            );
            await tester.pumpAndSettle();
            final editWrong = find.byKey(
              ValueKey('instance-parameters:${wrong.id}'),
            );
            await tester.ensureVisible(editWrong);
            await tester.tap(editWrong);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('instance-rebind-dialog')),
              findsOneWidget,
            );
            await tester.tap(find.byKey(const Key('instance-rebind-choice')));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(DropdownMenuItem<String>),
                matching: find.text('mmproj-F16.gguf'),
              ),
              findsNothing,
            );
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

  testWidgets(
    'missing saved resources remain distinct from the live owner state',
    (tester) async {
      final verified = await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final runtime = await CouncilRuntime.create(
            modelCount: 1,
            sourceSystemone: true,
          );
          final store = LaunchInstances(
            catalog: runtime.catalog,
            file: File('${runtime.root.path}/owner-state.json'),
          );
          try {
            final asset = runtime.library.state.artifacts.single;
            final definition = await store.save(
              name: 'Retained live owner',
              artifactId: asset.id,
              engineId: EngineCatalog.officialId,
              configuration: EngineLaunchConfiguration(
                formValues: {'--ctx-size': '8192'},
              ),
            );
            final running = await store.start(definition.id);
            await store.save(
              id: definition.id,
              name: definition.name,
              artifactId: definition.artifactId,
              engineId: definition.engineId,
              configuration: EngineLaunchConfiguration(
                formValues: {'--ctx-size': '16384'},
              ),
            );
            await runtime.library.scanDirectories([]);
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(body: InstancesPage(instances: store)),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('运行中 · 模型缺失'), findsOneWidget);
            expect(store.runsFor(definition.id).single.id, running.id);
            final more = find.byKey(ValueKey('instance-more:${definition.id}'));
            await tester.ensureVisible(more);
            await tester.tap(more);
            await tester.pumpAndSettle();
            await tester.tap(find.text('实际启动命令'));
            await tester.pumpAndSettle();
            expect(find.textContaining('--ctx-size 8192'), findsOneWidget);
            expect(find.textContaining('--ctx-size 16384'), findsNothing);
            await tester.tap(find.widgetWithText(TextButton, '关闭'));
            await tester.pumpAndSettle();
            final stopped = store.changes.firstWhere(
              (_) => store
                  .runsFor(definition.id)
                  .every((run) => !run.hasLiveProcess),
            );
            final stop = find.widgetWithText(TextButton, '停止');
            await tester.ensureVisible(stop);
            await tester.tap(stop);
            await stopped.timeout(const Duration(seconds: 5));
            await tester.pumpAndSettle();
            expect(find.text('模型缺失'), findsOneWidget);
            expect(store.actualCommand(definition.id), isNull);
            expect(await File(asset.files.first.path).exists(), isTrue);
            expect(tester.takeException(), isNull);
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
  for (final brightness in Brightness.values) {
    testWidgets(
      'startup settings and instance choices stay synchronized at $brightness with large real fonts',
      (tester) async {
        tester.view.physicalSize = const Size(1800, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final verified = await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final runtime = await CouncilRuntime.create(modelCount: 1);
            await runtime.catalog.setRuntimeEnabled(false);
            final store = LaunchInstances(
              catalog: runtime.catalog,
              file: File('${runtime.root.path}/instances.json'),
            );
            final startup = StartupModelSet(
              file: File('${runtime.root.path}/startup.json'),
            );
            final preferences = DownloadPreferences(
              file: File('${runtime.root.path}/preferences.json'),
            );
            try {
              await startup.load();
              final original = await store.save(
                name: '自启动实例配置',
                artifactId: runtime.library.state.artifacts.single.id,
                engineId: EngineCatalog.officialId,
                configuration: EngineLaunchConfiguration(),
              );
              await startup.add('missing-retained');
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(
                    brightness: brightness,
                    fontFamily: 'Layout Noto CJK',
                  ),
                  home: Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(2)),
                      child: Scaffold(
                        body: Row(
                          children: [
                            Expanded(
                              child: SettingsPage(
                                preferences: preferences,
                                libraryPath: runtime.root.path,
                                onLibraryPathChanged: (path) async => path,
                                pickLibraryDirectory: () async => null,
                                startupSet: startup,
                                instances: store,
                              ),
                            ),
                            Expanded(
                              child: InstancesPage(
                                instances: store,
                                startupSet: startup,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const Key('settings-nav-startup')));
              await tester.pumpAndSettle();
              expect(find.byType(DataTable), findsNWidgets(2));
              final settingsChoice = find.byKey(
                ValueKey('settings-autostart:${original.id}'),
              );
              await tester.ensureVisible(settingsChoice);
              final selected = startup.changes.firstWhere(
                (_) => startup.contains(original.id),
              );
              await tester.tap(settingsChoice);
              await selected.timeout(const Duration(seconds: 5));
              await tester.pumpAndSettle();
              final instanceChoice = find.byKey(
                ValueKey('instance-autostart:${original.id}'),
              );
              expect(tester.widget<Checkbox>(instanceChoice).value, isTrue);
              await startup.saveAutoOpenEngines(true);
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<SwitchListTile>(
                      find.byKey(const Key('autostart-master')),
                    )
                    .value,
                isTrue,
              );
              await tester.ensureVisible(instanceChoice);
              final removed = startup.changes.firstWhere(
                (_) => !startup.contains(original.id),
              );
              await tester.tap(instanceChoice);
              await removed.timeout(const Duration(seconds: 5));
              await tester.pumpAndSettle();
              expect(tester.widget<Checkbox>(settingsChoice).value, isFalse);
              expect(startup.contains('missing-retained'), isTrue);
              expect(runtime.catalog.runtimeEnabled, isFalse);
              expect(runtime.engine.hasLiveInstances, isFalse);
              expect(tester.takeException(), isNull);
              return true;
            } finally {
              await tester.pumpWidget(const SizedBox());
              await startup.close();
              await store.close();
              await runtime.close();
              preferences.dispose();
            }
          }, _NetworkBoundary()),
        );
        expect(verified, isTrue);
      },
    );
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
