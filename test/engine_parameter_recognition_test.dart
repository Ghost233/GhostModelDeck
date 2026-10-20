import 'fixtures/parameter_editor_navigation.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_launch_editor.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';
import 'fixtures/test_environment.dart';

void main() {
  test('llama native underscore options keep credentials private and model sources controlled', () async {
    final rules = EngineParameterRecognition.fromHelp(
      '$_currentHelp\n--api-key KEY  engine authentication key\n',
      family: EngineFamily.llamaCpp,
      version: 'b11457 native spelling contract',
    );
    const key = 'effective-underscore-secret';
    const raw =
        '--api_key "$key" --model_draft /unmanaged-draft '
        '--spec_draft_model /another-draft --docker_repo remote/model '
        '--model_url https://unmanaged.example/model --models_dir /unmanaged-target';
    final configuration = EngineLaunchConfiguration(
      formValues: {'--api-key': 'preserved-form-secret'},
      argumentText: raw,
    );
    final command = configuration.command(
      executable: testPythonExecutable,
      modelPath: '/selected-target',
      executableArguments: [
        '-P',
        '-c',
        'import json,sys; print(json.dumps(sys.argv[1:]))',
      ],
      recognition: rules,
    );
    expect(command.overriddenForm, contains('--api-key'));
    expect(command.arguments, isNot(contains('preserved-form-secret')));
    expect(command.displayText, isNot(contains(key)));
    expect(command.notices.join(' '), isNot(contains(key)));
    final native = await NativeEngineProcessIO().run(
      command.executable,
      command.arguments,
      timeout: const Duration(seconds: 5),
    );
    expect(native.exitCode, 0);
    final argv = (jsonDecode(native.stdout) as List).cast<String>();
    expect(argv, containsAllInOrder(['--api_key', key]));
    expect(argv, containsAllInOrder(['--model', '/selected-target']));
    expect(argv.join(' '), isNot(contains('unmanaged')));
    expect(argv.join(' '), isNot(contains('another-draft')));
    expect(argv.join(' '), isNot(contains('remote/model')));
    expect(configuration.argumentText, raw);
  });
  test('Splash abbreviated key stays secret while native argv keeps its exact value', () async {
    final rules = EngineParameterRecognition.fromHelp(
      '--api-key KEY  native authentication key\n',
      family: EngineFamily.splash,
      version: 'local CLI contract',
    );
    const key = 'abbreviated-secret';
    final command =
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: const {},
          argumentText: '--api-k="$key" --future="$key"',
        ).command(
          executable: testPythonExecutable,
          modelPath: '/assembly',
          executableArguments: [
            '-P',
            '-c',
            'import json,sys; print(json.dumps(sys.argv[1:]))',
          ],
          recognition: rules,
        );
    expect(command.displayText, isNot(contains(key)));
    expect(command.displayText, contains('[redacted]'));
    expect(command.notices.join(' '), isNot(contains(key)));
    final native = await NativeEngineProcessIO().run(
      command.executable,
      command.arguments,
      timeout: const Duration(seconds: 5),
    );
    expect(native.exitCode, 0);
    expect(
      jsonDecode(native.stdout),
      containsAllInOrder(['--api-k=$key', '--future=$key']),
    );
  });
  test('typed Splash flags and lists survive configuration restore and text precedence', () {
    final configuration = EngineLaunchConfiguration.fromJson({
      'family': 'splash',
      'formValues': {
        '--persistent-cache': 'true',
        '--disable-ane': 'false',
        '--allowed-host': jsonEncode(['localhost', 'desktop.local']),
        '--max-context': '32768',
        '--fast-topk': 'on',
      },
      'argumentText': '--max-context 4K --fast-topk off --model /unmanaged',
    });
    final restored = EngineLaunchConfiguration.fromJson(configuration.toJson());
    final command = restored.command(
      executable: '/splash',
      modelPath: '/model',
    );
    expect(command.arguments, contains('--persistent-cache'));
    expect(command.arguments, isNot(contains('--disable-ane')));
    expect(
      command.arguments,
      containsAllInOrder([
        '--allowed-host',
        'localhost',
        '--allowed-host',
        'desktop.local',
      ]),
    );
    expect(
      command.arguments,
      containsAllInOrder(['--max-context', '4K', '--fast-topk', 'off']),
    );
    expect(command.arguments, isNot(contains('32768')));
    expect(command.arguments, isNot(contains('/unmanaged')));
    expect(restored.formValues, configuration.formValues);
  });

  test('Splash unit hints remain soft and saved malformed text fails before ProcessIO', () async {
    final configuration = EngineLaunchConfiguration.fromJson({
      'family': 'splash',
      'formValues': {
        '--max-context': 'auto',
        '--max-memory': '8GiB',
        '--kv-format': 'bf16',
        '--queue-size': '+2',
      },
    });
    final valid = configuration.command(
      executable: '/python',
      modelPath: '/assembly',
    );
    expect(
      valid.notices.where(
        (notice) => notice.contains('通常') || notice.contains('缺少值'),
      ),
      isEmpty,
    );
    final invalid = EngineLaunchConfiguration(
      family: configuration.family,
      argumentText: '--max-context 3M --max-memory 4.5G --kv-format --queue-size -1 --future="x y"',
    ).command(executable: '/python', modelPath: '/assembly');
    expect(
      invalid.arguments,
      containsAllInOrder([
        '--max-context',
        '3M',
        '--max-memory',
        '4.5G',
        '--kv-format',
        '--queue-size',
        '-1',
        '--future=x y',
      ]),
    );
    expect(invalid.notices, contains(contains('--max-context')));
    expect(invalid.notices, contains(contains('--max-memory')));
    expect(invalid.notices, contains(contains('--kv-format 缺少值')));
    expect(invalid.notices, contains(contains('--queue-size')));
    final directory = await Directory.systemTemp.createTemp('gmd-splash-lex-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = File('${directory.path}/spawned');
    const brokenText = '--max-context "unfinished';
    final file = await File('${directory.path}/configuration.json')
        .writeAsString(
          jsonEncode({
            'family': 'splash',
            'formValues': <String, String>{},
            'argumentText': brokenText,
          }),
        );
    final saved = EngineLaunchConfiguration.fromJson(
      jsonDecode(await file.readAsString()),
    );
    expect(saved.argumentText, brokenText);
    Future<void> launch() async {
      final command = saved.command(
        executable: testPythonExecutable,
        modelPath: '/assembly',
        alias: 'bound',
        port: 8123,
        executableArguments: [
          '-P',
          '-c',
          'from pathlib import Path; Path(${jsonEncode(marker.path)}).write_text("spawned")',
          '/assembly',
        ],
        managedArguments: {
          '--model': 'Owner/Bound',
          '--tokenizer': '/tokenizer',
          '--binary': '/native',
        },
      );
      await NativeEngineProcessIO().run(
        command.executable,
        command.arguments,
        timeout: const Duration(seconds: 5),
      );
    }

    await expectLater(launch(), throwsA(isA<LaunchArgumentTextException>()));
    expect(await marker.exists(), isFalse);
    expect(
      (jsonDecode(await file.readAsString()) as Map)['argumentText'],
      brokenText,
    );
  });
  test('Splash managed bindings survive native argparse abbreviations and invalid positional text is refused', () async {
    const parser = '''import argparse,json
p=argparse.ArgumentParser()
p.add_argument("assembly")
for name in ("model","tokenizer","binary","host","port"):
    p.add_argument("--"+name, required=True)
p.add_argument("--served-model-name", action="append")
print(json.dumps(vars(p.parse_args())))
''';
    final EngineProcessIO io = NativeEngineProcessIO();
    final family = EngineLaunchConfiguration.fromJson({
      'family': 'splash',
      'formValues': <String, String>{},
    }).family;
    for (final (text, rejected) in [
      (
        '--mod Other/Target --tok /other-tokenizer --bin /other-native --ho 0.0.0.0 --por=80 --served other --served-model-name another',
        false,
      ),
      ('-- Other/Target --served-model-name other', true),
      ('/other-assembly', true),
    ]) {
      final command =
          EngineLaunchConfiguration(family: family, argumentText: text).command(
            executable: testPythonExecutable,
            modelPath: '/unused',
            alias: 'gmd-bound',
            port: 8123,
            executableArguments: ['-P', '-c', parser, '/verified assembly'],
            managedArguments: {
              '--model': 'Owner/Bound',
              '--tokenizer': '/verified tokenizer',
              '--binary': '/verified native',
            },
          );
      final result = await io.run(
        command.executable,
        command.arguments,
        timeout: const Duration(seconds: 5),
      );
      if (rejected) {
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('error:'));
      } else {
        expect(result.exitCode, 0);
        expect(jsonDecode(result.stdout), {
          'assembly': '/verified assembly',
          'model': 'Owner/Bound',
          'tokenizer': '/verified tokenizer',
          'binary': '/verified native',
          'host': '127.0.0.1',
          'port': '8123',
          'served_model_name': ['gmd-bound'],
        });
      }
    }
  });
  test('Splash help and supplied Python prefix share the actual ProcessIO argument snapshot', () async {
    const help = '''options:
  -h, --help  display help
  --model OWNER/REPO  target identity
  --tokenizer DIRECTORY  local tokenizer
  --binary FILE  native program
  --host HOST  listener
  --port PORT  listener port
  --served-model-name NAME  public alias
  --max-context, --context-tokens TOKENS  current context option
  --max-memory SIZE  current memory option
  --kv-format FORMAT  current KV option
  --queue-size REQUESTS  current queue option
  --new-label VALUE  newly observed value option
''';
    final EngineProcessIO io = NativeEngineProcessIO();
    final observed = await io.run(testPythonExecutable, [
      '-P',
      '-c',
      'import sys; sys.stdout.write(${jsonEncode(help)})',
    ], timeout: const Duration(seconds: 5));
    expect(observed.exitCode, 0);
    final rules = EngineParameterRecognition.fromHelp(
      observed.stdout,
      family: EngineFamily.splash,
      version: 'process-boundary fixture',
      executablePath: testPythonExecutable,
      contentFingerprint: 'process-boundary fixture',
    );
    expect(rules.status, EngineHelpStatus.available);
    expect(rules.canonicalName('--context-tokens'), '--max-context');
    const raw =
        '--context-tokens 64K --new-label "--tokenizer" --new-label "" --future="two words" --mod Evil/Model --served "evil alias"';
    final configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {
        '--max-context': '16K',
        '--max-memory': 'auto',
        '--kv-format': 'bf16',
        '--queue-size': '2',
      },
      argumentText: raw,
    );
    const probe = 'import json,sys; print(json.dumps(sys.argv[1:]))';
    final prefix = ['-P', '-c', probe, '/local assembly'];
    final binding = {
      '--model': 'Owner/Bound',
      '--tokenizer': '/local tokenizer',
      '--binary': '/local native/splash',
    };
    final command = configuration.command(
      executable: testPythonExecutable,
      modelPath: '/legacy modelPath is not Splash API identity',
      alias: 'gmd-bound',
      port: 8123,
      recognition: rules,
      executableArguments: prefix,
      managedArguments: binding,
    );
    prefix.add('unexpected mutation');
    binding['--model'] = 'Unexpected/Mutation';
    expect(command.provisional, isFalse);
    expect(command.overriddenForm, {'--max-context'});
    expect(command.arguments.take(4), ['-P', '-c', probe, '/local assembly']);
    final executed = await io.run(
      command.executable,
      command.arguments,
      timeout: const Duration(seconds: 5),
    );
    expect(executed.exitCode, 0);
    expect(jsonDecode(executed.stdout), [
      '/local assembly',
      '--max-memory',
      'auto',
      '--kv-format',
      'bf16',
      '--queue-size',
      '2',
      '--context-tokens',
      '64K',
      '--new-label',
      '--tokenizer',
      '--new-label',
      '',
      '--future=two words',
      '--model',
      'Owner/Bound',
      '--tokenizer',
      '/local tokenizer',
      '--binary',
      '/local native/splash',
      '--host',
      '127.0.0.1',
      '--port',
      '8123',
      '--served-model-name',
      'gmd-bound',
    ]);
    expect(command.notices, contains(contains('--model 由软件管理')));
    expect(command.displayText, contains("'/local assembly'"));
    expect(configuration.argumentText, raw);
    final restoredForm =
        EngineLaunchConfiguration(
          family: configuration.family,
          formValues: configuration.formValues,
        ).command(
          executable: command.executable,
          modelPath: '/assembly',
          alias: 'gmd-bound',
          port: 8123,
          executableArguments: ['-P', '-c', probe, '/assembly'],
          managedArguments: {
            '--model': 'Owner/Bound',
            '--tokenizer': '/tokenizer',
            '--binary': '/native',
          },
        );
    expect(restoredForm.overriddenForm, isEmpty);
    expect(
      restoredForm.arguments,
      containsAllInOrder(['--max-context', '16K']),
    );
  });
  test('Splash text overrides forms softly and cannot replace software managed options or abbreviations', () {
    const text =
        '--tokenizer "/raw tokenizer" --binary="/raw native" --mod Wrong/Model --alias other --por=80 --host 0.0.0.0 --served-model-n "other alias" --max-context 64K --max-memory 4.5G --kv-format wrong --queue-size wrong --future "two words"';
    final configuration = EngineLaunchConfiguration.fromJson({
      'family': 'splash',
      'formValues': {
        '--max-context': '16K',
        '--max-memory': '28G',
        '--kv-format': 'int8',
        '--queue-size': '8',
      },
      'argumentText': text,
    });
    final command = configuration.command(
      executable: '/verified Python/python',
      modelPath: '/assembly',
      alias: 'gmd-bound',
      port: 8123,
    );
    for (final rejected in [
      '/raw tokenizer',
      '/raw native',
      'Wrong/Model',
      'other',
      '80',
      '0.0.0.0',
      'other alias',
    ]) {
      expect(command.arguments, isNot(contains(rejected)), reason: rejected);
    }
    expect(
      command.arguments,
      containsAllInOrder([
        '--max-context',
        '64K',
        '--max-memory',
        '4.5G',
        '--kv-format',
        'wrong',
        '--queue-size',
        'wrong',
        '--future',
        'two words',
      ]),
    );
    expect(
      command.arguments,
      containsAllInOrder([
        '--host',
        '127.0.0.1',
        '--port',
        '8123',
        '--served-model-name',
        'gmd-bound',
      ]),
    );
    expect(command.overriddenForm, {
      '--max-context',
      '--max-memory',
      '--kv-format',
      '--queue-size',
    });
    expect(command.notices, contains(contains('--max-memory')));
    expect(command.notices, contains(contains('--kv-format')));
    expect(command.notices, contains(contains('--queue-size')));
    expect(command.notices, isNot(contains(contains('--max-context 通常'))));
    expect(command.isConfigurationOnly, isFalse);
    expect(
      command.provisional,
      isTrue,
      reason: 'no model binding or software Python prefix has been supplied',
    );
    expect(configuration.argumentText, text);
    expect(configuration.formValues['--max-context'], '16K');
  });
  test('Splash saved configuration has its own empty form and preserves original text', () async {
    final directory = await Directory.systemTemp.createTemp(
      'gmd-splash-config-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const originalText = " --future='two words'\n";
    final file = await File('${directory.path}/configuration.json')
        .writeAsString(
          jsonEncode({
            'family': 'splash',
            'formValues': <String, String>{},
            'argumentText': originalText,
          }),
        );
    final loaded = EngineLaunchConfiguration.fromJson(
      jsonDecode(await file.readAsString()),
    );
    expect(loaded.family.name, 'splash');
    expect(
      EngineLaunchConfiguration(family: loaded.family).formValues,
      isEmpty,
    );
    expect(
      EngineLaunchConfiguration.labelsFor(loaded.family).keys,
      containsAll([
        '--max-context',
        '--max-memory',
        '--kv-format',
        '--queue-size',
        '--disable-ane',
        '--compact-draft-ranking',
        '--fast-topk',
      ]),
    );
    expect(loaded.argumentText, originalText);
    await file.writeAsString(jsonEncode(loaded.toJson()));
    final reopened = EngineLaunchConfiguration.fromJson(
      jsonDecode(await file.readAsString()),
    );
    expect(reopened.toJson(), {
      'family': 'splash',
      'formValues': <String, String>{},
      'argumentText': originalText,
    });
    final legacy = EngineLaunchConfiguration.fromJson({
      'formValues': {'--ctx-size': '2048'},
    });
    expect(legacy.family.name, 'llamaCpp');
    expect(legacy.formValues['--ctx-size'], '2048');
  });
  for (final newAlias in [false, true]) {
    test(
      'managed partial help preserves ${newAlias ? 'new alias attached to retained' : 'single retained alias'} context anchor',
      () async {
        final fixture = await _RecognitionFixture.create(managed: true);
        addTearDown(fixture.close);
        final name = newAlias ? '--current-ctx' : '--context-tokens';
        final text = '$name 1024';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: text),
        );
        fixture.io.help =
            '$_requiredFlatHelp\n--context-tokens${newAlias ? ', --current-ctx' : ''} N      partial context description\n';
        await fixture.catalog.readParameters(fixture.id);
        final preview = await fixture.engine.previewLaunch(fixture.asset.id);
        expect(preview.overriddenForm, contains('--ctx-size'));
        expect(preview.arguments, isNot(contains('--ctx-size')));
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          text,
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final instance = await fixture.engine.start(fixture.asset.id);
          expect(fixture.io.started.single.skip(8), preview.arguments.skip(8));
          expect(
            fixture.io.started.single.sublist(
              fixture.io.started.single.length - 2,
            ),
            [name, '1024'],
          );
          await fixture.engine.stop(instance.id);
        }, _NetworkBoundary());
      },
    );
  }
  test('retained anchors are not guessed across conflicting or opposite help groups', () async {
    final fixture = await _RecognitionFixture.create(managed: true);
    addTearDown(fixture.close);
    for (final (row, text, overridden) in [
      (
        '--context-tokens, --parallel, --unconfirmed N',
        '--context-tokens 1024 --unconfirmed 2',
        {'--ctx-size'},
      ),
      ('--context-tokens, --no-context N', '--no-context 1024', <String>{}),
    ]) {
      fixture.io.help = '$_requiredFlatHelp\n$row      guarded aliases\n';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      await fixture.catalog.readParameters(fixture.id);
      final preview = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(preview.overriddenForm, overridden);
      expect(preview.arguments, containsAllInOrder(['--parallel', '1']));
      await HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(fixture.io.started.last.skip(8), preview.arguments.skip(8));
        await fixture.engine.stop(instance.id);
      }, _NetworkBoundary());
    }
  });
  test('another managed identity does not inherit a previous provider context anchor', () async {
    final previous = await _RecognitionFixture.create(managed: true);
    addTearDown(previous.close);
    final current = await _RecognitionFixture.create(
      managed: true,
      initialHelp:
          '$_requiredFlatHelp\n--context-tokens, --current-ctx N      new provider help\n',
    );
    addTearDown(current.close);
    expect(
      current.engine.parameterRecognition.executablePath,
      isNot(previous.engine.parameterRecognition.executablePath),
    );
    await current.catalog.saveLaunchDefaults(
      current.id,
      EngineLaunchConfiguration(argumentText: '--current-ctx 1024'),
    );
    await current.catalog.refresh();
    final preview = await current.engine.previewLaunch(current.asset.id);
    expect(preview.overriddenForm, isEmpty);
    expect(preview.arguments, containsAllInOrder(['--ctx-size', '4096']));
    await HttpOverrides.runWithHttpOverrides(() async {
      final instance = await current.engine.start(current.asset.id);
      expect(current.io.started.single.skip(8), preview.arguments.skip(8));
      await current.engine.stop(instance.id);
    }, _NetworkBoundary());
  });
  test('linked standard timestamp changes retain typed identity and saved startup', () async {
    final fixture = await _RecognitionFixture.create(
      linkedVersion:
          '0.00.000.141 I srv llama_server: initializing ...\n$_standardVersion',
    );
    addTearDown(fixture.close);
    const text = '--context-tokens 1024';
    await fixture.catalog.saveLaunchDefaults(
      fixture.id,
      EngineLaunchConfiguration(argumentText: text),
    );
    final fingerprint = fixture.engine.binarySha256;
    fixture.io.versionOutput =
        '0.00.000.090 I srv llama_server: initializing ...\n$_standardVersion';
    await fixture.catalog.readParameters(fixture.id);
    expect(
      fixture.engine.state.installation,
      LlamaInstallationStatus.installed,
    );
    expect(fixture.engine.binaryVersion!.build, 11146);
    expect(fixture.engine.binarySha256, fingerprint);
    expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
    final preview = await fixture.engine.previewLaunch(fixture.asset.id);
    expect(preview.overriddenForm, contains('--ctx-size'));
    await HttpOverrides.runWithHttpOverrides(() async {
      final instance = await fixture.engine.start(fixture.asset.id);
      expect(instance.status, LlamaInstanceStatus.ready);
      expect(fixture.io.started.single.skip(8), preview.arguments.skip(8));
      await fixture.engine.stop(instance.id);
    }, _NetworkBoundary());
  });
  for (final change in [
    'semantic',
    'build',
    'commit',
    'platform',
    'fingerprint',
  ]) {
    test(
      'explicit parameter observation records $change metadata without rejecting saved parameters',
      () async {
        final fixture = await _RecognitionFixture.create(
          linkedVersion: _standardVersion,
        );
        addTearDown(fixture.close);
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: '--context-tokens 1024'),
        );
        if (change == 'fingerprint') {
          await File(fixture.engine.executablePath!)
              .writeAsString('changed content');
        } else {
          fixture.io.versionOutput = switch (change) {
            'semantic' => _standardVersion.replaceFirst('0.5.0-dev', '0.5.0'),
            'build' => _standardVersion.replaceFirst('11146', '11147'),
            'commit' => _standardVersion.replaceFirst('7fe450e19', '000000000'),
            _ => _standardVersion.replaceFirst('Darwin arm64', 'Darwin x86_64'),
          };
        }
        await fixture.catalog.readParameters(fixture.id);
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          '--context-tokens 1024',
        );
        expect(fixture.io.started, isEmpty);

        expect(
          fixture.engine.state.installation,
          LlamaInstallationStatus.installed,
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isTrue,
        );
        expect(
          fixture.engine.linkedInstallation!.version,
          fixture.io.versionOutput.trim(),
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final run = await fixture.engine.start(fixture.asset.id);
          expect(run.status, LlamaInstanceStatus.ready);
          expect(
            run.launchCommand!.arguments,
            containsAllInOrder(['--context-tokens', '1024']),
          );
          expect(run.launchCommand!.arguments, isNot(contains('--ctx-size')));
          await fixture.engine.stop(run.id);
        }, _NetworkBoundary());
      },
    );
  }
  test(
    'opaque linked versions retain the current verified raw observation',
    () async {
      const opaque = 'version: vendor opaque\nbuilt for Darwin arm64';
      final fixture = await _RecognitionFixture.create(linkedVersion: opaque);
      addTearDown(fixture.close);
      await fixture.catalog.readParameters(fixture.id);
      expect(
        fixture.engine.state.installation,
        LlamaInstallationStatus.installed,
      );
      fixture.io.versionOutput = 'diagnostic changed\n$opaque';
      await fixture.catalog.readParameters(fixture.id);
      expect(
        fixture.engine.state.installation,
        LlamaInstallationStatus.installed,
      );
      expect(
        fixture.engine.linkedInstallation!.version,
        fixture.io.versionOutput,
      );
      expect(fixture.io.started, isEmpty);
    },
  );
  testWidgets(
    'changed executable can read help and save configuration without content verification',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _RecognitionFixture.create(managed: true),
      ))!;
      addTearDown(() => tester.runAsync(fixture.close));
      await tester.runAsync(() async {
        await File(fixture.engine.executablePath!)
            .writeAsString('unverified content');
        await fixture.catalog.readParameters(fixture.id);
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
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final action = find.byKey(ValueKey('engine-parameters:${fixture.id}'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('当前帮助规则不可用'), findsNothing);
      expect(
        fixture.engine.parameterRecognition.recognizes('--context-tokens'),
        isTrue,
      );
      await selectParameterGroup(tester, '参数文本与命令');
      expect(find.byTooltip('复制命令'), findsOneWidget);
      await selectParameterGroup(tester, '参数文本与命令');
      final input = find.byKey(const Key('engine-argument-text'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '--future new');
      await tester.pump();
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
        '--future new',
      );
      expect(fixture.io.started, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'shutdown drains accepted help IO without accepting its late rules',
    () async {
      final fixture = await _RecognitionFixture.create(managed: true);
      addTearDown(fixture.close);
      const text = '--context-tokens 2048';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final fingerprint =
          fixture.engine.parameterRecognition.contentFingerprint;
      fixture.io.help = _currentHelp.replaceAll(
        '--context-tokens',
        '--late-context',
      );
      fixture.io.helpRequested = Completer<void>();
      fixture.io.helpRelease = Completer<void>();
      addTearDown(() {
        final release = fixture.io.helpRelease!;
        if (!release.isCompleted) release.complete();
      });
      final refresh = fixture.catalog.readParameters(fixture.id);
      await fixture.io.helpRequested!.future.timeout(
        const Duration(seconds: 5),
      );
      var drained = false;
      final shutdown = fixture.engine.shutdown().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      fixture.io.helpRelease!.complete();
      await refresh;
      await shutdown;
      expect(
        fixture.engine.parameterRecognition.recognizes('--late-context'),
        isFalse,
      );
      expect(
        fixture.engine.parameterRecognition.canonicalName('--context-tokens'),
        '--ctx-size',
      );
      expect(
        fixture.engine.parameterRecognition.contentFingerprint,
        fingerprint,
      );
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
      expect(fixture.io.started, isEmpty);
      await expectLater(
        fixture.engine.start(fixture.asset.id),
        throwsA(isA<StateError>()),
      );
    },
  );
  for (final managed in [false, true]) {
    test(
      '${managed ? 'managed' : 'linked'} partial help preserves same-content usable rules through refresh and startup',
      () async {
        final fixture = await _RecognitionFixture.create(managed: managed);
        addTearDown(fixture.close);
        const text = '--extra-path "--model" --context-tokens 1024';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: text),
        );
        final before = await fixture.engine.previewLaunch(fixture.asset.id);
        final originalForm = fixture.catalog
            .launchDefaultsFor(fixture.id)
            .formValues;
        for (final help in [
          '$_requiredFlatHelp\n-c, --ctx-size N      current context description\n',
          _requiredFlatHelp,
        ]) {
          fixture.io.help = help;
          await fixture.catalog.readParameters(fixture.id);
          expect(
            fixture.engine.state.installation,
            LlamaInstallationStatus.installed,
          );
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          expect(preview.arguments, before.arguments);
          expect(
            preview.notices.any(
              (notice) =>
                  notice.contains('帮助') &&
                  (notice.contains('部分') || notice.contains('无法解析')),
            ),
            isTrue,
          );
          expect(
            fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
            text,
          );
          expect(
            fixture.catalog.launchDefaultsFor(fixture.id).formValues,
            originalForm,
          );
          await HttpOverrides.runWithHttpOverrides(() async {
            final instance = await fixture.engine.start(fixture.asset.id);
            expect(instance.status, LlamaInstanceStatus.ready);
            expect(fixture.io.started.last.skip(8), before.arguments.skip(8));
            await fixture.engine.stop(instance.id);
          }, _NetworkBoundary());
        }
      },
    );
  }
  for (final managed in [false, true]) {
    test(
      '${managed ? 'managed content change' : 'linked optional help failure'} permits actual startup and preserves configuration',
      () async {
        final fixture = await _RecognitionFixture.create(managed: managed);
        addTearDown(fixture.close);
        const text = '--context-tokens 2048';
        await fixture.catalog.saveLaunchDefaults(
          fixture.id,
          EngineLaunchConfiguration(argumentText: text),
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isTrue,
        );
        if (managed) {
          await File(fixture.engine.executablePath!)
              .writeAsString('different actual content');
        } else {
          fixture.io.helpExit = 1;
        }
        await fixture.catalog.readParameters(fixture.id);
        expect(
          fixture.engine.state.installation,
          LlamaInstallationStatus.installed,
        );
        expect(
          fixture.engine.parameterRecognition.recognizes('--context-tokens'),
          isTrue,
        );
        expect(fixture.engine.parameterRecognition.contentFingerprint, isNull);
        expect(fixture.engine.parameterRecognition.version, isNotNull);
        if (!managed) {
          expect(fixture.engine.parameterRecognition.notices, isNotEmpty);
        }
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          text,
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          final instance = await fixture.engine.start(fixture.asset.id);
          expect(instance.status, LlamaInstanceStatus.ready);
          expect(fixture.io.started.single, contains('--context-tokens'));
          await fixture.engine.stop(instance.id);
        }, _NetworkBoundary());
      },
    );
  }
  test(
    'managed optional help failure preserves current rules and saved startup',
    () async {
      final fixture = await _RecognitionFixture.create(managed: true);
      addTearDown(fixture.close);
      const text = '--context-tokens 1536 --brand-new "value space"';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final before = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(before.overriddenForm, contains('--ctx-size'));
      fixture.io.helpFailure = TimeoutException('controlled help deadline');
      fixture.io.versionDiagnostic = 'same content, changed diagnostic text\n';
      await fixture.catalog.readParameters(fixture.id);
      expect(
        fixture.engine.state.installation,
        LlamaInstallationStatus.installed,
      );
      expect(
        fixture.engine.parameterRecognition.status,
        EngineHelpStatus.unavailable,
      );
      expect(
        fixture.engine.parameterRecognition.version,
        fixture.engine.observedVersion,
      );
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
      final after = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(after.arguments, before.arguments);
      expect(
        after.notices.any(
          (notice) => notice.contains('帮助') && notice.contains('失败'),
        ),
        isTrue,
      );
      expect(
        after.notices.any((notice) => notice.contains('未知参数 --brand-new')),
        isTrue,
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(instance.status, LlamaInstanceStatus.ready);
        expect(fixture.io.started.single.skip(8), after.arguments.skip(8));
        await fixture.engine.stop(instance.id);
      }, _NetworkBoundary());
      expect(fixture.io.helpBudgets, isNotEmpty);
      expect(
        fixture.io.helpBudgets.every(
          (budget) =>
              budget > Duration.zero && budget <= const Duration(seconds: 10),
        ),
        isTrue,
      );
    },
  );
  test(
    'help-known option values retain quoted option names at startup',
    () async {
      final fixture = await _RecognitionFixture.create();
      addTearDown(fixture.close);
      await fixture.catalog.readParameters(fixture.id);
      const text =
          '--extra-path "--model" --extra-path "--ctx-size" '
          '--control-vector-layer-range "--alias" "--port"';
      await fixture.catalog.saveLaunchDefaults(
        fixture.id,
        EngineLaunchConfiguration(argumentText: text),
      );
      final preview = await fixture.engine.previewLaunch(fixture.asset.id);
      expect(
        fixture.engine.parameterRecognition.canonicalName('--no-perf'),
        '--no-perf',
      );
      expect(preview.overriddenForm, isEmpty);
      expect(preview.arguments.skip(8), [
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
        '--extra-path',
        '--model',
        '--extra-path',
        '--ctx-size',
        '--control-vector-layer-range',
        '--alias',
        '--port',
      ]);
      await HttpOverrides.runWithHttpOverrides(() async {
        final instance = await fixture.engine.start(fixture.asset.id);
        expect(fixture.io.started.single.skip(8), preview.arguments.skip(8));
        expect(instance.launchCommand!.arguments, fixture.io.started.single);
        await fixture.engine.stop(instance.id);
      }, _NetworkBoundary());
      expect(fixture.catalog.launchDefaultsFor(fixture.id).argumentText, text);
    },
  );
  for (final (positive, negative, source) in [
    ('--perf', '--no-perf', '  --perf\n'),
    ('--kv-offload', '--no-kv-offload', '  -nkvo\n'),
  ]) {
    testWidgets(
      'observed $positive switches share one editor and text wins at actual startup',
      (tester) async {
        final fixture = (await tester.runAsync(_RecognitionFixture.create))!;
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
          await fixture.catalog.readParameters(fixture.id);
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final action = find.byKey(
            ValueKey('engine-parameters:${fixture.id}'),
          );
          await tester.ensureVisible(action);
          await tester.tap(action);
          await fixture.catalog.readParameters(fixture.id);
        });
        await tester.pumpAndSettle();
        await selectParameterGroup(tester, '其他引擎参数');
        expect(find.byKey(Key('parameter-choice:$negative')), findsNothing);
        final toggle = find.byKey(Key('parameter-choice:$positive'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        await selectParameterGroup(tester, '参数文本与命令');
        EngineLaunchCommand preview() => tester
            .widget<EngineLaunchCommandView>(
              find.byType(EngineLaunchCommandView),
            )
            .command;
        expect(preview().arguments, contains(negative));
        expect(preview().arguments, isNot(contains(positive)));
        await tester.enterText(
          find.byKey(const Key('engine-argument-text')),
          source,
        );
        await tester.pump();
        expect(preview().overriddenForm, contains(positive));
        expect(preview().arguments, isNot(contains(negative)));
        await tester.runAsync(() async {
          final saved = fixture.catalog.changes.firstWhere(
            (state) => !state.busy,
          );
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await saved.timeout(const Duration(seconds: 5));
          await tester.pump();
        });
        await tester.pumpAndSettle();
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).formValues[positive],
          'false',
        );
        expect(
          fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
          source,
        );
        expect(fixture.io.started, isEmpty);
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final run = await fixture.engine.start(fixture.asset.id);
            expect(run.status, LlamaInstanceStatus.ready);
            expect(fixture.io.started.single, contains(source.trim()));
            expect(fixture.io.started.single, isNot(contains(negative)));
            await fixture.engine.stop(run.id);
          }, _NetworkBoundary()),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'API keys remain secret in the parameter editor preview and copied command',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _RecognitionFixture.create(
          initialHelp:
              '$_currentHelp\n--api-key KEY  engine authentication key\n',
        ),
      ))!;
      addTearDown(() => tester.runAsync(fixture.close));
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
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
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final action = find.byKey(ValueKey('engine-parameters:${fixture.id}'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '其他引擎参数');
      final keyField = find.byKey(const Key('parameter-text:--api-key'));
      await tester.ensureVisible(keyField);
      const key = 'engine-preview-secret';
      await tester.enterText(keyField, key);
      await tester.pump();
      expect(tester.widget<TextField>(keyField).obscureText, isTrue);
      await selectParameterGroup(tester, '参数文本与命令');
      final preview = tester
          .widget<EngineLaunchCommandView>(find.byType(EngineLaunchCommandView))
          .command;
      expect(preview.arguments, containsAllInOrder(['--api-key', key]));
      expect(preview.displayText, isNot(contains(key)));
      expect(preview.displayText, contains('[redacted]'));
      expect(preview.notices.join(' '), isNot(contains(key)));
      await tester.tap(find.byTooltip('复制命令'));
      await tester.pump();
      expect(clipboard, preview.displayText);
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final run = await fixture.engine.start(fixture.asset.id);
          expect(
            fixture.io.started.single,
            containsAllInOrder(['--api-key', key]),
          );
          expect(run.launchCommand!.displayText, isNot(contains(key)));
          await fixture.engine.stop(run.id);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final initial in <String?>[null, '"unfinished']) {
    testWidgets(
      'observed multi-value loading option repairs $initial and starts with both argv values',
      (tester) async {
        final fixture = (await tester.runAsync(_RecognitionFixture.create))!;
        addTearDown(() => tester.runAsync(fixture.close));
        if (initial != null) {
          await tester.runAsync(
            () => fixture.catalog.saveLaunchDefaults(
              fixture.id,
              EngineLaunchConfiguration(
                formValues: {'--control-vector-layer-range': initial},
              ),
            ),
          );
        }
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
          await fixture.catalog.readParameters(fixture.id);
        });
        await tester.pumpAndSettle();
        Future<void> open() async {
          await tester.runAsync(() async {
            final action = find.byKey(
              ValueKey('engine-parameters:${fixture.id}'),
            );
            await tester.ensureVisible(action);
            await tester.tap(action);
            await fixture.catalog.readParameters(fixture.id);
          });
          await tester.pumpAndSettle();
          await selectParameterGroup(tester, '其他引擎参数');
          await tester.enterText(
            find.byKey(const Key('parameter-search')),
            'control-vector-layer-range',
          );
          await tester.pumpAndSettle();
        }

        await open();
        final start = find.byKey(
          const Key('parameter-number:--control-vector-layer-range:0'),
        );
        final end = find.byKey(
          const Key('parameter-number:--control-vector-layer-range:1'),
        );
        await tester.enterText(start, '13');
        await tester.enterText(end, '7');
        await tester.pump();
        await selectParameterGroup(tester, '参数文本与命令');
        final preview = tester
            .widget<EngineLaunchCommandView>(
              find.byType(EngineLaunchCommandView),
            )
            .command;
        expect(
          preview.arguments,
          containsAllInOrder(['--control-vector-layer-range', '13', '7']),
        );
        await tester.runAsync(() async {
          final saved = fixture.catalog.changes.firstWhere(
            (state) => !state.busy,
          );
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
          await saved.timeout(const Duration(seconds: 5));
          await tester.pump();
        });
        await tester.pumpAndSettle();
        expect(fixture.io.started, isEmpty);
        await open();
        expect(tester.widget<TextField>(start).controller!.text, '13');
        expect(tester.widget<TextField>(end).controller!.text, '7');
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            final run = await fixture.engine.start(fixture.asset.id);
            expect(run.status, LlamaInstanceStatus.ready);
            expect(
              fixture.io.started.single,
              containsAllInOrder(['--control-vector-layer-range', '13', '7']),
            );
            await fixture.engine.stop(run.id);
          }, _NetworkBoundary()),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'native loading choice hints expose selectors and reach startup without CLI text',
    (tester) async {
      const help = '''$_currentHelp
--fit [on|off]  adjust unset arguments to fit in device memory
--cpu-strict <0|1>  strict CPU placement
--load-mode MODE  model loading mode
    - auto: automatic memory mapping
    - none: no special loading mode
    - mmap: map model into memory
    - mlock: lock model memory
    - mmap+mlock: mapping and lock
    - dio: DirectIO if available
--lazy-mode MODE  on-demand tensor reading
    - on: read from disk on demand
    - auto: only large tensors
    - off: keep resident
--rope-scale N  RoPE context scaling factor
''';
      final fixture = (await tester.runAsync(
        () => _RecognitionFixture.create(initialHelp: help),
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
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final action = find.byKey(ValueKey('engine-parameters:${fixture.id}'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '其他引擎参数');
      for (final (name, value) in [
        ('--fit', 'off'),
        ('--cpu-strict', '1'),
        ('--load-mode', 'mmap+mlock'),
        ('--lazy-mode', 'on'),
      ]) {
        await tester.enterText(find.byKey(const Key('parameter-search')), name);
        await tester.pumpAndSettle();
        final selector = find.byKey(Key('parameter-choice:$name'));
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(
                value == 'off'
                    ? '关闭'
                    : value == 'on'
                    ? '开启'
                    : value,
              )
              .last,
        );
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const Key('parameter-search')),
        'rope-scale',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('parameter-number:--rope-scale')),
        '1.5',
      );
      await tester.pump();
      expect(find.text('请输入整数'), findsNothing);
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
        isEmpty,
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          final run = await fixture.engine.start(fixture.asset.id);
          expect(run.status, LlamaInstanceStatus.ready);
          expect(preview.arguments.skip(8), fixture.io.started.single.skip(8));
          expect(
            fixture.io.started.single,
            containsAllInOrder([
              '--fit',
              'off',
              '--cpu-strict',
              '1',
              '--load-mode',
              'mmap+mlock',
              '--lazy-mode',
              'on',
              '--rope-scale',
              '1.5',
            ]),
          );
          await fixture.engine.stop(run.id);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'current linked help aliases keep model sources controlled through actual startup',
    (tester) async {
      final fixture = (await tester.runAsync(_RecognitionFixture.create))!;
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
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final action = find.byKey(ValueKey('engine-parameters:${fixture.id}'));
        await tester.ensureVisible(action);
        await tester.tap(action);
        await fixture.catalog.readParameters(fixture.id);
      });
      await tester.pumpAndSettle();
      await selectParameterGroup(tester, '参数文本与命令');
      final input = find.byKey(const Key('engine-argument-text'));
      await tester.ensureVisible(input);
      const source =
          '--context-tokens 2048 --extra-path "two words" --extra-path=again --no-perf --docker-repo remote/model -dr other/model';
      await tester.enterText(input, source);
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
      await tester.runAsync(() async {
        final saved = fixture.catalog.changes.firstWhere(
          (state) => !state.busy,
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await saved.timeout(const Duration(seconds: 5));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(
        fixture.catalog.launchDefaultsFor(fixture.id).argumentText,
        source,
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final preview = await fixture.engine.previewLaunch(fixture.asset.id);
          expect(preview.arguments, isNot(contains('--ctx-size')));
          expect(preview.overriddenForm, contains('--ctx-size'));
          expect(
            preview.notices.where((notice) => notice.contains('未知参数')),
            isEmpty,
          );
          final instance = await fixture.engine.start(fixture.asset.id);
          expect(instance.status, LlamaInstanceStatus.ready);
          expect(fixture.io.started.single.skip(8), [
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
            '--context-tokens',
            '2048',
            '--extra-path',
            'two words',
            '--extra-path=again',
            '--no-perf',
          ]);
          expect(instance.launchCommand!.arguments, fixture.io.started.single);
          expect(preview.arguments.skip(8), fixture.io.started.single.skip(8));
          await fixture.engine.stop(instance.id);
        }, _NetworkBoundary()),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

const _currentHelp = '''----- common params -----
-m, --model FNAME                      model path to load
-a, --alias STRING                     API model alias
--host HOST                            listen address
--port PORT                            listen port
-c, --ctx-size, --context-tokens N      number of context tokens
                                       current engine context description
-b, --batch-size N                     logical batch size
-ub, --ubatch-size N                    physical batch size
-np, --parallel N                      parallel slots
-ngl, --gpu-layers, --n-gpu-layers N    GPU layer count
-dev, --device DEVICE                  selected device
--extra-path PATH                      additional path for this version
-dr, --docker-repo [<repo>/]<model>[:quant]  model download source
--control-vector-layer-range START END
                                       selected layer range
--perf, --no-perf                      whether to enable performance timings
-kvo, --kv-offload, -nkvo, --no-kv-offload
                                       whether to offload KV cache
''';

const _requiredFlatHelp =
    '--model --alias --host --port --ctx-size --batch-size --ubatch-size '
    '--parallel --n-gpu-layers --device';

const _standardVersion =
    'version: 0.5.0-dev (build 11146, commit 7fe450e19)\nbuilt for Darwin arm64';

class _RecognitionFixture {
  _RecognitionFixture(
    this.root,
    this.library,
    this.official,
    this.catalog,
    this.io,
  );
  final Directory root;
  final ModelLibrary library;
  final LlamaEngine official;
  final EngineCatalog catalog;
  final _RecognitionIO io;
  late String id;
  late LibraryArtifact asset;
  LlamaEngine get engine => catalog.providerFor(id);

  static Future<_RecognitionFixture> create({
    bool managed = false,
    String? linkedVersion,
    String? initialHelp,
  }) async {
    final root = await Directory.systemTemp.createTemp('gmd-recognition-');
    final library = ModelLibrary();
    final use = ModelUseRegistry(library);
    final io = _RecognitionIO();
    if (linkedVersion != null) io.versionOutput = linkedVersion;
    if (initialHelp != null) io.help = initialHelp;
    final data = engineArchive();
    final official = LlamaEngine(
      library: library,
      useRegistry: use,
      io: io,
      installationDirectory: Directory('${root.path}/owned'),
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://fixture.example/engine'),
        sha256: sha256.convert(data).toString(),
        sizeBytes: data.length,
      ),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: official,
      useRegistry: use,
      io: io,
      registryFile: File('${root.path}/engines.json'),
    );
    final fixture = _RecognitionFixture(root, library, official, catalog, io);
    if (managed) {
      final archive = await File('${root.path}/engine.tar.gz')
          .writeAsBytes(data);
      await catalog.installOfficial(verifiedArchive: archive);
      fixture.id = EngineCatalog.officialId;
    } else {
      final binary = await File('${root.path}/external/llama-server')
          .create(recursive: true);
      await binary.writeAsString(
        'external executable at the process I/O boundary',
      );
      expect(
        (await Process.run('/bin/chmod', ['+x', binary.path])).exitCode,
        0,
      );
      fixture.id = (await catalog.link(binary.path)).id;
    }
    await writeDecisionKev(
      Directory('${root.path}/models'),
      ordinaryChat: true,
    );
    fixture.asset = (await library.scan(
      Directory('${root.path}/models'),
      verifyFiles: true,
    )).single;
    return fixture;
  }

  Future<void> close() async {
    await catalog.stopManaged();
    catalog.close();
    official.close();
    library.close();
    await root.delete(recursive: true);
  }
}

class _RecognitionIO implements EngineProcessIO {
  String help = _currentHelp;
  Object? helpFailure;
  String versionDiagnostic = '';
  String versionOutput =
      'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64';
  Completer<void>? helpRequested;
  Completer<void>? helpRelease;
  int helpExit = 0;
  final helpBudgets = <Duration>[];
  final started = <List<String>>[];
  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--version') {
      return EngineCommandResult(0, '$versionDiagnostic$versionOutput', '');
    }
    if (arguments.singleOrNull == '--help') {
      helpBudgets.add(timeout);
      if (helpRequested != null && !helpRequested!.isCompleted) {
        helpRequested!.complete();
        await helpRelease!.future;
      }
      if (helpFailure != null) throw helpFailure!;
      return EngineCommandResult(helpExit, help, '');
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
    started.add(List.of(arguments));
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
      } else {
        await request.drain<void>();
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
      }
      await request.response.close();
    });
    return _RecognitionChild(server);
  }
}

class _RecognitionChild implements EngineChild {
  _RecognitionChild(this.server);
  final HttpServer server;
  final stopped = Completer<int>();
  @override
  int get pid => 42429;
  @override
  Future<int> get exitCode => stopped.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill(ProcessSignal signal) {
    server.close(force: true).then((_) {
      if (!stopped.isCompleted) stopped.complete(0);
    });
    return true;
  }
}

class _NetworkBoundary extends HttpOverrides {}
