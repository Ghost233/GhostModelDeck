import 'fixtures/parameter_editor_navigation.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/chat_protocol.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/council.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  for (final (contextText, expected) in <(String, int?)>[
    ('16K', 16384),
    ('auto', null),
  ]) {
    testWidgets(
      'observed Splash context $contextText previews pending capacity without changing the live owner',
      (tester) async {
        final (
          fixture,
          cpp,
          catalog,
          store,
          controller,
          definition,
          run,
        ) = (await tester.runAsync(() async {
          final fixture = await SplashRuntimeFixture.create();
          fixture.io.monitorStatus = {
            'maximum_context_tokens': 8192,
            'http': {
              'requests': {'capacity': 1},
            },
          };
          final cpp = LlamaEngine(
            library: fixture.library,
            installationDirectory: Directory('${fixture.root.path}/cpp'),
          );
          final catalog = EngineCatalog(
            library: fixture.library,
            officialEngine: cpp,
            useRegistry: ModelUseRegistry(fixture.library),
            splashIO: fixture.io,
            registryFile: File('${fixture.root.path}/engines.json'),
          );
          final entry = await catalog.link(fixture.source.path);
          final store = LaunchInstances(
            catalog: catalog,
            file: File('${fixture.root.path}/instances.json'),
          );
          final definition = await store.save(
            name: 'Prefix preview',
            artifactId: fixture.asset.id,
            engineId: entry.id,
            configuration: EngineLaunchConfiguration(
              family: EngineFamily.splash,
              formValues: {'--max-context': '8192'},
              drafter: const DrafterConfiguration(enabled: false),
            ),
          );
          final run = await HttpOverrides.runWithHttpOverrides(
            () => store.start(definition.id),
            _NetworkBoundary(),
          );
          final controller = CouncilController(
            catalog: catalog,
            launchInstances: store,
            modelRegistryFile: File('${fixture.root.path}/committees.json'),
            scenarioRegistryFile: File('${fixture.root.path}/scenarios.json'),
          );
          await controller.models.load();
          return (fixture, cpp, catalog, store, controller, definition, run);
        }))!;
        addTearDown(
          () => tester.runAsync(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await controller.close();
            await store.close();
            await catalog.shutdown();
            catalog.close();
            cpp.close();
            await fixture.close();
          }),
        );
        expect(store.contextLengthFor(definition.id), 8192);
        final prepareCount = fixture.io.calls
            .where(
              (args) => args.any(
                (arg) => arg.contains('# Ghost Model Deck Splash preparation'),
              ),
            )
            .length;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InstancesPage(instances: store, models: controller.models),
            ),
          ),
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        final edit = find.byKey(
          ValueKey('instance-parameters:${definition.id}'),
        );
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await tester.pumpAndSettle();
        await selectParameterGroup(tester, '参数文本与命令');
        final raw = '--max-con $contextText';
        await tester.enterText(
          find.byKey(const Key('engine-argument-text')),
          raw,
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await tester.tap(find.text('状态与生效'));
        await tester.pumpAndSettle();
        expect(
          find.text('实例 Prefix preview：8192 → ${expected ?? '未指定'}'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final saved = store.changes.firstWhere(
            (_) => store.find(definition.id)!.configuration.argumentText == raw,
          );
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await saved.timeout(const Duration(seconds: 5));
        });
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip(
            expected == null
                ? '已生效上下文 8192；保存配置容量未确定，启动时由引擎核对。'
                : '已生效上下文 8192；保存配置 $expected，修改后重启生效。',
          ),
          findsOneWidget,
        );
        expect(store.contextLengthFor(definition.id), 8192);
        expect(store.runsFor(definition.id).single.id, run.id);
        expect(fixture.io.starts, 1);
        expect(
          fixture.io.calls
              .where(
                (args) => args.any(
                  (arg) =>
                      arg.contains('# Ghost Model Deck Splash preparation'),
                ),
              )
              .length,
          prepareCount,
        );
        await tester.runAsync(() async {
          await store.stop(definition.id);
          fixture.io.monitorStatus = null;
          await HttpOverrides.runWithHttpOverrides(
            () => store.start(definition.id),
            _NetworkBoundary(),
          );
        });
        expect(store.contextLengthFor(definition.id), expected);
        expect(fixture.io.starts, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final runningFamily in [EngineFamily.llamaCpp, EngineFamily.splash]) {
    testWidgets(
      'rebound instance editor keeps the live ${runningFamily.name} draft owner',
      (tester) async {
        final (fixture, cppIO, cpp, catalog, store, bytes) = (await tester
            .runAsync(() async {
              final fixture = await SplashRuntimeFixture.create();
              final cppIO = _RuntimeIO();
              final bytes = engineArchive();
              final cpp = LlamaEngine(
                library: fixture.library,
                installationDirectory: Directory('${fixture.root.path}/cpp'),
                io: cppIO,
                release: LlamaRelease(
                  tag: 'b11381',
                  commit: '836d57176',
                  url: Uri.parse('https://github.com/fixture'),
                  sha256: sha256.convert(bytes).toString(),
                  sizeBytes: bytes.length,
                ),
              );
              final catalog = EngineCatalog(
                library: fixture.library,
                officialEngine: cpp,
                useRegistry: ModelUseRegistry(fixture.library),
                io: cppIO,
                splashIO: fixture.io,
                registryFile: File('${fixture.root.path}/engines.json'),
              );
              final store = LaunchInstances(
                catalog: catalog,
                file: File('${fixture.root.path}/instances.json'),
              );
              return (fixture, cppIO, cpp, catalog, store, bytes);
            }))!;
        addTearDown(
          () => tester.runAsync(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await store.close();
            await catalog.shutdown();
            catalog.close();
            cpp.close();
            await fixture.close();
          }),
        );
        final (definition, run, expectedSource, pending) = (await tester
            .runAsync(() async {
              final archive = await File('${fixture.root.path}/engine.tar.gz')
                  .writeAsBytes(bytes);
              await catalog.installOfficial(verifiedArchive: archive);
              final splash = await catalog.link(fixture.source.path);
              final cppDraft = await File('${fixture.root.path}/cpp-draft.gguf')
                  .writeAsString('selected native draft');
              final splashDraft = await Directory(
                '${fixture.root.path}/splash-draft',
              ).create();
              await File('${splashDraft.path}/config.json')
                  .writeAsString('{"architectures":["DFlashDraftModel"]}');
              await File('${splashDraft.path}/model.safetensors')
                  .writeAsString('selected external draft');
              final splashRunning = runningFamily == EngineFamily.splash;
              final definition = await store.save(
                name: 'Rebound owner',
                artifactId: fixture.asset.id,
                engineId: splashRunning ? splash.id : EngineCatalog.officialId,
                configuration: EngineLaunchConfiguration(
                  family: runningFamily,
                  formValues: {
                    splashRunning ? '--max-context' : '--ctx-size': '8192',
                  },
                  drafter: DrafterConfiguration(
                    enabled: true,
                    path: splashRunning ? splashDraft.path : cppDraft.path,
                    mode: splashRunning ? null : 'draft-simple',
                  ),
                ),
              );
              final run = await HttpOverrides.runWithHttpOverrides(
                () => store.start(definition.id),
                _NetworkBoundary(),
              );
              final nextFamily = splashRunning
                  ? EngineFamily.llamaCpp
                  : EngineFamily.splash;
              final pending = await store.save(
                id: definition.id,
                name: definition.name,
                artifactId: definition.artifactId,
                engineId: splashRunning ? EngineCatalog.officialId : splash.id,
                configuration: EngineLaunchConfiguration(
                  family: nextFamily,
                  formValues: {
                    splashRunning ? '--ctx-size' : '--max-context': '16384',
                  },
                  drafter: const DrafterConfiguration(
                    enabled: false,
                    path: '/deleted/pending-source',
                  ),
                ),
              );
              final expected = splashRunning
                  ? await splashDraft.resolveSymbolicLinks()
                  : await cppDraft.resolveSymbolicLinks();
              return (definition, run, expected, pending);
            }))!;
        expect(store.contextLengthFor(definition.id), 8192);
        expect(pending.configuration.contextLength, 16384);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: InstancesPage(instances: store)),
          ),
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        final edit = find.byKey(
          ValueKey('instance-parameters:${definition.id}'),
        );
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await tester.pumpAndSettle();
        await tester.tap(find.text('状态与生效'));
        await tester.pumpAndSettle();
        expect(find.text(expectedSource), findsOneWidget);
        expect(find.text('无就绪运行实例'), findsNothing);
        expect(store.runsFor(definition.id).single.id, run.id);
        expect(cppIO.startedArguments.length + fixture.io.starts, 1);
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => store.stop(definition.id));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'instance editor rejects native generation ranges and preserves editable input',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (fixture, cpp, catalog, entry) = (await tester.runAsync(() async {
        final fixture = await SplashRuntimeFixture.create();
        final cpp = LlamaEngine(
          library: fixture.library,
          installationDirectory: fixture.source,
        );
        final catalog = EngineCatalog(
          library: fixture.library,
          officialEngine: cpp,
          useRegistry: ModelUseRegistry(fixture.library),
          registryFile: File('${fixture.root.path}/engines.json'),
          splashIO: fixture.io,
        );
        final entry = await catalog.link(fixture.source.path);
        return (fixture, cpp, catalog, entry);
      }))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await catalog.shutdown();
          catalog.close();
          cpp.close();
          await fixture.close();
        }),
      );
      EngineLaunchConfiguration? saved;
      final variant = LocalModelVariant(
        id: fixture.asset.id,
        label: 'GGUF',
        artifacts: [fixture.asset],
      );
      await tester.runAsync(() async {
        late BuildContext host;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const Scaffold();
              },
            ),
          ),
        );
        unawaited(
          showDialog<void>(
            context: host,
            builder: (_) => ModelRunDialog(
              catalog: catalog,
              library: fixture.library,
              modelPackage: LocalModelPackage(
                directoryPath: fixture.source.path,
                name: 'Selected model',
                variants: [variant],
                details: [],
              ),
              variant: variant,
              initialEngineId: entry.id,
              initialConfiguration: EngineLaunchConfiguration(
                family: EngineFamily.splash,
                drafter: const DrafterConfiguration(enabled: false),
                generation: GenerationConfiguration({'temperature': 2.1}),
              ),
              onSaveInstance: (_, _, _, configuration) async {
                saved = configuration;
              },
            ),
          ),
        );
        await _settleFilesystemFrames(tester);
      });
      await selectParameterGroup(tester, '基本生成');
      final field = find.byKey(
        const Key('parameter-number:generation:temperature'),
      );
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, '2.1');
      expect(find.textContaining('0 到 2'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.enterText(field, 'NaN');
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      expect(tester.widget<TextField>(field).controller!.text, 'NaN');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.enterText(field, '0.6');
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      await tester.ensureVisible(
        find.byKey(const Key('parameter-choice:generation:max_tokens')),
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:generation:max_tokens')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '停止与输出');
      final stop = find.byKey(const Key('parameter-list:generation:stop'));
      for (final value in ['1', '2', '3', '4', '5']) {
        await tester.ensureVisible(stop);
        await tester.enterText(stop, value);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.runAsync(() => _settleFilesystemFrames(tester));
      }
      expect(find.textContaining('最多支持 4'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      final fifth = find.widgetWithText(InputChip, '5');
      await tester.ensureVisible(fifth);
      await tester.tap(
        find.descendant(of: fifth, matching: find.byTooltip('Delete')),
      );
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      await tester.ensureVisible(
        find.byKey(const Key('parameter-choice:generation:response_format')),
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:generation:response_format')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('json_schema').last);
      await tester.pumpAndSettle();
      final schema = find.byKey(
        const Key('parameter-object:generation:schema'),
      );
      await tester.ensureVisible(schema);
      await tester.enterText(schema, '[]');
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.enterText(schema, '{"type":"object"}');
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      await tester.ensureVisible(
        find.byKey(const Key('parameter-choice:generation:ignore_eos')),
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:generation:ignore_eos')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启').last);
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      expect(find.textContaining('ignore_eos 不能'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('parameter-choice:generation:ignore_eos')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭').last);
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(FilledButton, '保存')),
      );
      await tester.pumpAndSettle();
      expect(saved!.generation.values['temperature'], 0.6);
      expect(saved!.generation.values.containsKey('max_tokens'), isTrue);
      expect(saved!.generation.values['max_tokens'], isNull);
      expect(saved!.generation.values['stop'], ['1', '2', '3', '4']);
      expect(saved!.generation.values['response_format'], {
        'type': 'json_schema',
        'json_schema': {
          'name': 'response',
          'schema': {'type': 'object'},
        },
      });
      expect(fixture.io.starts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final family in [EngineFamily.llamaCpp, EngineFamily.splash]) {
    testWidgets(
      'decision draft controls preserve native policy for ${family.name}',
      (tester) async {
        late Directory root;
        late EngineCatalog catalog;
        late LibraryArtifact asset;
        late String engineId;
        late Future<void> Function() closeResources;
        await tester.runAsync(() async {
          if (family == EngineFamily.splash) {
            final fixture = await SplashRuntimeFixture.create(
              ordinaryChat: false,
            );
            final cpp = LlamaEngine(
              library: fixture.library,
              installationDirectory: fixture.source,
            );
            catalog = EngineCatalog(
              library: fixture.library,
              officialEngine: cpp,
              useRegistry: ModelUseRegistry(fixture.library),
              registryFile: File('${fixture.root.path}/engines.json'),
              splashIO: fixture.io,
            );
            engineId = (await catalog.link(fixture.source.path)).id;
            root = fixture.root;
            asset = fixture.asset;
            closeResources = () async {
              await catalog.shutdown();
              catalog.close();
              cpp.close();
              await fixture.close();
            };
          } else {
            final fixture = await _LaunchTextFixture.create(
              ordinaryChat: false,
            );
            root = fixture.root;
            catalog = fixture.catalog;
            asset = fixture.asset;
            engineId = EngineCatalog.officialId;
            closeResources = fixture.close;
          }
        });
        final store = LaunchInstances(
          catalog: catalog,
          file: File('${root.path}/policy-instances.json'),
        );
        addTearDown(
          () => tester.runAsync(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await store.close();
            await closeResources();
          }),
        );
        expect(asset.decisionType, 'kev');
        final definition = (await tester.runAsync(
          () => store.save(
            name: 'Native policy',
            artifactId: asset.id,
            engineId: engineId,
            configuration: EngineLaunchConfiguration(
              family: family,
              drafter: DrafterConfiguration(
                enabled: false,
                mode: family == EngineFamily.llamaCpp ? 'draft-simple' : null,
              ),
            ),
          ),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: InstancesPage(instances: store)),
          ),
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        Future<void> open() async {
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('编辑参数'));
          await tester.tap(find.text('编辑参数'));
          await tester.runAsync(() => _settleFilesystemFrames(tester));
          await tester.pumpAndSettle();
          await selectParameterGroup(tester, '草稿模型');
        }

        await open();
        final toggle = find.byKey(const Key('splash-drafter-enabled'));
        if (family == EngineFamily.splash) {
          expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
          expect(find.textContaining('不支持草稿模型'), findsWidgets);
          await tester.tap(find.widgetWithText(TextButton, '取消'));
          await tester.pumpAndSettle();
          expect(store.runsFor(definition.id), isEmpty);
          return;
        }
        expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final mode = find.byKey(const Key('drafter-mode'));
        expect(
          tester
              .widget<DropdownButton<String>>(mode)
              .items!
              .map((item) => item.value),
          [
            '',
            'draft-simple',
            'draft-eagle3',
            'draft-mtp',
            'draft-dflash',
            'draft-dspark',
          ],
        );
        Future<void> choose(String label) async {
          await tester.ensureVisible(mode);
          await tester.tap(mode);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
        }

        for (final label in ['普通 draft', 'EAGLE3', 'MTP', 'DFlash', 'DSpark']) {
          await choose(label);
        }
        await choose('MTP');
        expect(find.textContaining('可留空'), findsWidgets);
        final draft = (await tester.runAsync(
          () =>
              File('${root.path}/chosen-draft.gguf')
                  .writeAsString('native input'),
        ))!;
        final picks = <String?>[draft.path, null, draft.path];
        const native = MethodChannel('com.ghost233.ghostmodeldeck/native');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          expect(call.method, 'pickParameterFile');
          return picks.removeAt(0);
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            native,
            null,
          ),
        );
        final pathRow = find.byKey(const Key('parameter-field:drafter-path'));
        final path = find.byKey(const Key('parameter-path:drafter-path'));
        Future<void> pick() async {
          final button = find.descendant(
            of: pathRow,
            matching: find.text('选择…'),
          );
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.runAsync(() => _settleFilesystemFrames(tester));
        }

        await pick();
        expect(tester.widget<TextField>(path).controller!.text, draft.path);
        await pick();
        expect(tester.widget<TextField>(path).controller!.text, draft.path);
        final resetPath = find.descendant(
          of: pathRow,
          matching: find.byTooltip('恢复默认'),
        );
        await tester.ensureVisible(resetPath);
        await tester.tap(resetPath);
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await tester.runAsync(() async {
          final saved = store.changes.firstWhere(
            (_) => store.find(definition.id)!.configuration.drafter!.enabled,
          );
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await saved.timeout(const Duration(seconds: 5));
        });
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        expect(store.find(definition.id)!.configuration.drafter!.toJson(), {
          'enabled': true,
          'path': null,
          'mode': 'draft-mtp',
        });
        await open();
        await choose('DSpark');
        await pick();
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        expect(store.find(definition.id)!.configuration.drafter!.toJson(), {
          'enabled': true,
          'path': null,
          'mode': 'draft-mtp',
        });
        expect(store.runsFor(definition.id), isEmpty);
        expect(await tester.runAsync(draft.readAsString), 'native input');
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final unit in ['G', 'GiB']) {
    testWidgets(
      'Splash $unit loading amount keeps middle editing through search and saves without startup',
      (tester) async {
        final (fixture, cpp, catalog, entry) = (await tester.runAsync(() async {
          final fixture = await SplashRuntimeFixture.create();
          final cpp = LlamaEngine(
            library: fixture.library,
            installationDirectory: fixture.source,
          );
          final catalog = EngineCatalog(
            library: fixture.library,
            officialEngine: cpp,
            useRegistry: ModelUseRegistry(fixture.library),
            registryFile: File('${fixture.root.path}/engines.json'),
            splashIO: fixture.io,
          );
          final entry = await catalog.link(fixture.source.path);
          await catalog.saveLaunchDefaults(
            entry.id,
            EngineLaunchConfiguration(
              family: EngineFamily.splash,
              formValues: {'--max-memory': '28$unit'},
            ),
          );
          return (fixture, cpp, catalog, entry);
        }))!;
        addTearDown(
          () => tester.runAsync(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await catalog.shutdown();
            catalog.close();
            cpp.close();
            await fixture.close();
          }),
        );
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: EnginePage(
                  catalog: catalog,
                  pickEngineDirectory: () async => null,
                ),
              ),
            ),
          );
          await catalog.refresh();
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final action = find.byKey(ValueKey('engine-parameters:${entry.id}'));
          await tester.ensureVisible(action);
          await tester.tap(action);
          await catalog.readParameters(entry.id);
        });
        await tester.pumpAndSettle();
        await selectParameterGroup(tester, '上下文与内存');
        final amount = find.byKey(const Key('parameter-quantity:--max-memory'));
        await tester.ensureVisible(amount);
        expect(
          find.descendant(
            of: find.byKey(const Key('parameter-field:--max-memory')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DropdownButton<String> && widget.value == unit,
            ),
          ),
          findsOneWidget,
        );
        await tester.tap(amount);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '218',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(tester.widget<TextField>(amount).controller!.text, '218');
        expect(
          tester.widget<TextField>(amount).controller!.selection.baseOffset,
          2,
        );
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '18',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('parameter-search')),
          'max-memory',
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(amount).controller!.text, '18');
        await tester.runAsync(() async {
          final saved = catalog.changes.firstWhere((state) => !state.busy);
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await saved.timeout(const Duration(seconds: 5));
          await tester.pump();
        });
        await tester.pumpAndSettle();
        expect(
          catalog.launchDefaultsFor(entry.id).formValues['--max-memory'],
          '18$unit',
        );
        expect(fixture.io.starts, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'instance capacity preview cancels without saving and save remains pending',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      final store = LaunchInstances(
        catalog: fixture.catalog,
        file: File('${fixture.root.path}/instances.json'),
      );
      final controller = CouncilController(
        catalog: fixture.catalog,
        launchInstances: store,
        modelRegistryFile: File('${fixture.root.path}/committees.json'),
        scenarioRegistryFile: File('${fixture.root.path}/scenarios.json'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        final closed = await tester.runAsync(() async {
          await controller.close();
          await store.close();
          await fixture.close();
          return true;
        });
        expect(closed, isTrue);
      });
      final definition = (await tester.runAsync(() async {
        final value = await store.save(
          name: 'Capacity',
          artifactId: fixture.asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(
            formValues: {'--ctx-size': '8192'},
          ),
        );
        await controller.models.load();
        return value;
      }))!;
      final original = (await tester.runAsync(store.file.readAsString))!;
      final exercised = await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InstancesPage(instances: store, models: controller.models),
            ),
          ),
        );
        await _settleFilesystemFrames(tester);
        Future<void> edit() async {
          await tester.ensureVisible(find.text('编辑参数'));
          await tester.tap(find.text('编辑参数'));
          await _settleFilesystemFrames(tester);
          await selectParameterGroup(tester, '上下文与内存');
          final field = find.byKey(
            const ValueKey('parameter-number:--ctx-size'),
          );
          await tester.ensureVisible(field);
          await tester.enterText(field, '16384');
          await _settleFilesystemFrames(tester);
          await tester.tap(find.text('状态与生效'));
          await tester.pumpAndSettle();
          expect(find.text('实例 Capacity：8192 → 16384'), findsOneWidget);
          await tester.tap(find.widgetWithText(TextButton, '关闭'));
          await tester.pumpAndSettle();
        }

        await edit();
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(await store.file.readAsString(), original);
        await edit();
        final saved = store.changes.firstWhere(
          (_) =>
              store.find(definition.id)!.configuration.contextLength == 16384,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await _settleFilesystemFrames(tester);
        expect(store.contextLengthFor(definition.id), 8192);
        expect(store.find(definition.id)!.configuration.contextLength, 16384);
        expect(store.runsFor(definition.id), isEmpty);
        expect(tester.takeException(), isNull);
        return true;
      });
      expect(exercised, isTrue);
    },
  );
  testWidgets(
    'instance JEV budget saves without changing launch arguments or starting a model',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      final store = LaunchInstances(
        catalog: fixture.catalog,
        file: File('${fixture.root.path}/instances.json'),
      );
      addTearDown(() => tester.runAsync(store.close));
      final definition = (await tester.runAsync(
        () => store.save(
          name: 'Saved',
          artifactId: fixture.asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InstancesPage(instances: store)),
        ),
      );
      await _settleFilesystemFrames(tester);
      await tester.runAsync(() => _openInstanceMore(tester, definition.id));
      final budget = find.text('JEV 预算 60 秒');
      await tester.ensureVisible(budget);
      await tester.runAsync(() => tester.tap(budget));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('instance-jev-budget')), '0');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();
      expect(find.text('请输入正整数秒'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('instance-jev-budget')),
        '17',
      );
      await tester.runAsync(() async {
        final saved = store.changes.firstWhere(
          (_) => store.find(definition.id)!.jevRequestTimeoutSeconds == 17,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        await saved.timeout(const Duration(seconds: 5));
      });
      await _settleFilesystemFrames(tester);
      await tester.runAsync(() => _openInstanceMore(tester, definition.id));
      expect(find.text('JEV 预算 17 秒'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        store.find(definition.id)!.configuration.toJson(),
        definition.configuration.toJson(),
      );
      expect(store.runsFor(definition.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'instance resource preparation is pending rather than a missing resource and blocks configuration edits',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      final store = LaunchInstances(
        catalog: fixture.catalog,
        file: File('${fixture.root.path}/instances.json'),
      );
      addTearDown(() => tester.runAsync(store.close));
      final gate = Completer<void>();
      await tester.runAsync(() async {
        await store.save(
          name: 'Saved',
          artifactId: fixture.asset.id,
          engineId: EngineCatalog.officialId,
          configuration: EngineLaunchConfiguration(),
        );
        await fixture.library.scanDirectories([]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InstancesPage(instances: store, prepare: () => gate.future),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('模型缺失'), findsNothing);
        expect(find.textContaining('模型缺失 ·'), findsNothing);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '编辑参数'))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byKey(
                  ValueKey('instance-more:${store.definitions.single.id}'),
                ),
              )
              .enabled,
          isFalse,
        );
        gate.complete();
        await tester.pump();
        await tester.pump();
        expect(find.text('模型缺失'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  test('linked engine refresh accepts changed bytes without hashing and retains the running instance', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _LaunchTextFixture.create();
      addTearDown(fixture.close);
      final binary = await File('${fixture.root.path}/linked/llama-server')
          .create(recursive: true);
      await binary.writeAsString('server fixture');
      expect(
        (await Process.run('/bin/chmod', ['+x', binary.path])).exitCode,
        0,
      );
      final registration = await fixture.catalog.link(binary.path);
      final provider = fixture.catalog.providerFor(registration.id);
      final first = await provider.start(fixture.asset.id);
      final oldFingerprint = first.binarySha256;
      await binary.writeAsString('verified new contents at the same path');
      await fixture.catalog.refresh();
      expect(
        fixture.catalog.state.entries
            .singleWhere((entry) => entry.id == registration.id)
            .status,
        LlamaInstallationStatus.installed,
      );
      expect(
        provider.state.instances
            .singleWhere((instance) => instance.id == first.id)
            .binarySha256,
        oldFingerprint,
      );
      expect(
        provider.state.instances
            .singleWhere((instance) => instance.id == first.id)
            .status,
        LlamaInstanceStatus.ready,
      );
      await provider.stop(first.id);
      final second = await provider.start(fixture.asset.id);
      expect(oldFingerprint, isNull);
      expect(second.binarySha256, isNull);
      expect(second.generation, isNot(first.generation));
      expect(second.launchCommand!.executable, binary.path);
      final saved =
          jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
      final row = (saved['linked'] as List).singleWhere(
        (row) => row['id'] == registration.id,
      );
      expect(row['fingerprints'], isEmpty);
      await provider.stop(second.id);
    }, _NetworkBoundary());
  });
  testWidgets(
    'instance failure shows a bounded summary and file entry while controls remain usable',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        final store = LaunchInstances(
          catalog: fixture.catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        try {
          await store.save(
            name: 'Saved',
            artifactId: fixture.asset.id,
            engineId: EngineCatalog.officialId,
            configuration: EngineLaunchConfiguration(),
          );
          final original =
              'startup failed\n${List.filled(200, 'usage and full runtime details').join('\n')}\nserver: error: invalid --kv-format';
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: InstancesPage(
                  instances: store,
                  prepare: () async {
                    throw StateError(original);
                  },
                ),
              ),
            ),
          );
          await _settleFilesystemFrames(tester);
          expect(find.textContaining('invalid --kv-format'), findsWidgets);
          expect(
            find.textContaining('usage and full runtime details'),
            findsNothing,
          );
          await tester.ensureVisible(find.widgetWithText(TextButton, '编辑参数'));
          expect(
            find.widgetWithText(TextButton, '编辑参数').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('完整错误文件'), findsOneWidget);
          final path = tester
              .widget<SelectableText>(
                find.byKey(const Key('instance-error-file')),
              )
              .data!;
          expect(await File(path).readAsString(), contains(original));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await store.close();
        }
      });
    },
  );
  testWidgets(
    'saved instance editor reopens the same model without rescanning engines',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        final store = LaunchInstances(
          catalog: fixture.catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        try {
          await store.load();
          final checks = fixture.io.versionChecks;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: InstancesPage(
                  instances: store,
                  initialArtifactId: fixture.asset.id,
                ),
              ),
            ),
          );
          await _settleFilesystemFrames(tester, dialogRemainsOpen: true);
          expect(find.text('实例配置'), findsOneWidget);
          expect(fixture.io.versionChecks, checks);
          await tester.tap(find.widgetWithText(TextButton, '取消'));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: InstancesPage(instances: store)),
            ),
          );
          await tester.pump();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: InstancesPage(
                  instances: store,
                  initialArtifactId: fixture.asset.id,
                ),
              ),
            ),
          );
          await _settleFilesystemFrames(tester, dialogRemainsOpen: true);
          expect(find.text('实例配置'), findsOneWidget);
          expect(fixture.io.versionChecks, checks);
          expect(fixture.engine.runtimeInstances, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await store.close();
        }
      });
    },
  );
  testWidgets(
    'recognized new architecture can save an instance without starting',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        final file = File(fixture.asset.files.single.path);
        final bytes = await file.readAsBytes();
        final marker = ascii.encode('qwen35');
        for (var offset = 0; offset <= bytes.length - marker.length; offset++) {
          if (List.generate(
                marker.length,
                (index) => bytes[offset + index],
              ).join(',') ==
              marker.join(',')) {
            bytes.setRange(
              offset,
              offset + marker.length,
              ascii.encode('novel0'),
            );
            break;
          }
        }
        await file.writeAsBytes(bytes);
        final asset = (await fixture.library.scan(
          Directory('${fixture.root.path}/models'),
          verifyFiles: true,
        )).single;
        expect(asset.architecture, 'novel0');
        expect(asset.kind, AssetKind.unknown);
        final store = LaunchInstances(
          catalog: fixture.catalog,
          file: File('${fixture.root.path}/instances.json'),
        );
        final routes = PublicModelRoutes(
          library: fixture.library,
          runtimes: [fixture.engine],
        );
        try {
          await store.load();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildJevTheme(Brightness.light),
              home: Scaffold(body: InstancesPage(instances: store)),
            ),
          );
          await _settleFilesystemFrames(tester);
          await tester.tap(find.text('创建实例'));
          await _settleFilesystemFrames(tester);
          expect(find.byType(Dialog), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await _settleFilesystemFrames(tester);
          await tester.pump(const Duration(milliseconds: 300));
          expect(store.definitions, hasLength(1));
          expect(store.definitions.single.artifactId, asset.id);
          expect(fixture.engine.runtimeInstances, isEmpty);
          final displayName = store.definitions.single.name;
          await _openInstanceMore(tester, store.definitions.single.id);
          await tester.tap(find.text('修改调用名'));
          await _settleFilesystemFrames(tester);
          await tester.enterText(
            find.widgetWithText(TextField, '公开调用名'),
            'FAST Model',
          );
          final renameDialog = find.ancestor(
            of: find.widgetWithText(TextField, '公开调用名'),
            matching: find.byType(AlertDialog),
          );
          final renamed = store.changes.firstWhere(
            (_) => store.definitions.single.publicName == 'fast-model',
          );
          await tester.tap(
            find.descendant(
              of: renameDialog,
              matching: find.widgetWithText(FilledButton, '保存'),
            ),
          );
          await renamed.timeout(const Duration(seconds: 5));
          await _settleFilesystemFrames(tester);
          await tester.pump(const Duration(milliseconds: 300));
          expect(store.definitions.single.publicName, 'fast-model');
          expect(store.definitions.single.name, displayName);
          expect(find.text('fast-model'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          routes.close();
          await store.close();
        }
      });
    },
  );
  test('model configuration JSON rejects partial mutation and retains orphan registrations', () async {
    final fixture = await _LaunchTextFixture.create();
    addTearDown(fixture.close);
    const id = EngineCatalog.officialId;
    await fixture.catalog.saveLaunchDefaults(
      id,
      EngineLaunchConfiguration(
        formValues: {
          ...EngineLaunchConfiguration.initialValues,
          '--ctx-size': '2048',
        },
      ),
    );
    final binary = await File('${fixture.root.path}/external/llama-server')
        .create(recursive: true);
    await binary.writeAsString('external native fixture');
    expect((await Process.run('/bin/chmod', ['+x', binary.path])).exitCode, 0);
    await fixture.catalog.link(binary.path);
    final registry = fixture.catalog.registryFile;
    final input =
        jsonDecode(await registry.readAsString()) as Map<String, dynamic>;
    input['schema'] = 4;
    final orphan = {
      'enabled': true,
      'configuration': {
        'formValues': {'--ctx-size': '3072'},
        'argumentText': ' --threads 7\n',
      },
    };
    input['modelLaunchOverrides'] = {
      'old-unlinked-registration': {'retained-model-variant': orphan},
      id: <String, Object?>{
        fixture.asset.id: {'enabled': true, 'configuration': null},
      },
    };
    final invalid = jsonEncode(input);
    await registry.writeAsString(invalid);
    await expectLater(
      fixture.reopen(),
      throwsA(
        isA<LlamaEngineException>().having(
          (error) => error.message,
          'reason',
          contains('模型启动配置'),
        ),
      ),
    );
    expect(
      fixture.catalog.state.entries,
      hasLength(1),
      reason: 'valid linked rows must not be partially registered',
    );
    expect(
      fixture.catalog.launchDefaultsFor(id).formValues['--ctx-size'],
      '4096',
    );
    expect(await registry.readAsString(), invalid);
    input['modelLaunchOverrides'][id][fixture.asset.id] = {
      'enabled': true,
      'configuration': {
        'formValues': {'--ctx-size': '1024'},
        'argumentText': '--device=CPU',
      },
    };
    await registry.writeAsString(jsonEncode(input));
    await fixture.catalog.refresh();
    await fixture.library.scan(
      Directory('${fixture.root.path}/models'),
      verifyFiles: true,
    );
    expect(fixture.catalog.state.entries, hasLength(2));
    expect(
      fixture.catalog
          .launchConfigurationFor(id, fixture.asset.id)
          .formValues['--ctx-size'],
      '1024',
    );
    await fixture.catalog.saveLaunchDefaults(
      id,
      EngineLaunchConfiguration(
        formValues: {
          ...EngineLaunchConfiguration.initialValues,
          '--ctx-size': '8192',
        },
      ),
    );
    final saved = jsonDecode(await registry.readAsString()) as Map;
    expect(
      saved['modelLaunchOverrides']['old-unlinked-registration']['retained-model-variant'],
      orphan,
    );
    expect(
      fixture.catalog
          .launchConfigurationFor(id, fixture.asset.id)
          .formValues['--ctx-size'],
      '1024',
    );
  });
  test('real model variants and concrete linked registrations keep isolated overrides', () async {
    final fixture = await _LaunchTextFixture.create();
    addTearDown(fixture.close);
    final models = Directory('${fixture.root.path}/models');
    final original = fixture.asset;
    await File(original.files.single.path)
        .copy('${File(original.files.single.path).parent.path}/Kev-Q4_0.gguf');
    final assets = await fixture.library.scan(models, verifyFiles: true);
    final packages = await LocalModelPackages.discover(models, assets);
    final variants = packages.packages.single.variants;
    expect(
      variants.map((variant) => variant.id).toSet(),
      assets.map((asset) => asset.id).toSet(),
    );
    expect(variants.map((variant) => variant.label).toSet(), {
      'GGUF · Q4_0',
      'GGUF · Q8_0',
    });
    final ids = <String>[];
    for (final directory in ['engine-a', 'engine-b']) {
      final binary = await File('${fixture.root.path}/$directory/llama-server')
          .create(recursive: true);
      await binary.writeAsString('external native fixture $directory');
      expect(
        (await Process.run('/bin/chmod', ['+x', binary.path])).exitCode,
        0,
      );
      ids.add((await fixture.catalog.link(binary.path)).id);
    }
    const contexts = ['1024', '2048', '3072', '4096'];
    for (var engine = 0; engine < 2; engine++) {
      for (var model = 0; model < 2; model++) {
        final index = engine * 2 + model;
        await fixture.catalog.saveModelLaunchOverrides(
          ids[engine],
          variants[model].id,
          EngineLaunchConfiguration(
            formValues: {
              ...EngineLaunchConfiguration.initialValues,
              '--ctx-size': contexts[index],
            },
            argumentText: '--threads ${index + 1}',
          ),
        );
      }
    }
    final originalId = original.id;
    await fixture.reopen(artifactId: originalId);
    await HttpOverrides.runWithHttpOverrides(() async {
      for (var engine = 0; engine < 2; engine++) {
        final provider = fixture.catalog.providerFor(ids[engine]);
        for (var model = 0; model < 2; model++) {
          final index = engine * 2 + model;
          final selection = fixture.catalog.modelLaunchOverridesFor(
            ids[engine],
            variants[model].id,
          );
          expect(selection.enabled, isTrue);
          expect(
            selection.configuration!.formValues['--ctx-size'],
            contexts[index],
          );
          expect(
            selection.configuration!.argumentText,
            '--threads ${index + 1}',
          );
          final preview = await provider.previewLaunch(variants[model].id);
          final running = await provider.start(variants[model].id);
          expect(
            preview.arguments,
            containsAllInOrder([
              '--ctx-size',
              contexts[index],
              '--threads',
              '${index + 1}',
            ]),
          );
          expect(
            fixture.io.startedArguments.last,
            containsAllInOrder([
              '--ctx-size',
              contexts[index],
              '--threads',
              '${index + 1}',
            ]),
          );
          expect(
            running.launchCommand!.arguments,
            fixture.io.startedArguments.last,
          );
          await provider.stop(running.id);
        }
      }
      final managed = fixture.catalog.modelLaunchOverridesFor(
        EngineCatalog.officialId,
        originalId,
      );
      expect(managed.enabled, isFalse);
      expect(managed.configuration, isNull);
      final untouched = await fixture.engine.start(originalId);
      expect(
        untouched.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '4096']),
      );
      expect(untouched.launchCommand!.arguments, isNot(contains('--threads')));
    }, _NetworkBoundary());
  });
  test('model overrides retain full independent empty or inherited state after reopen', () async {
    final fixture = await _LaunchTextFixture.create();
    addTearDown(fixture.close);
    const engineId = EngineCatalog.officialId;
    final initial = fixture.catalog.modelLaunchOverridesFor(
      engineId,
      fixture.asset.id,
    );
    expect(initial.enabled, isFalse);
    expect(initial.configuration, isNull);
    final defaults = EngineLaunchConfiguration(
      formValues: {
        ...EngineLaunchConfiguration.initialValues,
        '--ctx-size': '2048',
      },
      argumentText: ' --device=CPU\n',
    );
    await fixture.catalog.saveLaunchDefaults(engineId, defaults);
    await fixture.catalog.setModelLaunchMode(
      engineId,
      fixture.asset.id,
      independent: true,
    );
    final copied = fixture.catalog.modelLaunchOverridesFor(
      engineId,
      fixture.asset.id,
    );
    expect(copied.configuration!.formValues['--ctx-size'], '2048');
    expect(copied.configuration!.argumentText, ' --device=CPU\n');
    final independent = EngineLaunchConfiguration(
      formValues: {
        ...EngineLaunchConfiguration.initialValues,
        '--ctx-size': '1024',
      },
      argumentText: ' --threads 3\n',
    );
    await fixture.catalog.saveModelLaunchOverrides(
      engineId,
      fixture.asset.id,
      independent,
    );
    await fixture.catalog.saveLaunchDefaults(
      engineId,
      EngineLaunchConfiguration(
        formValues: {
          ...EngineLaunchConfiguration.initialValues,
          '--ctx-size': '8192',
        },
        argumentText: '--device=CPU',
      ),
    );
    await HttpOverrides.runWithHttpOverrides(() async {
      final running = await fixture.engine.start(fixture.asset.id);
      expect(
        running.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '1024', '--threads', '3']),
      );
      await fixture.catalog.setModelLaunchMode(
        engineId,
        fixture.asset.id,
        independent: false,
      );
      expect(
        fixture.engine.state.instances.single.status,
        LlamaInstanceStatus.ready,
      );
      expect(fixture.io.startedArguments, hasLength(1));
      expect(fixture.io.stopAttempts, 0);
      expect(
        fixture.engine.state.instances.single.launchCommand!.displayText,
        running.launchCommand!.displayText,
      );
      await fixture.engine.stop(running.id);
    }, _NetworkBoundary());
    await fixture.reopen();
    final inherited = fixture.catalog.modelLaunchOverridesFor(
      engineId,
      fixture.asset.id,
    );
    expect(inherited.enabled, isFalse);
    expect(inherited.configuration!.formValues['--ctx-size'], '1024');
    expect(inherited.configuration!.argumentText, ' --threads 3\n');
    await HttpOverrides.runWithHttpOverrides(() async {
      final inheritedRun = await fixture.engine.start(fixture.asset.id);
      expect(
        inheritedRun.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '8192', '--device=CPU']),
      );
      expect(
        inheritedRun.launchCommand!.arguments,
        isNot(contains('--threads')),
      );
      await fixture.engine.stop(inheritedRun.id);
      await fixture.catalog.setModelLaunchMode(
        engineId,
        fixture.asset.id,
        independent: true,
      );
      final restored = await fixture.engine.start(fixture.asset.id);
      expect(
        restored.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '1024', '--threads', '3']),
      );
      await fixture.engine.stop(restored.id);
    }, _NetworkBoundary());
    await fixture.catalog.saveModelLaunchOverrides(
      engineId,
      fixture.asset.id,
      EngineLaunchConfiguration(formValues: const {}, argumentText: ''),
    );
    await fixture.reopen();
    final empty = fixture.catalog.modelLaunchOverridesFor(
      engineId,
      fixture.asset.id,
    );
    expect(empty.enabled, isTrue);
    expect(empty.configuration, isNotNull);
    expect(empty.configuration!.formValues, isEmpty);
    expect(empty.configuration!.argumentText, '');
    await HttpOverrides.runWithHttpOverrides(() async {
      final preview = await fixture.engine.previewLaunch(fixture.asset.id);
      final running = await fixture.engine.start(fixture.asset.id);
      expect(preview.arguments, hasLength(8));
      expect(running.launchCommand!.arguments, hasLength(8));
    }, _NetworkBoundary());
  });
  testWidgets(
    'model parameter list edits drafts, restores overrides and keeps footer fixed',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      tester.view.physicalSize = const Size(1100, 732);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const id = EngineCatalog.officialId;
      await tester.runAsync(
        () => fixture.catalog.saveLaunchDefaults(
          id,
          EngineLaunchConfiguration(
            formValues: {
              ...EngineLaunchConfiguration.initialValues,
              '--ctx-size': '2048',
            },
            argumentText: ' --device=CPU\n',
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: LibraryPage(
                library: fixture.library,
                libraryPath: '${fixture.root.path}/models',
                engines: fixture.catalog,
              ),
            ),
          ),
        );
        await _settleFilesystemFrames(tester);
        await tester.ensureVisible(find.byTooltip('模型参数'));
        await tester.tap(find.byTooltip('模型参数'));
        await tester.pump();
        await fixture.catalog.refresh();
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(find.text('模型独立'), findsNothing);
      expect(find.text('引擎默认'), findsNothing);
      expect(find.text('编辑模型参数'), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      await selectParameterGroup(tester, '上下文与内存');
      final field = find.byKey(const Key('parameter-number:--ctx-size'));
      expect(tester.widget<TextField>(field).controller!.text, '2048');
      final saveBefore = tester.getRect(
        find.widgetWithText(FilledButton, '保存'),
      );
      await tester.enterText(field, '1024');
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '参数文本与命令');
      expect(find.textContaining('--ctx-size 1024'), findsOneWidget);
      await selectParameterGroup(tester, '上下文与内存');
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('parameter-field:--ctx-size')),
          matching: find.byTooltip('恢复默认'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '');
      await selectParameterGroup(tester, '参数文本与命令');
      expect(
        tester.getRect(find.widgetWithText(FilledButton, '保存')),
        saveBefore,
      );
      final text = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(text);
      expect(
        tester.widget<TextField>(text).controller!.text,
        ' --device=CPU\n',
      );
      await tester.enterText(text, '--threads 9');
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.modelLaunchOverridesFor(id, fixture.asset.id).enabled,
        isFalse,
      );
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byTooltip('模型参数'));
        await tester.tap(find.byTooltip('模型参数'));
        await tester.pump();
        await fixture.catalog.refresh();
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '上下文与内存');
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ctx-size')),
        '1024',
      );
      await tester.pumpAndSettle();
      await _saveTextEditor(tester, fixture);
      expect(fixture.catalog.preferredEngineFor(fixture.asset.id), id);
      expect(
        fixture.catalog
            .launchConfigurationFor(id, fixture.asset.id)
            .formValues['--ctx-size'],
        '1024',
      );
      expect(
        fixture.catalog.launchDefaultsFor(id).formValues['--ctx-size'],
        '2048',
      );
      expect(
        fixture.engine.state.instances,
        isEmpty,
        reason: 'save never starts a model',
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.ensureVisible(find.widgetWithText(TextButton, '运行'));
          await tester.tap(find.widgetWithText(TextButton, '运行'));
          final ready = fixture.engine.changes.firstWhere(
            (state) => state.instances.any(
              (i) => i.status == LlamaInstanceStatus.ready,
            ),
          );
          await ready.timeout(const Duration(seconds: 5));
          await _settleFilesystemFrames(tester);
        }, _NetworkBoundary()),
      );
      expect(
        fixture.io.startedArguments.single,
        containsAllInOrder(['--ctx-size', '1024', '--device=CPU']),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'quoted option-looking values keep their parameter role through editor save and start',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      const cases = [
        ('--device "--host"', ['--device', '--host'], {'--device'}, <String>{}),
        ('--device "-c"', ['--device', '-c'], {'--device'}, <String>{}),
        ('--alias "-dev" CPU', ['CPU'], <String>{}, {'--alias'}),
        (
          '--model "-weights.gguf" --parallel 2',
          ['--parallel', '2'],
          {'--parallel'},
          {'--model'},
        ),
        ('--device=--host', ['--device=--host'], {'--device'}, <String>{}),
        ('--device --host 0.0.0.0', ['--device'], {'--device'}, {'--host'}),
        (
          '--device -c 1024',
          ['--device', '-c', '1024'],
          {'--device', '--ctx-size'},
          <String>{},
        ),
        ('--device -c1024', ['--device', '-c1024'], {'--device'}, <String>{}),
        ('--alias -dev CPU', ['-dev', 'CPU'], {'--device'}, {'--alias'}),
        (r'--device \-c', ['--device', '-c'], {'--device'}, <String>{}),
        (r'--model \-weights.gguf', <String>[], <String>{}, {'--model'}),
      ];
      for (final (source, tail, overridden, managed) in cases) {
        await _openTextEditor(tester, fixture);
        final input = find.byKey(const Key('engine-argument-text'));
        await selectParameterGroup(tester, '参数文本与命令');
        await tester.ensureVisible(input);
        await tester.enterText(input, source);
        await tester.pump();
        await _saveTextEditor(tester, fixture);
        await _openTextEditor(tester, fixture);
        expect(tester.widget<TextField>(input).controller!.text, source);
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final preview = await fixture.engine.previewLaunch(
              fixture.asset.id,
            );
            final instance = await fixture.engine.start(fixture.asset.id);
            final expectedBody = [
              if (!overridden.contains('--ctx-size')) ...['--ctx-size', '4096'],
              '--batch-size',
              '4096',
              '--ubatch-size',
              '4096',
              if (!overridden.contains('--parallel')) ...['--parallel', '1'],
              '--n-gpu-layers',
              '99',
              if (!overridden.contains('--device')) ...['--device', 'MTL0'],
              ...tail,
            ];
            expect(
              fixture.io.startedArguments.last.skip(8).toList(),
              expectedBody,
              reason: source,
            );
            expect(
              preview.arguments.skip(8).toList(),
              expectedBody,
              reason: source,
            );
            expect(preview.overriddenForm, overridden, reason: source);
            for (final name in ['--model', '--alias', '--host', '--port']) {
              expect(
                preview.notices.any(
                  (notice) => notice.startsWith('$name 由软件管理'),
                ),
                managed.contains(name),
                reason: source,
              );
            }
            expect(
              instance.launchCommand!.arguments,
              fixture.io.startedArguments.last,
            );
            await fixture.engine.stop(instance.id);
          }, _NetworkBoundary()),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'unrepresentable NUL and trailing escape remain saved but cannot spawn',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      for (final (text, position) in [
        ('--device CPU\u0000ignored', 13),
        (
          r'--device CPU\'
              '\u0000ignored',
          14,
        ),
        (r'--device CPU\', 13),
      ]) {
        await _openTextEditor(tester, fixture);
        final input = find.byKey(const Key('engine-argument-text'));
        await selectParameterGroup(tester, '参数文本与命令');
        await tester.ensureVisible(input);
        await tester.enterText(input, text);
        await tester.pump();
        expect(find.textContaining('第 $position 位'), findsOneWidget);
        expect(find.byTooltip('复制命令'), findsNothing);
        await tester.pumpAndSettle();
        await _saveTextEditor(tester, fixture);
        await _openTextEditor(tester, fixture);
        expect(tester.widget<TextField>(input).controller!.text, text);
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await expectLater(
            fixture.engine.start(fixture.asset.id),
            throwsA(
              predicate<Object>(
                (error) => error.toString().contains('第 $position 位'),
              ),
            ),
          );
          expect(fixture.io.startedArguments, isEmpty);
          expect(fixture.engine.state.instances, isEmpty);
        });
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('user stop before a late native exit remains cancellation', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
    addTearDown(() => tester.runAsync(fixture.close));
    await _openTextEditor(tester, fixture);
    final input = find.byKey(const Key('engine-argument-text'));
    await selectParameterGroup(tester, '参数文本与命令');
    await tester.ensureVisible(input);
    await tester.enterText(input, '--ctx-size bananas');
    await tester.pump();
    await _saveTextEditor(tester, fixture);
    const diagnostic = 'error: invalid value for --ctx-size: bananas';
    fixture.io.startupError = diagnostic;
    addTearDown(() {
      final gate = fixture.io.startupExitGate;
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
    });
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        for (final recycle in [false, true]) {
          fixture.io.startupExitGate = Completer<void>();
          final started = fixture.engine.changes.firstWhere(
            (state) =>
                state.instances.any((instance) => instance.hasLiveProcess),
          );
          Object? startError;
          final start = fixture.engine
              .start(fixture.asset.id)
              .then<void>(
                (_) =>
                    fail('an unready native child must not complete startup'),
                onError: (Object error) => startError = error,
              );
          final state = await started.timeout(const Duration(seconds: 5));
          final instanceId = state.instances
              .singleWhere((instance) => instance.hasLiveProcess)
              .id;
          final stop = recycle
              ? fixture.engine.stopManaged()
              : fixture.engine.stop(instanceId);
          fixture.io.startupExitGate!.complete();
          await start;
          await stop;
          expect(
            startError,
            isA<LlamaEngineException>().having(
              (error) => error.message,
              'reason',
              contains('已取消'),
            ),
          );
          expect(startError.toString(), isNot(contains(diagnostic)));
          expect(
            fixture.engine.state.instances
                .singleWhere((instance) => instance.id == instanceId)
                .status,
            LlamaInstanceStatus.stopped,
          );
          expect(
            fixture.engine.state.instances.every(
              (instance) => !instance.hasLiveProcess,
            ),
            isTrue,
          );
        }
      }, _NetworkBoundary()),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'native argument rejection shows stderr and never publishes Ready',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      final input = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, '--ctx-size bananas');
      await tester.pump();
      await _saveTextEditor(tester, fixture);
      const diagnostic = 'error: invalid value for --ctx-size: bananas';
      fixture.io.startupError = diagnostic;
      final statuses = <LlamaInstanceStatus>[];
      final observations = fixture.engine.changes.listen((state) {
        statuses.addAll(state.instances.map((instance) => instance.status));
      });
      addTearDown(observations.cancel);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: LibraryPage(
                library: fixture.library,
                libraryPath: '${fixture.root.path}/models',
                engines: fixture.catalog,
              ),
            ),
          ),
        );
        await _settleFilesystemFrames(tester);
        await tester.pump();
        await fixture.catalog.refresh();
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final failed = fixture.engine.changes.firstWhere(
            (state) => state.instances.any(
              (instance) =>
                  instance.status == LlamaInstanceStatus.failed &&
                  !instance.hasLiveProcess &&
                  (instance.error?.contains(diagnostic) ?? false),
            ),
          );
          await tester.ensureVisible(find.widgetWithText(TextButton, '运行'));
          await tester.tap(find.widgetWithText(TextButton, '运行'));
          await failed.timeout(const Duration(seconds: 5));
          await fixture.catalog.refresh();
          await tester.pump();
          await _settleFilesystemFrames(tester, dialogRemainsOpen: true);
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('library-operation-error')),
          matching: find.textContaining(diagnostic),
        ),
        findsOneWidget,
      );
      expect(statuses, isNot(contains(LlamaInstanceStatus.ready)));
      final failed = fixture.engine.state.instances.single;
      expect(failed.status, LlamaInstanceStatus.failed);
      expect(failed.hasLiveProcess, isFalse);
      expect(failed.capabilities, isEmpty);
      expect(failed.error, contains(diagnostic));
      expect(
        failed.launchCommand!.arguments,
        fixture.io.startedArguments.single,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unclosed quote is saved but has no executable preview or spawned process',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      const text = '--device "CPU';
      final input = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, text);
      await tester.pump();
      expect(find.textContaining('第 10 位'), findsOneWidget);
      expect(find.text('完整启动命令'), findsNothing);
      expect(find.byTooltip('复制命令'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tester.pumpAndSettle();
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.reopen();
      });
      await _openTextEditor(tester, fixture);
      expect(tester.widget<TextField>(input).controller!.text, text);
      await tester.runAsync(() async {
        final positionedError = throwsA(
          predicate<Object>((error) => error.toString().contains('第 10 位')),
        );
        await expectLater(
          fixture.engine.previewLaunch(fixture.asset.id),
          positionedError,
        );
        await expectLater(
          fixture.engine.start(fixture.asset.id),
          positionedError,
        );
        expect(fixture.io.startedArguments, isEmpty);
        expect(fixture.engine.state.instances, isEmpty);
      });
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, '--device "CPU"');
      await tester.pump();
      expect(tester.widget<TextField>(input).decoration!.errorText, isNull);
      // InputDecorator fades the previous error label after the corrected frame.
      await tester.pumpAndSettle();
      expect(find.textContaining('第 10 位'), findsNothing);
      await selectParameterGroup(tester, '参数文本与命令');
      expect(find.text('完整启动命令'), findsOneWidget);
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final instance = await fixture.engine.start(fixture.asset.id);
          expect(instance.status, LlamaInstanceStatus.ready);
          expect(
            fixture.io.startedArguments.single,
            containsAllInOrder(['--device', 'CPU']),
          );
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown and semantically invalid options warn without blocking native input',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      const text =
          r'--brand-new=opaque --ctx-size bananas --batch-size '
          r'--parallel=2 /bin/echo ; | $HOME';
      final input = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, text);
      await tester.pump();
      expect(find.textContaining('未知参数 --brand-new'), findsOneWidget);
      expect(find.textContaining('--ctx-size 通常需要整数'), findsOneWidget);
      expect(find.textContaining('--batch-size 缺少值'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          final instance = await fixture.engine.start(fixture.asset.id);
          const tokens = [
            '--brand-new=opaque',
            '--ctx-size',
            'bananas',
            '--batch-size',
            '--parallel=2',
            '/bin/echo',
            ';',
            '|',
            r'$HOME',
          ];
          expect(fixture.io.startedArguments.single.skip(14).toList(), tokens);
          expect(preview.arguments.skip(14).toList(), tokens);
          expect(
            fixture.io.startedExecutables.single,
            fixture.engine.executablePath,
          );
          expect(instance.status, LlamaInstanceStatus.ready);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'managed model listener and identity text is removed without rewriting source',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      const text =
          '-m /foreign/model.gguf --alias=outside --host 0.0.0.0 '
          '--port=9999 -h --no-host';
      final input = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, text);
      await tester.pump();
      expect(find.textContaining('由软件管理'), findsNWidgets(4));
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          final instance = await fixture.engine.start(fixture.asset.id);
          final actual = fixture.io.startedArguments.single;
          expect(actual.take(8).toList(), [
            '--model',
            fixture.asset.files.single.path,
            '--alias',
            instance.id,
            '--host',
            '127.0.0.1',
            '--port',
            '${instance.endpoint.port}',
          ]);
          expect(actual.skip(8).toList(), [
            '--ctx-size',
            '4096',
            '--batch-size',
            '4096',
            '--ubatch-size',
            '4096',
            '--parallel',
            '1',
            '--n-gpu-layers',
            '99',
            '--device',
            'MTL0',
            '-h',
            '--no-host',
          ]);
          expect(preview.arguments.last, '--no-host');
          expect(instance.status, LlamaInstanceStatus.ready);
        }, _NetworkBoundary()),
      );
      await _openTextEditor(tester, fixture);
      expect(tester.widget<TextField>(input).controller!.text, text);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'quoted repeated and empty argument values retain their native boundaries',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      const text = r'''--device "CPU fallback" -c=1024 --device 'CPU final'
--experimental "" --pair=a=b --literal '$HOME ; echo nope | cat'
--escaped one\ two --slash "a\qb" --quote "say \"hi\"" --single 'a\b' '' ''';
      final input = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      await tester.ensureVisible(input);
      await tester.enterText(input, text);
      await tester.pump();
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          final instance = await fixture.engine.start(fixture.asset.id);
          const tokens = [
            '--device',
            'CPU fallback',
            '-c=1024',
            '--device',
            'CPU final',
            '--experimental',
            '',
            '--pair=a=b',
            '--literal',
            r'$HOME ; echo nope | cat',
            '--escaped',
            'one two',
            '--slash',
            r'a\qb',
            '--quote',
            'say "hi"',
            '--single',
            r'a\b',
            '',
          ];
          expect(fixture.io.startedArguments.single.skip(16).toList(), tokens);
          expect(preview.arguments.skip(16).toList(), tokens);
          expect(instance.status, LlamaInstanceStatus.ready);
        }, _NetworkBoundary()),
      );
      await _openTextEditor(tester, fixture);
      expect(tester.widget<TextField>(input).controller!.text, text);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('removing a text alias restores the preserved form value', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
    addTearDown(() => tester.runAsync(fixture.close));
    await _openTextEditor(tester, fixture);
    await selectParameterGroup(tester, '上下文与内存');
    final contextField = find.byKey(const Key('parameter-number:--ctx-size'));
    await tester.enterText(contextField, '2048');
    final arguments = find.byKey(const Key('engine-argument-text'));
    await selectParameterGroup(tester, '参数文本与命令');
    await tester.ensureVisible(arguments);
    await tester.enterText(arguments, '-c=1024');
    await tester.pump();
    expect(
      tester
          .widget<EngineLaunchCommandView>(find.byType(EngineLaunchCommandView))
          .command
          .overriddenForm,
      contains('--ctx-size'),
    );
    await _saveTextEditor(tester, fixture);
    await _openTextEditor(tester, fixture);
    await selectParameterGroup(tester, '参数文本与命令');
    await tester.ensureVisible(arguments);
    await tester.enterText(arguments, '');
    await tester.pump();
    await selectParameterGroup(tester, '上下文与内存');
    expect(tester.widget<TextField>(contextField).controller!.text, '2048');
    expect(
      tester.widget<TextField>(contextField).decoration!.errorText,
      isNull,
    );
    await _saveTextEditor(tester, fixture);
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(
          fixture.io.startedArguments.single,
          containsAllInOrder(['--ctx-size', '2048']),
        );
        expect(fixture.io.startedArguments.single, isNot(contains('-c=1024')));
        expect(instance.status, LlamaInstanceStatus.ready);
      }, _NetworkBoundary()),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'launch text retains its source and overrides known form aliases',
    (tester) async {
      final fixture = (await tester.runAsync(_LaunchTextFixture.create))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await _openTextEditor(tester, fixture);
      await selectParameterGroup(tester, '上下文与内存');
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ctx-size')),
        '2048',
      );
      const text = '  -c 1024  --device=CPU\n';
      final arguments = find.byKey(const Key('engine-argument-text'));
      await selectParameterGroup(tester, '参数文本与命令');
      expect(arguments, findsOneWidget);
      await tester.ensureVisible(arguments);
      await tester.enterText(arguments, text);
      await tester.pump();
      expect(
        tester
            .widget<EngineLaunchCommandView>(
              find.byType(EngineLaunchCommandView),
            )
            .command
            .overriddenForm,
        contains('--ctx-size'),
      );
      await _saveTextEditor(tester, fixture);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.reopen();
      });
      await _openTextEditor(tester, fixture);
      expect(tester.widget<TextField>(arguments).controller!.text, text);
      await selectParameterGroup(tester, '上下文与内存');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('parameter-number:--ctx-size')),
            )
            .controller!
            .text,
        '2048',
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          final instance = await fixture.engine.start(fixture.asset.id);
          final actual = fixture.io.startedArguments.single;
          expect(actual, isNot(contains('--ctx-size')));
          expect(actual, isNot(contains('--device')));
          expect(actual.skip(16).toList(), ['-c', '1024', '--device=CPU']);
          expect(preview.arguments.skip(16).toList(), [
            '-c',
            '1024',
            '--device=CPU',
          ]);
          expect(instance.status, LlamaInstanceStatus.ready);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('managed standard JEV and linked launch defaults remain independent after reopening', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-isolated-defaults-',
    );
    late ModelLibrary library;
    late List<LlamaEngine> providers;
    late EngineCatalog catalog;
    final ios = [_RuntimeIO(), _RuntimeIO(standard: true), _RuntimeIO()];
    final models = Directory('${root.path}/models');
    final owned = Directory('${root.path}/engines');
    final registry = File('${root.path}/engines.json');
    final archives = <File>[];
    final releases = <LlamaRelease>[];
    await writeDecisionKev(models, ordinaryChat: true);
    for (final standard in [false, true]) {
      final data = engineArchive(artifactTag: standard ? 'b11146' : 'b11381');
      archives.add(
        await File('${root.path}/$standard.tar.gz').writeAsBytes(data),
      );
      releases.add(
        LlamaRelease(
          tag: standard ? 'v0.5.0' : 'b11381',
          artifactTag: standard ? 'b11146' : 'b11381',
          expectedBuild: standard ? 11146 : 11381,
          supportsSystemone: !standard,
          commit: standard
              ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
              : '836d57176',
          url: Uri.parse('https://github.com/fixture'),
          sha256: sha256.convert(data).toString(),
          sizeBytes: data.length,
        ),
      );
    }
    void openCatalog() {
      library = ModelLibrary();
      final use = ModelUseRegistry(library);
      providers = [
        for (var index = 0; index < 2; index++)
          LlamaEngine(
            library: library,
            installationDirectory: owned,
            io: ios[index],
            useRegistry: use,
            loadTimeout: const Duration(seconds: 2),
            release: releases[index],
          ),
      ];
      catalog = EngineCatalog(
        library: library,
        officialEngine: providers[0],
        standardEngine: providers[1],
        useRegistry: use,
        registryFile: registry,
        io: ios[2],
      );
    }

    openCatalog();
    addTearDown(() async {
      await catalog.stopManaged();
      catalog.close();
      for (final provider in providers) {
        provider.close();
      }
      library.close();
      await root.delete(recursive: true);
    });
    await catalog.installOfficial(verifiedArchive: archives[0]);
    await catalog.installManaged(
      EngineCatalog.standardId,
      verifiedArchive: archives[1],
    );
    final external = await File('${root.path}/external/llama-server')
        .create(recursive: true);
    await external.writeAsString('external native fixture');
    expect(
      (await Process.run('/bin/chmod', ['+x', external.path])).exitCode,
      0,
    );
    final linked = await catalog.link(external.path);
    final ids = [EngineCatalog.officialId, EngineCatalog.standardId, linked.id];
    const contexts = ['1024', '2048', '3072'];
    const gpuLayers = ['11', '22', '33'];
    for (var index = 0; index < ids.length; index++) {
      final values = {
        ...EngineLaunchConfiguration.initialValues,
        '--ctx-size': contexts[index],
        '--n-gpu-layers': gpuLayers[index],
      };
      if (index == 2) values.remove('--device');
      await catalog.saveLaunchDefaults(
        ids[index],
        EngineLaunchConfiguration(formValues: values),
      );
    }
    catalog.close();
    for (final provider in providers) {
      provider.close();
    }
    library.close();
    openCatalog();
    await catalog.refresh();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    await HttpOverrides.runWithHttpOverrides(() async {
      for (var index = 0; index < ids.length; index++) {
        final provider = catalog.providerFor(ids[index]);
        final saved = catalog.launchDefaultsFor(ids[index]);
        expect(saved.formValues['--ctx-size'], contexts[index]);
        expect(saved.formValues['--n-gpu-layers'], gpuLayers[index]);
        expect(saved.formValues['--device'], index == 2 ? isNull : 'MTL0');
        final preview = await provider.previewLaunch(asset.id);
        expect(
          preview.arguments,
          containsAllInOrder([
            '--ctx-size',
            contexts[index],
            '--n-gpu-layers',
            gpuLayers[index],
          ]),
        );
        final instance = await provider.start(asset.id);
        expect(instance.status, LlamaInstanceStatus.ready);
        expect(ios[index].startedArguments.single, [
          '--model',
          await File(asset.files.single.path).resolveSymbolicLinks(),
          '--alias',
          instance.id,
          '--host',
          '127.0.0.1',
          '--port',
          '${instance.endpoint.port}',
          '--ctx-size',
          contexts[index],
          '--batch-size',
          '4096',
          '--ubatch-size',
          '4096',
          '--parallel',
          '1',
          '--n-gpu-layers',
          gpuLayers[index],
          if (index != 2) ...['--device', 'MTL0'],
        ]);
        expect(
          instance.launchCommand!.arguments,
          ios[index].startedArguments.single,
        );
      }
    }, _NetworkBoundary());
  });
  testWidgets(
    'saving cleared engine defaults affects only a subsequent manual restart',
    (tester) async {
      late Directory root;
      late ModelLibrary library;
      late LlamaEngine engine;
      late EngineCatalog catalog;
      late LibraryArtifact asset;
      final io = _RuntimeIO();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd-next-launch-');
        library = ModelLibrary();
        final models = Directory('${root.path}/models');
        await writeDecisionKev(models, ordinaryChat: true);
        asset = (await library.scan(models, verifyFiles: true)).single;
        final use = ModelUseRegistry(library);
        final data = engineArchive();
        final archive = await File('${root.path}/engine.tar.gz')
            .writeAsBytes(data);
        engine = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          io: io,
          useRegistry: use,
          loadTimeout: const Duration(seconds: 2),
          release: LlamaRelease(
            tag: 'b11381',
            commit: '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: engine,
          useRegistry: use,
          registryFile: File('${root.path}/engines.json'),
          io: io,
        );
        await catalog.installOfficial(verifiedArchive: archive);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await catalog.stopManaged();
          catalog.close();
          engine.close();
          library.close();
          await root.delete(recursive: true);
        });
      });
      late LlamaInstance original;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          original = await catalog
              .providerFor(EngineCatalog.officialId)
              .start(asset.id);
        }, _NetworkBoundary()),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: EnginePage(
                catalog: catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byTooltip('启动参数'));
        await tester.tap(find.byTooltip('启动参数'));
        await catalog.readParameters(EngineCatalog.officialId);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '上下文与内存');
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ctx-size')),
        '2048',
      );
      await selectParameterGroup(tester, '计算与设备');
      final device = find.byKey(const Key('parameter-choice:--device'));
      await tester.tap(device);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继承引擎默认').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final saved = catalog.changes.firstWhere((state) => !state.busy);
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      final stillRunning = engine.state.instances.single;
      expect(stillRunning.id, original.id);
      expect(stillRunning.status, LlamaInstanceStatus.ready);
      expect(io.startedArguments, hasLength(1));
      expect(io.stopAttempts, 0);
      expect(
        stillRunning.launchCommand!.arguments,
        containsAllInOrder(['--ctx-size', '4096', '--device', 'MTL0']),
      );
      late LlamaInstance restarted;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await catalog.providerFor(EngineCatalog.officialId).stop(original.id);
          restarted = await catalog
              .providerFor(EngineCatalog.officialId)
              .start(asset.id);
        }, _NetworkBoundary()),
      );
      expect(io.startedArguments, hasLength(2));
      expect(
        io.startedArguments.last,
        containsAllInOrder(['--ctx-size', '2048']),
      );
      expect(io.startedArguments.last, isNot(contains('--device')));
      expect(restarted.launchCommand!.arguments, io.startedArguments.last);
      final stopped = engine.state.instances.singleWhere(
        (instance) => instance.id == original.id,
      );
      expect(stopped.status, LlamaInstanceStatus.stopped);
      expect(
        stopped.launchCommand!.displayText,
        original.launchCommand!.displayText,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'saved engine defaults are previewed copied and used by the public model run',
    (tester) async {
      late Directory root, models;
      late ModelLibrary library;
      late LlamaEngine engine;
      late EngineCatalog catalog;
      final io = _RuntimeIO();
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('gmd launch preview ');
        models = Directory('${root.path}/models');
        await writeDecisionKev(models, ordinaryChat: true);
        library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final data = engineArchive();
        final archive = await File('${root.path}/engine.tar.gz')
            .writeAsBytes(data);
        engine = LlamaEngine(
          library: library,
          installationDirectory: Directory('${root.path}/engines'),
          io: io,
          useRegistry: use,
          loadTimeout: const Duration(seconds: 2),
          release: LlamaRelease(
            tag: 'b11381',
            commit: '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        );
        catalog = EngineCatalog(
          library: library,
          officialEngine: engine,
          useRegistry: use,
          registryFile: File('${root.path}/engines.json'),
          io: io,
        );
        await catalog.installOfficial(verifiedArchive: archive);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await catalog.stopManaged();
          catalog.close();
          engine.close();
          library.close();
          await root.delete(recursive: true);
        });
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: EnginePage(
                catalog: catalog,
                pickEngineDirectory: () async => null,
              ),
            ),
          ),
        );
        await catalog.refresh();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byTooltip('启动参数'));
        await tester.tap(find.byTooltip('启动参数'));
        await catalog.readParameters(EngineCatalog.officialId);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '上下文与内存');
      await tester.enterText(
        find.byKey(const Key('parameter-number:--ctx-size')),
        '2048',
      );
      await tester.runAsync(() async {
        final saved = catalog.changes.firstWhere((state) => !state.busy);
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(28),
                child: LibraryPage(
                  library: library,
                  libraryPath: models.path,
                  engines: catalog,
                ),
              ),
            ),
          ),
        );
        await _settleFilesystemFrames(tester);
      });
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byTooltip('模型参数'));
        await tester.tap(find.byTooltip('模型参数'));
        // Build the real dialog in the I/O zone before queuing a refresh behind
        // its own refresh. Leaving this zone earlier strands its loading state.
        await tester.pump();
        await catalog.refresh();
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await selectParameterGroup(tester, '参数文本与命令');
      expect(find.text('完整启动命令'), findsOneWidget);
      await tester.tap(find.byTooltip('复制命令'));
      await tester.pump();
      final modelPath = await tester.runAsync(
        () =>
            File(library.state.artifacts.single.files.single.path)
                .resolveSymbolicLinks(),
      );
      expect(clipboard, contains('--ctx-size 2048'));
      expect(clipboard, contains(modelPath!));
      expect(clipboard, contains(engine.executablePath!));
      expect(clipboard, contains('启动时分配'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await catalog.refresh();
        await _settleFilesystemFrames(tester);
      });
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final ready = catalog.changes.firstWhere(
            (_) => engine.state.instances.any(
              (instance) => instance.status == LlamaInstanceStatus.ready,
            ),
          );
          await tester.ensureVisible(find.widgetWithText(TextButton, '运行'));
          await tester.tap(find.widgetWithText(TextButton, '运行'));
          await ready.timeout(const Duration(seconds: 5));
        }, _NetworkBoundary()),
      );
      await tester.runAsync(() => _settleFilesystemFrames(tester));
      final instance = engine.state.instances.single;
      expect(io.startedArguments.single, [
        '--model',
        modelPath,
        '--alias',
        instance.id,
        '--host',
        '127.0.0.1',
        '--port',
        '${instance.endpoint.port}',
        '--ctx-size',
        '2048',
        '--batch-size',
        '4096',
        '--ubatch-size',
        '4096',
        '--parallel',
        '1',
        '--n-gpu-layers',
        '99',
        '--device',
        'MTL0',
      ]);
      await _openLibraryDetails(tester, instance.asset.id);
      await tester.ensureVisible(find.byTooltip('实际启动命令'));
      await tester.tap(find.byTooltip('实际启动命令'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('复制命令'));
      await tester.pump();
      expect(
        clipboard,
        "'${io.startedExecutables.single}' --model '$modelPath' "
        '--alias ${instance.id} --host 127.0.0.1 '
        '--port ${instance.endpoint.port} --ctx-size 2048 --batch-size 4096 '
        '--ubatch-size 4096 --parallel 1 --n-gpu-layers 99 --device MTL0',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final lateLink in [false, true]) {
    test(
      'catalog recycle holds ${lateLink ? 'late linked' : 'captured'} provider admission until every child exits',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-aggregate-recycle-',
        );
        final library = ModelLibrary();
        final use = ModelUseRegistry(library);
        final ios = [_RuntimeIO(), _RuntimeIO(standard: true), _RuntimeIO()];
        final providers = <LlamaEngine>[];
        late EngineCatalog catalog;
        addTearDown(() async {
          if (ios[1].stopRelease != null && !ios[1].stopRelease!.isCompleted) {
            ios[1].stopRelease!.complete();
          }
          await catalog.stopManaged();
          catalog.close();
          for (final provider in providers) {
            provider.close();
          }
          library.close();
          await root.delete(recursive: true);
        });
        final models = Directory('${root.path}/models');
        await writeDecisionKev(models, ordinaryChat: true);
        final asset = (await library.scan(models, verifyFiles: true)).single;
        final archives = <File>[];
        for (var index = 0; index < 2; index++) {
          final standard = index == 1;
          final data = engineArchive(
            artifactTag: standard ? 'b11146' : 'b11381',
          );
          archives.add(
            await File('${root.path}/$index.tar.gz').writeAsBytes(data),
          );
          providers.add(
            LlamaEngine(
              library: library,
              useRegistry: use,
              installationDirectory: Directory('${root.path}/engines'),
              io: ios[index],
              release: LlamaRelease(
                tag: standard ? 'v0.5.0' : 'b11381',
                artifactTag: standard ? 'b11146' : 'b11381',
                expectedBuild: standard ? 11146 : 11381,
                supportsSystemone: !standard,
                expectedBinaryVersion: '0.5.0-dev',
                commit: standard
                    ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                    : '836d57176',
                url: Uri.parse('https://github.com/fixture/$index'),
                sha256: sha256.convert(data).toString(),
                sizeBytes: data.length,
              ),
            ),
          );
        }
        catalog = EngineCatalog(
          library: library,
          officialEngine: providers[0],
          standardEngine: providers[1],
          useRegistry: use,
          registryFile: File('${root.path}/registry.json'),
          io: ios[2],
        );
        await catalog.installOfficial(verifiedArchive: archives[0]);
        await catalog.installManaged(
          EngineCatalog.standardId,
          verifiedArchive: archives[1],
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final capturedA = catalog.providerFor(EngineCatalog.officialId);
          final runtimeA = catalog.runtimeFor(EngineCatalog.officialId);
          expect(runtimeA, same(capturedA));
          expect(catalog.state.entries.first.family, EngineFamily.llamaCpp);
          final a = await runtimeA.startRuntime(asset.id);
          expect(a.status, RuntimeInstanceStatus.ready);
          expect(a.capabilities, contains(RuntimeCapability.textGeneration));
          expect(a.capabilities, contains(RuntimeCapability.choiceProbability));
          expect(capturedA.state.instances.single.typedEvidence, isEmpty);
          expect(capturedA.state.instances.single.lastResult, isNull);
          expect(catalog.runsFor([asset.id]).single.instance.id, a.id);
          await providers[1].start(asset.id);
          Future<EngineRegistration>? linking;
          if (lateLink) {
            final external = await File('${root.path}/external/llama-server')
                .create(recursive: true);
            await external.writeAsString('external native fixture');
            expect(
              (await Process.run('/bin/chmod', ['+x', external.path])).exitCode,
              0,
            );
            ios[2].inspectionRequested = Completer<void>();
            ios[2].inspectionRelease = Completer<void>();
            linking = catalog.link(external.path);
            await ios[2].inspectionRequested!.future.timeout(
              const Duration(seconds: 3),
            );
          }
          ios[1].stopRelease = Completer<void>();
          ios[1].stopRequested = Completer<void>();
          final aStopped = capturedA.changes.firstWhere(
            (s) => s.instances.single.status == LlamaInstanceStatus.stopped,
          );
          var recycled = false;
          final recycle = catalog.stopManaged().then((_) => recycled = true);
          try {
            await ios[1].stopRequested!.future.timeout(
              const Duration(seconds: 3),
            );
            await aStopped.timeout(const Duration(seconds: 3));
            await expectLater(
              capturedA.start(asset.id),
              throwsA(isA<LlamaEngineException>()),
            );
            await expectLater(
              providers[1].start(asset.id),
              throwsA(isA<LlamaEngineException>()),
            );
            if (linking != null) {
              final bStopped = providers[1].changes.firstWhere(
                (s) => s.instances.single.status == LlamaInstanceStatus.stopped,
              );
              ios[1].stopRelease!.complete();
              await bStopped.timeout(const Duration(seconds: 3));
              // One event-loop turn settles the completed child futures, while the
              // preaccepted link remains held at its real command I/O seam.
              await Future<void>.delayed(Duration.zero);
              expect(
                recycled,
                isFalse,
                reason: 'catalog must drain preaccepted enrollment',
              );
              ios[2].inspectionRelease!.complete();
              final linked = await linking.timeout(const Duration(seconds: 3));
              final lateProvider = catalog.providerFor(linked.id);
              await expectLater(
                lateProvider.start(asset.id),
                throwsA(isA<LlamaEngineException>()),
              );
              expect(lateProvider.state.instances, isEmpty);
            }
            expect(ios.map((io) => io.startedExecutables.length), [1, 1, 0]);
          } finally {
            if (ios[2].inspectionRelease != null &&
                !ios[2].inspectionRelease!.isCompleted) {
              ios[2].inspectionRelease!.complete();
            }
            if (!ios[1].stopRelease!.isCompleted) {
              ios[1].stopRelease!.complete();
            }
            await recycle;
          }
          expect(
            providers.every(
              (p) => p.state.instances.every((i) => !i.hasLiveProcess),
            ),
            isTrue,
          );
          final next = await capturedA.start(asset.id);
          expect(next.generation, greaterThan(a.generation));
          await capturedA.stopManaged();
          final standalone = await capturedA.start(asset.id);
          expect(standalone.generation, greaterThan(next.generation));
        }, _NetworkBoundary());
      },
    );
  }
  test('dual managed and linked process identities recycle and seal together while removal owns only selected scope', () async {
    final root = await Directory.systemTemp.createTemp('gmd-three-providers-');
    final library = ModelLibrary();
    final use = ModelUseRegistry(library);
    final ios = [_RuntimeIO(), _RuntimeIO(standard: true), _RuntimeIO()];
    final providers = <LlamaEngine>[];
    late EngineCatalog catalog;
    addTearDown(() async {
      await catalog.stopManaged();
      catalog.close();
      for (final provider in providers) {
        provider.close();
      }
      library.close();
      await root.delete(recursive: true);
    });
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: true);
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final archives = <File>[];
    for (var index = 0; index < 2; index++) {
      final standard = index == 1;
      final data = engineArchive(artifactTag: standard ? 'b11146' : 'b11381');
      archives.add(await File('${root.path}/$index.tar.gz').writeAsBytes(data));
      providers.add(
        LlamaEngine(
          library: library,
          useRegistry: use,
          installationDirectory: Directory('${root.path}/engines'),
          io: ios[index],
          release: LlamaRelease(
            tag: standard ? 'v0.5.0' : 'b11381',
            artifactTag: standard ? 'b11146' : 'b11381',
            expectedBuild: standard ? 11146 : 11381,
            supportsSystemone: !standard,
            expectedBinaryVersion: '0.5.0-dev',
            commit: standard
                ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                : '836d57176',
            url: Uri.parse('https://github.com/fixture/$index'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          ),
        ),
      );
    }
    catalog = EngineCatalog(
      library: library,
      officialEngine: providers[0],
      standardEngine: providers[1],
      useRegistry: use,
      registryFile: File('${root.path}/registry.json'),
      io: ios[2],
    );
    await catalog.installOfficial(verifiedArchive: archives[0]);
    await catalog.installManaged(
      EngineCatalog.standardId,
      verifiedArchive: archives[1],
    );
    final external = await File('${root.path}/external/llama-server')
        .create(recursive: true);
    await external.writeAsString('external native fixture');
    final chmod = await Process.run('/bin/chmod', ['+x', external.path]);
    expect(chmod.exitCode, 0);
    final linked = await catalog.link(external.parent.path);
    expect(linked.archiveSha256, isNull);
    expect(linked.release, isNull);
    expect(linked.binarySha256, isNull);
    final all = [...providers, catalog.providerFor(linked.id)];
    await HttpOverrides.runWithHttpOverrides(() async {
      final first = <LlamaInstance>[];
      for (final provider in all) {
        first.add(await provider.start(asset.id));
      }
      expect(first.map((i) => i.installationId).toSet(), {
        EngineCatalog.officialId,
        EngineCatalog.standardId,
        linked.id,
      });
      expect(first.map((i) => i.engineServiceId).toSet(), hasLength(3));
      expect(
        first.map((i) => i.modelInferenceInstanceId).toSet(),
        hasLength(3),
      );
      expect(
        first.every(
          (i) =>
              i.nativeAlias == i.id &&
              i.capabilities.contains(LlamaCapability.textGeneration),
        ),
        isTrue,
      );
      await expectLater(
        catalog.prepareRemoval(EngineCatalog.standardId),
        throwsA(isA<LlamaEngineException>()),
      );
      ios.first.stopFailure = true;
      await expectLater(
        catalog.stopManaged(),
        throwsA(isA<LlamaEngineException>()),
      );
      expect(ios.map((i) => i.stopAttempts), [1, 1, 1]);
      expect(all.first.state.instances.single.hasLiveProcess, isTrue);
      expect(all.first.state.instances.single.capabilities, isEmpty);
      expect(all[1].state.instances.single.status, LlamaInstanceStatus.stopped);
      expect(all[2].state.instances.single.status, LlamaInstanceStatus.stopped);
      await catalog.stopManaged();
      expect(ios.map((i) => i.stopAttempts), [2, 1, 1]);
      for (final provider in all) {
        expect(
          provider.state.instances.single.status,
          LlamaInstanceStatus.stopped,
        );
        expect(provider.state.instances.single.nativeAlias, isNull);
        expect(provider.state.instances.single.capabilities, isEmpty);
      }
      final restarted = <LlamaInstance>[];
      for (final provider in all) {
        restarted.add(await provider.start(asset.id));
      }
      for (var index = 0; index < 3; index++) {
        expect(restarted[index].installationId, first[index].installationId);
        expect(
          restarted[index].engineServiceId,
          isNot(first[index].engineServiceId),
        );
        expect(restarted[index].id, isNot(first[index].id));
        expect(
          restarted[index].generation,
          greaterThan(first[index].generation),
        );
      }
      final standardBinary = File(all[1].executablePath!);
      await standardBinary.delete();
      await catalog.refresh();
      expect(all[1].state.installation, LlamaInstallationStatus.failed);
      expect(all[1].state.instances.last.capabilities, {
        LlamaCapability.textGeneration,
      });
      expect(all[1].state.instances.last.acceptingRequests, isTrue);
      expect(all[1].state.instances.last.nativeAlias, restarted[1].id);
      expect(all[1].state.instances.last.hasLiveProcess, isTrue);
      expect(all[0].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(all[2].state.instances.last.status, LlamaInstanceStatus.ready);
      await standardBinary.writeAsString('server fixture');
      await catalog.refresh();
      expect(
        all[1].state.instances.last.capabilities,
        {LlamaCapability.textGeneration},
        reason:
            'resource repair leaves the admitted running snapshot unchanged',
      );
      await all[1].stop(restarted[1].id);
      final removal = await catalog.prepareRemoval(EngineCatalog.standardId);
      await catalog.remove(removal, confirmed: true);
      expect(all[0].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(all[2].state.instances.last.status, LlamaInstanceStatus.ready);
      expect(await external.readAsString(), 'external native fixture');
      await catalog.shutdown();
      expect(ios.map((i) => i.stopAttempts), [3, 2, 2]);
      for (final provider in all) {
        expect(provider.state.instances.last.capabilities, isEmpty);
        await expectLater(provider.start(asset.id), throwsA(isA<StateError>()));
      }
    }, _NetworkBoundary());
  });
  for (final selection in [(false, false), (true, false), (true, true)]) {
    final (ordinaryChat, standard) = selection;
    testWidgets(
      'running ${standard
          ? 'selected standard ordinary text'
          : ordinaryChat
          ? 'ordinary text'
          : 'decision'} from the library discovers an existing installation without visiting engine management',
      (tester) async {
        late Directory root, models;
        late ModelLibrary library;
        late LlamaEngine original, fresh;
        LlamaEngine? peer;
        late EngineCatalog catalog;
        final io = _RuntimeIO(standard: standard);
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('jev-library-run-');
          models = Directory('${root.path}/models');
          await writeDecisionKev(models, ordinaryChat: ordinaryChat);
          library = ModelLibrary();
          final use = ModelUseRegistry(library);
          final data = engineArchive(
            artifactTag: standard ? 'b11146' : 'b11381',
          );
          final archive = await File('${root.path}/release.tar.gz')
              .writeAsBytes(data);
          final release = LlamaRelease(
            tag: standard ? 'v0.5.0' : 'b11381',
            artifactTag: standard ? 'b11146' : 'b11381',
            expectedBuild: standard ? 11146 : 11381,
            supportsSystemone: !standard,
            commit: standard
                ? '7fe450e19305b828c199d602c23a8337aaa1f03b'
                : '836d57176',
            url: Uri.parse('https://github.com/fixture'),
            sha256: sha256.convert(data).toString(),
            sizeBytes: data.length,
          );
          final owned = Directory('${root.path}/engines');
          original = LlamaEngine(
            library: library,
            installationDirectory: owned,
            io: io,
            release: release,
            useRegistry: use,
          );
          await original.install(verifiedArchive: archive);
          fresh = LlamaEngine(
            library: library,
            installationDirectory: owned,
            io: io,
            release: release,
            useRegistry: use,
            loadTimeout: const Duration(seconds: 2),
          );
          if (standard) {
            final peerData = engineArchive();
            final peerArchive = await File('${root.path}/peer.tar.gz')
                .writeAsBytes(peerData);
            peer = LlamaEngine(
              library: library,
              installationDirectory: owned,
              useRegistry: use,
              io: _RuntimeIO(),
              release: LlamaRelease(
                tag: 'b11381',
                commit: '836d57176',
                url: Uri.parse('https://github.com/fixture'),
                sha256: sha256.convert(peerData).toString(),
                sizeBytes: peerData.length,
              ),
            );
            await peer!.install(verifiedArchive: peerArchive);
          }
          catalog = EngineCatalog(
            library: library,
            officialEngine: peer ?? fresh,
            standardEngine: standard ? fresh : null,
            useRegistry: use,
            registryFile: File('${root.path}/private/engines.json'),
            io: io,
          );
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            if (io.stopRelease != null && !io.stopRelease!.isCompleted) {
              io.stopRelease!.complete();
            }
            await catalog.stopManaged();
            catalog.close();
            original.close();
            fresh.close();
            peer?.close();
            library.close();
            await root.delete(recursive: true);
          });
        });
        expect(fresh.state.installation, LlamaInstallationStatus.absent);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildJevTheme(Brightness.light),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(28),
                  child: LibraryPage(
                    library: library,
                    libraryPath: models.path,
                    engines: catalog,
                  ),
                ),
              ),
            ),
          );
          for (var n = 0; n < 100; n++) {
            await tester.pump();
            final run = find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '模型参数',
            );
            if (run.evaluate().isNotEmpty &&
                tester.widget<IconButton>(run).onPressed != null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await tester.ensureVisible(find.byTooltip('模型参数'));
          await tester.tap(find.byTooltip('模型参数'));
          for (var n = 0; n < 100; n++) {
            await tester.pump();
            final dropdown = find.descendant(
              of: find.byWidgetPredicate(
                (w) =>
                    w is DropdownButtonFormField<String> &&
                    w.key.toString().contains('instance-engine:'),
              ),
              matching: find.byType(DropdownButton<String>),
            );
            if (dropdown.evaluate().isNotEmpty &&
                tester.widget<DropdownButton<String>>(dropdown).items!.length ==
                    (standard ? 2 : 1) &&
                tester.widget<DropdownButton<String>>(dropdown).onChanged !=
                    null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        final dropdown = tester.widget<DropdownButton<String>>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) =>
                  w is DropdownButtonFormField<String> &&
                  w.key.toString().contains('instance-engine:'),
            ),
            matching: find.byType(DropdownButton<String>),
          ),
        );
        expect(dropdown.items, hasLength(standard ? 2 : 1));
        if (standard) {
          // Opening the menu owns the Future that later runs onChanged. Keep
          // that complete interaction in the real I/O zone for help file reads.
          await tester.runAsync(() async {
            await tester.tap(
              find.descendant(
                of: find.byWidgetPredicate(
                  (w) =>
                      w is DropdownButtonFormField<String> &&
                      w.key.toString().contains('instance-engine:'),
                ),
                matching: find.byType(DropdownButton<String>),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.textContaining('b11146').last);
            await tester.pump(const Duration(milliseconds: 350));
            await _settleFilesystemFrames(tester, dialogRemainsOpen: true);
          });
          await tester.pumpAndSettle();
        }
        expect(find.text('请先安装或关联引擎'), findsNothing);
        final engineField = find.byType(DropdownButtonFormField<String>);
        final version = find.textContaining(
          standard ? '7fe450e19' : '836d57176',
        );
        final fieldBounds = tester.getRect(engineField);
        final versionBounds = tester.getRect(version);
        expect(versionBounds.top, greaterThanOrEqualTo(fieldBounds.top));
        expect(
          versionBounds.bottom,
          lessThanOrEqualTo(fieldBounds.bottom),
          reason: 'The selected engine version must stay inside its input',
        );
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await catalog.refresh();
          await _settleFilesystemFrames(tester);
        });
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final completed = catalog.changes.firstWhere(
              (_) => fresh.state.instances.any(
                (instance) => instance.status == LlamaInstanceStatus.ready,
              ),
            );
            await tester.ensureVisible(find.widgetWithText(TextButton, '运行'));
            await tester.tap(find.widgetWithText(TextButton, '运行'));
            await completed.timeout(const Duration(seconds: 5));
          }, _NetworkBoundary()),
        );
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        await _openLibraryDetails(
          tester,
          fresh.state.instances.single.asset.id,
        );
        expect(find.text('运行中'), findsOneWidget);
        expect(find.text('运行模型'), findsNothing);
        expect(find.widgetWithText(TextButton, '停止'), findsOneWidget);
        if (ordinaryChat) {
          expect(fresh.state.instances.single.lastTextResult, isNull);
          final explicit = await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              () => fresh.generateText(
                fresh.state.instances.single.id,
                TextRequest(prompt: 'Hello'),
              ),
              _NetworkBoundary(),
            ),
          );
          expect(explicit!.text, 'Hello.');
          expect(
            fresh.state.instances.single.capabilities,
            contains(LlamaCapability.textGeneration),
          );
          expect(fresh.state.instances.single.lastResult, isNull);
        } else {
          expect(fresh.state.instances.single.lastResult, isNull);
          final explicit = await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              () => fresh.decide(
                fresh.state.instances.single.id,
                DecisionRequest(
                  state: 'A change',
                  instructions: 'Choose an action',
                  options: {'keep': 'Keep', 'change': 'Change'},
                ),
              ),
              _NetworkBoundary(),
            ),
          );
          expect(explicit!.probabilities, {'keep': 0.25, 'change': 0.75});
        }
        final instance = fresh.state.instances.single;
        expect(
          instance.installationId,
          standard ? EngineCatalog.standardId : EngineCatalog.officialId,
        );
        expect(instance.engineServiceId, isNotNull);
        expect(
          instance.engineServiceId,
          isNot(instance.modelInferenceInstanceId),
        );
        expect(instance.nativeAlias, instance.id);
        expect(instance.pid, 42421);
        expect(instance.generation, greaterThan(0));
        expect(instance.binaryVersion!.build, standard ? 11146 : 11381);
        expect(instance.binaryVersion!.semanticVersion, '0.5.0-dev');
        expect(
          instance.processEnvironment,
          isNull,
          reason: 'I/O fixture does not observe a native environment',
        );
        expect(
          io.startedExecutables.single,
          endsWith('/${standard ? 'v0.5.0' : 'b11381'}/llama-server'),
        );
        if (standard) expect(peer!.state.instances, isEmpty);
        expect(library.state.artifacts.single.fingerprintsVerified, isFalse);
        await expectLater(
          library.prepareDeletion([library.state.artifacts.single.id]),
          throwsA(isA<LibraryException>()),
        );
        io.stopFailure = true;
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(TextButton, '停止'));
          await _settleFilesystemFrames(tester);
        });
        expect(find.text('Bad state: provider refused stop'), findsOneWidget);
        expect(fresh.state.instances.single.status, LlamaInstanceStatus.failed);
        expect(fresh.state.instances.single.hasLiveProcess, isTrue);
        expect(fresh.state.instances.single.acceptingRequests, isFalse);
        expect(fresh.state.instances.single.capabilities, isEmpty);
        await expectLater(
          library.prepareDeletion([library.state.artifacts.single.id]),
          throwsA(isA<LibraryException>()),
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '停止'))
              .onPressed,
          isNotNull,
        );
        io.stopRelease = Completer<void>();
        io.stopRequested = Completer<void>();
        await tester.runAsync(() async {
          final stopped = catalog.changes.firstWhere(
            (_) =>
                fresh.state.instances.single.status ==
                LlamaInstanceStatus.stopped,
          );
          await tester.ensureVisible(find.widgetWithText(TextButton, '停止'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(TextButton, '停止'));
          await tester.pump();
          await io.stopRequested!.future.timeout(const Duration(seconds: 3));
          await tester.pump();
          expect(find.text('运行中'), findsNothing);
          final pendingStop = find.widgetWithText(TextButton, '停止中');
          expect(pendingStop, findsOneWidget);
          expect(tester.widget<TextButton>(pendingStop).onPressed, isNull);
          await tester.tap(pendingStop);
          expect(io.stopAttempts, 2);
          io.stopRelease!.complete();
          for (var n = 0; n < 200; n++) {
            await tester.pump();
            if (fresh.state.instances.single.status ==
                LlamaInstanceStatus.stopped) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          await stopped.timeout(const Duration(seconds: 5));
          expect(
            (await library.prepareDeletion([library.state.artifacts.single.id]))
                .files,
            hasLength(1),
          );
        });
        await tester.runAsync(() => _settleFilesystemFrames(tester));
        expect(find.text('已停止'), findsOneWidget);
        expect(fresh.state.instances.single.hasLiveProcess, isFalse);
        expect(find.text('运行中'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _NetworkBoundary extends HttpOverrides {}

class _LaunchTextFixture {
  _LaunchTextFixture(this.root, this.release, this.io);
  final Directory root;
  final LlamaRelease release;
  final _RuntimeIO io;
  late ModelLibrary library;
  late LlamaEngine engine;
  late EngineCatalog catalog;
  late LibraryArtifact asset;

  static Future<_LaunchTextFixture> create({bool ordinaryChat = true}) async {
    final root = await Directory.systemTemp.createTemp('gmd-launch-text-');
    final data = engineArchive();
    final fixture = _LaunchTextFixture(
      root,
      LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
      _RuntimeIO(),
    );
    final archive = await File('${root.path}/engine.tar.gz').writeAsBytes(data);
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: ordinaryChat);
    fixture._open();
    await fixture.catalog.installOfficial(verifiedArchive: archive);
    fixture.asset = (await fixture.library.scan(
      models,
      verifyFiles: true,
    )).single;
    return fixture;
  }

  void _open() {
    library = ModelLibrary();
    final use = ModelUseRegistry(library);
    engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      useRegistry: use,
      release: release,
      io: io,
      loadTimeout: const Duration(seconds: 2),
    );
    catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: use,
      registryFile: File('${root.path}/engines.json'),
      io: io,
    );
  }

  Future<void> reopen({String? artifactId}) async {
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    _open();
    await catalog.refresh();
    final assets = await library.scan(
      Directory('${root.path}/models'),
      verifyFiles: true,
    );
    asset = artifactId == null
        ? assets.single
        : assets.singleWhere((asset) => asset.id == artifactId);
  }

  Future<void> close() async {
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    await root.delete(recursive: true);
  }
}

Future<void> _openTextEditor(
  WidgetTester tester,
  _LaunchTextFixture fixture,
) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildJevTheme(Brightness.light),
        home: Scaffold(
          body: EnginePage(
            catalog: fixture.catalog,
            pickEngineDirectory: () async => null,
          ),
        ),
      ),
    );
    await fixture.catalog.refresh();
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.ensureVisible(find.byTooltip('启动参数'));
    await tester.tap(find.byTooltip('启动参数'));
    await fixture.catalog.readParameters(EngineCatalog.officialId);
  });
  await tester.pumpAndSettle();
  await selectParameterGroup(tester, '参数文本与命令');
}

