import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'scanned_code.dart';
import 'wechat_qrcode_error.dart';
import 'wechat_qrcode_platform.dart';

/// Default [WeChatQrCodePlatform] backed by method/event channels and a
/// platform view.
class MethodChannelWeChatQrCode extends WeChatQrCodePlatform {
  @visibleForTesting
  static const MethodChannel methods = MethodChannel('wechat_qrcode/methods');

  @visibleForTesting
  static const EventChannel events = EventChannel('wechat_qrcode/events');

  /// Must match the view type registered by the Android and iOS
  /// implementations.
  @visibleForTesting
  static const String viewType = 'wechat_qrcode/scanner';

  @override
  Future<void> initialize() => _invoke('initialize');

  @override
  Future<List<String>> decodeImageFile(String path) async {
    final result = await _invoke<List<Object?>?>('decodeImageFile', {
      'path': path,
    });
    if (result == null) {
      return const <String>[];
    }
    return List<String>.unmodifiable(result.whereType<String>());
  }

  @override
  Future<void> startScanning() => _invoke('startScanning');

  @override
  Future<bool> hasCameraPermission() async {
    final granted = await _invoke<bool>('hasCameraPermission');
    return granted ?? false;
  }

  @override
  Future<void> stopScanning() => _invoke('stopScanning');

  @override
  Future<void> pauseScanning() => _invoke('pauseScanning');

  @override
  Future<void> resumeScanning() => _invoke('resumeScanning');

  @override
  Future<void> setTorch(bool enabled) =>
      _invoke('setTorch', {'enabled': enabled});

  @override
  Future<void> release() => _invoke('release');

  @override
  Stream<List<ScannedCode>> scanResults() {
    return events
        .receiveBroadcastStream()
        .map<List<ScannedCode>>((event) {
          if (event is! List) {
            throw const WeChatQrCodeException(
              WeChatQrCodeError.decodeFailed,
              'Scan result event was not a list.',
            );
          }
          return List<ScannedCode>.unmodifiable(event.map(_parseCode));
        })
        .handleError((Object error) {
          throw _mapError(error);
        });
  }

  /// Parses one entry of a scan-result event.
  ///
  /// Entries are maps of `{text, x, y}`; `x`/`y` may be absent or null when the
  /// engine reported no vertices for that code.
  static ScannedCode _parseCode(Object? entry) {
    if (entry is Map) {
      final text = entry['text'];
      if (text is String) {
        final x = entry['x'];
        final y = entry['y'];
        final center = (x is num && y is num)
            ? Offset(x.toDouble(), y.toDouble())
            : null;
        return ScannedCode(text: text, center: center);
      }
    }
    // A bare string is still a usable payload; losing the position is better
    // than losing the result.
    if (entry is String) {
      return ScannedCode(text: entry);
    }
    throw const WeChatQrCodeException(
      WeChatQrCodeError.decodeFailed,
      'A scan result entry was neither a map nor a string.',
    );
  }

  @override
  Widget buildScannerView({Key? key}) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          key: key,
          viewType: viewType,
          // The preview is a SurfaceView-backed CameraX PreviewView; letting
          // Flutter layer a texture over it is unnecessary and costs frames.
          layoutDirection: TextDirection.ltr,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          key: key,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          // Scanned content is never interactive, so the platform view should
          // not compete with Flutter's overlays for gestures.
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await methods.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (error) {
      throw WeChatQrCodeException(
        WeChatQrCodeError.unsupportedPlatform,
        'No WeChatQRCode implementation is registered for this platform.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw _mapError(error);
    }
  }

  /// Translates the platform's stable error codes into typed errors.
  static WeChatQrCodeException _mapError(Object error) {
    if (error is WeChatQrCodeException) {
      return error;
    }
    if (error is PlatformException) {
      return WeChatQrCodeException(
        _errorCodeFor(error.code),
        error.message ?? error.code,
        cause: error,
      );
    }
    return WeChatQrCodeException(
      WeChatQrCodeError.decodeFailed,
      error.toString(),
      cause: error,
    );
  }

  static WeChatQrCodeError _errorCodeFor(String code) {
    for (final candidate in WeChatQrCodeError.values) {
      if (candidate.name == code) {
        return candidate;
      }
    }
    return WeChatQrCodeError.decodeFailed;
  }
}
