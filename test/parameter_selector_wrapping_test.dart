import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_parameter_definitions.dart';
import 'package:ghost_model_deck/parameter_value_field.dart';

void main() {
  testWidgets(
    'parameter selectors wrap the full selected filename and menu entries',
    (tester) async {
      final path =
          '/models/${List.filled(8, 'long-directory').join('/')}/selected-template.jinja';
      final other =
          '/models/${List.filled(7, 'another-directory').join('/')}/other-template.jinja';
      var selected = path;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: StatefulBuilder(
                  builder: (context, update) => ParameterValueField(
                    id: 'template',
                    definition: EngineParameterDefinition(
                      '--chat-template',
                      '模板文件',
                      'templates',
                      ParameterKind.choice,
                      choices: [path, other],
                    ),
                    value: selected,
                    onChanged: (value) =>
                        update(() => selected = value as String),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      void expectWrapped(Finder text) {
        final RenderParagraph paragraph = tester.renderObject(text);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(
          paragraph
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: (paragraph.text.toPlainText()).length,
                ),
              )
              .length,
          greaterThan(2),
        );
      }

      final dropdown = find.byKey(const Key('parameter-choice:template'));
      expectWrapped(find.text(path));
      expect(tester.getSize(dropdown).height, greaterThan(48));
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(other),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text(other).last),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      expectWrapped(find.text(other).last);
      await tester.tap(find.text(other).last);
      await tester.pumpAndSettle();
      expect(selected, other);
      expectWrapped(find.text(other));
      expect(tester.takeException(), isNull);
    },
  );
}
