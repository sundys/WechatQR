/// A parsed semantic version (https://semver.org), used to decide whether a
/// GitHub release is actually newer than the installed build.
///
/// Comparison is deliberately *not* string comparison: `1.10.0` is newer than
/// `1.9.0`, and `1.0.0-rc.1` is older than `1.0.0`.
class SemVersion implements Comparable<SemVersion> {
  const SemVersion({
    required this.major,
    this.minor = 0,
    this.patch = 0,
    this.preRelease = const <String>[],
  });

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated pre-release identifiers, empty for a normal release.
  final List<String> preRelease;

  /// Build metadata (`+build.5`) is parsed but discarded, because the semver
  /// spec excludes it from precedence.
  ///
  /// Accepts a leading version prefix such as `v1.2.3` or `app-v1.2.3`, and
  /// tolerates a missing minor/patch (`1`, `1.2`). Anything else — including a
  /// four-part version like `1.2.3.4` — is rejected so that a malformed tag
  /// can never be mistaken for a valid one.
  static final RegExp _pattern = RegExp(
    r'^[^0-9]*(\d+)(?:\.(\d+))?(?:\.(\d+))?'
    r'(?:-([0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?$',
  );

  static SemVersion? tryParse(String? input) {
    if (input == null) {
      return null;
    }
    final match = _pattern.firstMatch(input.trim());
    if (match == null) {
      return null;
    }

    final major = int.tryParse(match.group(1)!);
    if (major == null) {
      return null;
    }

    return SemVersion(
      major: major,
      minor: _intOrZero(match.group(2)),
      patch: _intOrZero(match.group(3)),
      preRelease: _splitPreRelease(match.group(4)),
    );
  }

  /// Like [tryParse] but throws [FormatException] for unusable input.
  factory SemVersion.parse(String input) {
    final parsed = tryParse(input);
    if (parsed == null) {
      throw FormatException('Not a semantic version', input);
    }
    return parsed;
  }

  bool get isPreRelease => preRelease.isNotEmpty;

  bool isNewerThan(SemVersion other) => compareTo(other) > 0;

  @override
  int compareTo(SemVersion other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    if (patch != other.patch) {
      return patch.compareTo(other.patch);
    }
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// A normal release outranks any pre-release of the same version. Otherwise
  /// identifiers are compared left to right: numeric identifiers numerically,
  /// numeric before alphanumeric, alphanumeric lexically; if all shared
  /// identifiers match, the longer list wins.
  static int _comparePreRelease(List<String> a, List<String> b) {
    if (a.isEmpty && b.isEmpty) {
      return 0;
    }
    if (a.isEmpty) {
      return 1;
    }
    if (b.isEmpty) {
      return -1;
    }

    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      final result = _compareIdentifier(a[i], b[i]);
      if (result != 0) {
        return result;
      }
    }
    return a.length.compareTo(b.length);
  }

  static int _compareIdentifier(String a, String b) {
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    if (aNumber != null && bNumber != null) {
      return aNumber.compareTo(bNumber);
    }
    if (aNumber != null) {
      return -1;
    }
    if (bNumber != null) {
      return 1;
    }
    return a.compareTo(b);
  }

  static int _intOrZero(String? value) => value == null ? 0 : int.parse(value);

  static List<String> _splitPreRelease(String? value) {
    if (value == null || value.isEmpty) {
      return const <String>[];
    }
    return List<String>.unmodifiable(value.split('.'));
  }

  @override
  bool operator ==(Object other) =>
      other is SemVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(preRelease));

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    return isPreRelease ? '$base-${preRelease.join('.')}' : base;
  }
}
