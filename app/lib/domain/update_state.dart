import 'release_info.dart';
import 'sem_version.dart';

/// Explicit state machine for the update flow.
///
/// Every transition is driven by [UpdateController]; nothing else constructs
/// these states, which keeps "do not trigger a second download or install"
/// enforceable in one place.
sealed class UpdateState {
  const UpdateState();
}

/// Nothing in flight. Also the state after the user dismisses a prompt.
final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// A release check is running.
final class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

/// The check completed and the installed build is current.
final class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate(this.currentVersion);

  final SemVersion currentVersion;
}

/// A newer stable release exists and the user has not yet answered.
final class UpdateAvailable extends UpdateState {
  const UpdateAvailable({required this.currentVersion, required this.release});

  final SemVersion currentVersion;
  final ReleaseInfo release;
}

/// Downloading the update package. [totalBytes] is `null` when the server did
/// not report a length.
final class UpdateDownloading extends UpdateState {
  const UpdateDownloading({
    required this.release,
    required this.receivedBytes,
    this.totalBytes,
  });

  final ReleaseInfo release;
  final int receivedBytes;
  final int? totalBytes;

  /// Fraction in `0.0..1.0`, or `null` when the total size is unknown.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// The download stopped before a usable file existed. Partial files are
/// removed; [retryable] is false for conditions a retry cannot fix (HTTP 404,
/// missing asset).
final class UpdateDownloadFailed extends UpdateState {
  const UpdateDownloadFailed({
    required this.release,
    required this.message,
    this.retryable = true,
  });

  final ReleaseInfo release;
  final String message;
  final bool retryable;
}

/// A complete, length- and (when available) digest-verified file is on disk and
/// ready to hand to the system installer.
final class UpdateDownloaded extends UpdateState {
  const UpdateDownloaded({
    required this.release,
    required this.filePath,
    required this.sizeBytes,
  });

  final ReleaseInfo release;
  final String filePath;
  final int sizeBytes;
}

/// The system installer has been launched for [filePath].
final class UpdateInstalling extends UpdateState {
  const UpdateInstalling({required this.release, required this.filePath});

  final ReleaseInfo release;
  final String filePath;
}

/// The user came back from the installer without the update being applied. The
/// UI offers "reinstall" from this state.
final class UpdateInstallInterrupted extends UpdateState {
  const UpdateInstallInterrupted({
    required this.release,
    required this.filePath,
  });

  final ReleaseInfo release;
  final String filePath;
}

/// The user chose to skip this release; the prompt must not reappear for the
/// same version, but a manual tap on the version row may re-check.
final class UpdateIgnored extends UpdateState {
  const UpdateIgnored(this.release);

  final ReleaseInfo release;
}
