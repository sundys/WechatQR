import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_qrcode/wechat_qrcode.dart';
import 'package:wechatqr/domain/app_theme_mode.dart';
import 'package:wechatqr/domain/scan_settings.dart';
import 'package:wechatqr/domain/scan_source.dart';
import 'package:wechatqr/state/history_controller.dart';
import 'package:wechatqr/state/scan_controller.dart';
import 'package:wechatqr/state/settings_controller.dart';

import '../support/fakes.dart';

void main() {
  late FakeWeChatQrCodePlatform platform;
  late FakeSettingsStore settingsStore;
  late SettingsController settings;
  late FakeHistoryStore historyStore;
  late HistoryController history;
  late FakePlatformServices services;
  late FakeClipboard clipboard;
  late FakeLinkOpener opener;
  late ScanController controller;
  late DateTime now;

  setUp(() async {
    now = DateTime(2026, 1, 1, 12);
    platform = FakeWeChatQrCodePlatform();
    settingsStore = FakeSettingsStore();
    settings = SettingsController(store: settingsStore);
    historyStore = FakeHistoryStore();
    history = HistoryController(store: historyStore, idGenerator: () => 'id');
    services = FakePlatformServices();
    clipboard = FakeClipboard();
    opener = FakeLinkOpener();

    controller = ScanController(
      engine: WeChatQrCode(platform: platform),
      settings: settings,
      history: history,
      platformServices: services,
      clipboard: clipboard,
      linkOpener: opener,
      clock: () => now,
    );
  });

  tearDown(() => platform.close());

  Future<void> ready() => controller.initializeEngine();

  group('engine lifecycle', () {
    test('reports readiness after a successful init', () async {
      await ready();
      expect(controller.isEngineReady, isTrue);
      expect(controller.engineError, isNull);
    });

    test('surfaces a model-load failure instead of throwing', () async {
      platform.initializeFails = true;
      await controller.initializeEngine();

      expect(controller.isEngineReady, isFalse);
      expect(controller.engineError?.code, WeChatQrCodeError.modelLoadFailed);
    });

    test('a denied camera permission becomes a permission error', () async {
      platform.startError = const WeChatQrCodeException(
        WeChatQrCodeError.cameraPermissionDenied,
        'denied',
      );
      await ready();
      await controller.startScanning();

      expect(controller.isScanning, isFalse);
      expect(controller.hasPermissionProblem, isTrue);
      expect(controller.needsAppSettings, isFalse);
    });

    test('a permanent denial is distinguishable from a plain denial', () async {
      platform.startError = const WeChatQrCodeException(
        WeChatQrCodeError.cameraPermissionPermanentlyDenied,
        'denied forever',
      );
      await ready();
      await controller.startScanning();

      expect(controller.needsAppSettings, isTrue);
    });

    test('stopScanning releases the camera exactly once', () async {
      await ready();
      await controller.startScanning();
      await controller.stopScanning();
      await controller.stopScanning();

      expect(controller.isScanning, isFalse);
      expect(platform.stopCount, 1);
    });
  });

  group('frame results', () {
    test('a decoded frame opens the result and pauses analysis', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['hello']);
      await pumpEventQueue();

      expect(controller.result?.primary, 'hello');
      expect(controller.resultSource, ScanSource.camera);
      expect(platform.pauseCount, 1);
    });

    test(
      'a multi-code frame marks every code without deciding for the user',
      () async {
        await ready();
        await controller.startScanning();
        platform.emitCodes(const [
          ScannedCode(text: 'first', center: Offset(0.25, 0.40)),
          ScannedCode(text: 'second', center: Offset(0.75, 0.60)),
        ]);
        await pumpEventQueue();

        // No result yet: the user is being asked which code they meant.
        expect(controller.result, isNull);
        expect(controller.isAwaitingSelection, isTrue);
        expect(controller.markedCodes.map((c) => c.text), ['first', 'second']);
        expect(controller.markedCodes.first.center, const Offset(0.25, 0.40));
        // The preview keeps running, but frames stop being decoded so the marks
        // cannot move out from under the indicators.
        expect(platform.pauseCount, 1);
      },
    );

    test('choosing a marked code presents only that code', () async {
      await ready();
      await controller.startScanning();
      platform.emitCodes(const [
        ScannedCode(text: 'first', center: Offset(0.25, 0.40)),
        ScannedCode(text: 'second', center: Offset(0.75, 0.60)),
      ]);
      await pumpEventQueue();

      await controller.selectMarked(1);

      expect(controller.isAwaitingSelection, isFalse);
      expect(controller.result?.primary, 'second');
      // Only the chosen payload is treated as the result, so the copy and
      // history side effects apply to it alone.
      expect(controller.result?.isMulti, isFalse);
      expect(clipboard.text, 'second');
      expect(history.entries.single.content, 'second');
    });

    test('the selection window elapsing shows every code', () async {
      // A short window keeps the test fast; the production value is 3 seconds.
      controller.dispose();
      controller = ScanController(
        engine: WeChatQrCode(platform: platform),
        settings: settings,
        history: history,
        platformServices: services,
        clipboard: clipboard,
        linkOpener: opener,
        clock: () => now,
        selectionWindow: const Duration(milliseconds: 30),
      );

      await ready();
      await controller.startScanning();
      platform.emitCodes(const [
        ScannedCode(text: 'first', center: Offset(0.25, 0.40)),
        ScannedCode(text: 'second', center: Offset(0.75, 0.60)),
      ]);
      await pumpEventQueue();

      expect(controller.result, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(controller.isAwaitingSelection, isFalse);
      expect(controller.result?.isMulti, isTrue);
      expect(controller.result?.all, ['first', 'second']);
    });

    test('a frame arriving during the selection window is ignored', () async {
      await ready();
      await controller.startScanning();
      platform.emitCodes(const [
        ScannedCode(text: 'first', center: Offset(0.25, 0.40)),
        ScannedCode(text: 'second', center: Offset(0.75, 0.60)),
      ]);
      await pumpEventQueue();

      platform.emitCodes(const [
        ScannedCode(text: 'third', center: Offset(0.10, 0.10)),
      ]);
      await pumpEventQueue();

      expect(controller.markedCodes.map((c) => c.text), ['first', 'second']);
      expect(controller.result, isNull);
    });

    test('closing the result clears the markers', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['hello']);
      await pumpEventQueue();
      expect(controller.markedCodes, isNotEmpty);

      await controller.closeResult();

      expect(controller.markedCodes, isEmpty);
      expect(controller.isAwaitingSelection, isFalse);
    });

    test('a single code is still presented without waiting', () async {
      await ready();
      await controller.startScanning();
      platform.emitCodes(const [
        ScannedCode(text: 'only', center: Offset(0.5, 0.5)),
      ]);
      await pumpEventQueue();

      expect(controller.isAwaitingSelection, isFalse);
      expect(controller.result?.primary, 'only');
    });

    test('selectMarked is a no-op when nothing is being chosen', () async {
      await ready();
      await controller.startScanning();

      await controller.selectMarked(0);

      expect(controller.result, isNull);
    });

    test('the same code is not re-presented while the sheet is open', () async {
      await ready();
      await controller.startScanning();

      platform.emit(['hello']);
      await pumpEventQueue();
      var notifications = 0;
      controller.addListener(() => notifications++);

      platform.emit(['hello']);
      platform.emit(['hello']);
      await pumpEventQueue();

      expect(notifications, 0);
      expect(controller.result?.primary, 'hello');
    });

    test('closing the sheet suppresses an immediate re-detection', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['hello']);
      await pumpEventQueue();
      await controller.closeResult();

      expect(controller.result, isNull);
      expect(platform.resumeCount, 1);

      // The code is still in frame; without the suppression window it would pop
      // straight back up.
      platform.emit(['hello']);
      await pumpEventQueue();
      expect(controller.result, isNull);
    });

    test('the same code is presented again after the window elapses', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['hello']);
      await pumpEventQueue();
      await controller.closeResult();

      now = now.add(const Duration(seconds: 10));
      platform.emit(['hello']);
      await pumpEventQueue();

      expect(controller.result?.primary, 'hello');
    });

    test('blank payloads are ignored', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['', '   ']);
      await pumpEventQueue();

      expect(controller.result, isNull);
    });

    test('a stream error is recorded, not thrown', () async {
      await ready();
      await controller.startScanning();
      platform.emitError(
        const WeChatQrCodeException(WeChatQrCodeError.decodeFailed, 'boom'),
      );
      await pumpEventQueue();

      expect(controller.engineError?.code, WeChatQrCodeError.decodeFailed);
    });
  });

  group('settings-driven side effects', () {
    Future<void> emitOnce(String payload) async {
      await ready();
      await controller.startScanning();
      platform.emit([payload]);
      await pumpEventQueue();
    }

    test('copies to the clipboard when auto-copy is on', () async {
      await emitOnce('hello');
      expect(clipboard.writeCount, 1);
      expect(clipboard.text, 'hello');
      expect(controller.resultCopied, isTrue);
    });

    test('does not touch the clipboard when auto-copy is off', () async {
      await settings.setAutoCopyClipboard(false);
      await emitOnce('hello');

      expect(clipboard.writeCount, 0);
      expect(controller.resultCopied, isFalse);
    });

    test('vibrates when enabled', () async {
      await emitOnce('hello');
      expect(services.vibrateCount, 1);
    });

    test('does not vibrate when disabled', () async {
      await settings.setVibrationEnabled(false);
      await emitOnce('hello');

      expect(services.vibrateCount, 0);
    });

    test('records history when continuous scan is on', () async {
      await emitOnce('hello');
      expect(history.entries.single.content, 'hello');
    });

    test('does not record history when continuous scan is off', () async {
      await settings.setContinuousScan(false);
      await emitOnce('hello');

      expect(history.entries, isEmpty);
    });

    test('opens a validated https URL when auto-open is on', () async {
      await settings.setAutoOpenWebsite(true);
      await emitOnce('https://example.com/x');

      expect(opener.opened.single.toString(), 'https://example.com/x');
    });

    test('never opens a non-http scheme, even with auto-open on', () async {
      await settings.setAutoOpenWebsite(true);
      await emitOnce('javascript:alert(1)');

      expect(opener.opened, isEmpty);
      // The payload is still shown and copied like any other text.
      expect(controller.result?.primary, 'javascript:alert(1)');
    });

    test('never opens anything when auto-open is off', () async {
      await emitOnce('https://example.com');
      expect(opener.opened, isEmpty);
    });

    test('reports a link that the platform refused to open', () async {
      opener.succeed = false;
      await settings.setAutoOpenWebsite(true);
      await emitOnce('https://example.com');

      expect(controller.resultLinkFailed, isTrue);
      // The result is kept so the user can still copy it.
      expect(controller.result?.primary, 'https://example.com');
    });

    test('theme selection does not affect scanning', () async {
      await settings.setThemeMode(AppThemeMode.dark);
      await emitOnce('hello');

      expect(controller.result?.primary, 'hello');
    });
  });

  group('gallery decoding', () {
    test('returns the selection and records it as a gallery scan', () async {
      await ready();
      platform.imageResult = ['from-image'];

      final selection = await controller.decodeImageFile('/tmp/x.png');

      expect(selection?.primary, 'from-image');
      expect(controller.resultSource, ScanSource.gallery);
      expect(history.entries.single.source, ScanSource.gallery);
    });

    test('does not pause the camera for a gallery decode', () async {
      await ready();
      platform.imageResult = ['x'];
      await controller.decodeImageFile('/tmp/x.png');

      expect(platform.pauseCount, 0);
    });

    test('returns null when the image has no QR code', () async {
      await ready();
      platform.imageResult = const [];

      final selection = await controller.decodeImageFile('/tmp/x.png');

      expect(selection, isNull);
      expect(controller.result, isNull);
      expect(history.entries, isEmpty);
    });

    test('propagates a decode failure as a typed error', () async {
      await ready();
      platform.imageError = const WeChatQrCodeException(
        WeChatQrCodeError.unsupportedImageFormat,
        'nope',
      );

      await expectLater(
        controller.decodeImageFile('/tmp/x.gif'),
        throwsA(
          isA<WeChatQrCodeException>().having(
            (e) => e.code,
            'code',
            WeChatQrCodeError.unsupportedImageFormat,
          ),
        ),
      );
    });
  });

  group('result sheet actions', () {
    test('openResultLink refuses a non-openable payload', () async {
      await ready();
      await controller.startScanning();
      platform.emit(['not a link']);
      await pumpEventQueue();

      await controller.openResultLink();

      expect(opener.opened, isEmpty);
    });

    test('openResultLink reports a failed launch', () async {
      opener.succeed = false;
      await ready();
      await controller.startScanning();
      platform.emit(['https://example.com']);
      await pumpEventQueue();

      await controller.openResultLink();

      expect(controller.resultLinkFailed, isTrue);
    });

    test('copyToClipboard writes the payload on demand', () async {
      await controller.copyToClipboard('manual copy');
      expect(clipboard.text, 'manual copy');
    });
  });

  group('engine configuration', () {
    test('gate methods are forwarded to the platform', () async {
      await ready();
      await controller.startScanning();

      await controller.pauseScanning();
      await controller.resumeScanning();
      await controller.setTorch(true);

      expect(platform.pauseCount, 1);
      expect(platform.resumeCount, 1);
      expect(platform.lastTorch, isTrue);
    });

    test(
      'default settings keep the engine idle until explicitly started',
      () async {
        await ready();
        expect(controller.isScanning, isFalse);
        expect(platform.startCount, 0);
      },
    );

    test('the default settings match the spec', () {
      expect(settings.settings, ScanSettings.defaults);
    });
  });
}
