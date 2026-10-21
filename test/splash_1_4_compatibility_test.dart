import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_definitions.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';

import 'fixtures/splash_1_4_help.dart';
import 'fixtures/splash_help.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  test(
    '1.4 actual help omits tokenizer argv while retaining managed protection',
    () async {
      final fixture = await SplashRuntimeFixture.create(
        helpOutput: splash14Help,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(engine.close);
      final configuration = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        drafter: const DrafterConfiguration(enabled: false),
        formValues: {
          '--tokenizer': '/wrong/form',
          '--experimental-quantized-ffn': 'on',
          '--chat-template': '/selected/tiel.jinja',
        },
        argumentText:
            '--tokenizer /wrong/text --toke=/wrong/prefix --max-context 8192',
      );
      final command = engine.composeLaunch(
        configuration,
        alias: 'fixture',
        port: 9999,
      );
      expect(
        command.arguments.where(
          (v) => v.startsWith('--tokenizer') || v.startsWith('--toke'),
        ),
        isEmpty,
      );
      expect(command.arguments, isNot(contains('/wrong/text')));
      expect(command.arguments, isNot(contains('/wrong/form')));
      expect(
        command.arguments,
        containsAllInOrder([
          '--experimental-quantized-ffn',
          'on',
          '--chat-template',
          '/selected/tiel.jinja',
        ]),
      );
      expect(command.arguments, containsAllInOrder(['--max-context', '8192']));
      expect(command.notices.join(), contains('模型目录'));
      final template = EngineParameterDefinitions.definition(
        '--chat-template',
        EngineFamily.splash,
        recognition: fixture.installation.recognition,
      );
      expect(template.kind, ParameterKind.file);
      expect(await Directory('/wrong/text').exists(), isFalse);
    },
  );

  for (final help in [
    '',
    '--max-context TOKENS  context only',
    splashCurrentHelp,
  ]) {
    test(
      'older or incomplete help retains managed tokenizer: ${help.length}',
      () async {
        final fixture = await SplashRuntimeFixture.create(helpOutput: help);
        addTearDown(fixture.close);
        final engine = fixture.engine();
        addTearDown(engine.close);
        final command = engine.composeLaunch(
          EngineLaunchConfiguration(family: EngineFamily.splash),
        );
        expect(command.arguments, contains('--tokenizer'));
      },
    );
  }

  test('1.4 preview has no tokenizer placeholder requirement', () {
    final rules = EngineParameterRecognition.fromHelp(
      splash14Help,
      family: EngineFamily.splash,
      version: '1.4.0',
    );
    final command = EngineLaunchConfiguration(family: EngineFamily.splash)
        .command(
          executable: '/python',
          modelPath: '/assembly',
          alias: 'fixture',
          port: 9999,
          recognition: rules,
          executableArguments: ['/assembly'],
          managedArguments: {
            '--model': 'local/fixture',
            '--binary': '/engine/splash',
          },
        );
    expect(command.provisional, isFalse);
    expect(command.arguments, isNot(contains('--tokenizer')));
  });

  test(
    'an executable replacement re-observes the older tokenizer interface',
    () {
      final modern = EngineParameterRecognition.fromHelp(
        splash14Help,
        family: EngineFamily.splash,
        version: 'source checkout',
        executablePath: '/engine/python',
        contentFingerprint: 'new',
      );
      final older = EngineParameterRecognition.fromHelp(
        splashCurrentHelp,
        family: EngineFamily.splash,
        version: 'source checkout',
        executablePath: '/engine/python',
        contentFingerprint: 'old',
        previous: modern,
      );
      final command = EngineLaunchConfiguration(family: EngineFamily.splash)
          .command(
            executable: '/engine/python',
            modelPath: '/assembly',
            recognition: older,
          );
      expect(command.arguments, contains('--tokenizer'));
    },
  );
}
