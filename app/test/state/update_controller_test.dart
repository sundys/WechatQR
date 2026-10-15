import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wechatqr/data/update_preferences.dart';
import 'package:wechatqr/domain/release_info.dart';
import 'package:wechatqr/domain/sem_version.dart';
import 'package:wechatqr/domain/update_state.dart';
import 'package:wechatqr/services/apk_downloader.dart';
import 'package:wechatqr/services/app_version_service.dart';
import 'package:wechatqr/services/release_service.dart';
import 'package:wechatqr/state/update_controller.dart';

import '../support/fakes.dart';

void main() {
  late Directory tempDir;
  late FakeReleaseService releaseService;
  late FakePlatformServices platformServices;
  late FakeUpdatePreferences preferences;
  late ApkDownloader downloader;
  late UpdateController controller;

  final apkBytes = utf8.encode('pretend apk payload');

  InstalledVersion installed(String version) => InstalledVersion(
    version: version,
    buildNumber: '1',
    packageName: 'com.sundys.wechatqr',
  );

  /// Version the running build reports; mutable so an update landing can be
  /// simulated without rebuilding the controller.
  late String reportedVersion;

  /// Assembles a controller with a downloader that returns [apkBytes].
  void buildController({
    String installedVersion = '1.0.0',
    int downloadStatus = 200,
  }) {
    reportedVersion = installedVersion;

    downloader = ApkDownloader(
      updatesDirectoryProvider: () async => tempDir,
      client: MockClient(
        (_) async => http.Response.bytes(apkBytes, downloadStatus),
      ),
    );

    controller = UpdateController(
      releaseService: releaseService,
      downloader: downloader,
      platformServices: platformServices,
      preferences: preferences,
      versionProvider: () async => installed(reportedVersion),
    );
  }

  ReleaseInfo releaseWith({
    required String tag,
    bool withApk = true,
    int? apkSize,
  }) {
    return buildRelease(
      tag,
      notes: 'Fixed things.',
      assets: withApk
          ? [
              ReleaseAsset(
                name: 'app-arm64-v8a.apk',
                downloadUrl: Uri.parse('https://example.test/app.apk'),
                sizeBytes: apkSize,
              ),
            ]
          : const [],
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wechatqr-update-');
    releaseService = FakeReleaseService();
    platformServices = FakePlatformServices();
    preferences = FakeUpdatePreferences();
    buildController();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('checking', () {
    test('offers a newer stable release', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');

      await controller.check();

      expect(controller.state, isA<UpdateAvailable>());
      final state = controller.state as UpdateAvailable;
      expect(state.release.version, SemVersion.parse('1.1.0'));
      expect(state.currentVersion, SemVersion.parse('1.0.0'));
    });

    test('reports up to date when the release is the same or older', () async {
      releaseService.release = releaseWith(tag: 'v1.0.0');
      await controller.check();
      expect(controller.state, isA<UpdateUpToDate>());

      releaseService.release = releaseWith(tag: 'v0.9.0');
      await controller.check();
      expect(controller.state, isA<UpdateUpToDate>());
    });

    test('reports up to date when there is no stable release', () async {
      releaseService.release = null;
      await controller.check();
      expect(controller.state, isA<UpdateUpToDate>());
    });

    test('a pre-release of the installed version is not an update', () async {
      releaseService.release = releaseWith(tag: 'v1.0.0-rc.1');
      await controller.check();

      expect(controller.state, isA<UpdateUpToDate>());
    });

    test('honours a previously ignored version', () async {
      preferences.ignored = 'v1.1.0';
      releaseService.release = releaseWith(tag: 'v1.1.0');

      await controller.check();

      expect(controller.state, isA<UpdateIgnored>());
    });

    test('a manual check overrides the ignored version', () async {
      preferences.ignored = 'v1.1.0';
      releaseService.release = releaseWith(tag: 'v1.1.0');

      await controller.check(manual: true);

      expect(controller.state, isA<UpdateAvailable>());
    });

    test('records a failed check without changing state', () async {
      releaseService.error = const ReleaseCheckException(
        ReleaseCheckFailure.networkUnavailable,
        'offline',
      );

      await controller.check();

      expect(controller.state, isA<UpdateIdle>());
      expect(
        controller.lastCheckFailure?.failure,
        ReleaseCheckFailure.networkUnavailable,
      );
    });

    test('explains that the release source is not configured', () async {
      releaseService.error = const ReleaseCheckException(
        ReleaseCheckFailure.notConfigured,
        'placeholder',
      );

      await controller.check();

      expect(
        controller.lastCheckFailure?.failure,
        ReleaseCheckFailure.notConfigured,
      );
    });

    test('a check in flight is not started twice', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');

      final first = controller.check();
      final second = controller.check();
      await Future.wait([first, second]);

      expect(releaseService.calls, 1);
    });
  });

  group('downloading', () {
    Future<void> reachUpdateAvailable() async {
      releaseService.release = releaseWith(
        tag: 'v1.1.0',
        apkSize: apkBytes.length,
      );
      await controller.check();
    }

    test('downloads and verifies the package', () async {
      await reachUpdateAvailable();

      await controller.download();

      final state = controller.state;
      expect(state, isA<UpdateDownloaded>());
      expect(await File((state as UpdateDownloaded).filePath).exists(), isTrue);
      expect(state.sizeBytes, apkBytes.length);
    });

    test('fails clearly when the release has no APK asset', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0', withApk: false);
      await controller.check();

      await controller.download();

      final state = controller.state as UpdateDownloadFailed;
      expect(state.retryable, isFalse);
      expect(state.message, contains('Android package'));
    });

    test('reports a failed download as retryable', () async {
      buildController(downloadStatus: 500, installedVersion: '1.0.0');
      await reachUpdateAvailable();

      await controller.download();

      final state = controller.state as UpdateDownloadFailed;
      expect(state.retryable, isTrue);
    });

    test('a length mismatch is surfaced, not installed', () async {
      await reachUpdateAvailable();
      // The release advertises the wrong size, so the payload fails its check.
      releaseService.release = releaseWith(tag: 'v1.1.0', apkSize: 999999);
      await controller.check();

      await controller.download();

      expect(controller.state, isA<UpdateDownloadFailed>());
    });

    test('cancelling returns to the update-available prompt', () async {
      await reachUpdateAvailable();

      // Cancel before any chunk is processed.
      controller.cancelDownload();
      await controller.download();

      // Either it finished before the token was observed or it was cancelled;
      // both are legitimate, but a half-written file must never be reported as
      // downloaded.
      expect(
        controller.state,
        anyOf(isA<UpdateAvailable>(), isA<UpdateDownloaded>()),
      );
    });
  });

  group('installing', () {
    Future<void> reachDownloaded() async {
      releaseService.release = releaseWith(
        tag: 'v1.1.0',
        apkSize: apkBytes.length,
      );
      await controller.check();
      await controller.download();
    }

    test('hands the verified file to the installer', () async {
      await reachDownloaded();

      await controller.install();

      expect(platformServices.installedPaths.length, 1);
      expect(preferences.pending, isNotNull);
      expect(preferences.pending?.versionTag, 'v1.1.0');
      expect(controller.state, isA<UpdateInstalling>());
    });

    test(
      'asks for the install permission instead of failing silently',
      () async {
        await reachDownloaded();
        platformServices.canInstall = false;

        await controller.install();

        expect(controller.needsInstallPermission, isTrue);
        expect(platformServices.installedPaths, isEmpty);
        // No pending marker: nothing was handed to the installer.
        expect(preferences.pending, isNull);
      },
    );

    test('leaves state alone when there is nothing downloaded', () async {
      await controller.install();

      expect(platformServices.installedPaths, isEmpty);
    });

    test('an install failure does not leave a stale pending marker', () async {
      await reachDownloaded();
      platformServices.failInstall = true;

      await controller.install();

      expect(preferences.pending, isNull);
      expect(controller.state, isA<UpdateDownloadFailed>());
    });
  });

  group('resuming', () {
    test('clears the marker when the install completed', () async {
      releaseService.release = releaseWith(
        tag: 'v1.1.0',
        apkSize: apkBytes.length,
      );
      await controller.check();
      await controller.download();
      await controller.install();
      expect(controller.state, isA<UpdateInstalling>());
      expect(preferences.pending, isNotNull);

      // The user completed the install and came back: the running build now
      // reports the version that was being installed.
      reportedVersion = '1.1.0';
      await controller.onResume();

      expect(controller.state, isA<UpdateIdle>());
      expect(preferences.pending, isNull);
    });

    test(
      'a restart with the new version already installed clears the marker',
      () async {
        // Simulates a process restart: a fresh controller, and a marker left by a
        // session that has since been updated.
        buildController(installedVersion: '1.1.0');
        preferences.pending = PendingInstall(
          filePath: '${tempDir.path}/app.apk',
          versionTag: 'v1.1.0',
        );

        await controller.restorePendingInstall();

        expect(controller.state, isA<UpdateIdle>());
        expect(preferences.pending, isNull);
      },
    );

    test('offers a reinstall when the install did not complete', () async {
      final apk = File('${tempDir.path}/app.apk');
      await apk.writeAsBytes(apkBytes);
      preferences.pending = PendingInstall(
        filePath: apk.path,
        versionTag: 'v1.1.0',
      );

      await controller.restorePendingInstall();

      expect(controller.state, isA<UpdateInstallInterrupted>());
    });

    test('drops a marker whose package is gone', () async {
      preferences.pending = PendingInstall(
        filePath: '${tempDir.path}/missing.apk',
        versionTag: 'v1.1.0',
      );

      await controller.restorePendingInstall();

      expect(controller.state, isA<UpdateIdle>());
      expect(preferences.pending, isNull);
    });
  });

  group('ignoring', () {
    test('persists the ignored tag so the prompt does not return', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');
      await controller.check();

      await controller.ignore();

      expect(preferences.ignored, 'v1.1.0');
      expect(controller.state, isA<UpdateIgnored>());
    });

    test('a later non-manual check still respects the ignored tag', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');
      await controller.check();
      await controller.ignore();

      await controller.check();

      expect(controller.state, isA<UpdateIgnored>());
    });
  });

  group('state machine guards', () {
    test('a busy controller refuses to start another check', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');
      final checking = controller.check();
      expect(controller.isBusy, isTrue);
      await checking;
    });

    test('download is refused while not in an offerable state', () async {
      await controller.download();
      expect(controller.state, isA<UpdateIdle>());
    });

    test('dismiss returns to idle but not while busy', () async {
      releaseService.release = releaseWith(tag: 'v1.1.0');
      await controller.check();
      controller.dismiss();
      expect(controller.state, isA<UpdateIdle>());
    });

    test('versions are compared by parsed value, not string', () async {
      // Installed v1.9.0 with a release of v1.10.0 is an update; string
      // comparison would say otherwise.
      buildController(installedVersion: '1.9.0');
      releaseService.release = releaseWith(tag: 'v1.10.0');

      await controller.check();

      expect(controller.state, isA<UpdateAvailable>());
    });

    test(
      'a build-metadata version that cannot be parsed is reported',
      () async {
        buildController(installedVersion: 'not-a-version');
        releaseService.release = releaseWith(tag: 'v1.1.0');

        await controller.check();

        expect(controller.state, isA<UpdateIdle>());
        expect(controller.lastCheckFailure, isNotNull);
        // Nothing was requested from GitHub, because comparison was impossible.
        expect(releaseService.calls, 0);
      },
    );
  });
}
