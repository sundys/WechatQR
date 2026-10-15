import 'package:url_launcher/url_launcher.dart';

/// Opens external links through the platform's own browser.
///
/// Wrapped behind an interface so the scan flow — the part that decides
/// *whether* a link may be opened — is testable without a platform channel.
abstract interface class LinkOpener {
  /// Opens [uri]. Returns `false` when the platform could not handle it, so the
  /// caller can keep the decoded content on screen and tell the user to copy or
  /// open it manually (project spec §13).
  ///
  /// Callers must only pass URIs that passed
  /// `ContentClassifier.browserUri`; this class does not re-validate, and it
  /// deliberately offers no way to launch a non-`http(s)` scheme.
  Future<bool> open(Uri uri);
}

class UrlLauncherLinkOpener implements LinkOpener {
  const UrlLauncherLinkOpener();

  @override
  Future<bool> open(Uri uri) async {
    try {
      // inAppBrowserView maps to Chrome Custom Tabs on Android and to
      // SFSafariViewController on iOS; both fall back to the system browser
      // when unavailable (project spec §6.2).
      final launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      if (launched) {
        return true;
      }
      // Custom Tabs unavailable — retry with the plain system browser.
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
