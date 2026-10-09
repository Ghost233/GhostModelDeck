import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/omlx_engine.dart';

import 'fixtures/qwen2_mlx_layout.dart';

void main() {
  test('current oMLX help belongs to verified registration and saved configuration', () async {
    final fixture = await _OmlxConfigurationFixture.create();
    addTearDown(fixture.close);
    fixture.io.help +=
        '  --requests, --max-concurrent-requests COUNT  current request description\n'
        '  --pool-directory, --model-dir MODEL_DIR  current model pool directory\n'
        '  --hf-cache, --no-hf-cache  current opposite cache switches\n';
    const raw =
        ' --requests 6 --pool-directory "/foreign pool" --api-key private '
        '--model "user model" --alias user-alias --hf-cache --no-hf-cache --future="two words"\n';
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        formValues: {'--max-concurrent-requests': '4'},
        argumentText: raw,
      ),
    );
    await fixture.catalog.refresh();
    final rules = fixture.catalog.parameterRecognitionFor(fixture.id);
    expect(rules.recognizes('--requests'), isTrue);
    expect(rules.version, '0.7.0');
    expect(rules.executablePath, '${fixture.app.path}/Contents/MacOS/omlx-cli');
    expect(
      rules.contentFingerprint,
      fixture.catalog.state.entries
          .singleWhere((entry) => entry.id == fixture.id)
          .omlxReceipt!
          .bundleManifestSha256,
    );
    expect(
      rules.descriptionFor('--requests')!.description,
      'current request description',
    );
    expect(rules.canonicalName('--hf-cache'), '--hf-cache');
    expect(rules.canonicalName('--no-hf-cache'), '--no-hf-cache');
    final saved = fixture.catalog.launchDefaultsFor(fixture.id);
    final result = saved.command(
      executable: fixture.app.path,
      modelPath: 'not assigned',
      recognition: rules,
    );
    expect(result.isConfigurationOnly, isTrue);
    expect(result.overriddenForm, {'--max-concurrent-requests'});
    expect(result.arguments, [
      '--requests',
      '6',
      '--model',
      'user model',
      '--alias',
      'user-alias',
      '--hf-cache',
      '--no-hf-cache',
      '--future=two words',
    ]);
    expect(result.displayText, isNot(contains(fixture.app.path)));
    expect(result.notices, contains(contains('--model-dir 由软件管理')));
    expect(saved.argumentText, raw);
    expect(
      (jsonDecode(
        await fixture.catalog.registryFile.readAsString(),
      ) as Map)['linked'].toString(),
      isNot(contains('current request description')),
    );
    expect(
      fixture.io.calls.any((call) => call.$2.join(' ') == 'serve --help'),
      isTrue,
    );
    expect(fixture.pool.starts, 0);
  });

  test('optional oMLX help failure keeps saved text but required identity still rejects', () async {
    final fixture = await _OmlxConfigurationFixture.create();
    addTearDown(fixture.close);
    fixture.io.help += '  --requests, --max-concurrent-requests COUNT  current request description\n';
    await fixture.catalog.refresh();
    const raw = ' --requests 9\n';
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        formValues: {'--max-concurrent-requests': '4'},
        argumentText: raw,
      ),
    );
    expect(
      fixture.catalog
          .parameterRecognitionFor(fixture.id)
          .recognizes('--requests'),
      isTrue,
    );
    fixture.io.helpFailure = TimeoutException('controlled process timeout');
    await fixture.catalog.refresh();
    final failedHelp = fixture.catalog.parameterRecognitionFor(fixture.id);
    expect(
      fixture.catalog.state.entries
          .singleWhere((entry) => entry.id == fixture.id)
          .status,
      LlamaInstallationStatus.installed,
    );
    expect(failedHelp.status, EngineHelpStatus.unavailable);
    expect(failedHelp.canonicalName('--requests'), '--max-concurrent-requests');
    expect(failedHelp.notices.join(' '), contains('帮助'));
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, raw);
    fixture.io.helpFailure = null;
    fixture.io.helpExit = 17;
    await fixture.catalog.refresh();
    expect(
      fixture.catalog.parameterRecognitionFor(fixture.id).status,
      EngineHelpStatus.unavailable,
    );
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, raw);
    fixture.io.helpExit = 0;
    fixture.io.help = 'x' * (512 * 1024 + 1);
    await fixture.catalog.refresh();
    expect(
      fixture.catalog.parameterRecognitionFor(fixture.id).status,
      EngineHelpStatus.unavailable,
    );
    fixture.io.help = 'unparseable current output';
    await fixture.catalog.refresh();
    expect(
      fixture.catalog
          .parameterRecognitionFor(fixture.id)
          .canonicalName('--requests'),
      '--max-concurrent-requests',
    );
    fixture.io.version = '0.7.1';
    await fixture.catalog.refresh();
    expect(
      fixture.catalog.state.entries
          .singleWhere((entry) => entry.id == fixture.id)
          .status,
      LlamaInstallationStatus.failed,
    );
    expect(
      fixture.catalog
          .parameterRecognitionFor(fixture.id)
          .recognizes('--requests'),
      isFalse,
    );
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, raw);
    expect(fixture.pool.starts, 0);
  });

  test('oMLX verified versions survive saved history and restore while unverified versions stay unknown', () async {
    final fixture = await _OmlxConfigurationFixture.create();
    addTearDown(fixture.close);
    final managed = fixture.engine.bundle;
    await for (final entry in fixture.app.list(recursive: true)) {
      if (entry is! File) continue;
      final target = File(
        '${managed.path}${entry.path.substring(fixture.app.path.length)}',
      );
      await target.parent.create(recursive: true);
      await entry.copy(target.path);
    }
    final receipt = await fixture.engine.inspectLinked(managed);
    expect(receipt.parameterRecognition!.version, '0.7.0');
    await File('${managed.parent.path}/installation.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'receipt': {...receipt.toJson(), 'dmgSha256': OmlxEngine.dmgDigest},
      }),
    );
    await fixture.catalog.refresh();
    EngineRegistration registration(String id) =>
        fixture.catalog.state.entries.singleWhere((entry) => entry.id == id);
    final sourceId = fixture.id;
    expect(registration(sourceId).version, '0.7.0');
    expect(registration(EngineCatalog.omlxId).version, '0.7.0');
    const sourceText = ' --max-concurrent-requests 8\n';
    await fixture.catalog.saveLaunchDefaults(
      sourceId,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        formValues: {'--max-concurrent-requests': '4'},
        argumentText: sourceText,
      ),
    );
    await fixture.catalog.saveLaunchDefaults(
      EngineCatalog.omlxId,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        argumentText: '--max-concurrent-requests 2',
      ),
    );
    final saved =
        jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
    expect((saved['configurationVersions'] as Map?)?[sourceId], '0.7.0');
    expect(
      (saved['configurationVersions'] as Map?)?[EngineCatalog.omlxId],
      '0.7.0',
    );
    await fixture.catalog.remove(
      await fixture.catalog.prepareRemoval(sourceId),
      confirmed: true,
    );
    await fixture.reopen();
    final history = fixture.catalog.unlinkedConfigurations.singleWhere(
      (entry) => entry.registrationId == sourceId,
    );
    expect(history.version, '0.7.0');
    expect(history.defaults!.argumentText, sourceText);
    fixture.id = (await fixture.catalog.link(fixture.app.path)).id;
    await fixture.catalog.restoreUnlinkedConfiguration(sourceId, fixture.id);
    expect(registration(fixture.id).version, '0.7.0');
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      sourceText,
    );
    final restored =
        jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
    expect((restored['configurationVersions'] as Map?)?[fixture.id], '0.7.0');
    // A legal older history may know neither a parameter origin nor an engine
    // version. A fresh target's verified CLI is not that parameter provenance.
    ((restored['unlinkedConfigurations'] as Map)[sourceId] as Map)['version'] =
        null;
    (restored['configurationVersions'] as Map).remove(sourceId);
    await fixture.catalog.registryFile.writeAsString(jsonEncode(restored));
    await fixture.reopen();
    await fixture.catalog.restoreUnlinkedConfiguration(sourceId, fixture.id);
    expect(registration(fixture.id).version, '0.7.0');
    final unknownRestored =
        jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
    final unknownOrigins = unknownRestored['configurationVersions'] as Map;
    expect(unknownOrigins.containsKey(fixture.id), isTrue);
    expect(unknownOrigins[fixture.id], isNull);
    final relayId = fixture.id;
    await fixture.catalog.remove(
      await fixture.catalog.prepareRemoval(relayId),
      confirmed: true,
    );
    await fixture.reopen();
    fixture.id = (await fixture.catalog.link(fixture.app.path)).id;
    await fixture.catalog.restoreUnlinkedConfiguration(relayId, fixture.id);
    expect(registration(fixture.id).version, '0.7.0');
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      sourceText,
    );
    final relayed =
        jsonDecode(await fixture.catalog.registryFile.readAsString()) as Map;
    final relayedOrigins = relayed['configurationVersions'] as Map;
    expect(relayedOrigins.containsKey(fixture.id), isTrue);
    expect(relayedOrigins[fixture.id], isNull);
    const targetText = '--max-concurrent-requests 1';
    final targetConfiguration = EngineLaunchConfiguration(
      family: EngineFamily.omlx,
      argumentText: targetText,
    );
    await fixture.catalog.saveLaunchDefaults(fixture.id, targetConfiguration);
    await fixture.reopen(refresh: false);
    final callsBeforeLoad = fixture.io.calls.length;
    // Saving can lazily load expected receipts, but must not call them a current
    // CLI observation before the original inspection has run again.
    await fixture.catalog.saveLaunchDefaults(fixture.id, targetConfiguration);
    expect(fixture.io.calls.length, callsBeforeLoad);
    expect(registration(fixture.id).version, isNull);
    expect(registration(EngineCatalog.omlxId).version, isNull);
    fixture.io.version = '0.7.1';
    final beforeFailure = await fixture.catalog.registryFile.readAsString();
    await fixture.catalog.refresh();
    for (final id in [fixture.id, EngineCatalog.omlxId]) {
      expect(registration(id).status, LlamaInstallationStatus.failed);
      expect(registration(id).version, isNull);
      expect(fixture.catalog.parameterRecognitionFor(id).version, isNull);
    }
    await expectLater(
      fixture.catalog.restoreUnlinkedConfiguration(sourceId, fixture.id),
      throwsA(isA<OmlxException>()),
    );
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      targetText,
    );
    expect(await fixture.catalog.registryFile.readAsString(), beforeFailure);
    expect(fixture.pool.starts, 0);
    final invalidShape = jsonDecode(beforeFailure) as Map;
    (invalidShape['configurationVersions'] as Map)[fixture.id] = 7;
    final invalidText = jsonEncode(invalidShape);
    await fixture.catalog.registryFile.writeAsString(invalidText);
    await expectLater(fixture.reopen(), throwsA(isA<LlamaEngineException>()));
    expect(
      fixture.catalog.state.entries.where(
        (entry) => entry.source == EngineSource.linked,
      ),
      isEmpty,
    );
    expect(await fixture.catalog.registryFile.readAsString(), invalidText);
  });

  test('oMLX history restore publishes fresh help and closes metadata on required failure', () async {
    final fixture = await _OmlxConfigurationFixture.create();
    addTearDown(fixture.close);
    fixture.io.help +=
        '  --source-requests, --max-concurrent-requests COUNT  source help\n';
    await fixture.catalog.refresh();
    final sourceId = fixture.id;
    const sourceText = ' --source-requests 8\n';
    await fixture.catalog.saveLaunchDefaults(
      sourceId,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        formValues: {'--max-concurrent-requests': '4'},
        argumentText: sourceText,
      ),
    );
    await fixture.catalog.remove(
      await fixture.catalog.prepareRemoval(sourceId),
      confirmed: true,
    );
    expect(await fixture.app.exists(), isTrue);
    fixture.id = (await fixture.catalog.link(fixture.app.path)).id;
    expect(fixture.id, isNot(sourceId));
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, isEmpty);
    fixture.io.help += '  --fresh-requests, --max-concurrent-requests COUNT  fresh restore help\n';
    await fixture.catalog.restoreUnlinkedConfiguration(sourceId, fixture.id);
    expect(
      fixture.catalog
          .parameterRecognitionFor(fixture.id)
          .recognizes('--fresh-requests'),
      isTrue,
    );
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      sourceText,
    );
    const targetText = '--max-concurrent-requests 2';
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        argumentText: targetText,
      ),
    );
    fixture.io.version = '0.7.1';
    await expectLater(
      fixture.catalog.restoreUnlinkedConfiguration(sourceId, fixture.id),
      throwsA(isA<OmlxException>()),
    );
    expect(
      fixture.catalog.state.entries
          .singleWhere((entry) => entry.id == fixture.id)
          .status,
      LlamaInstallationStatus.failed,
    );
    expect(
      fixture.catalog
          .parameterRecognitionFor(fixture.id)
          .recognizes('--fresh-requests'),
      isFalse,
    );
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      targetText,
    );
    expect(fixture.pool.starts, 0);
  });

  test(
    'late oMLX help cannot publish rules after admission cancellation',
    () async {
      final fixture = await _OmlxConfigurationFixture.create();
      addTearDown(fixture.close);
      fixture.io.help +=
          '  --late-requests, --max-concurrent-requests COUNT  late help\n';
      fixture.io.helpStarted = Completer<void>();
      fixture.io.releaseHelp = Completer<void>();
      final refreshing = fixture.catalog.refresh();
      await fixture.io.helpStarted!.future;
      final release = fixture.engine.holdInstallationAdmission();
      fixture.io.releaseHelp!.complete();
      await refreshing;
      release();
      expect(
        fixture.catalog.state.entries
            .singleWhere((entry) => entry.id == fixture.id)
            .status,
        LlamaInstallationStatus.failed,
      );
      expect(
        fixture.catalog
            .parameterRecognitionFor(fixture.id)
            .recognizes('--late-requests'),
        isFalse,
      );
      expect(
        await fixture.engine.installationDirectory.list().toList(),
        isEmpty,
      );
      expect(fixture.pool.starts, 0);
    },
  );

  for (final changed in ['content', 'builder', 'signature']) {
    test(
      'oMLX $changed guards remain mandatory around optional help',
      () async {
        final fixture = await _OmlxConfigurationFixture.create();
        addTearDown(fixture.close);
        fixture.io.help +=
            '  --requests, --max-concurrent-requests COUNT  current help\n';
        await fixture.catalog.refresh();
        const raw = '--requests 7';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(
            family: EngineFamily.omlx,
            argumentText: raw,
          ),
        );
        expect(
          fixture.catalog
              .parameterRecognitionFor(fixture.id)
              .recognizes('--requests'),
          isTrue,
        );
        if (changed == 'builder') {
          fixture.io.builderAfterProbe = true;
        } else {
          fixture.io.afterHelp = () async {
            if (changed == 'content') {
              await File('${fixture.app.path}/Contents/MacOS/omlx-cli')
                  .writeAsString('changed during help');
            } else {
              fixture.io.team = 'DIFFERENT';
            }
          };
        }
        await fixture.catalog.refresh();
        expect(
          fixture.catalog.state.entries
              .singleWhere((entry) => entry.id == fixture.id)
              .status,
          LlamaInstallationStatus.failed,
        );
        expect(
          fixture.catalog
              .parameterRecognitionFor(fixture.id)
              .recognizes('--requests'),
          isFalse,
        );
        expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, raw);
        expect(fixture.pool.starts, 0);
      },
    );
  }

  test('managed and linked oMLX observations stay attached to their own receipt paths', () async {
    final fixture = await _OmlxConfigurationFixture.create();
    addTearDown(fixture.close);
    final managed = fixture.engine.bundle;
    await for (final entry in fixture.app.list(recursive: true)) {
      if (entry is! File) continue;
      final target = File(
        '${managed.path}${entry.path.substring(fixture.app.path.length)}',
      );
      await target.parent.create(recursive: true);
      await entry.copy(target.path);
    }
    final receipt = await fixture.engine.inspectLinked(managed);
    await File('${managed.parent.path}/installation.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'receipt': {...receipt.toJson(), 'dmgSha256': OmlxEngine.dmgDigest},
      }),
    );
    fixture.io.helpByApp[managed.path] =
        '${fixture.io.help}  --managed-requests, --max-concurrent-requests COUNT  managed help\n';
    fixture.io.helpByApp[fixture.app.path] =
        '${fixture.io.help}  --linked-requests, --max-concurrent-requests COUNT  linked help\n';
    await fixture.catalog.refresh();
    final managedRules = fixture.catalog.parameterRecognitionFor(
      EngineCatalog.omlxId,
    );
    final linkedRules = fixture.catalog.parameterRecognitionFor(fixture.id);
    expect(fixture.engine.state.status, OmlxInstallationStatus.installed);
    expect(managedRules.recognizes('--managed-requests'), isTrue);
    expect(managedRules.recognizes('--linked-requests'), isFalse);
    expect(linkedRules.recognizes('--linked-requests'), isTrue);
    expect(linkedRules.recognizes('--managed-requests'), isFalse);
    expect(managedRules.contentFingerprint, linkedRules.contentFingerprint);
    expect(managedRules.executablePath, isNot(linkedRules.executablePath));
    await fixture.catalog.saveLaunchDefaults(
      EngineCatalog.omlxId,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        argumentText: '--managed-requests 2',
      ),
    );
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(
        family: EngineFamily.omlx,
        argumentText: '--linked-requests 3',
      ),
    );
    fixture.io.helpFailure = TimeoutException(
      'controlled optional I/O failure',
    );
    await fixture.catalog.refresh();
    expect(
      fixture.catalog
          .parameterRecognitionFor(EngineCatalog.omlxId)
          .recognizes('--managed-requests'),
      isTrue,
    );
    expect(
      fixture.catalog
          .parameterRecognitionFor(EngineCatalog.omlxId)
          .recognizes('--linked-requests'),
      isFalse,
    );
    expect(
      fixture.catalog.launchDefaultsFor(EngineCatalog.omlxId).argumentText,
      '--managed-requests 2',
    );
    expect(
      fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
      '--linked-requests 3',
    );
    await expectLater(
      fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(),
      ),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(fixture.pool.starts, 0);
  });

  testWidgets(
    'oMLX model configuration persists through restart while production run stays disabled',
    (tester) async {
      final fixture = (await tester.runAsync(
        _OmlxConfigurationFixture.create,
      ))!;
      addTearDown(() => tester.runAsync(fixture.close));
      late LocalModelPackage model;
      await tester.runAsync(() async {
        final models = Directory('${fixture.root.path}/models');
        for (final entry in Qwen2MlxFixture().bytes().entries) {
          final file = File('${models.path}/model-a/${entry.key}');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(entry.value);
        }
        final assets = await fixture.library.scan(models, verifyFiles: true);
        model = (await LocalModelPackages.discover(
          models,
          assets,
        )).packages.single;
      });
      Future<void> openDialog() async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showModelRunDialog(
                      context,
                      catalog: fixture.catalog,
                      library: fixture.library,
                      modelPackage: model,
                      variant: model.variants.single,
                    ),
                    child: const Text('configure model'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('configure model'));
          await tester.pump();
          await fixture.catalog.refresh();
        });
        await tester.pumpAndSettle();
      }

      await openDialog();
      expect(find.textContaining('生产模型运行尚未接通'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '运行'))
            .onPressed,
        isNull,
      );
      expect(find.text('模型独立'), findsOneWidget);
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.text('模型独立'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模型参数'));
      await tester.pumpAndSettle();
      final requests = find.widgetWithText(TextField, '最大并发请求数');
      // Desktop pointer input keeps focus without touch selection handles.
      await tester.tap(requests, kind: PointerDeviceKind.mouse);
      await tester.pump();
      tester.testTextInput.enterText('3');
      await tester.pump();
      final text = find.widgetWithText(TextField, '启动参数文本');
      await tester.ensureVisible(text);
      const raw = ' --max-concurrent-requests "unfinished';
      await tester.tap(text, kind: PointerDeviceKind.mouse);
      await tester.pump();
      final client = tester.testTextInput.log
          .lastWhere((call) => call.method == 'TextInput.setClient')
          .arguments;
      tester.testTextInput.enterText(raw);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(text).decoration!.errorText,
        contains('未闭合'),
      );
      expect(
        tester.testTextInput.log
            .lastWhere((call) => call.method == 'TextInput.setClient')
            .arguments,
        client,
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: text, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(
        find.widgetWithText(FilledButton, '保存').hitTestable(),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(
          find.widgetWithText(FilledButton, '保存'),
          kind: PointerDeviceKind.mouse,
        );
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      final id = model.variants.single.artifacts.single.id;
      expect(
        fixture.catalog.launchConfigurationFor(fixture.id, id).argumentText,
        raw,
      );
      expect(fixture.catalog.launchDefaultsFor(fixture.id).formValues, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.reopen);
      await openDialog();
      await tester.tap(find.text('编辑模型参数'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(text).controller!.text, raw);
      expect(tester.widget<TextField>(requests).controller!.text, '3');
      expect(
        fixture.catalog.launchConfigurationFor(fixture.id, id).family,
        EngineFamily.omlx,
      );
      expect(fixture.pool.starts, 0);
      expect(fixture.engine.runtimeInstances, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'registered oMLX edits and reopens raw configuration without a production run',
    (tester) async {
      final fixture = (await tester.runAsync(
        _OmlxConfigurationFixture.create,
      ))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
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
      expect(find.byTooltip('启动参数'), findsNWidgets(3));
      await tester.tap(find.byTooltip('启动参数').at(1));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '上下文大小'), findsNothing);
      final requests = find.widgetWithText(TextField, '最大并发请求数');
      await tester.ensureVisible(requests);
      await tester.enterText(requests, '4');
      final input = find.widgetWithText(TextField, '启动参数文本');
      await tester.ensureVisible(input);
      const raw = '  --max-concurrent-requests 6 --future "two words"\n';
      await tester.enterText(input, raw);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(requests).decoration!.errorText,
        '已被文本覆盖',
      );
      expect(find.textContaining('生产模型运行尚未接通'), findsWidgets);
      expect(find.text('完整启动命令'), findsNothing);
      expect(find.byTooltip('复制命令'), findsNothing);
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, raw);
      expect(
        fixture.catalog
            .launchDefaultsFor(fixture.id)
            .formValues['--max-concurrent-requests'],
        '4',
      );
      await tester.tap(find.byTooltip('启动参数').at(1));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, raw);
      expect(tester.widget<TextField>(requests).controller!.text, '4');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(fixture.reopen);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
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
      await tester.tap(find.byTooltip('启动参数').at(1));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, raw);
      expect(tester.widget<TextField>(requests).controller!.text, '4');
      expect(fixture.pool.starts, 0);
      expect(fixture.engine.runtimeInstances, isEmpty);
      expect(
        fixture.io.calls
            .where((call) => call.$1.endsWith('/omlx-cli'))
            .every(
              (call) =>
                  call.$2.join(' ') == '--version' ||
                  call.$2.join(' ') == 'serve --help',
            ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _OmlxConfigurationFixture {
  _OmlxConfigurationFixture(this.root, this.app, this.io, this.pool);
  final Directory root;
  final Directory app;
  final _ConfigurationBundleIO io;
  final _NoPoolIO pool;
  late ModelLibrary library;
  late LlamaEngine cpp;
  late OmlxEngine engine;
  late EngineCatalog catalog;
  late String id;

  static Future<_OmlxConfigurationFixture> create() async {
    final root = await Directory.systemTemp.createTemp('gmd-omlx-config-');
    final app = Directory('${root.path}/foreign.app');
    for (final name in [
      'Contents/Info.plist',
      'Contents/MacOS/omlx-cli',
      'Contents/Resources/Python/cpython-3.11/bin/python3',
      'Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/sitecustomize.py',
      'Contents/Resources/omlx/__init__.py',
    ]) {
      final file = File('${app.path}/$name');
      await file.parent.create(recursive: true);
      await file.writeAsString('fixture-only $name');
    }
    final fixture = _OmlxConfigurationFixture(
      root,
      app,
      _ConfigurationBundleIO(),
      _NoPoolIO(),
    );
    fixture.open();
    try {
      fixture.id = (await fixture.catalog.link(app.path)).id;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
    return fixture;
  }

  void open() {
    library = ModelLibrary();
    cpp = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/cpp'),
    );
    engine = OmlxEngine(
      installationDirectory: Directory('${root.path}/owned'),
      io: io,
      poolIo: pool,
    );
    catalog = EngineCatalog(
      library: library,
      officialEngine: cpp,
      omlxEngine: engine,
      useRegistry: ModelUseRegistry(library),
      registryFile: File('${root.path}/engines.json'),
    );
  }

  Future<void> reopen({bool refresh = true}) async {
    await catalog.shutdown();
    catalog.close();
    cpp.close();
    library.close();
    open();
    if (refresh) await catalog.refresh();
    final models = Directory('${root.path}/models');
    if (await models.exists()) {
      await library.scan(models, verifyFiles: true);
    }
  }

  Future<void> close() async {
    await catalog.shutdown();
    catalog.close();
    cpp.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _ConfigurationBundleIO implements OmlxProcessIO {
  _ConfigurationBundleIO();
  final calls = <(String, List<String>)>[];
  String version = '0.7.0';
  Object? helpFailure;
  int helpExit = 0;
  final helpByApp = <String, String>{};
  Completer<void>? helpStarted;
  Completer<void>? releaseHelp;
  Future<void> Function()? afterHelp;
  bool builderAfterProbe = false;
  bool builderPresent = false;
  String team = 'PSK5Q5T46L';
  String help = '''usage: cli.py serve [options]
options:
  --model-dir MODEL_DIR  model pool directory
  --host HOST           listen address
  --port PORT           listen port
  --base-path BASE_PATH  private data directory
  --max-concurrent-requests COUNT
                        max requests for this current CLI
  --memory-guard {off,safe,balanced,aggressive}
                        memory guard tier
  --hot-cache-max-size SIZE
                        hot cache bytes
  --no-hf-cache         disable HF discovery
''';
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? input,
  }) async {
    calls.add((executable, List.of(arguments)));
    if (executable == '/usr/bin/id') return ProcessResult(1, 0, '501\n', '');
    if (executable == '/usr/bin/stat') {
      if (arguments.last.startsWith('/Users/cryingneko')) {
        return builderPresent
            ? ProcessResult(1, 0, '501:20:0700:Directory', '')
            : ProcessResult(1, 1, '', 'No such file or directory');
      }
      return ProcessResult(
        1,
        0,
        List.filled(arguments.length - 2, '501:20:0700:Directory').join('\n'),
        '',
      );
    }
    if (executable == '/bin/ls') {
      return ProcessResult(
        1,
        0,
        List.filled(
          arguments.length - 1,
          'drwx------ owner group path',
        ).join('\n'),
        '',
      );
    }
    if (executable == '/bin/chmod') return ProcessResult(1, 0, '', '');
    if (executable == '/usr/bin/codesign') {
      return ProcessResult(
        1,
        0,
        '',
        'Identifier=app.omlx\nTeamIdentifier=$team\n',
      );
    }
    if (executable == '/usr/sbin/spctl') {
      return ProcessResult(1, 0, '', 'accepted');
    }
    if (executable == '/usr/bin/plutil') {
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'CFBundleIdentifier': 'app.omlx',
          'CFBundleShortVersionString': '0.7.0',
          'CFBundleVersion': '2987',
        }),
        '',
      );
    }
    if (executable.endsWith('/omlx-cli')) {
      expect(workingDirectory, isNotNull);
      expect(environment['HOME'], workingDirectory);
      expect(environment['TMPDIR'], workingDirectory);
      if (arguments.join(' ') == 'serve --help') {
        expect(timeout, const Duration(seconds: 10));
        if (helpFailure != null) throw helpFailure!;
        if (helpStarted != null && !helpStarted!.isCompleted) {
          helpStarted!.complete();
        }
        await releaseHelp?.future;
        await afterHelp?.call();
        final appPath = executable.substring(
          0,
          executable.indexOf('/Contents/'),
        );
        return ProcessResult(1, helpExit, helpByApp[appPath] ?? help, '');
      }
      expect(arguments, ['--version']);
      return ProcessResult(1, 0, '$version\n', '');
    }
    if (executable.endsWith('/python3')) {
      if (builderAfterProbe) builderPresent = true;
      final app = Directory(
        executable.substring(0, executable.indexOf('/Contents/')),
      );
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'python': '3.11.10',
          'architecture': 'arm64',
          'prefix': '${app.path}/Contents/Resources/Python/cpython-3.11',
          'paths': [app.path, OmlxEngine.builderPath, workingDirectory],
          'origins': ['${app.path}/Contents/Resources/omlx/__init__.py'],
          'versions': {
            'omlx': '0.7.0',
            'mlx': '0.32.2',
            'mlx-lm': '0.31.4.dev132+g94cdcae13',
            'fastapi': '0.142.2',
            'transformers': '5.17.0',
          },
          'gpu': [
            [19.0, 22.0],
            [43.0, 50.0],
          ],
        }),
        '',
      );
    }
    throw StateError('Unexpected original native check $executable');
  }

  @override
  Future<void> download(Uri url, File destination) =>
      throw StateError('No downloads');
}

class _NoPoolIO implements OmlxPoolIO {
  int starts = 0;
  @override
  Future<OmlxPoolChild> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    starts++;
    throw StateError('Configuration must not start a pool');
  }
}
