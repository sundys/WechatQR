import 'package:package_info_plus/package_info_plus.dart';

import '../domain/sem_version.dart';

/// The version the running build reports, read from package metadata rather
/// than hardcoded (project spec §8.4).
class InstalledVersion {
  const InstalledVersion({
    required this.version,
    required this.buildNumber,
    required this.packageName,
  });

  /// `CFBundleShortVersionString` / Android `versionName`.
  final String version;

  /// `CFBundleVersion` / Android `versionCode` as a string.
  final String buildNumber;

  final String packageName;

  /// Parsed form of [version]; `null` when the build metadata is not a version
  /// this app can compare, in which case update checks report that rather than
  /// guessing.
  SemVersion? get parsed => SemVersion.tryParse(version);

  @override
  String toString() => '$version+$buildNumber';
}

typedef InstalledVersionProvider = Future<InstalledVersion> Function();

/// Reads the version from the platform package metadata.
Future<InstalledVersion> readInstalledVersion() async {
  final info = await PackageInfo.fromPlatform();
  return InstalledVersion(
    version: info.version,
    buildNumber: info.buildNumber,
    packageName: info.packageName,
  );
}
