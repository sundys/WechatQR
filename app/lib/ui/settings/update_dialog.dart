import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/release_info.dart';
import '../../domain/update_state.dart';
import '../../state/update_controller.dart';

/// Shows the update prompt and keeps it in step with the state machine.
///
/// Every branch here is a presentation of a state the controller already owns;
/// the dialog never decides anything itself, which is what keeps a second
/// download or install from being triggered from the UI (project spec §8.4).
Future<void> showUpdateDialog(BuildContext context, UpdateController update) {
  return showDialog<void>(
    context: context,
    builder: (_) => UpdateDialog(update: update),
  );
}

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({required this.update, super.key});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        if (update.needsInstallPermission) {
          return _dialog(
            context,
            title: '需要安装权限',
            body: const Text(
              '系统未允许本应用安装应用包。请在系统设置中允许“安装未知应用”后重试。'
              '安装仍需在系统界面中确认。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () =>
                    unawaited(update.openInstallPermissionSettings()),
                child: const Text('去设置'),
              ),
            ],
          );
        }

        return switch (update.state) {
          UpdateAvailable(:final release, :final currentVersion) => _dialog(
            context,
            title: '发现新版本 ${release.version}',
            body: _releaseNotes(
              context,
              currentVersion: currentVersion.toString(),
              release: release,
            ),
            actions: [
              TextButton(
                onPressed: () => unawaited(update.ignore()),
                child: const Text('忽略更新'),
              ),
              FilledButton(
                onPressed: () => unawaited(update.download()),
                child: const Text('下载更新'),
              ),
            ],
          ),

          UpdateDownloading(:final receivedBytes, :final totalBytes) => _dialog(
            context,
            title: '正在下载更新',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  // A null value is an indeterminate bar, used when the server
                  // did not report a length.
                  value: totalBytes == null || totalBytes <= 0
                      ? null
                      : (receivedBytes / totalBytes).clamp(0.0, 1.0),
                ),
                const SizedBox(height: 12),
                Text(_progressLabel(receivedBytes, totalBytes)),
                const SizedBox(height: 8),
                const Text('下载在后台进行，退出此窗口不会中断。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  update.cancelDownload();
                  Navigator.of(context).pop();
                },
                child: const Text('取消下载'),
              ),
            ],
          ),

          UpdateDownloadFailed(:final message, :final retryable) => _dialog(
            context,
            title: '下载失败',
            body: Text(retryable ? '$message\n\n可以重试。' : message),
            actions: [
              TextButton(
                onPressed: () {
                  update.dismiss();
                  Navigator.of(context).pop();
                },
                child: const Text('关闭'),
              ),
              if (retryable)
                FilledButton(
                  onPressed: () => unawaited(update.download()),
                  child: const Text('重试'),
                ),
            ],
          ),

          UpdateDownloaded(:final release, :final sizeBytes) => _dialog(
            context,
            title: '下载完成',
            body: Text(
              '${release.version} 的安装包已校验完成'
              '（${_formatBytes(sizeBytes)}）。\n\n'
              '接下来会打开系统安装程序，安装需要您在系统界面中确认。',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  update.dismiss();
                  Navigator.of(context).pop();
                },
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => unawaited(update.install()),
                child: const Text('立即安装'),
              ),
            ],
          ),

          UpdateInstalling() => _dialog(
            context,
            title: '等待系统安装',
            body: const Text('安装程序已打开，请在系统界面中完成安装。安装完成后回到本应用即可。'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),

          UpdateInstallInterrupted() => _dialog(
            context,
            title: '安装未完成',
            body: const Text('上次安装没有完成。已下载的安装包仍保留，可以重新安装。'),
            actions: [
              TextButton(
                onPressed: () {
                  update.dismiss();
                  Navigator.of(context).pop();
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => unawaited(update.install()),
                child: const Text('重新安装'),
              ),
            ],
          ),

          UpdateIgnored(:final release) => _dialog(
            context,
            title: '已忽略该版本',
            body: Text(
              '${release.version} 已被忽略，不会再自动提示。'
              '之后仍可在设置中点按“应用版本”重新检查。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),

          UpdateUpToDate(:final currentVersion) => _dialog(
            context,
            title: '已是最新版本',
            body: Text('当前版本 $currentVersion，没有可用的更新。'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('好'),
              ),
            ],
          ),

          UpdateIdle() || UpdateChecking() => _dialog(
            context,
            title: '正在检查更新',
            body: const LinearProgressIndicator(),
            actions: const <Widget>[],
          ),
        };
      },
    );
  }

  Widget _dialog(
    BuildContext context, {
    required String title,
    required Widget body,
    required List<Widget> actions,
  }) {
    return AlertDialog(
      title: Text(title),
      // Notes and error text can be long; a bounded scroll area keeps the
      // dialog on screen (project spec §13).
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: SingleChildScrollView(child: body),
      ),
      actions: actions,
    );
  }

  Widget _releaseNotes(
    BuildContext context, {
    required String currentVersion,
    required ReleaseInfo release,
  }) {
    final notes = release.notes.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('当前版本：$currentVersion\n最新版本：${release.version}'),
        const SizedBox(height: 12),
        Text(
          notes.isEmpty ? '该版本没有提供更新说明。' : '更新说明',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(notes),
        ],
      ],
    );
  }

  static String _progressLabel(int received, int? total) {
    if (total == null || total <= 0) {
      return '已下载 ${_formatBytes(received)}';
    }
    return '${_formatBytes(received)} / ${_formatBytes(total)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
  }
}
