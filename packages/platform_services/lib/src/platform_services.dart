import 'dart:typed_data';

/// Native capabilities the shared Flutter layer cannot provide on its own.
///
/// Kept separate from the QR engine plugin so each plugin has one
/// responsibility (project spec §4.3): this one covers device feedback, saving
/// to the system gallery, and handing an APK to the Android installer.
abstract interface class PlatformServices {
  /// A short confirmation vibration on scan success.
  ///
  /// Silently does nothing on devices without a vibrator, matching the spec's
  /// "degrade quietly" requirement (§6.2).
  Future<void> vibrate();

  /// Writes [pngBytes] into the system photo gallery.
  ///
  /// Android writes through MediaStore; iOS uses Photo Library add-only access.
  /// Only the image the user explicitly asked to save is written.
  Future<void> saveImageToGallery(
    Uint8List pngBytes, {
    required String fileName,
  });

  /// Whether this app may currently launch the package installer.
  ///
  /// Always `false` on iOS.
  Future<bool> canInstallPackages();

  /// Opens the system screen where the user grants "install unknown apps" for
  /// this app. The user is always taken through the OS flow; nothing is granted
  /// programmatically (project spec §3.1).
  Future<void> openInstallPermissionSettings();

  /// Opens this app's own system settings page.
  ///
  /// The escape hatch offered when a permission was permanently denied and the
  /// app can no longer prompt for it (project spec §5).
  Future<void> openAppSettings();

  /// Hands [filePath] to the system package installer.
  ///
  /// [filePath] must live under the app's private `updates` directory, which is
  /// the only location exposed to the installer's FileProvider. The user still
  /// has to confirm installation in the system UI; this never installs
  /// silently.
  Future<void> installApk(String filePath);
}
