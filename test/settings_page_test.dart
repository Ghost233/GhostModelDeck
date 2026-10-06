import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/settings_page.dart';

void main() {
  testWidgets(
    'the complete shared library path is visible on hover at minimum desktop size',
    (tester) async {
      const path =
          '/Users/model-owner/Library/Application Support/shared-with-LM-Studio/models/a-very-long-model-library-directory/another-long-component/full-location';
      tester.view.physicalSize = const Size(900, 560);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final preferences = DownloadPreferences(
        file: File('/unused-download-preferences.json'),
      );
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJevTheme(Brightness.light),
          home: Scaffold(
            body: SettingsPage(
              preferences: preferences,
              libraryPath: path,
              onLibraryPathChanged: (value) async => value,
              pickLibraryDirectory: () async => null,
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text(path)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        find.text(path),
        findsNWidgets(2),
        reason: 'Hover reveals the complete path alongside the truncated row',
      );
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );

  testWidgets('two-pane shell switches between 常规 and 软件更新', (tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = DownloadPreferences(
      file: File('/unused-download-preferences.json'),
    );
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildJevTheme(Brightness.light),
        home: Scaffold(
          body: SettingsPage(
            preferences: preferences,
            libraryPath: '/tmp/library',
            onLibraryPathChanged: (value) async => value,
            pickLibraryDirectory: () async => null,
          ),
        ),
      ),
    );
    // 默认落在「常规」面板，原有设置内容保持可见。
    expect(find.text('默认下载来源'), findsOneWidget);
    expect(find.text('选择目录'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-current-version')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-nav-update')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-current-version')),
      findsOneWidget,
    );
    expect(find.text('默认下载来源'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-nav-general')));
    await tester.pumpAndSettle();
    expect(find.text('默认下载来源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
