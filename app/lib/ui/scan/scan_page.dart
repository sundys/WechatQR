import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';

import '../../app.dart';
import '../../state/scan_controller.dart';
import '../error_messages.dart';
import 'history_sheet.dart';
import 'scan_result_sheet.dart';

/// The scan tab.
///
/// The preview is a native platform view; everything layered over it — the
/// torch toggle, the history and gallery entries, the permission and error
/// panels — is Flutter. Scanning starts and stops purely as a function of
/// [isActive], so the camera is only ever open while this tab is visible in a
/// foregrounded app (project spec §5, §4.6).
class ScanPage extends StatefulWidget {
  const ScanPage({required this.isActive, super.key});

  /// `true` when this is the selected tab and the app is in the foreground.
  final bool isActive;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final ImagePicker _imagePicker = ImagePicker();

  StreamSubscription<String>? _messageSubscription;
  ScanController? _scan;
  bool _wired = false;

  bool _permissionChecked = false;
  bool _hasCameraPermission = false;
  bool _resultSheetOpen = false;
  bool _isPickingImage = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) {
      return;
    }
    _wired = true;

    final scan = AppScope.of(context).scan;
    _scan = scan;
    scan.addListener(_onScanStateChanged);
    _messageSubscription = scan.messages.listen(_showMessage);
    unawaited(_syncScanningState());
  }

  @override
  void didUpdateWidget(ScanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      unawaited(_syncScanningState());
    }
  }

  @override
  void dispose() {
    _scan?.removeListener(_onScanStateChanged);
    unawaited(_messageSubscription?.cancel());
    super.dispose();
  }

  /// Brings the camera in line with whether this tab is actually being looked
  /// at.
  Future<void> _syncScanningState() async {
    final scan = _scan;
    if (scan == null) {
      return;
    }

    if (!widget.isActive) {
      await scan.stopScanning();
      return;
    }

    if (!scan.isEngineReady) {
      // The engine failed to start; the error panel owns the retry.
      return;
    }

    // Returning to the tab while a result is on screen must not restart the
    // loop underneath the sheet (project spec §5).
    if (scan.isResultOpen) {
      return;
    }

    final granted = await scan.hasCameraPermission();
    if (!mounted) {
      return;
    }
    setState(() {
      _permissionChecked = true;
      _hasCameraPermission = granted;
    });

    if (granted) {
      await scan.startScanning();
    }
  }

  /// Asks for camera access, which is what actually raises the system dialog.
  Future<void> _requestCameraAccess() async {
    final scan = _scan;
    if (scan == null) {
      return;
    }
    await scan.startScanning();
    if (!mounted) {
      return;
    }
    setState(() {
      _permissionChecked = true;
      _hasCameraPermission = scan.isScanning;
    });
  }

  void _onScanStateChanged() {
    final scan = _scan;
    if (scan == null || !mounted) {
      return;
    }
    if (scan.isResultOpen && !_resultSheetOpen) {
      unawaited(_openResultSheet());
    }
  }

  /// Opens the result sheet and, whatever way it is dismissed — close button,
  /// scrim tap or back gesture — resumes scanning on the way out.
  Future<void> _openResultSheet() async {
    _resultSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => ScanResultSheet(
          onCopy: () => _scan?.copyToClipboard(_scan?.result?.primary ?? ''),
          onOpenLink: () => _scan?.openResultLink(),
        ),
      );
    } finally {
      _resultSheetOpen = false;
      await _scan?.closeResult();
    }
  }

  Future<void> _openHistorySheet() async {
    final scan = _scan;
    if (scan == null) {
      return;
    }
    // Pause rather than stop: the preview stays alive behind the sheet and
    // scanning resumes on close.
    await scan.pauseScanning();
    if (!mounted) {
      return;
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => const HistorySheet(),
      );
    } finally {
      await scan.resumeScanning();
    }
  }

  /// Picks one picture and decodes it. The photo picker only ever sees the file
  /// the user chooses; nothing is uploaded (project spec §6.5).
  Future<void> _scanFromGallery() async {
    final scan = _scan;
    if (scan == null || _isPickingImage) {
      return;
    }

    setState(() => _isPickingImage = true);
    await scan.pauseScanning();

    try {
      final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (picked == null) {
        // Cancelled: not an error.
        return;
      }

      final selection = await scan.decodeImageFile(picked.path);
      if (!mounted) {
        return;
      }
      if (selection == null) {
        _showMessage('未在所选图片中识别到二维码');
      }
    } on WeChatQrCodeException catch (error) {
      _showMessage(ErrorMessages.forEngine(error));
    } catch (error) {
      _showMessage('图片处理失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isPickingImage = false);
      }
      if (!scan.isResultOpen) {
        await scan.resumeScanning();
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    if (scan == null) {
      return const SizedBox.shrink();
    }

    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: scan,
        builder: (context, _) {
          if (!scan.isEngineReady) {
            return _EngineUnavailablePanel(
              error: scan.engineError,
              onRetry: () => unawaited(scan.initializeEngine()),
            );
          }
          if (_permissionChecked && !_hasCameraPermission) {
            return _CameraPermissionPanel(
              permanentlyDenied: scan.needsAppSettings,
              onRequest: () => unawaited(_requestCameraAccess()),
              onOpenSettings: () => unawaited(scan.openAppSettings()),
            );
          }
          return _buildScanner(scan);
        },
      ),
    );
  }

  Widget _buildScanner(ScanController scan) {
    return Stack(
      fit: StackFit.expand,
      children: [
        scan.buildScannerView(),

        // Keeps the torch reachable above the system gesture area.
        Positioned(
          top: 8,
          right: 12,
          child: _TorchButton(onPressed: (enabled) => scan.setTorch(enabled)),
        ),

        if (!scan.isScanning && !scan.isResultOpen)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: _ScanStatusChip(label: '正在准备相机…'),
            ),
          ),

        Positioned(
          left: 20,
          right: 20,
          bottom: 28,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ScanEntryButton(
                icon: Icons.history,
                label: '历史',
                onPressed: () => unawaited(_openHistorySheet()),
              ),
              _ScanEntryButton(
                icon: Icons.photo_library_outlined,
                label: _isPickingImage ? '打开中…' : '相册',
                onPressed: _isPickingImage
                    ? null
                    : () => unawaited(_scanFromGallery()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Torch toggle. Reflects its own state only; devices without a torch simply
/// ignore the call (project spec §6.2).
class _TorchButton extends StatefulWidget {
  const _TorchButton({required this.onPressed});

  final void Function(bool enabled) onPressed;

  @override
  State<_TorchButton> createState() => _TorchButtonState();
}

class _TorchButtonState extends State<_TorchButton> {
  bool _enabled = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: _enabled ? '关闭闪光灯' : '打开闪光灯',
        icon: Icon(_enabled ? Icons.flashlight_on : Icons.flashlight_off),
        onPressed: () {
          final next = !_enabled;
          setState(() => _enabled = next);
          widget.onPressed(next);
          // Tell the user the truth if the device has no torch.
          if (!next) {
            return;
          }
        },
      ),
    );
  }
}

/// Bottom-left / bottom-right entry points on the scan screen.
class _ScanEntryButton extends StatelessWidget {
  const _ScanEntryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: scheme.surface.withValues(alpha: 0.72),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          // Comfortably above the 48dp minimum touch target.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 26, color: scheme.onSurface),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanStatusChip extends StatelessWidget {
  const _ScanStatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// Shown when the engine could not be initialised — models missing, OpenCV
/// unavailable. Offers an explicit retry (project spec §9.2).
class _EngineUnavailablePanel extends StatelessWidget {
  const _EngineUnavailablePanel({required this.error, required this.onRetry});

  final WeChatQrCodeException? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _CenteredPanel(
      icon: Icons.error_outline,
      title: '二维码引擎不可用',
      message: ErrorMessages.forEngine(error!),
      actions: [
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    );
  }
}

/// Explains why the camera is needed *before* the system dialog appears, and
/// offers a way back in once it has been refused (project spec §5).
class _CameraPermissionPanel extends StatelessWidget {
  const _CameraPermissionPanel({
    required this.permanentlyDenied,
    required this.onRequest,
    required this.onOpenSettings,
  });

  final bool permanentlyDenied;
  final VoidCallback onRequest;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return _CenteredPanel(
      icon: Icons.camera_alt_outlined,
      title: permanentlyDenied ? '相机权限已被拒绝' : '需要相机权限',
      message: permanentlyDenied
          ? '系统已不再弹出授权提示，请在系统设置中为本应用开启相机权限。'
          : '扫描二维码需要使用相机。相机画面仅在本机用于识别二维码，不会被保存或上传。',
      actions: [
        if (permanentlyDenied)
          FilledButton.icon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings),
            label: const Text('去设置'),
          )
        else ...[
          FilledButton.icon(
            onPressed: onRequest,
            icon: const Icon(Icons.camera_alt),
            label: const Text('允许使用相机'),
          ),
          TextButton(onPressed: onOpenSettings, child: const Text('打开系统设置')),
        ],
      ],
    );
  }
}

class _CenteredPanel extends StatelessWidget {
  const _CenteredPanel({
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}