Future<void> _saveTextEditor(
  WidgetTester tester,
  _LaunchTextFixture fixture,
) async {
  await tester.runAsync(() async {
    final saved = fixture.catalog.changes.firstWhere((state) => !state.busy);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await saved.timeout(const Duration(seconds: 5));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

Future<void> _settleFilesystemFrames(
  WidgetTester tester, {
  bool dialogRemainsOpen = false,
}) async {
  for (var n = 0; n < 100; n++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        (dialogRemainsOpen || find.text('运行模型').evaluate().isEmpty)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Runtime page did not settle');
}

class _RuntimeIO implements EngineProcessIO {
  _RuntimeIO({this.standard = false});
  final bool standard;
  final startedExecutables = <String>[];
  final startedArguments = <List<String>>[];
  String? startupError;
  Completer<void>? startupExitGate;
  bool stopFailure = false;
  int stopAttempts = 0;
  int versionChecks = 0;
  Completer<void>? stopRelease;
  Completer<void>? stopRequested;
  Completer<void>? inspectionRequested;
  Completer<void>? inspectionRelease;
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--help') {
      return const EngineCommandResult(
        0,
        '--model --alias --host --port --ctx-size --batch-size --ubatch-size --parallel --n-gpu-layers --device',
        '',
      );
    }
    if (arguments.singleOrNull == '--version') {
      versionChecks++;
      if (inspectionRequested != null && !inspectionRequested!.isCompleted) {
        inspectionRequested!.complete();
        await inspectionRelease!.future;
      }
      return EngineCommandResult(
        0,
        standard
            ? 'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64'
            : 'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    startedExecutables.add(executable);
    startedArguments.add(List.of(arguments));
    if (startupError != null) {
      return _RejectedRuntimeChild(startupError!, startupExitGate?.future);
    }
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/props') {
        request.response.write(
          jsonEncode({
            'model_alias': arg('--alias'),
            'model_path': arg('--model'),
          }),
        );
      } else if (request.uri.path == '/v1/chat/completions') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], arg('--alias'));
        expect(body['stream'], false);
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'Hello.'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'completion_tokens': 2},
          }),
        );
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (!(body['questions'] as Map).containsKey('council_choice')) {
          request.response.statusCode = HttpStatus.notImplemented;
          request.response.write('{"error":"fixture has no typed head"}');
          await request.response.close();
          return;
        }
        final options =
            (body['questions'] as Map)['council_choice']['criteria'] as Map;
        request.response.write(
          jsonEncode({
            'model': arg('--alias'),
            'answers': {
              'council_choice': {
                'type': 'choice',
                'choice': options.keys.last,
                'probabilities': {
                  options.keys.first: 0.25,
                  options.keys.last: 0.75,
                },
              },
            },
            'usage': {'output_tokens': 0},
          }),
        );
      }
      await request.response.close();
    });
    return _RuntimeChild(server, this);
  }
}

