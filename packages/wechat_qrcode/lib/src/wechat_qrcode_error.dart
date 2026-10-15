/// Typed errors raised by the WeChatQRCode engine wrapper.
///
/// Callers switch on [WeChatQrCodeError] to show a specific, actionable message
/// (project spec §4.7) instead of surfacing a raw platform string.
library;

enum WeChatQrCodeError {
  /// The engine was used before [WeChatQrCode.initialize] completed.
  notInitialized,

  /// The CNN model files are missing, unreadable or rejected by OpenCV.
  modelLoadFailed,

  /// The user has not granted camera access yet.
  cameraPermissionDenied,

  /// The user has permanently denied camera access; only system settings can
  /// change this now.
  cameraPermissionPermanentlyDenied,

  /// No usable camera, or the camera is held by another application.
  cameraUnavailable,

  /// The supplied file is missing, empty, or exceeds the decoder's limits.
  invalidImage,

  /// The platform could not decode the chosen image format.
  unsupportedImageFormat,

  /// The engine ran but reported an internal failure.
  decodeFailed,

  /// Called on a platform with no WeChatQRCode implementation.
  unsupportedPlatform,
}

class WeChatQrCodeException implements Exception {
  const WeChatQrCodeException(this.code, this.message, {this.cause});

  final WeChatQrCodeError code;

  /// Human-readable detail. Not intended for direct display; the UI maps
  /// [code] to localised copy.
  final String message;

  final Object? cause;

  /// Convenience for the common "was this a permission problem" branch.
  bool get isPermissionProblem =>
      code == WeChatQrCodeError.cameraPermissionDenied ||
      code == WeChatQrCodeError.cameraPermissionPermanentlyDenied;

  @override
  String toString() => 'WeChatQrCodeException(${code.name}: $message)';
}
