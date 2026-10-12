import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  testWidgets('unrecognized files are not offered as model variants', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-library-summary-',
      );
      final library = ModelLibrary();
      try {
        await writeDecisionKev(root);
        await File('${root.path}/config.json')
            .writeAsString(jsonEncode({'model_type': 'fixture'}));
        await File('${root.path}/mystery.bin').writeAsBytes([0, 1, 255]);
        final scanned = library.changes.firstWhere(
          (state) => !state.scanning && state.rootPath != null,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(library: library, libraryPath: root.path),
            ),
          ),
        );
        await scanned.timeout(const Duration(seconds: 5));
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(find.byType(DropdownButton<String>), findsNothing);
        expect(find.textContaining('待验证'), findsNothing);
        expect(find.textContaining('其他文件'), findsNothing);
        expect(find.text('没有匹配的模型包'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        library.close();
        await root.delete(recursive: true);
      }
    });
  });
}
