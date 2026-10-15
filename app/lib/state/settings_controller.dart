import 'package:flutter/foundation.dart';

import '../data/settings_store.dart';
import '../domain/app_theme_mode.dart';
import '../domain/scan_settings.dart';

/// Holds the current [ScanSettings] and writes every change through to storage.
///
/// Changes take effect in memory first and are then persisted, so switches
/// respond immediately; a persistence failure is recorded in
/// [persistenceError] instead of being swallowed (project spec §4.7) or
/// reverting a switch the user just flipped.
class SettingsController extends ChangeNotifier {
  SettingsController({required this._store, ScanSettings? initial})
    : _settings = initial ?? ScanSettings.defaults;

  final SettingsStore _store;
  ScanSettings _settings;

  ScanSettings get settings => _settings;

  /// Set when the last persist attempt failed; cleared on the next success.
  Object? _persistenceError;
  Object? get persistenceError => _persistenceError;

  /// Loads persisted settings. Safe to call more than once.
  Future<void> load() async {
    try {
      final stored = await _store.load();
      if (stored == null || stored == _settings) {
        return;
      }
      _settings = stored;
      notifyListeners();
    } catch (error) {
      _persistenceError = error;
      notifyListeners();
    }
  }

  Future<void> setAutoOpenWebsite(bool value) =>
      _update(_settings.copyWith(autoOpenWebsite: value));

  Future<void> setContinuousScan(bool value) =>
      _update(_settings.copyWith(continuousScan: value));

  Future<void> setAutoCopyClipboard(bool value) =>
      _update(_settings.copyWith(autoCopyClipboard: value));

  Future<void> setVibrationEnabled(bool value) =>
      _update(_settings.copyWith(vibrationEnabled: value));

  Future<void> setThemeMode(AppThemeMode value) =>
      _update(_settings.copyWith(themeMode: value));

  Future<void> _update(ScanSettings next) async {
    if (next == _settings) {
      return;
    }
    _settings = next;
    notifyListeners();

    try {
      await _store.save(next);
      if (_persistenceError != null) {
        _persistenceError = null;
        notifyListeners();
      }
    } catch (error) {
      _persistenceError = error;
      notifyListeners();
    }
  }
}
