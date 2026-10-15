import 'app_theme_mode.dart';

/// User-controlled scanning and appearance settings.
///
/// Persisted locally only. Defaults follow the project spec's recommended
/// values.
class ScanSettings {
  const ScanSettings({
    this.autoOpenWebsite = false,
    this.continuousScan = true,
    this.autoCopyClipboard = true,
    this.vibrationEnabled = true,
    this.themeMode = AppThemeMode.system,
  });

  /// The spec's recommended defaults, used on first launch and whenever a
  /// stored value is missing or unreadable.
  static const ScanSettings defaults = ScanSettings();

  /// Open validated `http`/`https` URLs in the platform browser as soon as they
  /// are decoded.
  final bool autoOpenWebsite;

  /// Write each distinct decoded payload into the history. When off, scanning
  /// still works and still shows results — it just does not add history rows.
  final bool continuousScan;

  /// Copy each decoded payload to the system clipboard.
  final bool autoCopyClipboard;

  /// Give a short vibration on a successful decode.
  final bool vibrationEnabled;

  final AppThemeMode themeMode;

  ScanSettings copyWith({
    bool? autoOpenWebsite,
    bool? continuousScan,
    bool? autoCopyClipboard,
    bool? vibrationEnabled,
    AppThemeMode? themeMode,
  }) {
    return ScanSettings(
      autoOpenWebsite: autoOpenWebsite ?? this.autoOpenWebsite,
      continuousScan: continuousScan ?? this.continuousScan,
      autoCopyClipboard: autoCopyClipboard ?? this.autoCopyClipboard,
      vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
      themeMode: themeMode ?? this.themeMode,
    );
  }

  Map<String, Object?> toJson() => {
    'autoOpenWebsite': autoOpenWebsite,
    'continuousScan': continuousScan,
    'autoCopyClipboard': autoCopyClipboard,
    'vibrationEnabled': vibrationEnabled,
    'themeMode': themeMode.storageKey,
  };

  /// Rebuilds settings from persisted JSON, falling back to [defaults] for any
  /// missing or mistyped field so a corrupted store cannot brick the app.
  factory ScanSettings.fromJson(Map<String, Object?> json) {
    bool readBool(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    return ScanSettings(
      autoOpenWebsite: readBool('autoOpenWebsite', defaults.autoOpenWebsite),
      continuousScan: readBool('continuousScan', defaults.continuousScan),
      autoCopyClipboard: readBool(
        'autoCopyClipboard',
        defaults.autoCopyClipboard,
      ),
      vibrationEnabled: readBool('vibrationEnabled', defaults.vibrationEnabled),
      themeMode: AppThemeMode.fromStorageKey(json['themeMode']),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ScanSettings &&
        other.autoOpenWebsite == autoOpenWebsite &&
        other.continuousScan == continuousScan &&
        other.autoCopyClipboard == autoCopyClipboard &&
        other.vibrationEnabled == vibrationEnabled &&
        other.themeMode == themeMode;
  }

  @override
  int get hashCode => Object.hash(
    autoOpenWebsite,
    continuousScan,
    autoCopyClipboard,
    vibrationEnabled,
    themeMode,
  );

  @override
  String toString() =>
      'ScanSettings(autoOpenWebsite: $autoOpenWebsite, '
      'continuousScan: $continuousScan, '
      'autoCopyClipboard: $autoCopyClipboard, '
      'vibrationEnabled: $vibrationEnabled, themeMode: ${themeMode.name})';
}
