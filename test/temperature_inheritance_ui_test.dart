import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_launch_configuration.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/instances_page.dart';
import 'package:ghost_model_deck/launch_instances.dart';
import 'package:ghost_model_deck/llm_playground_page.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/parameter_editor_navigation.dart';
import 'llm_playground_test.dart' show LlmTestRuntime;

void main() {
  testWidgets(
    'llama instance temperature inheritance has no invented slider and remains editable',
    (tester) async {
      _viewport(tester);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(_Runtime.create, _Network()),
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
        final action = find.byKey(
          ValueKey('instance-parameters:${fixture.definition.id}'),
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await _settle(tester);
      });
      await selectParameterGroup(tester, '基本生成');
      final field = _number('generation');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(_slider('generation'), findsNothing);
      final row = find.byKey(
        const Key('parameter-field:generation:temperature'),
      );
      await _tap(
        tester,
        find.descendant(of: row, matching: find.byTooltip('增加')),
      );
      expect(tester.widget<TextField>(field).enabled, isTrue);
      expect(tester.widget<Slider>(_slider('generation')).onChanged, isNotNull);
      expect(
        tester.widget<Slider>(_slider('generation')).value,
        num.parse(tester.widget<TextField>(field).controller!.text),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '0');
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_slider('generation')).value, 0);
      await tester.enterText(field, '1.3');
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_slider('generation')).value, 1.3);
      await _tap(tester, _slider('generation'));
      expect(num.parse(tester.widget<TextField>(field).controller!.text), 1);
      await _tap(
        tester,
        find.descendant(of: row, matching: find.byTooltip('恢复默认')),
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(_slider('generation'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _settle(
          tester,
          completed: () => find
              .byKey(const Key('parameter-group-navigation'))
              .evaluate()
              .isEmpty,
        );
      });
      expect(
        fixture.store
            .find(fixture.definition.id)!
            .configuration
            .generation
            .values
            .containsKey('temperature'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'llama playground shows only known inherited or explicit temperature slider values',
    (tester) async {
      _viewport(tester);
      final fixture = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(_Runtime.create, _Network()),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }),
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => fixture.store.start(fixture.definition.id),
          _Network(),
        ),
      );
      Future<void> open() async {
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: LlmPlaygroundPage(gateway: fixture.gateway),
                ),
              ),
            );
            await _settle(
              tester,
              completed: () =>
                  find.byKey(const Key('llm-discovery')).evaluate().isNotEmpty,
            );
          }, _Network()),
        );
        await _tap(tester, find.byKey(const Key('llm-json-mode')));
        await tester.enterText(
          find.byKey(const Key('llm-json')),
          jsonEncode({
            'model': fixture.definition.publicName,
            'messages': [
              {'role': 'user', 'content': 'OK'},
            ],
          }),
        );
        await _tap(tester, find.byKey(const Key('llm-form-mode')));
      }

      await open();
      expect(
        tester.widget<TextField>(_number('llm')).controller!.text,
        isEmpty,
      );
      expect(_slider('llm'), findsNothing);
      // This is an explicit saved instance default, not an inferred binary default.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => fixture.store.save(
          id: fixture.definition.id,
          name: fixture.definition.name,
          artifactId: fixture.definition.artifactId,
          engineId: fixture.definition.engineId,
          configuration: EngineLaunchConfiguration(
            generation: GenerationConfiguration({'temperature': 0.8}),
          ),
        ),
      );
      await open();
      final field = _number('llm');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(tester.widget<TextField>(field).decoration!.hintText, '0.8');
      expect(tester.widget<Slider>(_slider('llm')).value, 0.8);
      expect(tester.widget<Slider>(_slider('llm')).onChanged, isNotNull);
      await _tap(tester, _slider('llm'));
      expect(num.parse(tester.widget<TextField>(field).controller!.text), 1);
      await tester.ensureVisible(field);
      await tester.enterText(field, '0');
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_slider('llm')).value, 0);
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      expect(_document(tester)['temperature'], 0);
      await _tap(tester, find.byKey(const Key('llm-form-mode')));
      await tester.ensureVisible(field);
      await tester.enterText(field, '1.4');
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_slider('llm')).value, 1.4);
      final row = find.byKey(const Key('parameter-field:llm:temperature'));
      await _tap(
        tester,
        find.descendant(of: row, matching: find.byTooltip('恢复默认')),
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(tester.widget<Slider>(_slider('llm')).value, 0.8);
      await _tap(tester, find.byKey(const Key('llm-json-mode')));
      expect(_document(tester).containsKey('temperature'), isFalse);
      expect(
        fixture.store
            .find(fixture.definition.id)!
            .configuration
            .generation
            .values['temperature'],
        0.8,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _Runtime {
  _Runtime(this.source, this.store, this.definition, this.routes, this.gateway);
  final LlmTestRuntime source;
  final LaunchInstances store;
  final LaunchInstance definition;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  static Future<_Runtime> create() async {
    final source = await LlmTestRuntime.create();
    final store = LaunchInstances(
      catalog: source.catalog,
      file: File('${source.root.path}/temperature-instances.json'),
    );
    final definition = await store.save(
      name: 'Temperature inheritance',
      artifactId: source.asset.id,
      engineId: EngineCatalog.officialId,
      configuration: EngineLaunchConfiguration(),
    );
    final routes = PublicModelRoutes(
      library: source.library,
      runtimes: source.catalog.runtimes.toList(),
      instances: store,
    );
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    await gateway.start();
    return _Runtime(source, store, definition, routes, gateway);
  }

  Future<void> close() async {
    await gateway.stop();
    gateway.close();
    routes.close();
    await store.close();
    await source.close();
  }
}

Map<String, Object?> _document(WidgetTester tester) =>
    Map<String, Object?>.from(
      jsonDecode(
        tester
            .widget<TextField>(find.byKey(const Key('llm-json')))
            .controller!
            .text,
      ) as Map,
    );
Finder _number(String prefix) =>
    find.byKey(Key('parameter-number:$prefix:temperature'));
Finder _slider(String prefix) =>
    find.byKey(Key('parameter-slider:$prefix:temperature'));
void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester, {bool Function()? completed}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  do {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        (completed?.call() ?? true)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  } while (DateTime.now().isBefore(deadline));
  fail('Temperature inheritance GUI did not settle');
}

class _Network extends HttpOverrides {}
