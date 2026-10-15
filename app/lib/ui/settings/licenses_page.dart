import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../services/app_version_service.dart';
import 'third_party_notices.dart';

/// Open-source licence detail screen.
///
/// Lists the components the app actually ships, then hands off to Flutter's
/// licence page for the complete, machine-collected licence bodies — including
/// the ones registered for the vendored WeChatQRCode sources and the CNN models
/// (project spec §8.4).
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('开源许可')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '本应用直接使用以下第三方组件。点击下方按钮可查看完整的许可证文本，'
              '其中包含 WeChatQRCode 本地集成代码与二维码模型文件的版权声明。',
            ),
          ),
          const Divider(height: 24),

          for (final component in ThirdPartyNotices.components)
            _ComponentTile(component: component),

          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '模型文件校验值',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SelectableText(
              ThirdPartyNotices.modelProvenance,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: () => unawaited(_openFlutterLicensePage(context)),
              icon: const Icon(Icons.description_outlined),
              label: const Text('查看完整许可证文本'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openFlutterLicensePage(BuildContext context) async {
    String version = '';
    try {
      final installed = await readInstalledVersion();
      version = installed.version;
    } catch (_) {
      // A missing version must not block reading the licences.
    }
    if (!context.mounted) {
      return;
    }
    showLicensePage(
      context: context,
      applicationName: AppConfig.appName,
      applicationVersion: version,
      applicationLegalese:
          '包含 WeChatQRCode、WeChat QRCode 模型与 OpenCV，'
          '均以 Apache-2.0 许可分发。',
    );
  }
}

class _ComponentTile extends StatelessWidget {
  const _ComponentTile({required this.component});

  final ThirdPartyComponent component;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      title: Text(component.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${component.version} · ${component.license}'),
            const SizedBox(height: 2),
            Text(component.copyright, style: theme.textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(component.purpose, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      isThreeLine: true,
    );
  }
}
