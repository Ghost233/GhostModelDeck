import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> selectParameterGroup(WidgetTester tester, String label) async {
  final nav = find.byKey(const Key('parameter-group-navigation'));
  final item = find.descendant(of: nav, matching: find.text(label));
  final scroll = find.descendant(of: nav, matching: find.byType(Scrollable));
  await tester.scrollUntilVisible(item, 120, scrollable: scroll);
  await Scrollable.ensureVisible(tester.element(item), alignment: .5);
  await tester.pumpAndSettle();
  expect(item.hitTestable(), findsOneWidget);
  await tester.tap(item.hitTestable());
  await tester.pumpAndSettle();
}