class _RuntimeChild implements EngineChild {
  _RuntimeChild(this.server, this.io);
  final HttpServer server;
  final _RuntimeIO io;
  final stopped = Completer<int>();
  @override
  int get pid => 42421;
  @override
  Future<int> get exitCode => stopped.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    io.stopAttempts++;
    if (io.stopFailure) {
      io.stopFailure = false;
      throw StateError('provider refused stop');
    }
    if (io.stopRequested != null && !io.stopRequested!.isCompleted) {
      io.stopRequested!.complete();
    }
    server.close(force: true).then((_) async {
      await io.stopRelease?.future;
      if (!stopped.isCompleted) stopped.complete(0);
    });
    return true;
  }
}

class _RejectedRuntimeChild implements EngineChild {
  _RejectedRuntimeChild(this.diagnostic, Future<void>? exitGate)
    : _exitCode = (exitGate ?? Future<void>.value()).then((_) => 64);
  final String diagnostic;
  final Future<int> _exitCode;
  @override
  int get pid => 42422;
  @override
  Future<int> get exitCode => _exitCode;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode('$diagnostic\n'));
  @override
  bool kill(ProcessSignal signal) => true;
}

Future<void> _openLibraryDetails(WidgetTester tester, String artifactId) async {
  await tester.runAsync(() async {
    final more = find.byKey(ValueKey('model-more:$artifactId'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件详情').last);
    await tester.pumpAndSettle();
  });
}

Future<void> _openInstanceMore(WidgetTester tester, String instanceId) async {
  final more = find.byKey(ValueKey('instance-more:$instanceId'));
  await tester.ensureVisible(more);
  await tester.tap(more);
  await tester.pumpAndSettle();
}
