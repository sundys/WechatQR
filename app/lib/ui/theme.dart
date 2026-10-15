import 'package:flutter/material.dart';

import '../domain/app_theme_mode.dart';

/// Material 3 colour schemes for the light and dark themes.
///
/// One seed drives both schemes, so every page, dialog, sheet, switch and input
/// shares the same palette in either mode (project spec §8.1, §13).
abstract final class AppTheme {
  /// Seed colour for the palette.
  static const Color seed = Color(0xFF07C160);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Keeps rows and touch targets at a comfortable size on every screen
      // density (project spec §13).
      visualDensity: VisualDensity.standard,
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
    );
  }
}

extension AppThemeModeX on AppThemeMode {
  ThemeMode toFlutterThemeMode() => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  String get label => switch (this) {
    AppThemeMode.system => '跟随系统',
    AppThemeMode.light => '浅色',
    AppThemeMode.dark => '暗色',
  };
}
