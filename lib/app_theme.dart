import 'package:flutter/material.dart';

ThemeData buildJevTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? const ColorScheme.dark(
          primary: Color(0xFF79AFFF),
          secondary: Color(0xFF79AFFF),
          onPrimary: Color(0xFF0C1626),
          surface: Color(0xFF202123),
          onSurface: Color(0xFFF0F0F1),
          onSurfaceVariant: Color(0xFF96989D),
          outline: Color(0xFF45474B),
          outlineVariant: Color(0xFF303236),
          surfaceContainer: Color(0xFF18191B),
          surfaceContainerLow: Color(0xFF26272A),
          surfaceContainerHigh: Color(0xFF2C2D30),
          error: Color(0xFFFF8A8A),
        )
      : const ColorScheme.light(
          primary: Color(0xFF286AE6),
          secondary: Color(0xFF286AE6),
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: Color(0xFF222327),
          onSurfaceVariant: Color(0xFF747983),
          outline: Color(0xFFD1D3D8),
          outlineVariant: Color(0xFFE5E6E9),
          surfaceContainer: Color(0xFFFAFAFB),
          surfaceContainerLow: Color(0xFFF3F4F6),
          surfaceContainerHigh: Color(0xFFEDEEF0),
          error: Color(0xFFD64747),
        );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );
  final text = base.textTheme.copyWith(
    headlineSmall: TextStyle(
      fontSize: 24,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    titleMedium: TextStyle(
      fontSize: 15,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    titleSmall: TextStyle(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    bodyLarge: TextStyle(fontSize: 14, height: 1.5, color: scheme.onSurface),
    bodyMedium: TextStyle(fontSize: 13, height: 1.5, color: scheme.onSurface),
    bodySmall: TextStyle(
      fontSize: 12,
      height: 1.45,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: const TextStyle(
      fontSize: 13,
      height: 1.25,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      height: 1.3,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    ),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surfaceContainer,
    visualDensity: VisualDensity.compact,
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surface,
      hintStyle: TextStyle(
        fontSize: 13,
        color: dark ? const Color(0xFF8A8E96) : const Color(0xFF9499A2),
      ),
      labelStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1.3),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(72, 36),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(72, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        side: BorderSide(color: scheme.outline),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(56, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        iconSize: 18,
        minimumSize: const Size(32, 32),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      titleTextStyle: text.titleMedium?.copyWith(fontSize: 20),
      contentTextStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: text.labelMedium,
      dataTextStyle: text.bodyMedium,
      headingRowHeight: 38,
      dataRowMinHeight: 54,
      dataRowMaxHeight: 64,
      dividerThickness: 1,
      horizontalMargin: 16,
      columnSpacing: 24,
    ),
  );
}

class JevPageHeader extends StatelessWidget {
  const JevPageHeader({super.key, required this.title, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const Spacer(),
        ?action,
      ],
    ),
  );
}

class JevSurface extends StatelessWidget {
  const JevSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

enum JevStatusTone { neutral, success, warning, error }

class JevStatusChip extends StatelessWidget {
  const JevStatusChip({
    super.key,
    required this.label,
    this.tone = JevStatusTone.neutral,
  });
  final String label;
  final JevStatusTone tone;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (tone) {
      JevStatusTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
      JevStatusTone.success =>
        dark ? const Color(0xFF77D6A5) : const Color(0xFF218854),
      JevStatusTone.warning =>
        dark ? const Color(0xFFE9BC72) : const Color(0xFFA16B19),
      JevStatusTone.error => Theme.of(context).colorScheme.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .12 : .08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
