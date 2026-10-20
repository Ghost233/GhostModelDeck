import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/llm_playground_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'splash_engine_test.dart' show SplashRuntimeFixture;
import 'fixtures/parameter_editor_navigation.dart';

void main() {
  test(
    'Splash public JSON and SSE preserve exact signed and unsigned seed boundaries',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _SeedRuntime.create();
      addTearDown(fixture.close);
      for (final stream in [false, true]) {
        for (final seed in [
          '9223372036854775807',
          '9223372036854775808',
          '18446744073709551615',
          '-9223372036854775808',
          '-1',
        ]) {
          final response = await fixture.post('"seed":$seed', stream: stream);
          expect(response.status, 200, reason: '$seed ${response.body}');
          expect(
            fixture.source.io.rawChatBodies.last,
            contains('"seed":$seed'),
          );
          if (stream) expect(response.body, contains('data: [DONE]'));
        }
        for (final seed in [
          '18446744073709551616',
          '-9223372036854775809',
          List.filled(100, '9').join(),
        ]) {
          final before = fixture.source.io.rawChatBodies.length;
          final response = await fixture.post('"seed":$seed', stream: stream);
          expect(response.status, 400, reason: seed);
          expect(fixture.source.io.rawChatBodies.length, before);
        }
      }
    }, _Network()),
  );
  test(
    'public seed decoding follows escaped names and the final top-level value',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = await _SeedRuntime.create();
      addTearDown(fixture.close);
      final cases = [
        (r'"se\u0065d":18446744073709551615', '18446744073709551615'),
        (r'"seed":1,"se\u0065d":18446744073709551615', '18446744073709551615'),
        (r'"se\u0065d":18446744073709551615,"seed":-1', '-1'),
        (
          r'"seed":3,"chat_template_kwargs":{"seed":9,"items":[{"se\u0065d":10}]}',
          '3',
        ),
        (r'"seed":4,"stop":["literal \"seed\":999 and { } [ ] \\ end"]', '4'),
      ];
      for (final stream in [false, true]) {
        for (final (fields, expected) in cases) {
          final response = await fixture.post(fields, stream: stream);
          expect(response.status, 200, reason: response.body);
          expect(
            fixture.source.io.rawChatBodies.last,
            contains('"seed":$expected'),
          );
        }
        for (final fields in [
          r'"chat_template_kwargs":{"seed":18446744073709551615}',
          r'"seed":18446744073709551615,"seed":null',
        ]) {
          final response = await fixture.post(fields, stream: stream);
          expect(response.status, 200, reason: response.body);
          expect(
            fixture.source.io.chatBodies.last.containsKey('seed'),
            isFalse,
          );
        }
        for (final fields in [
          r'"seed":18446744073709551615,"seed":"1"',
          r'"seed":18446744073709551615,"seed":true',
          r'"seed":18446744073709551615,"seed":1e0',
        ]) {
          final before = fixture.source.io.rawChatBodies.length;
          final response = await fixture.post(fields, stream: stream);
          expect(response.status, 400, reason: fields);
          expect(fixture.source.io.rawChatBodies.length, before);
        }
      }
    }, _Network()),
  );

  testWidgets(
    'unsigned seed input saves and reopens without losing decimal precision',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => _SeedRuntime.create(start: false),
          _Network(),
        ),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: InstancesPage(instances: fixture.store)),
          ),
        );
        await _settle(tester);
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await selectParameterGroup(tester, '基本生成');
      final seed = find.byKey(const Key('parameter-number:generation:seed'));
      await tester.ensureVisible(seed);
      await tester.enterText(seed, '18446744073709551615');
      await tester.runAsync(() => _settle(tester));
      expect(tester.widget<TextField>(seed).decoration!.errorText, isNull);
      final row = find.byKey(const Key('parameter-field:generation:seed'));
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('增加')),
      );
      await tester.runAsync(() => _settle(tester));
      expect(
        tester.widget<TextField>(seed).controller!.text,
        '18446744073709551616',
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('减少')),
      );
      await tester.runAsync(() => _settle(tester));
      expect(
        tester.widget<TextField>(seed).controller!.text,
        '18446744073709551615',
      );
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _settle(tester);
        final reopened = LaunchInstances(
          catalog: fixture.catalog,
          file: fixture.store.file,
        );
        await reopened.load();
        expect(
          reopened
              .find(fixture.definition.id)!
              .configuration
              .generation
              .values['seed']
              .toString(),
          '18446744073709551615',
        );
        await reopened.close();
        await tester.ensureVisible(find.text('编辑参数'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑参数'));
        await _settle(tester);
      });
      await selectParameterGroup(tester, '基本生成');
      expect(
        tester.widget<TextField>(seed).controller!.text,
        '18446744073709551615',
      );
      expect(tester.widget<TextField>(seed).decoration!.errorText, isNull);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await fixture.store.start(fixture.definition.id);
          for (final stream in [false, true]) {
            final inherited = await fixture.post('"seed":null', stream: stream);
            expect(inherited.status, 200, reason: inherited.body);
            expect(
              fixture.source.io.rawChatBodies.last,
              contains('"seed":18446744073709551615'),
            );
          }
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: LlmPlaygroundPage(gateway: fixture.gateway)),
            ),
          );
          await _settle(tester, until: find.byKey(const Key('llm-discovery')));
        }, _Network()),
      );
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final document =
          '{"model":${jsonEncode(fixture.definition.publicName)},"messages":[{"role":"user","content":"Reply OK"}],"stream":false,"seed":18446744073709551615}';
      await tester.enterText(find.byKey(const Key('llm-json')), document);
      await _tap(tester, find.byKey(const Key('llm-form-mode')));
      final overrideSeed = find.byKey(const Key('parameter-number:llm:seed'));
      await tester.ensureVisible(overrideSeed);
      expect(
        tester.widget<TextField>(overrideSeed).controller!.text,
        '18446744073709551615',
      );
      await tester.enterText(overrideSeed, '18446744073709551614');
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      final edited = tester
          .widget<TextField>(find.byKey(const Key('llm-json')))
          .controller!
          .text;
      expect(edited, contains('"seed": 18446744073709551614'));
      for (final stream in [false, true]) {
        await tester.enterText(
          find.byKey(const Key('llm-json')),
          edited.replaceFirst('"stream": false', '"stream": $stream'),
        );
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await _tap(tester, find.byKey(const Key('llm-run')));
            await _settle(
              tester,
              until: find.byKey(const Key('llm-completed')),
            );
          }, _Network()),
        );
        expect(
          fixture.source.io.rawChatBodies.last,
          contains('"seed":18446744073709551614'),
        );
        final evidence = jsonDecode(
          tester
              .widget<SelectableText>(find.byKey(const Key('llm-result')))
              .data!,
        ) as Map;
        expect(evidence['request']['seed'], '18446744073709551614');
      }
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _settle(WidgetTester tester, {Finder? until}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  do {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        (until == null || until.evaluate().isNotEmpty)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  } while (DateTime.now().isBefore(deadline));
  fail('Seed configuration GUI did not settle');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Network extends HttpOverrides {}

class _SeedRuntime {
  _SeedRuntime(
    this.source,
    this.cpp,
    this.catalog,
    this.store,
    this.definition,
    this.routes,
    this.gateway,
  );
  final SplashRuntimeFixture source;
  final LlamaEngine cpp;
  final EngineCatalog catalog;
  final LaunchInstances store;
  final LaunchInstance definition;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;

  static Future<_SeedRuntime> create({bool start = true}) async {
    final source = await SplashRuntimeFixture.create();
    final cpp = LlamaEngine(
      library: source.library,
      installationDirectory: Directory('${source.root.path}/cpp'),
    );
    final catalog = EngineCatalog(
      library: source.library,
      officialEngine: cpp,
      useRegistry: ModelUseRegistry(source.library),
      registryFile: File('${source.root.path}/engines.json'),
      splashIO: source.io,
    );
    final entry = await catalog.link(source.source.path);
    final store = LaunchInstances(
      catalog: catalog,
      file: File('${source.root.path}/instances.json'),
    );
    final definition = await store.save(
      name: 'Precise seed',
      artifactId: source.asset.id,
      engineId: entry.id,
      configuration: EngineLaunchConfiguration(
        family: EngineFamily.splash,
        drafter: const DrafterConfiguration(enabled: false),
      ),
    );
    if (start) await store.start(definition.id);
    final routes = PublicModelRoutes(
      library: source.library,
      runtimes: catalog.runtimes.toList(),
      instances: store,
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await gateway.start();
    return _SeedRuntime(
      source,
      cpp,
      catalog,
      store,
      definition,
      routes,
      gateway,
    );
  }

  Future<({int status, String body})> post(
    String fields, {
    bool stream = false,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        gateway.baseUrl!.resolve('/v1/chat/completions'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        '{"model":${jsonEncode(definition.publicName)},"messages":[{"role":"user","content":"Reply OK"}],"stream":$stream,$fields}',
      );
      final response = await request.close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await gateway.stop();
    gateway.close();
    routes.close();
    await catalog.shutdown();
    await store.close();
    catalog.close();
    cpp.close();
    await source.close();
  }
}
