import 'dart:async';
import 'dart:typed_data';

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
    this._selectionWindow = const Duration(seconds: 3),
  }) : _clock = clock ?? DateTime.now;

  final WeChatQrCode _engine;
  final SettingsController _settings;
  final HistoryController _history;
  final PlatformServices _platformServices;
  final ClipboardService _clipboard;
  final LinkOpener _linkOpener;
  final DateTime Function() _clock;

  /// How long a multi-code frame waits for the user to pick one before every
  /// result is shown. Injectable so tests do not have to wait three seconds.
  final Duration _selectionWindow;

  final ScanDedup _dedup = ScanDedup();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  StreamSubscription<List<ScannedCode>>? _subscription;

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

  /// Codes currently marked in the preview. Populated while the user is
  /// choosing between several codes and kept while a result is on screen, so
  /// the indicators stay put behind the sheet.
  List<ScannedCode> _marked = const <ScannedCode>[];
  List<ScannedCode> get markedCodes => _marked;

  Uint8List? _frozenFrame;

  /// A still image of the frame the markers were placed for, or `null`.
  ///
  /// The picture is held still while markers are on screen because the markers
  /// belong to the frame the codes were decoded from: with a live preview they
  /// drift off the codes the moment the phone moves.
  Uint8List? get frozenFrame => _frozenFrame;

  bool _disposed = false;

  bool _awaitingSelection = false;

  /// `true` while a multi-code frame is waiting for the user to pick one.
  bool get isAwaitingSelection => _awaitingSelection;

  Timer? _selectionTimer;

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

  void _onFrameResults(List<ScannedCode> codes) {
    final usable = codes
        .where((code) => code.text.trim().isNotEmpty)
        .toList(growable: false);
    if (usable.isEmpty) {
      return;
    }
    if (_result != null || _awaitingSelection) {
      // Something is already on screen; ignore further frames rather than
      // swapping the content under the user.
      return;
    }

    final now = _clock();
    if (!_dedup.shouldEmit(usable.first.text, now)) {
      return;
    }

    if (usable.length == 1) {
      final selection = ScanResultPolicy.select([usable.first.text]);
      if (selection != null) {
        unawaited(
          _handleSelection(selection, ScanSource.camera, now, marked: usable),
        );
      }
      return;
    }

    // Several codes in one frame: mark them all and give the user a moment to
    // pick one, instead of assuming. Choosing nothing shows every result.
    _beginSelection(usable);
  }

  /// Marks every code in a multi-code frame and starts the selection window.
  void _beginSelection(List<ScannedCode> codes) {
    _awaitingSelection = true;
    _marked = codes;
    notifyListeners();

    unawaited(_freezeFrame());

    _selectionTimer?.cancel();
    _selectionTimer = Timer(_selectionWindow, () {
      _selectionTimer = null;
      unawaited(_showAllMarked());
    });
  }

  /// Captures the current frame and suspends analysis.
  ///
  /// Safe to call repeatedly: the frame is captured once, so the picture does
  /// not change under markers that were placed for an earlier one.
  Future<void> _freezeFrame() async {
    if (_frozenFrame == null) {
      try {
        _frozenFrame = await _engine.capturePreview();
      } on WeChatQrCodeException {
        // No still image available: the markers then float over a live preview,
        // which is worse but not broken.
        _frozenFrame = null;
      }
      if (!_disposed) {
        notifyListeners();
      }
    }
    await pauseScanning();
  }

  /// Called when the selection window elapses: show every marked code.
  Future<void> _showAllMarked() async {
    if (!_awaitingSelection) {
      return;
    }
    _awaitingSelection = false;

    final codes = _marked;
    final selection = ScanResultPolicy.select(
      codes.map((code) => code.text).toList(growable: false),
    );
    if (selection == null) {
      _marked = const <ScannedCode>[];
      notifyListeners();
      return;
    }
    await _handleSelection(
      selection,
      ScanSource.camera,
      _clock(),
      marked: codes,
    );
  }

  /// Called when the user taps the indicator for the code at [index].
  Future<void> selectMarked(int index) async {
    if (!_awaitingSelection) {
      return;
    }
    final codes = _marked;
    if (index < 0 || index >= codes.length) {
      return;
    }

    _selectionTimer?.cancel();
    _selectionTimer = null;
    _awaitingSelection = false;

    // Presenting only the chosen code also means the enabled side effects —
    // copy, history, auto-open — apply to it alone.
    final selection = ScanResultPolicy.select([codes[index].text]);
    if (selection == null) {
      return;
    }
    await _handleSelection(
      selection,
      ScanSource.camera,
      _clock(),
      marked: codes,
    );
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
    DateTime at, {
    List<ScannedCode> marked = const <ScannedCode>[],
  }) async {
    if (source == ScanSource.camera) {
      // Pause the recognition loop so the sheet cannot be replaced or re-shown
      // while it is on screen (project spec §6.1), and hold the picture still so
      // the markers stay on the codes behind the sheet.
      await _freezeFrame();
    }

    _result = selection;
    _resultSource = source;
    _marked = marked;
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
      // Every payload the frame produced, not just the one being presented. A
      // frame that decoded several codes recorded only the one shown, so the
      // rest were lost as soon as the preview moved on — which is exactly when
      // the user noticed them. `marked` is the whole set for a camera frame;
      // a picture from the gallery has no markers, so its own results are used.
      final contents = marked.isNotEmpty
          ? marked.map((code) => code.text).toList(growable: false)
          : selection.all;
      for (final content in contents) {
        await _history.add(content: content, source: source, scannedAt: at);
      }
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

    _selectionTimer?.cancel();
    _selectionTimer = null;
    _awaitingSelection = false;
    _result = null;
    _marked = const <ScannedCode>[];
    // Let the preview move again now that nothing is pinned to a frame.
    _frozenFrame = null;
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
    _disposed = true;
    _selectionTimer?.cancel();
    _subscription?.cancel();
    _messages.close();
    super.dispose();
  }
}
