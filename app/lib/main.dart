import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_services/platform_services.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';

import 'app.dart';
import 'data/history_store.dart';
import 'data/settings_store.dart';
import 'data/update_preferences.dart';
import 'services/apk_downloader.dart';
import 'services/clipboard_service.dart';
import 'services/link_opener.dart';
import 'services/release_service.dart';
import 'state/history_controller.dart';
import 'state/scan_controller.dart';
import 'state/settings_controller.dart';
import 'state/update_controller.dart';
import 'ui/settings/third_party_notices.dart';

/// Composition root.
///
/// Every collaborator is constructed here and injected, which is what keeps the
/// controllers testable with fakes.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Attribution for the vendored engine and the CNN models, so Flutter's
  // licence page reports them alongside the package licences.
  ThirdPartyNotices.register();

  final settings = SettingsController(store: SharedPreferencesSettingsStore());
  final history = HistoryController(store: JsonFileHistoryStore());
  await Future.wait<void>([settings.load(), history.load()]);

  final platformServices = MethodChannelPlatformServices();
  final engine = WeChatQrCode();
  const clipboard = SystemClipboardService();
  const linkOpener = UrlLauncherLinkOpener();

  final scan = ScanController(
    engine: engine,
    settings: settings,
    history: history,
    platformServices: platformServices,
    clipboard: clipboard,
    linkOpener: linkOpener,
  );

  final update = UpdateController(
    releaseService: GitHubReleaseService(),
    downloader: ApkDownloader(),
    platformServices: platformServices,
    preferences: SharedPreferencesUpdateStore(),
  );

  // The detector is built before the first frame so the scan tab can start
  // immediately. Failures are captured on the controller and shown in the UI
  // rather than thrown at startup.
  await scan.initializeEngine();

  runApp(
    WeChatQrApp(
      settings: settings,
      history: history,
      scan: scan,
      update: update,
      platformServices: platformServices,
      clipboard: clipboard,
      linkOpener: linkOpener,
    ),
  );

  // Detects a reinstall left pending by a previous session; nothing blocks on it.
  unawaited(update.restorePendingInstall());
}
