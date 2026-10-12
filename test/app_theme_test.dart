import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final brightness in Brightness.values) {
    test(
      'desktop typography preserves the system font (${brightness.name})',
      () {
        final theme = buildJevTheme(brightness);
        final systemFont = ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.macOS,
          brightness: brightness,
        ).textTheme.bodyMedium!.fontFamily;

        expect(systemFont, isNotNull);
        final styles = <String, TextStyle?>{
          'page title': theme.textTheme.headlineSmall,
          'large title': theme.textTheme.titleLarge,
          'medium title': theme.textTheme.titleMedium,
          'small title': theme.textTheme.titleSmall,
          'large body': theme.textTheme.bodyLarge,
          'medium body': theme.textTheme.bodyMedium,
          'small body': theme.textTheme.bodySmall,
          'large label': theme.textTheme.labelLarge,
          'medium label': theme.textTheme.labelMedium,
          'small label': theme.textTheme.labelSmall,
          'input hint': theme.inputDecorationTheme.hintStyle,
          'input label': theme.inputDecorationTheme.labelStyle,
          'dialog title': theme.dialogTheme.titleTextStyle,
          'dialog body': theme.dialogTheme.contentTextStyle,
          'table header': theme.dataTableTheme.headingTextStyle,
          'table body': theme.dataTableTheme.dataTextStyle,
          'filled button': theme.filledButtonTheme.style?.textStyle?.resolve(
            {},
          ),
          'outlined button': theme.outlinedButtonTheme.style?.textStyle
              ?.resolve({}),
          'text button': theme.textButtonTheme.style?.textStyle?.resolve({}),
        };
        for (final entry in styles.entries) {
          expect(entry.value?.fontFamily, systemFont, reason: entry.key);
        }
      },
    );
  }
}
