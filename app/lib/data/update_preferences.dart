import 'package:shared_preferences/shared_preferences.dart';

/// An APK handed to the system installer that has not been confirmed installed
/// yet.
class PendingInstall {
  const PendingInstall({required this.filePath, required this.versionTag});

  final String filePath;

  /// Release tag the APK came from, compared against the installed version when
  /// the app resumes to decide whether the install went through.
  final String versionTag;

  @override
  bool operator ==(Object other) =>
      other is PendingInstall &&
      other.filePath == filePath &&
      other.versionTag == versionTag;

  @override
  int get hashCode => Object.hash(filePath, versionTag);
}

/// Small persisted bits of the update flow.
abstract interface class UpdatePreferencesStore {
  /// Release tag the user asked to skip, or `null`.
  Future<String?> ignoredVersionTag();

  Future<void> setIgnoredVersionTag(String? tag);

  Future<PendingInstall?> pendingInstall();

  Future<void> setPendingInstall(PendingInstall? pending);
}

class SharedPreferencesUpdateStore implements UpdatePreferencesStore {
  static const String _ignoredKey = 'update_ignored_version_v1';
  static const String _pendingPathKey = 'update_pending_apk_path_v1';
  static const String _pendingTagKey = 'update_pending_apk_tag_v1';

  @override
  Future<String?> ignoredVersionTag() async {
    final preferences = await SharedPreferences.getInstance();
    final tag = preferences.getString(_ignoredKey);
    return (tag == null || tag.isEmpty) ? null : tag;
  }

  @override
  Future<void> setIgnoredVersionTag(String? tag) async {
    final preferences = await SharedPreferences.getInstance();
    if (tag == null || tag.isEmpty) {
      await preferences.remove(_ignoredKey);
    } else {
      await preferences.setString(_ignoredKey, tag);
    }
  }

  @override
  Future<PendingInstall?> pendingInstall() async {
    final preferences = await SharedPreferences.getInstance();
    final path = preferences.getString(_pendingPathKey);
    final tag = preferences.getString(_pendingTagKey);
    if (path == null || path.isEmpty || tag == null || tag.isEmpty) {
      return null;
    }
    return PendingInstall(filePath: path, versionTag: tag);
  }

  @override
  Future<void> setPendingInstall(PendingInstall? pending) async {
    final preferences = await SharedPreferences.getInstance();
    if (pending == null) {
      await preferences.remove(_pendingPathKey);
      await preferences.remove(_pendingTagKey);
      return;
    }
    await preferences.setString(_pendingPathKey, pending.filePath);
    await preferences.setString(_pendingTagKey, pending.versionTag);
  }
}
