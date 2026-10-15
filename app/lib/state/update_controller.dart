import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../data/update_preferences.dart';
import '../domain/release_info.dart';
import '../domain/sem_version.dart';
import '../domain/update_state.dart';
import '../services/apk_downloader.dart';
import '../services/app_version_service.dart';
import '../services/release_service.dart';
import 'package:platform_services/platform_services.dart';

/// Drives the update state machine.
///
/// All transitions happen here, which is what makes "never start a second
/// download or a second install" checkable in one place (project spec §8.4,
/// §12.3). The controller performs no I/O itself beyond calling its injected
/// collaborators.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this._releaseService,
    required this._downloader,
    required this._platformServices,
    required this._preferences,
    InstalledVersionProvider? versionProvider,
  }) : _versionProvider = versionProvider ?? readInstalledVersion;

  final ReleaseService _releaseService;
  final ApkDownloader _downloader;
  final PlatformServices _platformServices;
  final UpdatePreferencesStore _preferences;
  final InstalledVersionProvider _versionProvider;

  UpdateState _state = const UpdateIdle();
  UpdateState get state => _state;

  InstalledVersion? _installed;
  InstalledVersion? get installed => _installed;

  /// The running build's version, read from package metadata and cached.
  ///
  /// The settings screen shows this; it is never hardcoded (project spec §8.4).
  Future<InstalledVersion> currentVersion() async {
    final cached = _installed;
    if (cached != null) {
      return cached;
    }
    final version = await _versionProvider();
    _installed = version;
    return version;
  }

  /// Set when the most recent check could not complete, so the settings screen
  /// can explain why instead of silently doing nothing.
  ReleaseCheckException? _lastCheckFailure;
  ReleaseCheckException? get lastCheckFailure => _lastCheckFailure;

  /// Set when an install was attempted without the "install unknown apps"
  /// permission, so the UI can offer the system settings screen.
  bool _needsInstallPermission = false;
  bool get needsInstallPermission => _needsInstallPermission;

  DownloadCancelToken? _cancelToken;

  bool get isBusy =>
      _state is UpdateChecking ||
      _state is UpdateDownloading ||
      _state is UpdateInstalling;

  /// Looks for a newer stable release.
  ///
  /// [manual] is `true` when the user tapped the version row; a manual check
  /// ignores a previous "skip this version".
  Future<void> check({bool manual = false}) async {
    if (isBusy) {
      return;
    }

    _needsInstallPermission = false;
    _lastCheckFailure = null;
    _setState(const UpdateChecking());

    final InstalledVersion installed;
    try {
      installed = await _versionProvider();
      _installed = installed;
    } catch (error) {
      _lastCheckFailure = ReleaseCheckException(
        ReleaseCheckFailure.malformedResponse,
        'The installed version could not be read.',
        cause: error,
      );
      _setState(const UpdateIdle());
      return;
    }

    final current = installed.parsed;
    if (current == null) {
      _lastCheckFailure = const ReleaseCheckException(
        ReleaseCheckFailure.malformedResponse,
        'The installed version is not comparable.',
      );
      _setState(const UpdateIdle());
      return;
    }

    final ReleaseInfo? release;
    try {
      release = await _releaseService.latestStable();
    } on ReleaseCheckException catch (error) {
      _lastCheckFailure = error;
      _setState(const UpdateIdle());
      return;
    } catch (error) {
      _lastCheckFailure = ReleaseCheckException(
        ReleaseCheckFailure.malformedResponse,
        'The release check failed.',
        cause: error,
      );
      _setState(const UpdateIdle());
      return;
    }

    if (release == null || !release.version.isNewerThan(current)) {
      _setState(UpdateUpToDate(current));
      return;
    }

    if (!manual) {
      final ignoredTag = await _preferences.ignoredVersionTag();
      if (ignoredTag == release.tagName) {
        _setState(UpdateIgnored(release));
        return;
      }
    }

    _setState(UpdateAvailable(currentVersion: current, release: release));
  }

  /// Downloads the update package, verifying it before it is kept.
  Future<void> download() async {
    final release = _releaseOf(_state);
    if (release == null || _state is UpdateDownloading) {
      return;
    }

    final asset = AppConfig.selectAndroidAsset(release);
    if (asset == null) {
      _setState(
        UpdateDownloadFailed(
          release: release,
          message: 'This release does not include an Android package.',
          retryable: false,
        ),
      );
      return;
    }

    final token = DownloadCancelToken();
    _cancelToken = token;

    var lastPercent = -1;
    _setState(
      UpdateDownloading(
        release: release,
        receivedBytes: 0,
        totalBytes: asset.sizeBytes,
      ),
    );

    try {
      final downloaded = await _downloader.download(
        asset,
        release: release,
        cancelToken: token,
        onProgress: (received, total) {
          // Notify on whole-percent changes only; a progress callback fires per
          // chunk and would otherwise rebuild the dialog thousands of times.
          final percent = (total == null || total <= 0)
              ? -1
              : ((received / total) * 100).floor();
          if (percent == lastPercent) {
            return;
          }
          lastPercent = percent;
          _setState(
            UpdateDownloading(
              release: release,
              receivedBytes: received,
              totalBytes: total,
            ),
          );
        },
      );

      _setState(
        UpdateDownloaded(
          release: release,
          filePath: downloaded.filePath,
          sizeBytes: downloaded.sizeBytes,
        ),
      );
    } on UpdateDownloadException catch (error) {
      if (error.failure == UpdateDownloadFailure.cancelled) {
        _setState(
          UpdateAvailable(
            currentVersion: _installed?.parsed ?? release.version,
            release: release,
          ),
        );
        return;
      }
      _setState(
        UpdateDownloadFailed(
          release: release,
          message: error.message,
          retryable: error.retryable,
        ),
      );
    } finally {
      _cancelToken = null;
    }
  }

  /// Requests cancellation of an in-flight download. The partial file is
  /// removed by the downloader.
  void cancelDownload() {
    _cancelToken?.cancel();
  }

  /// Hands the downloaded package to the system installer.
  Future<void> install() async {
    final filePath = _installableFilePath(_state);
    final release = _releaseOf(_state);
    if (filePath == null || release == null) {
      return;
    }

    _needsInstallPermission = false;

    final bool canInstall;
    try {
      canInstall = await _platformServices.canInstallPackages();
    } on PlatformServiceException {
      _needsInstallPermission = true;
      notifyListeners();
      return;
    }

    if (!canInstall) {
      _needsInstallPermission = true;
      notifyListeners();
      return;
    }

    await _preferences.setPendingInstall(
      PendingInstall(filePath: filePath, versionTag: release.tagName),
    );
    _setState(UpdateInstalling(release: release, filePath: filePath));

    try {
      await _platformServices.installApk(filePath);
    } on PlatformServiceException catch (error) {
      await _preferences.setPendingInstall(null);
      _setState(
        UpdateDownloadFailed(
          release: release,
          message: error.message,
          retryable: true,
        ),
      );
    }
  }

  /// Opens the system screen for granting "install unknown apps".
  Future<void> openInstallPermissionSettings() async {
    _needsInstallPermission = false;
    notifyListeners();
    await _platformServices.openInstallPermissionSettings();
  }

  /// Skips this release and remembers the choice across restarts.
  Future<void> ignore() async {
    final release = _releaseOf(_state);
    if (release == null) {
      return;
    }
    await _preferences.setIgnoredVersionTag(release.tagName);
    _setState(UpdateIgnored(release));
  }

  /// Returns to the idle state after the user dismisses a prompt.
  void dismiss() {
    if (isBusy) {
      return;
    }
    _needsInstallPermission = false;
    _setState(const UpdateIdle());
  }

  /// Called when the app returns to the foreground.
  ///
  /// Detects the case where the user came back from the system installer
  /// without completing the update, so the UI can offer "reinstall" (project
  /// spec §3.1).
  Future<void> onResume() async {
    if (_state is! UpdateInstalling) {
      return;
    }
    await _resolvePendingInstall(previousRelease: _releaseOf(_state));
  }

  /// Restores the "reinstall" affordance after a process restart, where
  /// [onResume] never had the chance to run.
  Future<void> restorePendingInstall() async {
    if (_state is! UpdateIdle) {
      return;
    }
    await _resolvePendingInstall(previousRelease: null);
  }

  /// Decides whether an install that was handed to the system installer
  /// actually completed.
  ///
  /// The signal is the installed version: if this build now reports the pending
  /// version, the update went through. Otherwise, and only while the package is
  /// still on disk, the UI offers to reinstall it. Every exit path clears the
  /// pending marker so it cannot go stale.
  Future<void> _resolvePendingInstall({
    required ReleaseInfo? previousRelease,
  }) async {
    final pending = await _preferences.pendingInstall();
    if (pending == null) {
      return;
    }

    final installed = await _versionProvider();
    _installed = installed;

    if (_sameVersion(installed.version, pending.versionTag)) {
      await _preferences.setPendingInstall(null);
      _setState(const UpdateIdle());
      return;
    }

    if (!await File(pending.filePath).exists()) {
      await _preferences.setPendingInstall(null);
      _setState(const UpdateIdle());
      return;
    }

    _setState(
      UpdateInstallInterrupted(
        release: previousRelease ?? _releaseFromTag(pending.versionTag),
        filePath: pending.filePath,
      ),
    );
  }

  /// Compares a build-metadata version against a release tag by parsing both,
  /// so `v1.2.0` and `1.2.0` are recognised as the same release.
  static bool _sameVersion(String installedVersion, String tag) {
    final installed = SemVersion.tryParse(installedVersion);
    final tagged = SemVersion.tryParse(tag);
    return installed != null && tagged != null && installed == tagged;
  }

  /// Minimal stand-in release used when only the persisted tag is available,
  /// e.g. after a restart. It carries no assets, so it can never trigger a
  /// download.
  ReleaseInfo _releaseFromTag(String tag) => ReleaseInfo(
    version: SemVersion.tryParse(tag) ?? const SemVersion(major: 0),
    tagName: tag,
    title: tag,
    notes: '',
    htmlUrl: AppConfig.releasesPageUri,
    assets: const <ReleaseAsset>[],
  );

  ReleaseInfo? _releaseOf(UpdateState state) => switch (state) {
    UpdateAvailable(:final release) => release,
    UpdateDownloading(:final release) => release,
    UpdateDownloadFailed(:final release) => release,
    UpdateDownloaded(:final release) => release,
    UpdateInstalling(:final release) => release,
    UpdateInstallInterrupted(:final release) => release,
    UpdateIgnored(:final release) => release,
    UpdateIdle() => null,
    UpdateChecking() => null,
    UpdateUpToDate() => null,
  };

  String? _installableFilePath(UpdateState state) => switch (state) {
    UpdateDownloaded(:final filePath) => filePath,
    UpdateInstallInterrupted(:final filePath) => filePath,
    _ => null,
  };

  void _setState(UpdateState state) {
    _state = state;
    notifyListeners();
  }
}
