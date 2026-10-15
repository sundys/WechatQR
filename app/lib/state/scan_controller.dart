import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:platform_services/platform_services.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';

import '../domain/content_classifier.dart';
import '../domain/scan_dedup.dart';
import '../domain/scan_result_policy.dart';
import '../domain/scan_source.dart';
import '../services/clipboard_service.dart';
import '../services/link_opener.dart';
import 'history_controller.dart';
import 'settings_controller.dart';

/// Orchestrates the scanning experience: engine lifecycle, result de-duplication
/// and the side effects a successful decode triggers.
///
/// Every side effect is gated by a setting here, so the UI never has to know
/// *when* to copy, vibrate, record or open a link (project spec §6.2).
class ScanController extends ChangeNotifier {
  ScanController({
    required this._engine,
    required this._settings,
    required this._history,
    required this._platformServices,
    required this._clipboard,
    required this._linkOpener,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final WeChatQrCode _engine;
  final SettingsController _settings;
  final HistoryController _history;
  final PlatformServices _platformServices;
  final ClipboardService _clipboard;
  final LinkOpener _linkOpener;
  final DateTime Function() _clock;

  final ScanDedup _dedup = ScanDedup();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  StreamSubscription<List<String>>? _subscription;

  /// Short user-facing notices (copied, clipboard empty, link could not open).
  Stream<String> get messages => _messages.stream;

  bool _engineReady = false;
  bool get isEngineReady => _engineReady;

  WeChatQrCodeException? _engineError;
  WeChatQrCodeException? get engineError => _engineError;

  /// `true` when the engine cannot start because the camera permission was
  /// refused, so the UI can offer retry / settings.
  bool get hasPermissionProblem => _engineError?.isPermissionProblem ?? false;

  /// `true` when retrying cannot help and only system settings can.
  bool get needsAppSettings =>
      _engineError?.code == WeChatQrCodeError.cameraPermissionPermanentlyDenied;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  ScanResultSelection? _result;
  ScanResultSelection? get result => _result;
  bool get isResultOpen => _result != null;

  ScanSource _resultSource = ScanSource.camera;
  ScanSource get resultSource => _resultSource;

  bool _resultCopied = false;
  bool get resultCopied => _resultCopied;

  bool _resultLinkFailed = false;

  /// Set when auto-open was requested but the platform could not open the link;
  /// the result sheet then tells the user to copy or open it manually.
  bool get resultLinkFailed => _resultLinkFailed;

  /// Loads the models. Intended to run once, at startup.
  Future<void> initializeEngine() async {
    try {
      await _engine.initialize();
      _engineReady = true;
      _engineError = null;
    } on WeChatQrCodeException catch (error) {
      _engineReady = false;
      _engineError = error;
    }
    notifyListeners();
  }

  /// The native camera preview widget. Place it as the bottom-most child of a
  /// [Stack] and layer Flutter controls over it.
  Widget buildScannerView({Key? key}) => _engine.buildScannerView(key: key);

  /// Whether camera access has already been granted.
  ///
  /// The UI uses this to explain why the camera is needed before the system
  /// dialog is shown (project spec §5).
  Future<bool> hasCameraPermission() => _engine.hasCameraPermission();

  /// Starts (or retries) the live camera scan.
  Future<void> startScanning() async {
    if (_isScanning) {
      return;
    }
    try {
      await _engine.startScanning();
      _subscription ??= _engine.results.listen(
        _onFrameResults,
        onError: _onEngineStreamError,
      );
      _isScanning = true;
      _engineError = null;
    } on WeChatQrCodeException catch (error) {
      _isScanning = false;
      _engineError = error;
    }
    notifyListeners();
  }

  /// Stops the scan and releases the camera. Called when leaving the scan tab
  /// or when the app goes to the background (project spec §4.6).
  Future<void> stopScanning() async {
    if (!_isScanning) {
      return;
    }
    _isScanning = false;
    notifyListeners();
    try {
      await _engine.stopScanning();
    } on WeChatQrCodeException {
      // The camera is going away regardless; nothing useful to report.
    }
  }

  /// Suspends frame analysis while keeping the preview live.
  Future<void> pauseScanning() async {
    if (!_isScanning) {
      return;
    }
    try {
      await _engine.pauseScanning();
    } on WeChatQrCodeException {
      // Non-fatal: worst case a frame is decoded while a sheet is open.
    }
  }

  /// Resumes frame analysis.
  Future<void> resumeScanning() async {
    if (!_isScanning) {
      return;
    }
    try {
      await _engine.resumeScanning();
    } on WeChatQrCodeException {
      // Non-fatal.
    }
  }

  /// Turns the torch on or off.
  Future<void> setTorch(bool enabled) async {
    try {
      await _engine.setTorch(enabled);
    } on WeChatQrCodeException {
      // Unsupported devices simply have no torch.
    }
  }

  /// Decodes a picture the user picked from the gallery.
  ///
  /// Returns the selection, or `null` when the image holds no QR code — which
  /// is a normal outcome, not an error. Throws [WeChatQrCodeException] for
  /// unreadable or unsupported images.
  Future<ScanResultSelection?> decodeImageFile(String path) async {
    final texts = await _engine.decodeImageFile(path);
    final selection = ScanResultPolicy.select(texts);
    if (selection == null) {
      return null;
    }
    await _handleSelection(selection, ScanSource.gallery, _clock());
    return selection;
  }

  /// Copies [text] to the clipboard on the user's explicit request.
  Future<void> copyToClipboard(String text) async {
    await _clipboard.writeText(text);
    _emit('已复制');
  }

  void _onFrameResults(List<String> texts) {
    final selection = ScanResultPolicy.select(texts);
    if (selection == null) {
      return;
    }
    if (_result != null) {
      // A sheet is already open; ignore further frames rather than swapping the
      // content under the user.
      return;
    }

    final now = _clock();
    if (!_dedup.shouldEmit(selection.primary, now)) {
      return;
    }

    unawaited(_handleSelection(selection, ScanSource.camera, now));
  }

  void _onEngineStreamError(Object error) {
    _engineError = error is WeChatQrCodeException
        ? error
        : WeChatQrCodeException(
            WeChatQrCodeError.decodeFailed,
            error.toString(),
            cause: error,
          );
    notifyListeners();
  }

  /// Presents a decoded payload and applies the enabled side effects.
  Future<void> _handleSelection(
    ScanResultSelection selection,
    ScanSource source,
    DateTime at,
  ) async {
    if (source == ScanSource.camera) {
      // Pause the recognition loop so the sheet cannot be replaced or re-shown
      // while it is on screen (project spec §6.1).
      await pauseScanning();
    }

    _result = selection;
    _resultSource = source;
    _resultCopied = false;
    _resultLinkFailed = false;
    notifyListeners();

    final settings = _settings.settings;

    if (settings.vibrationEnabled) {
      // Vibration is applied for gallery decodes too, so feedback is consistent
      // between the two entry points (project spec §6.5).
      try {
        await _platformServices.vibrate();
      } on PlatformServiceException {
        // Devices without a vibrator degrade quietly.
      }
    }

    if (settings.autoCopyClipboard) {
      try {
        await _clipboard.writeText(selection.primary);
        _resultCopied = true;
        notifyListeners();
      } catch (error) {
        debugPrint('Clipboard write failed: $error');
      }
    }

    if (settings.continuousScan) {
      await _history.add(
        content: selection.primary,
        source: source,
        scannedAt: at,
      );
    }

    if (settings.autoOpenWebsite) {
      final uri = ContentClassifier.browserUri(selection.primary);
      if (uri != null) {
        final opened = await _linkOpener.open(uri);
        if (!opened) {
          _resultLinkFailed = true;
          notifyListeners();
        }
      }
    }
  }

  /// Closes the result sheet, suppresses an immediate re-detection of the same
  /// payload and resumes scanning.
  Future<void> closeResult() async {
    final current = _result;
    if (current == null) {
      return;
    }

    // Without this, a code still in frame would pop the sheet straight back up.
    _dedup.suppress(current.primary, _clock());

    _result = null;
    _resultCopied = false;
    _resultLinkFailed = false;
    notifyListeners();

    await resumeScanning();
  }

  /// Opens a validated link from the result sheet on demand.
  Future<void> openResultLink() async {
    final current = _result;
    if (current == null) {
      return;
    }
    final uri = ContentClassifier.browserUri(current.primary);
    if (uri == null) {
      _emit('该内容不是可打开的网址');
      return;
    }
    final opened = await _linkOpener.open(uri);
    if (!opened) {
      _resultLinkFailed = true;
      notifyListeners();
      _emit('无法打开链接，可手动复制后在浏览器中打开');
    }
  }

  /// Opens this app's system settings page, for a permanently denied permission.
  Future<void> openAppSettings() async {
    try {
      await _platformServices.openAppSettings();
    } on PlatformServiceException catch (error) {
      debugPrint('Opening app settings failed: $error');
    }
  }

  void _emit(String message) {
    if (!_messages.isClosed) {
      _messages.add(message);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }
}
