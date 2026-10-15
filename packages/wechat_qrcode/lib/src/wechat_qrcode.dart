import 'package:flutter/widgets.dart';

import 'wechat_qrcode_error.dart';
import 'wechat_qrcode_platform.dart';

/// Dart entry point to the native WeChatQRCode engine.
///
/// The heavy lifting — CNN model loading, frame analysis and decoding — happens
/// in the platform implementations (Kotlin/CameraX on Android, ObjC++/AVFoundation
/// on iOS). This class is the shared, testable surface the UI uses.
class WeChatQrCode {
  WeChatQrCode({WeChatQrCodePlatform? platform})
    : _platform = platform ?? WeChatQrCodePlatform.instance;

  final WeChatQrCodePlatform _platform;

  bool _initialized = false;

  /// `true` once [initialize] has completed successfully.
  bool get isInitialized => _initialized;

  /// Loads the models and prepares the detector.
  ///
  /// Idempotent. Throws [WeChatQrCodeException] with
  /// [WeChatQrCodeError.modelLoadFailed] when the models cannot be loaded, so
  /// the UI can offer a retry or explain the failure (project spec §9.2).
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await _platform.initialize();
    _initialized = true;
  }

  /// Decodes every QR code found in the image at [path].
  ///
  /// Only the file the user picked is read; nothing is uploaded (project spec
  /// §6.5). Returns an empty list when no QR code is present.
  Future<List<String>> decodeImageFile(String path) async {
    _requireInitialized();
    return _platform.decodeImageFile(path);
  }

  /// Starts the live camera scan.
  Future<void> startScanning() async {
    _requireInitialized();
    await _platform.startScanning();
  }

  /// Whether camera access has already been granted, so the UI can explain the
  /// purpose before the system dialog appears.
  Future<bool> hasCameraPermission() => _platform.hasCameraPermission();

  /// Stops the live camera scan and releases the camera.
  Future<void> stopScanning() => _platform.stopScanning();

  /// Suspends frame analysis but keeps the preview live.
  Future<void> pauseScanning() => _platform.pauseScanning();

  /// Resumes frame analysis after [pauseScanning].
  Future<void> resumeScanning() => _platform.resumeScanning();

  /// Decoded payloads, one event per successful frame.
  Stream<List<String>> get results => _platform.scanResults();

  /// Enables or disables the torch; unsupported devices ignore this.
  Future<void> setTorch(bool enabled) => _platform.setTorch(enabled);

  /// Releases the detector and native resources. The instance must be
  /// re-initialised afterwards.
  Future<void> release() async {
    _initialized = false;
    await _platform.release();
  }

  /// The camera preview widget. Place inside a [Stack] beneath the Flutter
  /// overlays; the scan itself is driven by [startScanning]/[stopScanning].
  Widget buildScannerView({Key? key}) => _platform.buildScannerView(key: key);

  void _requireInitialized() {
    if (!_initialized) {
      throw const WeChatQrCodeException(
        WeChatQrCodeError.notInitialized,
        'initialize() must complete before the engine can be used.',
      );
    }
  }
}

/// Exposed so callers can install a fake implementation in tests.
WeChatQrCodePlatform get weChatQrCodePlatform => WeChatQrCodePlatform.instance;

set weChatQrCodePlatform(WeChatQrCodePlatform platform) =>
    WeChatQrCodePlatform.instance = platform;
