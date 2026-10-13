import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/desktop_home_route.dart';

void main() {
  testWidgets(
    'duplicate dropdown activation preserves the desktop root and service owner',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var disposed = false;
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) => DesktopHomeRoute(
              settings: settings,
              builder: (_) => _Owner(onDispose: () => disposed = true),
            ),
          ),
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        final option = find.semantics.byLabel('second').last;
        tester.semantics.tap(option);
        tester.semantics.tap(option);
        await tester.pumpAndSettle();
        expect(disposed, isFalse);
        expect(find.byType(_Owner), findsOneWidget);
        expect(find.byType(Scaffold), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}

class _Owner extends StatefulWidget {
  const _Owner({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DropdownButtonFormField<String>(
      initialValue: 'first',
      items: [
        for (final value in ['first', 'second'])
          DropdownMenuItem(value: value, child: Text(value)),
      ],
      onChanged: (_) {},
    ),
  );
}
