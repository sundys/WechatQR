/// Errors raised by platform capability calls.
library;

enum PlatformServiceError {
  /// The capability does not exist on this platform. Notably, installing a
  /// package is Android-only (project spec §3.2).
  unsupported,

  /// A required runtime permission was refused.
  permissionDenied,

  /// The user or the OS refused to grant "install unknown apps" for this app.
  installPermissionMissing,

  /// Writing the image to the shared gallery failed.
  saveFailed,

  /// The supplied APK path does not exist or cannot be read.
  fileNotFound,

  /// The system installer could not be launched.
  installFailed,
}

class PlatformServiceException implements Exception {
  const PlatformServiceException(this.code, this.message, {this.cause});

  final PlatformServiceError code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'PlatformServiceException(${code.name}: $message)';
}
