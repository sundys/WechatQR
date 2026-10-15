/// App-wide theme preference.
///
/// Named `AppThemeMode` rather than `ThemeMode` to stay unambiguous next to
/// Flutter's own `ThemeMode` from `package:flutter/material.dart`, which the UI
/// layer maps this onto.
enum AppThemeMode {
  /// Follow the operating system setting and react to changes while running.
  system,

  /// Always use the light colour scheme.
  light,

  /// Always use the dark colour scheme.
  dark;

  /// Stable identifier used for persistence. Never persist [Enum.index] or
  /// [Enum.name] directly at a call site; go through these helpers so renaming
  /// an enum constant cannot silently corrupt stored settings.
  String get storageKey => name;

  static AppThemeMode fromStorageKey(Object? value) {
    for (final mode in AppThemeMode.values) {
      if (mode.storageKey == value) {
        return mode;
      }
    }
    return AppThemeMode.system;
  }
}
