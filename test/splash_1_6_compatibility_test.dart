import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_definitions.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/splash_engine.dart';

import 'fixtures/splash_1_6_help.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

void main() {
  final recognition = EngineParameterRecognition.fromHelp(
    splash16Help,
    family: EngineFamily.splash,
    version: '1.6.0',
  );

  test('1.6 memory, verification and file options have typed controls', () {
    expect(recognition.status, EngineHelpStatus.available);
    final fields = {
      for (final field in EngineParameterDefinitions.forEngine(
        EngineFamily.splash,
        recognition: recognition,
      ))
        field.name: field,
    };
    expect(fields['--ple-memory']!.kind, ParameterKind.quantity);
    expect(fields['--sparse-kv-memory']!.kind, ParameterKind.quantity);
    expect(fields['--verify-rows']!.choices, ['auto', 'all']);
    expect(fields['--chat-template']!.kind, ParameterKind.file);
    expect(fields['--serve-record']!.kind, ParameterKind.file);
    expect(fields, isNot(contains('--moe-memory-pressure')));
    expect(fields, isNot(contains('--host-memory-reserve')));
    final options = RegExp(r'^  (?:-h, )?(--[\w-]+)', multiLine: true)
        .allMatches(splash16Help)
        .map((match) => match[1]!)
        .where((name) => name != '--help');
    expect(fields.keys, containsAll(options));
  });

  test('1.6 tuple routes retain the custom SystemOne capability', () async {
    final fixture = await SplashRuntimeFixture.create(helpOutput: splash16Help);
    addTearDown(fixture.close);
    final source = File('${fixture.source.path}/server/server.py');
    await source.writeAsString('''
ROUTES = {
    ("POST", "/v1/systemone"): Route(
        dialects.scoring.post_systemone,
    ),
}
''');
    final installation = await SplashEngine.inspectInstallation(fixture.source);
    expect(installation.supportsSystemone, isTrue);
    await source.writeAsString('ROUTES = {}');
    final withoutRoute = await SplashEngine.inspectInstallation(fixture.source);
    expect(withoutRoute.supportsSystemone, isFalse);
  });

  test('1.6 supports million-token contexts and fractional memory sizes', () {
    for (final (context, tokens) in [('1M', 1000000), ('100K', 102400)]) {
      final configuration = EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {
          '--max-context': context,
          '--max-memory': '40G',
          '--ple-memory': '2.5G',
          '--expert-memory': 'auto',
          '--sparse-kv-memory': '1200M',
          '--verify-rows': 'all',
        },
        argumentText: '--max-memory 4.5GiB',
      );
      expect(configuration.contextLengthFor(recognition: recognition), tokens);
      final command = configuration.command(
        executable: '/python',
        modelPath: '/assembly',
        recognition: recognition,
      );
      expect(command.arguments, containsAllInOrder(['--max-memory', '4.5GiB']));
      expect(command.arguments, isNot(contains('40G')));
      expect(command.notices.where((notice) => notice.contains('通常')), isEmpty);
    }
  });

  test('1.6 preserves retired settings without passing them to the server', () {
    final configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {
        '--moe-memory-pressure': 'on',
        '--host-memory-reserve': '4G',
        '--expert-memory': 'auto',
      },
      argumentText: '--moe-memory-pressure off --host-memory-reserve=6G --verify-rows all',
    );
    final command = configuration.command(
      executable: '/python',
      modelPath: '/assembly',
      recognition: recognition,
    );
    expect(command.arguments, isNot(contains('--moe-memory-pressure')));
    expect(command.arguments, isNot(contains('--host-memory-reserve')));
    expect(command.arguments, isNot(contains('--host-memory-reserve=6G')));
    expect(command.arguments, isNot(contains('off')));
    expect(command.arguments, isNot(contains('4G')));
    expect(command.arguments, containsAllInOrder(['--expert-memory', 'auto']));
    expect(command.arguments, containsAllInOrder(['--verify-rows', 'all']));
    expect(command.notices.join(), contains('不传递'));
    expect(configuration.formValues['--moe-memory-pressure'], 'on');
    expect(configuration.argumentText, contains('--host-memory-reserve=6G'));

    final legacy = EngineParameterRecognition.fromHelp(
      '$splash16Help\n  --moe-memory-pressure {on,off}  legacy control\n'
      '  --host-memory-reserve SIZE  legacy reserve\n',
      family: EngineFamily.splash,
      version: 'custom legacy controls',
    );
    final legacyCommand = configuration.command(
      executable: '/python',
      modelPath: '/assembly',
      recognition: legacy,
    );
    expect(legacyCommand.arguments, contains('--moe-memory-pressure'));
    expect(legacyCommand.arguments, contains('--host-memory-reserve=6G'));
  });

  test(
    '1.6 runtime composes calibrated arguments through its public start',
    () async {
      final fixture = await SplashRuntimeFixture.create(
        helpOutput: splash16Help,
      );
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(engine.close);
      addTearDown(engine.shutdown);
      final run = await engine.startWithConfiguration(
        fixture.asset.id,
        EngineLaunchConfiguration(
          family: EngineFamily.splash,
          drafter: const DrafterConfiguration(enabled: false),
          formValues: {
            '--ple-memory': 'off',
            '--sparse-kv-memory': '1200M',
            '--verify-rows': 'all',
            '--moe-memory-pressure': 'on',
          },
        ),
      );
      expect(run.status, RuntimeInstanceStatus.ready);
      final arguments = fixture.io.launchArguments.last;
      expect(arguments, containsAllInOrder(['--ple-memory', 'off']));
      expect(arguments, containsAllInOrder(['--sparse-kv-memory', '1200M']));
      expect(arguments, containsAllInOrder(['--verify-rows', 'all']));
      expect(arguments, isNot(contains('--moe-memory-pressure')));
      expect(arguments, isNot(contains('--tokenizer')));
    },
  );
}
