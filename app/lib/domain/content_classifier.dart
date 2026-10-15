import 'content_type.dart';

/// Describes decoded payloads and decides what may be opened externally.
///
/// Safety rules enforced here (project spec §6.2, §4.8, §11):
///
/// * Only `http` and `https` are ever treated as openable URLs.
/// * Anything with a different but recognisable scheme (`javascript:`,
///   `file:`, `intent:`, `data:`, `content:`, …) is [ContentType.other] and is
///   never opened, never auto-copied into an executable context, and never
///   interpreted as an instruction.
/// * Text that merely *looks* like a URL but does not parse into an absolute
///   URL with a host stays [ContentType.text].
/// * Host display uses the parsed host only, so credentials embedded in a URL
///   (`https://user:pass@evil.example`) cannot masquerade as a trusted name.
///
/// This class performs no I/O and never launches anything; it only classifies
/// and validates.
abstract final class ContentClassifier {
  /// The only schemes the app will hand to the platform browser.
  static const Set<String> openableSchemes = {'http', 'https'};

  /// Classifies [content] for display and storage purposes.
  static ContentType classify(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return ContentType.text;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return ContentType.text;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty) {
      return ContentType.text;
    }

    if (openableSchemes.contains(scheme)) {
      return _hasUsableAuthority(uri) ? ContentType.url : ContentType.text;
    }

    return ContentType.other;
  }

  /// Returns the URL to open for [content], or `null` when nothing should be
  /// opened.
  ///
  /// Callers must treat `null` as "show the payload as text and let the user
  /// copy it" rather than falling back to some other launch mechanism.
  static Uri? browserUri(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return null;
    }

    if (!openableSchemes.contains(uri.scheme.toLowerCase())) {
      return null;
    }

    return _hasUsableAuthority(uri) ? uri : null;
  }

  /// Host (and non-default port) to show next to a link, so the user can see
  /// where a code actually points before opening it. Returns `null` when
  /// [content] is not an openable URL.
  static String? displayHost(String content) {
    final uri = browserUri(content);
    if (uri == null) {
      return null;
    }
    final host = uri.host;
    return uri.hasPort ? '$host:${uri.port}' : host;
  }

  static bool _hasUsableAuthority(Uri uri) =>
      uri.hasAuthority && uri.host.isNotEmpty;
}
