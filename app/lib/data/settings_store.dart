import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/scan_settings.dart';

/// Persistence boundary for [ScanSettings].
///
/// An interface rather than a concrete class so the settings controller can be
/// tested without touching platform channels.
abstract interface class SettingsStore {
  /// Returns the stored settings, or `null` on first launch / when the stored
  /// value is unreadable.
  Future<ScanSettings?> load();

  Future<void> save(ScanSettings settings);
}

/// Stores settings as a single JSON string in `shared_preferences`.
///
/// One key holding one document keeps a settings change atomic — there is no
/// window in which half of a change is visible.
class SharedPreferencesSettingsStore implements SettingsStore {
  SharedPreferencesSettingsStore();

  static const String storageKey = 'scan_settings_v1';

  @override
  Future<ScanSettings?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return ScanSettings.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      // A corrupted document falls back to defaults instead of crashing.
      return null;
    }
  }

  @override
  Future<void> save(ScanSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(settings.toJson()));
  }
}
