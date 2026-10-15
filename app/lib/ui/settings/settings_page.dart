import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../config/app_config.dart';
import '../../domain/app_theme_mode.dart';
import '../../services/app_version_service.dart';
import '../../state/settings_controller.dart';
import '../../domain/update_state.dart';
import '../error_messages.dart';
import '../theme.dart';
import 'about_dialog.dart';
import 'licenses_page.dart';
import 'update_dialog.dart';

/// The settings tab: grouped rows, each with a leading icon and a trailing
/// switch, value or chevron.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _wired = false;
  InstalledVersion? _version;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) {
      return;
    }
    _wired = true;
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final version = await AppScope.of(context).update.currentVersion();
      if (mounted) {
        setState(() => _version = version);
      }
    } catch (_) {
      // The row simply shows an unknown version rather than failing the page.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: scope.settings,
        builder: (context, _) {
          final settings = scope.settings;

          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const _SectionHeader('通用'),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('主题'),
                subtitle: Text(settings.settings.themeMode.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(_chooseTheme(settings)),
              ),

              const _SectionHeader('扫描控制'),
              SwitchListTile(
                secondary: const Icon(Icons.public),
                title: const Text('自动打开网站'),
                subtitle: const Text('识别到合法的 http/https 网址时自动打开'),
                value: settings.settings.autoOpenWebsite,
                onChanged: settings.setAutoOpenWebsite,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.qr_code_scanner),
                title: const Text('连续扫描'),
                subtitle: const Text('将不同的识别结果写入历史记录'),
                value: settings.settings.continuousScan,
                onChanged: settings.setContinuousScan,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.copy_all_outlined),
                title: const Text('自动复制剪贴板'),
                subtitle: const Text('识别成功后复制二维码内容'),
                value: settings.settings.autoCopyClipboard,
                onChanged: settings.setAutoCopyClipboard,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.vibration),
                title: const Text('振动'),
                subtitle: const Text('识别成功时短振动提示'),
                value: settings.settings.vibrationEnabled,
                onChanged: settings.setVibrationEnabled,
              ),

              const _SectionHeader('关于'),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('介绍'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(showAboutAppDialog(context)),
              ),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('开源许可'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LicensesPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('应用版本'),
                subtitle: Text(_versionSubtitle()),
                trailing: _versionTrailing(),
                onTap: () => unawaited(_onVersionTapped()),
              ),
            ],
          );
        },
      ),
    );
  }

  String _versionSubtitle() {
    final version = _version;
    if (version == null) {
      return '读取中…';
    }
    final build = version.buildNumber.isEmpty
        ? ''
        : ' (${version.buildNumber})';
    return '${version.version}$build';
  }

  Widget _versionTrailing() {
    final update = AppScope.of(context).update;
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        if (update.state is UpdateChecking) {
          return const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        // iOS has no APK installation path; the row only opens the release page
        // there, so the chevron is the honest affordance.
        return Icon(
          defaultTargetPlatform == TargetPlatform.iOS
              ? Icons.open_in_new
              : Icons.refresh,
        );
      },
    );
  }

  Future<void> _chooseTheme(SettingsController settings) async {
    final selected = await showDialog<AppThemeMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('主题'),
        children: [
          for (final mode in AppThemeMode.values)
            ListTile(
              title: Text(mode.label),
              // Selection is shown by an icon and the checked state, not by
              // colour alone (project spec §13).
              trailing: mode == settings.settings.themeMode
                  ? Icon(
                      Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary,
                    )
                  : null,
              selected: mode == settings.settings.themeMode,
              onTap: () => Navigator.of(dialogContext).pop(mode),
            ),
        ],
      ),
    );

    if (selected != null) {
      await settings.setThemeMode(selected);
    }
  }

  /// Android checks for a new release; iOS just opens the Releases page, since
  /// there is no in-app install path there (project spec §3.2, §8.4).
  Future<void> _onVersionTapped() async {
    final scope = AppScope.of(context);

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final opened = await scope.linkOpener.open(AppConfig.releasesPageUri);
      if (!opened && mounted) {
        _notify('无法打开发布页面，请手动访问 ${AppConfig.releasesPageUrlForDisplay}');
      }
      return;
    }

    final update = scope.update;
    await update.check(manual: true);
    if (!mounted) {
      return;
    }

    final failure = update.lastCheckFailure;
    if (failure != null && update.state is UpdateIdle) {
      _notify(ErrorMessages.forReleaseCheck(failure));
      return;
    }

    switch (update.state) {
      case UpdateAvailable():
      case UpdateDownloadFailed():
      case UpdateDownloaded():
      case UpdateInstalling():
      case UpdateInstallInterrupted():
      case UpdateDownloading():
        await showUpdateDialog(context, update);
      case UpdateUpToDate():
        _notify('已是最新版本');
      case UpdateIdle():
      case UpdateChecking():
      case UpdateIgnored():
        break;
    }
  }

  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
