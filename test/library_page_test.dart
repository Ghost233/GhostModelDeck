import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/decision_gguf.dart';

void main() {
  testWidgets(
    'model file summary reveals its existing directory through the native Finder entry',
    (tester) async {
      final verified = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('gmd-model-finder-');
        final library = ModelLibrary();
        const channel = MethodChannel('com.ghost233.ghostmodeldeck/native');
        final revealed = Completer<MethodCall>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (!revealed.isCompleted) revealed.complete(call);
            return null;
          },
        );
        try {
          final model = await writeDecisionKev(root);
          final scanned = library.changes.firstWhere(
            (state) => !state.scanning && state.rootPath != null,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(
                  library: library,
                  libraryPath: root.path,
                  onCreateInstance: (_) {},
                ),
              ),
            ),
          );
          await scanned.timeout(const Duration(seconds: 5));
          for (var frame = 0; frame < 20; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          final more = find.byKey(
            ValueKey('model-more:${library.state.artifacts.single.id}'),
          );
          await tester.ensureVisible(more);
          await tester.tap(more);
          await tester.pumpAndSettle();
          await tester.tap(find.text('文件详情').last);
          await tester.pumpAndSettle();
          expect(find.textContaining(model.path), findsOneWidget);
          expect(find.textContaining('未验证'), findsNothing);
          await tester.tap(find.text('在 Finder 中显示').last);
          final call = await revealed.future.timeout(
            const Duration(seconds: 5),
          );
          expect(call.method, 'revealInFinder');
          expect(call.arguments, {'path': model.parent.path});
          expect(await model.exists(), isTrue);
          expect(tester.takeException(), isNull);
          return true;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          library.close();
          await root.delete(recursive: true);
        }
      });
      expect(verified, isTrue);
    },
  );
  testWidgets(
    'deleting one variant retains its shared projector until the last variant is deleted',
    (tester) async {
      final verified = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-shared-projector-',
        );
        final library = ModelLibrary();
        try {
          final first = await writeDecisionKev(root);
          final other = await first.copy(
            '${first.parent.path}/Other-Q8_0.gguf',
          );
          List<int> u32(int value) => (ByteData(
            4,
          )..setUint32(0, value, Endian.little)).buffer.asUint8List();
          List<int> u64(int value) => (ByteData(
            8,
          )..setUint64(0, value, Endian.little)).buffer.asUint8List();
          final key = utf8.encode('general.architecture');
          final bytes = BytesBuilder()
            ..add(ascii.encode('GGUF'))
            ..add(u32(3))
            ..add(u64(0))
            ..add(u64(1))
            ..add(u64(key.length))
            ..add(key)
            ..add(u32(8))
            ..add(u64(4))
            ..add(ascii.encode('clip'));
          final projector = await File('${first.parent.path}/mmproj-F16.gguf')
              .writeAsBytes(bytes.takeBytes());
          final scanned = library.changes.firstWhere(
            (state) => !state.scanning && state.rootPath != null,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(
                  library: library,
                  libraryPath: root.path,
                  onCreateInstance: (_) {},
                ),
              ),
            ),
          );
          await scanned.timeout(const Duration(seconds: 5));
          Future<void> settle() async {
            for (var frame = 0; frame < 20; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          }

          await settle();
          expect(
            tester.widget<DataTable>(find.byType(DataTable)).rows,
            hasLength(2),
          );
          final id = library.state.artifacts
              .singleWhere((asset) => asset.files.single.path == first.path)
              .id;
          final more = find.byKey(ValueKey('model-more:$id'));
          await tester.ensureVisible(more);
          await tester.tap(more);
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除模型').last);
          await settle();
          final dialog = find.byType(AlertDialog);
          final plan = tester
              .widget<SelectableText>(
                find.descendant(
                  of: dialog,
                  matching: find.byType(SelectableText),
                ),
              )
              .data!;
          expect(plan, contains(first.path));
          expect(plan, isNot(contains(other.path)));
          expect(plan, isNot(contains(projector.path)));
          var deleted = library.changes.firstWhere(
            (state) => !state.scanning && state.artifacts.length == 2,
          );
          await tester.tap(find.widgetWithText(FilledButton, '删除'));
          await tester.pumpAndSettle();
          await deleted.timeout(const Duration(seconds: 5));
          await settle();
          expect(await first.exists(), isFalse);
          expect(await other.exists(), isTrue);
          expect(await projector.exists(), isTrue);
          expect(find.byType(Checkbox), findsOneWidget);
          await tester.tap(find.byType(Checkbox));
          await tester.pump();
          final remove = find.widgetWithText(OutlinedButton, '删除模型');
          await tester.ensureVisible(remove);
          await tester.tap(remove);
          await settle();
          final lastPlan = tester
              .widget<SelectableText>(
                find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(SelectableText),
                ),
              )
              .data!;
          expect(lastPlan, contains(other.path));
          expect(lastPlan, contains(projector.path));
          deleted = library.changes.firstWhere(
            (state) => !state.scanning && state.artifacts.isEmpty,
          );
          await tester.tap(find.widgetWithText(FilledButton, '删除'));
          await tester.pumpAndSettle();
          await deleted.timeout(const Duration(seconds: 5));
          expect(await other.exists(), isFalse);
          expect(await projector.exists(), isFalse);
          expect(tester.takeException(), isNull);
          return true;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          library.close();
          await root.delete(recursive: true);
        }
      });
      expect(verified, isTrue);
    },
  );
  testWidgets(
    'model table exposes each variant as a separate row and creates the selected instance',
    (tester) async {
      final verified = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-variant-table-',
        );
        final library = ModelLibrary();
        final selected = <String>{};
        try {
          final first = await writeDecisionKev(root);
          await first.copy('${first.parent.path}/Other-Q8_0.gguf');
          final scanned = library.changes.firstWhere(
            (state) => !state.scanning && state.rootPath != null,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(
                  library: library,
                  libraryPath: root.path,
                  onCreateInstance: selected.add,
                ),
              ),
            ),
          );
          await scanned.timeout(const Duration(seconds: 5));
          for (var frame = 0; frame < 20; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(find.byType(DataTable), findsOneWidget);
          expect(
            tester.widget<DataTable>(find.byType(DataTable)).rows,
            hasLength(2),
          );
          for (final label in ['模型名', '格式', '量化', '大小', '所在目录', '操作']) {
            expect(find.text(label), findsOneWidget);
          }
          expect(find.byType(DropdownButton<String>), findsNothing);
          final actions = find.widgetWithText(TextButton, '创建实例');
          expect(actions, findsNWidgets(2));
          for (var index = 0; index < 2; index++) {
            await tester.ensureVisible(actions.at(index));
            await tester.tap(actions.at(index));
          }
          expect(
            selected,
            library.state.artifacts.map((asset) => asset.id).toSet(),
          );
          expect(tester.takeException(), isNull);
          return true;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          library.close();
          await root.delete(recursive: true);
        }
      });
      expect(verified, isTrue);
    },
  );
  testWidgets(
    'model library creates instances without model parameter controls',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-library-instance-',
        );
        final library = ModelLibrary();
        String? selected;
        try {
          await writeDecisionKev(root);
          final scanned = library.changes.firstWhere(
            (state) => !state.scanning && state.rootPath != null,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(
                  library: library,
                  libraryPath: root.path,
                  onCreateInstance: (id) => selected = id,
                ),
              ),
            ),
          );
          await scanned.timeout(const Duration(seconds: 5));
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(find.byTooltip('模型参数'), findsNothing);
          expect(find.text('运行'), findsNothing);
          await tester.ensureVisible(find.text('创建实例'));
          await tester.tap(find.text('创建实例'));
          expect(selected, library.state.artifacts.single.id);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          library.close();
          await root.delete(recursive: true);
        }
      });
    },
  );
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
        expect(find.text('核验'), findsNothing);
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
