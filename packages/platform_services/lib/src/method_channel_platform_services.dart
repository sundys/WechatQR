import 'package:flutter/services.dart';

import 'platform_service_error.dart';
import 'platform_services.dart';

/// Channel-backed [PlatformServices].
class MethodChannelPlatformServices implements PlatformServices {
  MethodChannelPlatformServices({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Channel shared with the Kotlin and Swift implementations.
  static const String channelName = 'platform_services/methods';

  final MethodChannel _channel;

  @override
  Future<void> vibrate() => _invoke<void>('vibrate');

  @override
  Future<void> saveImageToGallery(
    Uint8List pngBytes, {
    required String fileName,
  }) {
    return _invoke<void>('saveImageToGallery', {
      'bytes': pngBytes,
      'fileName': fileName,
    });
  }

  @override
  Future<bool> canInstallPackages() async {
    final result = await _invoke<bool>('canInstallPackages');
    return result ?? false;
  }

  @override
  Future<void> openInstallPermissionSettings() =>
      _invoke<void>('openInstallPermissionSettings');

  @override
  Future<void> openAppSettings() => _invoke<void>('openAppSettings');

  @override
  Future<void> installApk(String filePath) =>
      _invoke<void>('installApk', {'path': filePath});

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (error) {
      throw PlatformServiceException(
        PlatformServiceError.unsupported,
        'No platform implementation is registered for "$method".',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw PlatformServiceException(
        _errorCodeFor(error.code),
        error.message ?? error.code,
        cause: error,
      );
    }
  }

  static PlatformServiceError _errorCodeFor(String code) {
    for (final candidate in PlatformServiceError.values) {
      if (candidate.name == code) {
        return candidate;
      }
    }
    return PlatformServiceError.saveFailed;
  }
}
