import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_parameter_recognition.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/splash_engine.dart';

import 'fixtures/splash_help.dart';
import 'splash_engine_test.dart' show SplashRuntimeFixture;

const _option = '--experimental-quantized-ffn';
// The new server contract, kept separate from the observed older CLI fixture.
const _help =
    '$splashCurrentHelp\n  $_option {on,off}  experimental FFN (default: off)\n';

EngineParameterRecognition _recognition(String help) =>
    EngineParameterRecognition.fromHelp(
      help,
      family: EngineFamily.splash,
      version: 'quantized FFN contract fixture',
    );

EngineLaunchConfiguration _configuration(String? value, {String text = ''}) =>
    EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {_option: ?value},
      argumentText: text,
      drafter: const DrafterConfiguration(enabled: false),
    );

void main() {
  test('FFN stays off by default and the observed engine receives on/off', () {
    for (final value in <String?>[null, 'on', 'off']) {
      final configuration = _configuration(value);
      final restored = EngineLaunchConfiguration.fromJson(
        configuration.toJson(),
      );
      final arguments = restored
          .command(
            executable: 'splash',
            modelPath: '/model',
            recognition: _recognition(_help),
          )
          .arguments;
      if (value == null) {
        expect(arguments, isNot(contains(_option)));
      } else {
        expect(arguments, containsAllInOrder([_option, value]));
      }
      expect(restored.formValues, configuration.formValues);
    }
  });

  test('older/unobserved engines omit off and reject on without losing configuration', () {
    for (final recognition in [
      _recognition(splashCurrentHelp),
      EngineParameterRecognition.builtIn(family: EngineFamily.splash),
    ]) {
      for (final text in [
        '',
        '$_option off',
        '$_option=off',
        '$_option on $_option off',
      ]) {
        final configuration = _configuration('off', text: text);
        final command = configuration.command(
          executable: 'splash',
          modelPath: '/model',
          recognition: recognition,
        );
        expect(
          command.arguments.any((arg) => arg.startsWith(_option)),
          isFalse,
        );
        expect(command.notices.join(), contains('不支持实验性量化 FFN'));
        expect(configuration.argumentText, text);
      }
      for (final text in [
        '',
        '$_option on',
        '$_option=on',
        '$_option off $_option on',
      ]) {
        expect(
          () => _configuration('on', text: text).command(
            executable: 'splash',
            modelPath: '/model',
            recognition: recognition,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('请更新引擎或关闭'),
            ),
          ),
        );
      }
      final overridden = _configuration('on', text: '$_option off').command(
        executable: 'splash',
        modelPath: '/model',
        recognition: recognition,
      );
      expect(overridden.arguments, isNot(contains(_option)));
    }
  });

  test('FFN text override preserves all other optimization parameters', () {
    final configuration = EngineLaunchConfiguration(
      family: EngineFamily.splash,
      formValues: {
        _option: 'off',
        '--ane-ffn-share': '0.25',
        '--kv-format': 'bf16',
        '--max-context': '8192',
      },
      argumentText: '$_option=on',
      drafter: const DrafterConfiguration(enabled: false),
    );
    final command = configuration.command(
      executable: 'splash',
      modelPath: '/model',
      recognition: _recognition(_help),
    );
    expect(command.arguments, contains('$_option=on'));
    expect(command.arguments, isNot(contains(_option)));
    expect(
      command.arguments,
      containsAllInOrder([
        '--max-context',
        '8192',
        '--kv-format',
        'bf16',
        '--ane-ffn-share',
        '0.25',
      ]),
    );
    expect(configuration.drafter!.enabled, isFalse);
    expect(configuration.contextLength, 8192);
  });

  test('FFN persists independently and survives reopen and restart', () async {
    final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
    addTearDown(fixture.close);
    final cpp = LlamaEngine(
      library: fixture.library,
      installationDirectory: Directory('${fixture.root.path}/cpp'),
    );
    addTearDown(cpp.close);
    final catalog = EngineCatalog(
      library: fixture.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(fixture.library),
      registryFile: File('${fixture.root.path}/engines.json'),
      splashIO: fixture.io,
    );
    addTearDown(catalog.close);
    addTearDown(catalog.shutdown);
    final entry = await catalog.link(fixture.source.path);
    await catalog.readParameters(entry.id);
    final store = LaunchInstances(
      catalog: catalog,
      file: File('${fixture.root.path}/instances.json'),
    );
    addTearDown(store.close);
    final enabled = await store.save(
      name: 'Quantized',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: _configuration('on'),
    );
    final baseline = await store.save(
      name: 'Baseline',
      artifactId: fixture.asset.id,
      engineId: entry.id,
      configuration: _configuration(null),
    );
    final reopened = LaunchInstances(catalog: catalog, file: store.file);
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.find(enabled.id)!.configuration.formValues[_option], 'on');
    expect(
      reopened.find(baseline.id)!.configuration.formValues[_option],
      isNull,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final run = await reopened.start(enabled.id);
      expect(run.status, RuntimeInstanceStatus.ready);
      expect(
        fixture.io.launchArguments.last,
        containsAllInOrder([_option, 'on']),
      );
      await reopened.stop(enabled.id);
    }
    await reopened.start(baseline.id);
    expect(fixture.io.launchArguments.last, isNot(contains(_option)));
    await reopened.stop(baseline.id);
  });

  test(
    'actual FFN is native-only, per run, and refreshed after idle reload',
    () async {
      final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
      addTearDown(fixture.close);
      final engine = fixture.engine();
      addTearDown(engine.close);
      addTearDown(engine.shutdown);
      fixture.io.startupFeatures = {
        'experimental_quantized_ffn': true,
        'ffn_cache_bytes': 0,
      };
      fixture.io.monitorStatus = {'active_requests': 0};
      final first = await engine.startWithConfiguration(
        fixture.asset.id,
        _configuration('on'),
        launchInstanceId: 'on',
      );
      expect(engine.actualQuantizedFfnFor('on'), (
        enabled: true,
        cacheBytes: 0,
      ));
      fixture.io.startupFeatures = {
        'experimental_quantized_ffn': false,
        'ffn_cache_bytes': 4096,
      };
      await engine.startWithConfiguration(
        fixture.asset.id,
        _configuration('off'),
        launchInstanceId: 'off',
      );
      expect(engine.actualQuantizedFfnFor('off'), (
        enabled: false,
        cacheBytes: 4096,
      ));
      expect(engine.actualQuantizedFfnFor('on'), (
        enabled: true,
        cacheBytes: 0,
      ));
      final pid = fixture.io.children.first.pid;
      // Native memory release/reload keeps the same managed launch arguments.
      for (final features in <Map<String, Object?>>[
        {},
        {'experimental_quantized_ffn': 'true', 'ffn_cache_bytes': -1},
        {'experimental_quantized_ffn': true, 'ffn_cache_bytes': 0},
      ]) {
        fixture.io.startupFeaturesByPid[pid] = features;
        await engine.readTelemetry(
          first.id,
          cancellation: DecisionCancellation(),
        );
        expect(
          engine.actualQuantizedFfnFor('on'),
          features['experimental_quantized_ffn'] == true
              ? (enabled: true, cacheBytes: 0)
              : (enabled: null, cacheBytes: null),
        );
        expect(
          fixture.io.launchArguments.first,
          containsAllInOrder([_option, 'on']),
        );
      }
      expect(fixture.io.starts, 2);
      await engine.stop(first.id);
      expect(engine.actualQuantizedFfnFor('on'), isNull);
    },
  );

  test('native FFN model rejection is retained as a startup error', () async {
    final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    addTearDown(engine.shutdown);
    fixture.io.launchStderr = 'experimental quantized FFN supports ordinary Qwen3.5-4B generation only; 27B/MoE/Kev/D3/ModernBERT unsupported';
    fixture.io.launchExitCode = 2;
    await expectLater(
      engine.startWithConfiguration(
        fixture.asset.id,
        _configuration('on'),
        launchInstanceId: 'unsupported',
      ),
      throwsA(isA<SplashEngineException>()),
    );
    expect(
      fixture.io.launchArguments.single,
      containsAllInOrder([_option, 'on']),
    );
    expect(engine.state.instances.single.status, RuntimeInstanceStatus.failed);
    expect(engine.state.instances.single.error, contains('Qwen3.5-4B'));
    expect(engine.actualQuantizedFfnFor('unsupported'), isNull);
  });

  test('FFN switch leaves explicit DFlash selection intact', () async {
    final fixture = await SplashRuntimeFixture.create(helpOutput: _help);
    addTearDown(fixture.close);
    final engine = fixture.engine();
    addTearDown(engine.close);
    addTearDown(engine.shutdown);
    fixture.io.startupFeatures = {
      'experimental_quantized_ffn': true,
      'ffn_cache_bytes': 0,
    };
    final draft = '${fixture.assembly.path}/draft';
    await engine.startWithConfiguration(
      fixture.asset.id,
      EngineLaunchConfiguration(
        family: EngineFamily.splash,
        formValues: {_option: 'on'},
        drafter: DrafterConfiguration(enabled: true, path: draft),
      ),
      launchInstanceId: 'dflash',
    );
    expect(
      fixture.io.launchArguments.single,
      containsAllInOrder([_option, 'on']),
    );
    expect(engine.actualDrafterFor('dflash')!.type, 'dflash');
    expect(engine.actualDrafterFor('dflash')!.source, draft);
    expect(engine.actualQuantizedFfnFor('dflash'), (
      enabled: true,
      cacheBytes: 0,
    ));
  });
}
