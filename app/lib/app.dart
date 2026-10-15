import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:platform_services/platform_services.dart';

import 'config/app_config.dart';
import 'services/clipboard_service.dart';
import 'services/link_opener.dart';
import 'state/history_controller.dart';
import 'state/scan_controller.dart';
import 'state/settings_controller.dart';
import 'state/update_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

/// Provides the application's controllers to the widget tree.
///
/// `updateShouldNotify` is `false` because the controller identities never
/// change; widgets that need to react to state listen to the individual
/// controllers instead, which keeps rebuilds scoped.
class AppScope extends InheritedWidget {
  const AppScope({
    required this.settings,
    required this.history,
    required this.scan,
    required this.update,
    required this.platformServices,
    required this.clipboard,
    required this.linkOpener,
    required super.child,
    super.key,
  });

  final SettingsController settings;
  final HistoryController history;
  final ScanController scan;
  final UpdateController update;
  final PlatformServices platformServices;

  /// Shared with the generate page, which needs paste access. Kept on the scope
  /// so exactly one object touches the system clipboard.
  final ClipboardService clipboard;

  /// Shared with the settings screen, which opens the Releases page on iOS.
  final LinkOpener linkOpener;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope.of() requires a WeChatQrApp ancestor.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

class WeChatQrApp extends StatelessWidget {
  const WeChatQrApp({
    required this.settings,
    required this.history,
    required this.scan,
    required this.update,
    required this.platformServices,
    required this.clipboard,
    required this.linkOpener,
    super.key,
  });

  final SettingsController settings;
  final HistoryController history;
  final ScanController scan;
  final UpdateController update;
  final PlatformServices platformServices;
  final ClipboardService clipboard;
  final LinkOpener linkOpener;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      history: history,
      scan: scan,
      update: update,
      platformServices: platformServices,
      clipboard: clipboard,
      linkOpener: linkOpener,
      // Rebuilds only when the theme selection changes; the settings page and
      // every dialog read their colours from the same scheme.
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return MaterialApp(
            title: AppConfig.appName,
            debugShowCheckedModeBanner: false,
            // The interface is Chinese-only, so the built-in widget strings are
            // pinned to Chinese too. Leaving this to the device locale produced
            // English long-press menus ("Copy", "Select all", "Paste") next to
            // Chinese screens.
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            themeMode: settings.settings.themeMode.toFlutterThemeMode(),
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            home: const AppShell(),
          );
        },
      ),
    );
  }
}
