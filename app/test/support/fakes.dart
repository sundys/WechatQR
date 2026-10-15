import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:platform_services/platform_services.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';
import 'package:wechatqr/data/history_store.dart';
import 'package:wechatqr/data/settings_store.dart';
import 'package:wechatqr/data/update_preferences.dart';
import 'package:wechatqr/domain/history_entry.dart';
import 'package:wechatqr/domain/release_info.dart';
import 'package:wechatqr/domain/scan_settings.dart';
import 'package:wechatqr/domain/sem_version.dart';
import 'package:wechatqr/services/clipboard_service.dart';
import 'package:wechatqr/services/link_opener.dart';
import 'package:wechatqr/services/release_service.dart';

/// In-memory settings store, with an optional failure to exercise the
/// persistence-error path.
class FakeSettingsStore implements SettingsStore {
  FakeSettingsStore({this.initial, this.failOnSave = false});

  ScanSettings? initial;
  bool failOnSave;
  int saveCount = 0;

  @override
  Future<ScanSettings?> load() async => initial;

  @override
  Future<void> save(ScanSettings settings) async {
    saveCount++;
    if (failOnSave) {
      throw StateError('disk full');
    }
    initial = settings;
  }
}

/// In-memory history store that records what was persisted.
class FakeHistoryStore implements HistoryStore {
  FakeHistoryStore({List<HistoryEntry>? initial})
    : saved = List<HistoryEntry>.from(initial ?? const []);

  List<HistoryEntry> saved;
  int saveCount = 0;

  @override
  Future<List<HistoryEntry>> load() async => List<HistoryEntry>.from(saved);

  @override
  Future<void> save(List<HistoryEntry> entries) async {
    saveCount++;
    saved = List<HistoryEntry>.from(entries);
  }
}

class FakePlatformServices implements PlatformServices {
  int vibrateCount = 0;
  bool canInstall = true;
  final List<String> installedPaths = [];
  final List<Uint8List> savedImages = [];
  int openSettingsCount = 0;
  bool failInstall = false;

  @override
  Future<void> vibrate() async => vibrateCount++;

  @override
  Future<bool> canInstallPackages() async => canInstall;

  @override
  Future<void> saveImageToGallery(
    Uint8List pngBytes, {
    required String fileName,
  }) async {
    savedImages.add(pngBytes);
  }

  @override
  Future<void> openInstallPermissionSettings() async => openSettingsCount++;

  @override
  Future<void> openAppSettings() async => openSettingsCount++;

  @override
  Future<void> installApk(String filePath) async {
    if (failInstall) {
      throw const PlatformServiceException(
        PlatformServiceError.installFailed,
        'no installer',
      );
    }
    installedPaths.add(filePath);
  }
}

class FakeClipboard implements ClipboardService {
  FakeClipboard([this.text]);

  String? text;
  int writeCount = 0;

  @override
  Future<String?> readText() async => text;

  @override
  Future<void> writeText(String text) async {
    writeCount++;
    this.text = text;
  }
}

class FakeLinkOpener implements LinkOpener {
  FakeLinkOpener({this.succeed = true});

  bool succeed;
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return succeed;
  }
}

/// Stand-in for the native engine.
class FakeWeChatQrCodePlatform extends WeChatQrCodePlatform {
  bool initializeFails = false;
  bool permissionGranted = true;
  Object? startError;
  List<String> imageResult = const <String>[];
  Object? imageError;

  int initializeCount = 0;
  int startCount = 0;
  int stopCount = 0;
  int pauseCount = 0;
  int resumeCount = 0;
  bool? lastTorch;

  final StreamController<List<String>> _results =
      StreamController<List<String>>.broadcast();

  /// Pushes a decoded frame as the native side would.
  void emit(List<String> texts) => _results.add(texts);

  /// Pushes an error through the results stream.
  void emitError(Object error) => _results.addError(error);

  @override
  Future<void> initialize() async {
    initializeCount++;
    if (initializeFails) {
      throw const WeChatQrCodeException(
        WeChatQrCodeError.modelLoadFailed,
        'models missing',
      );
    }
  }

  @override
  Future<List<String>> decodeImageFile(String path) async {
    if (imageError != null) {
      throw imageError!;
    }
    return imageResult;
  }

  @override
  Future<void> startScanning() async {
    startCount++;
    if (startError != null) {
      throw startError!;
    }
  }

  @override
  Future<void> stopScanning() async => stopCount++;

  @override
  Future<void> pauseScanning() async => pauseCount++;

  @override
  Future<void> resumeScanning() async => resumeCount++;

  @override
  Future<bool> hasCameraPermission() async => permissionGranted;

  @override
  Future<void> setTorch(bool enabled) async => lastTorch = enabled;

  @override
  Future<void> release() async {}

  @override
  Stream<List<String>> scanResults() => _results.stream;

  @override
  Widget buildScannerView({Key? key}) => const SizedBox.shrink();

  Future<void> close() => _results.close();
}

class FakeUpdatePreferences implements UpdatePreferencesStore {
  FakeUpdatePreferences({this.ignored, this.pending});

  String? ignored;
  PendingInstall? pending;

  @override
  Future<String?> ignoredVersionTag() async => ignored;

  @override
  Future<void> setIgnoredVersionTag(String? tag) async => ignored = tag;

  @override
  Future<PendingInstall?> pendingInstall() async => pending;

  @override
  Future<void> setPendingInstall(PendingInstall? value) async =>
      pending = value;
}

class FakeReleaseService implements ReleaseService {
  FakeReleaseService({this.release, this.error});

  ReleaseInfo? release;
  ReleaseCheckException? error;
  int calls = 0;

  @override
  Future<ReleaseInfo?> latestStable() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return release;
  }
}

/// Builds a [ReleaseInfo] without going through JSON.
ReleaseInfo buildRelease(
  String tag, {
  List<ReleaseAsset> assets = const [],
  String notes = '',
}) {
  return ReleaseInfo(
    version: SemVersion.parse(tag),
    tagName: tag,
    title: tag,
    notes: notes,
    htmlUrl: Uri.parse('https://example.test/releases/$tag'),
    assets: assets,
  );
}
