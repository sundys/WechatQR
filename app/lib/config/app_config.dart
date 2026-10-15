import '../domain/release_info.dart';

/// Single place for every GitHub/update constant, so repository addresses,
/// API endpoints and asset-matching rules are not scattered through UI code
/// (project spec §8.4).
abstract final class AppConfig {
  /// Display name of the application.
  static const String appName = '二维码';

  /// GitHub account or organisation that hosts the releases.
  static const String githubOwner = 'sundys';

  /// GitHub repository that hosts the releases.
  static const String githubRepo = 'WechatQR';

  /// `true` when a usable repository has been configured.
  ///
  /// Guards the update check so a misconfigured build reports the problem
  /// instead of requesting a repository that does not exist.
  static bool get isConfigured =>
      githubOwner.isNotEmpty &&
      githubRepo.isNotEmpty &&
      githubOwner != 'OWNER' &&
      githubRepo != 'REPO';

  /// Human-facing Releases page. Used by the iOS version row, which only ever
  /// opens the web page (project spec §3.2).
  static Uri get releasesPageUri =>
      Uri.parse('https://github.com/$githubOwner/$githubRepo/releases');

  /// The Releases page as text, for messages that tell the user where to go
  /// when the browser could not be launched.
  static String get releasesPageUrlForDisplay =>
      'https://github.com/$githubOwner/$githubRepo/releases';

  /// Release asset naming convention, produced by `.github/workflows/release.yml`:
  ///
  /// ```
  /// wechatqr-<version>-arm64-v8a.apk
  /// wechatqr-<version>.ipa
  /// ```
  ///
  /// The APK name carries the ABI so that [androidAbiPreference] can match it
  /// and so nobody installs an arm64 package on a device it cannot run on.
  static String androidAssetName(String version) =>
      'wechatqr-$version-arm64-v8a.apk';

  static String iosAssetName(String version) => 'wechatqr-$version.ipa';

  /// Endpoint listing releases, newest first.
  ///
  /// The list endpoint is used rather than `/releases/latest` because that
  /// endpoint reports whatever is newest, which can be a pre-release when the
  /// project publishes one; the spec requires drafts and pre-releases to be
  /// ignored by default, so the newest *stable* entry is selected from this
  /// list instead.
  static Uri releasesApiUri(int perPage) => Uri.parse(
    'https://api.github.com/repos/$githubOwner/$githubRepo/releases'
    '?per_page=$perPage',
  );

  /// Ceiling on how many releases are inspected when looking for the newest
  /// stable one.
  static const int releasePageSize = 30;

  /// Matches Android package files. Case-insensitive because asset naming is
  /// up to the release author.
  static final RegExp androidAssetPattern = RegExp(
    r'\.apk$',
    caseSensitive: false,
  );

  /// Preferred ABI order for picking one APK out of several. The first entry
  /// present in an asset name wins.
  static const List<String> androidAbiPreference = <String>[
    'arm64-v8a',
    'universal',
    'armeabi-v7a',
  ];

  /// Picks the APK to download, or `null` when the release carries none.
  ///
  /// Preference is arm64-v8a first (the ABI this app ships in release builds),
  /// then a universal package, then armeabi-v7a. An APK that matches no
  /// preference is still accepted as a last resort so an unusually named asset
  /// is not silently dropped.
  static ReleaseAsset? selectAndroidAsset(ReleaseInfo release) {
    final candidates = release.assets
        .where((asset) => androidAssetPattern.hasMatch(asset.name))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    for (final abi in androidAbiPreference) {
      for (final asset in candidates) {
        if (asset.name.toLowerCase().contains(abi)) {
          return asset;
        }
      }
    }
    return candidates.first;
  }

  /// Bounds the download size accepted from a release asset, as a defence
  /// against a mis-published or hostile asset. 512 MiB.
  static const int maxDownloadBytes = 512 * 1024 * 1024;
}
