import 'sem_version.dart';

/// A downloadable file attached to a GitHub release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.sizeBytes,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;

  /// Advertised size in bytes, used to detect a truncated download. May be
  /// absent in the API response.
  final int? sizeBytes;

  /// Lower-case hex SHA-256 from the release asset `digest` field, when GitHub
  /// supplies one. Used to verify a downloaded APK before installation.
  final String? sha256;

  @override
  String toString() =>
      'ReleaseAsset(name: $name, sizeBytes: $sizeBytes, '
      'sha256: ${sha256 == null ? 'none' : 'present'})';
}

/// A stable GitHub release, reduced to what the update flow needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    required this.assets,
    this.publishedAt,
  });

  final SemVersion version;

  /// Raw tag as published, kept so messages can show exactly what the upstream
  /// project named the release.
  final String tagName;
  final String title;
  final String notes;
  final Uri htmlUrl;
  final List<ReleaseAsset> assets;
  final DateTime? publishedAt;

  /// Parses one release object from the GitHub Releases API.
  ///
  /// Returns `null` when the object cannot be used — missing/unparsable tag,
  /// missing download page URL, or no usable asset URLs — so callers can report
  /// a clear "response format unexpected" error instead of proceeding with
  /// partial data.
  static ReleaseInfo? fromGitHubJson(Object? json) {
    if (json is! Map) {
      return null;
    }

    final tagName = json['tag_name'];
    if (tagName is! String) {
      return null;
    }
    final version = SemVersion.tryParse(tagName);
    if (version == null) {
      return null;
    }

    final htmlUrl = _parseUri(json['html_url']);
    if (htmlUrl == null) {
      return null;
    }

    final assets = <ReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final rawAsset in rawAssets) {
        final asset = _parseAsset(rawAsset);
        if (asset != null) {
          assets.add(asset);
        }
      }
    }

    return ReleaseInfo(
      version: version,
      tagName: tagName,
      title: _stringOr(json['name'], tagName),
      notes: _stringOr(json['body'], ''),
      htmlUrl: htmlUrl,
      assets: List<ReleaseAsset>.unmodifiable(assets),
      publishedAt: _parseDate(json['published_at']),
    );
  }

  static ReleaseAsset? _parseAsset(Object? json) {
    if (json is! Map) {
      return null;
    }
    final name = json['name'];
    final downloadUrl = _parseUri(json['browser_download_url']);
    if (name is! String || name.isEmpty || downloadUrl == null) {
      return null;
    }
    return ReleaseAsset(
      name: name,
      downloadUrl: downloadUrl,
      sizeBytes: json['size'] is int ? json['size'] as int : null,
      sha256: _parseSha256Digest(json['digest']),
    );
  }

  /// GitHub reports asset digests as `"sha256:<hex>"`. Anything of another
  /// shape is ignored rather than guessed at.
  static String? _parseSha256Digest(Object? digest) {
    if (digest is! String) {
      return null;
    }
    const prefix = 'sha256:';
    if (!digest.toLowerCase().startsWith(prefix)) {
      return null;
    }
    final hex = digest.substring(prefix.length).trim().toLowerCase();
    if (hex.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      return null;
    }
    return hex;
  }

  static Uri? _parseUri(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    return uri;
  }

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static String _stringOr(Object? value, String fallback) =>
      value is String && value.isNotEmpty ? value : fallback;

  @override
  String toString() => 'ReleaseInfo($tagName, assets: ${assets.length})';
}
