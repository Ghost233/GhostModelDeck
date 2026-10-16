import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/management_table.dart';

import 'fixtures/test_environment.dart';

typedef Entry = ({String id, String name, String status, int size});

void main() {
  setUpAll(() async {
    expect(await layoutFontFile.exists(), isTrue);
    await (FontLoader('Layout Noto CJK')..addFont(
          Future.value(
            ByteData.sublistView(await layoutFontFile.readAsBytes()),
          ),
        ))
        .load();
    expect(await materialIconsFontFile.exists(), isTrue);
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(await materialIconsFontFile.readAsBytes()),
          ),
        ))
        .load();
  });
  testWidgets(
    'table searches and sorts the whole collection before paging and operates on the displayed identity',
    (tester) async {
      String? operated;
      final items = List.generate(
        63,
        (index) => (
          id: 'id-$index',
          name: '模型 ${index.toString().padLeft(2, '0')}',
          status: index.isEven ? '已安装' : '未安装',
          size: 63 - index,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManagementTable<Entry>(
              id: 'sample',
              items: items,
              rowKey: (row) => row.id,
              searchText: (row) => row.name,
              status: (row) => row.status,
              columns: [
                ManagementColumn(
                  label: '模型',
                  cell: (row) => Text(row.name),
                  compare: (a, b) => a.name.compareTo(b.name),
                ),
                ManagementColumn(
                  label: '大小',
                  cell: (row) => Text('${row.size}'),
                  compare: (a, b) => a.size.compareTo(b.size),
                ),
                ManagementColumn(
                  label: '操作',
                  cell: (row) => TextButton(
                    onPressed: () => operated = row.id,
                    child: Text('运行 ${row.id}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('模型 00'), findsOneWidget);
      expect(find.text('模型 20'), findsNothing);
      await tester.tap(find.byKey(const Key('sample-next')));
      await tester.pump();
      expect(find.text('模型 20'), findsOneWidget);
      expect(find.text('模型 00'), findsNothing);
      await tester.enterText(find.byKey(const Key('sample-search')), '模型 62');
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(DataTable),
          matching: find.text('模型 62'),
        ),
        findsOneWidget,
      );
      expect(find.text('第 1 / 1 页 · 1 / 63 条'), findsOneWidget);
      await tester.tap(find.text('运行 id-62'));
      expect(operated, 'id-62');
      await tester.enterText(find.byKey(const Key('sample-search')), '');
      await tester.pump();
      await tester.tap(find.text('大小'));
      await tester.pump();
      expect(find.text('模型 62'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sample-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('未安装').last);
      await tester.pumpAndSettle();
      expect(find.text('模型 62'), findsNothing);
      expect(find.text('模型 61'), findsOneWidget);
      await tester.tap(find.text('运行 id-61'));
      expect(operated, 'id-61');
      expect(tester.takeException(), isNull);
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'table supports long paths and reachable actions with real fonts at $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(760, 560);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var operated = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: brightness,
              fontFamily: 'Layout Noto CJK',
            ),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: Scaffold(
                body: ManagementTable<String>(
                  id: 'narrow',
                  items: ['/Users/用户/${List.filled(30, '很长的模型目录').join('/')}'],
                  rowKey: (row) => row,
                  searchText: (row) => row,
                  columns: [
                    ManagementColumn(
                      label: '所在目录',
                      minWidth: 500,
                      cell: (row) => Text(
                        row,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ManagementColumn(
                      label: '操作',
                      minWidth: 220,
                      cell: (row) => TextButton(
                        onPressed: () => operated = true,
                        child: const Text('在 Finder 中显示'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.text('在 Finder 中显示'));
        await tester.tap(find.text('在 Finder 中显示'));
        await tester.pump();
        expect(operated, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
