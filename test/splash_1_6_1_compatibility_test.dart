import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_definitions.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/splash_engine.dart';
import 'package:ghost_model_deck/splash_preparation.dart';

import 'fixtures/splash_1_6_help.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

const _help =
    '$splash16Help\n  --activations {auto,bf16}  Activation precision\n';

void main() {
  final current = EngineParameterRecognition.fromHelp(
    _help,
    family: EngineFamily.splash,
    version: 'Splash (source checkout)',
  );
  final old = EngineParameterRecognition.fromHelp(
    splash16Help,
    family: EngineFamily.splash,
    version: 'Splash (source checkout)',
  );

  test('existing instance JSON keeps explicit choices and absent defaults', () {
    for (final values in [
      <String, String>{},
      {'--kv-format': 'int8', '--ple-memory': 'auto'},
      {'--kv-format': 'q4h', '--ple-memory': 'off'},
    ]) {
      final instance = LaunchInstance.fromJson({
        'id': 'legacy',
        'name': 'Legacy',
        'public_name': 'legacy',
        'artifact_id': 'model',
        'engine_id': 'splash',
        'revision': 1,
        'configuration': {'family': 'splash', 'formValues': values},
      });
      final config = LaunchInstance.fromJson(instance.toJson()).configuration;
      expect(config.formValues, values);
      final args = config
          .command(
            executable: '/python',
            modelPath: '/model',
            recognition: current,
          )
          .arguments;
      expect(args, isNot(contains('--activations')));
      if (values.isEmpty) {
        expect(args, isNot(contains('--kv-format')));
        expect(args, isNot(contains('--ple-memory')));
      } else {
        expect(
          args,
          containsAllInOrder(['--kv-format', values['--kv-format']]),
        );
        expect(
          args,
          containsAllInOrder(['--ple-memory', values['--ple-memory']]),
        );
      }
    }
  });

  test(
    'activation setting is independent and old CLI preserves saved input',
    () {
      expect(current.supportsSplashActivations, isTrue);
      expect(old.supportsSplashActivations, isFalse);
      final config = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {'--activations': 'auto', '--kv-format': 'q4h'},
        argumentText: '--activations=bf16 --max-context 32K',
      );
      EngineLaunchCommand command(EngineParameterRecognition recognition) =>
          config.command(
            executable: '/python',
            modelPath: '/model',
            recognition: recognition,
          );
      expect(
        command(current).arguments,
        containsAll(['--activations=bf16', '--kv-format', 'q4h']),
      );
      expect(command(current).overriddenForm, contains('--activations'));
      expect(command(old).arguments, isNot(contains('--activations=bf16')));
      expect(
        command(old).arguments,
        containsAllInOrder(['--max-context', '32K']),
      );
      expect(command(old).notices, contains(contains('使用引擎默认激活精度')));
      expect(
        config.toJson()['argumentText'],
        '--activations=bf16 --max-context 32K',
      );
    },
  );

  test('model capabilities limit Flash Next to dense-format alternatives', () {
    LibraryArtifact model(
      String path,
      String architecture,
      int headDimension,
    ) => LibraryArtifact(
      id: path,
      files: [LibraryFile(path: path, sizeBytes: 1)],
      format: 'GGUF',
      kind: AssetKind.chat,
      integrity: AssetIntegrity.complete,
      engineCapability: EngineCapability.awaitingVerification,
      architecture: architecture,
      attentionHeadDimension: headDimension,
    );
    Map<String, EngineParameterDefinition> fields(LibraryArtifact? model) => {
      for (final field in EngineParameterDefinitions.forEngine(
        EngineFamily.splash,
        recognition: current,
        splashModel: model,
      ))
        field.name: field,
    };
    final flash = model('/Qwen3.8-Flash-Next-UD-IQ1_M.gguf', 'qwen4exp', 256);
    final axion = model(
      '/Axion-1.0-35B.APEX-I-MiniPlus-V2.1.gguf',
      'qwen35moe',
      256,
    );
    final other = model('/other.gguf', 'qwen35', 128);
    expect(usesSplashQ4hLauncherDefault(flash), isTrue);
    expect(usesSplashQ4hLauncherDefault(axion), isTrue);
    expect(usesSplashQ4hLauncherDefault(other), isFalse);
    expect(fields(flash)['--kv-format']!.choices, ['int8', 'bf16', 'q4h']);
    expect(fields(flash), contains('--ple-memory'));
    expect(fields(axion), isNot(contains('--ple-memory')));
    expect(
      fields(axion)['--kv-format']!.choices,
      containsAll(['q4_0', 'q4_0_unrotated']),
    );
    expect(fields(other)['--kv-format']!.choices, ['int8', 'bf16', 'q4h']);
    expect(fields(null)['--kv-format']!.choices, ['int8', 'bf16', 'q4h']);
    expect(fields(null)['--activations']!.choices, ['auto', 'bf16']);
  });

  test(
    'start sends explicit BF16 only when current help supports it',
    () async {
      final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
      addTearDown(fixture.close);
      final unread = await SplashEngine.inspectInstallation(
        fixture.source,
        io: fixture.io,
      );
      final engine = fixture.engine(installation: unread);
      addTearDown(engine.close);
      addTearDown(engine.shutdown);
      for (final (activation, supports) in [
        ('auto', true),
        ('bf16', true),
        ('bf16', false),
      ]) {
        fixture.io.helpOutput = supports ? _help : splash16Help;
        final config = EngineLaunchConfiguration(
          family: EngineFamily.splash,
          formValues: {'--activations': activation, '--kv-format': 'int8'},
          drafter: const DrafterConfiguration(enabled: false),
        );
        final run = await engine.startWithConfiguration(
          fixture.asset.id,
          config,
        );
        expect(run.status, RuntimeInstanceStatus.ready);
        final argv = fixture.io.launchArguments.last;
        expect(argv, containsAllInOrder(['--kv-format', 'int8']));
        if (activation == 'bf16' && supports) {
          expect(argv, containsAllInOrder(['--activations', 'bf16']));
        } else {
          expect(argv, isNot(contains('--activations')));
        }
        expect(config.formValues['--activations'], activation);
      }
    },
  );

  test('status 69 remains visible when Splash exits before Ready', () async {
    final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
    addTearDown(fixture.close);
    fixture.io.launchExitCode = 69;
    fixture.io.launchStderr = 'native engine unavailable';
    final engine = fixture.engine();
    addTearDown(engine.close);
    addTearDown(engine.shutdown);
    await expectLater(
      engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(family: EngineFamily.splash),
      ),
      throwsA(
        isA<SplashEngineException>().having(
          (error) => error.message,
          'message',
          allOf(contains('69'), contains('native engine unavailable')),
        ),
      ),
    );
  });
}
