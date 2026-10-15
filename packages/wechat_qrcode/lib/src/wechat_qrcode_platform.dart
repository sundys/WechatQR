import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel_wechat_qrcode.dart';

/// Contract every platform implementation of the WeChatQRCode engine must
/// satisfy.
///
/// Mirrors the responsibilities in the project spec §9.1: load models once,
/// decode still images, drive the live camera scan lifecycle, stream results,
/// and release native resources.
abstract class WeChatQrCodePlatform extends PlatformInterface {
  WeChatQrCodePlatform() : super(token: _token);

  static final Object _token = Object();

  static WeChatQrCodePlatform _instance = MethodChannelWeChatQrCode();

  static WeChatQrCodePlatform get instance => _instance;

  /// Replaces the implementation. Used by tests to install a fake.
  static set instance(WeChatQrCodePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Loads the detection and super-resolution models and builds the detector.
  ///
  /// Must be idempotent: calling it again reuses the existing detector rather
  /// than reloading the models (project spec §9.2).
  Future<void> initialize();

  /// Decodes every QR code in the image at [path].
  ///
  /// Runs off the platform's UI thread. Returns an empty list when the image
  /// holds no decodable QR code — that is not an error. Throws
  /// [WeChatQrCodeException] for unreadable or unsupported images.
  Future<List<String>> decodeImageFile(String path);

  /// Starts the live camera scan. Safe to call before the scanner view exists:
  /// the platform remembers the request and begins once the view is attached.
  Future<void> startScanning();

  /// Whether camera access has already been granted.
  ///
  /// Lets the UI show the reason the camera is needed *before* the system dialog
  /// appears, instead of prompting an uninformed user on first launch
  /// (project spec §5).
  Future<bool> hasCameraPermission();

  /// Stops the live camera scan and releases the camera. Safe to call when not
  /// scanning.
  Future<void> stopScanning();

  /// Suspends frame analysis while keeping the camera preview live.
  ///
  /// Used while a scan result is on screen so the recognition loop stops
  /// without the preview flickering (project spec §6.1).
  Future<void> pauseScanning();

  /// Resumes frame analysis after [pauseScanning].
  Future<void> resumeScanning();

  /// Emits one event per frame that produced at least one decoded payload.
  ///
  /// The platform suppresses frames while it is already analysing one, and the
  /// Dart side applies its own short-window de-duplication on top.
  Stream<List<String>> scanResults();

  /// Turns the torch on or off. Silently ignored where unsupported.
  Future<void> setTorch(bool enabled);

  /// Releases the detector and any other native resources.
  Future<void> release();

  /// Builds the camera preview widget for this platform.
  Widget buildScannerView({Key? key});
}
