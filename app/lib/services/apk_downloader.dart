import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../domain/release_info.dart';

/// Why an update package could not be downloaded.
enum UpdateDownloadFailure {
  network,
  httpStatus,

  /// The file was shorter or longer than the server and/or the release API
  /// said it would be.
  lengthMismatch,

  /// The SHA-256 of the received bytes did not match the published digest.
  checksumMismatch,

  /// The user cancelled.
  cancelled,

  /// The advertised size exceeds [AppConfig.maxDownloadBytes].
  tooLarge,

  /// The file could not be written to app-private storage.
  storage,
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(
    this.failure,
    this.message, {
    this.statusCode,
    this.cause,
    this.retryable = true,
  });

  final UpdateDownloadFailure failure;
  final String message;
  final int? statusCode;
  final Object? cause;

  /// `false` for conditions a retry cannot fix (404, missing asset).
  final bool retryable;

  @override
  String toString() =>
      'UpdateDownloadException(${failure.name}, status: $statusCode, $message)';
}

/// Cooperative cancellation for an in-flight download.
class DownloadCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// A verified update package sitting in app-private storage.
class DownloadedApk {
  const DownloadedApk({
    required this.filePath,
    required this.sizeBytes,
    required this.release,
    required this.asset,
  });

  final String filePath;
  final int sizeBytes;
  final ReleaseInfo release;
  final ReleaseAsset asset;
}

/// Downloads and verifies an update APK.
///
/// Everything a downloaded file must pass before it can be handed to the
/// installer lives here: HTTP status, byte count against both the response
/// `Content-Length` and the release API's advertised size, and the SHA-256
/// digest when GitHub publishes one. A file that fails any check is deleted
/// rather than left around to be installed by mistake (project spec §3.1).
class ApkDownloader {
  ApkDownloader({
    http.Client? client,
    Future<Directory> Function()? updatesDirectoryProvider,
    Duration? timeout,
  }) : _client = client ?? http.Client(),
       _updatesDirectoryProvider =
           updatesDirectoryProvider ?? _defaultUpdatesDirectory,
       _timeout = timeout ?? const Duration(minutes: 5);

  /// Subdirectory of the app's private files directory that the installer's
  /// FileProvider exposes. This is the only place an APK may live.
  static const String updatesDirectoryName = 'updates';

  final http.Client _client;
  final Future<Directory> Function() _updatesDirectoryProvider;
  final Duration _timeout;

  static Future<Directory> _defaultUpdatesDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}$updatesDirectoryName',
    );
  }

  Future<Directory> _updatesDirectory() async {
    final directory = await _updatesDirectoryProvider();
    await directory.create(recursive: true);
    return directory;
  }

  /// Returns the APK already waiting in private storage, if any.
  ///
  /// Used to offer "reinstall" after the user returns from the system installer
  /// without completing the update, and to avoid re-downloading on resume.
  Future<File?> pendingApk() async {
    final directory = await _updatesDirectory();
    File? newest;
    DateTime? newestTime;

    await for (final entity in directory.list()) {
      if (entity is! File || !_isApk(entity.path)) {
        continue;
      }
      final modified = await entity.lastModified();
      if (newestTime == null || modified.isAfter(newestTime)) {
        newest = entity;
        newestTime = modified;
      }
    }

    return newest;
  }

  /// Downloads [asset] and returns the verified file.
  ///
  /// [onProgress] receives bytes written and the expected total when known.
  /// Throws [UpdateDownloadException]; nothing is left on disk when it throws.
  Future<DownloadedApk> download(
    ReleaseAsset asset, {
    required ReleaseInfo release,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    final advertised = asset.sizeBytes;
    if (advertised != null && advertised > AppConfig.maxDownloadBytes) {
      throw UpdateDownloadException(
        UpdateDownloadFailure.tooLarge,
        'The update package is larger than this app will download.',
        retryable: false,
      );
    }

    final directory = await _updatesDirectory();
    final fileName = _sanitizeFileName(asset.name);
    final target = File('${directory.path}${Platform.pathSeparator}$fileName');
    final partial = File('${target.path}.part');

    await _deleteIfExists(partial);

    final digestSink = _DigestSink();
    ByteConversionSink? digestInput;

    try {
      final request = http.Request('GET', asset.downloadUrl);
      request.headers['User-Agent'] = 'WeChatQR-UpdateChecker';

      final response = await _client
          .send(request)
          .timeout(
            _timeout,
            onTimeout: () {
              throw const UpdateDownloadException(
                UpdateDownloadFailure.network,
                'The download timed out.',
              );
            },
          );

      if (response.statusCode != 200) {
        throw UpdateDownloadException(
          UpdateDownloadFailure.httpStatus,
          'The update server returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
          retryable: response.statusCode != 404,
        );
      }

      final total = response.contentLength ?? advertised;
      if (total != null && total > AppConfig.maxDownloadBytes) {
        throw const UpdateDownloadException(
          UpdateDownloadFailure.tooLarge,
          'The update package is larger than this app will download.',
          retryable: false,
        );
      }

      digestInput = sha256.startChunkedConversion(digestSink);

      final sink = partial.openWrite();
      var received = 0;
      onProgress?.call(received, total);

      try {
        await for (final chunk in response.stream) {
          if (cancelToken?.isCancelled ?? false) {
            throw const UpdateDownloadException(
              UpdateDownloadFailure.cancelled,
              'The download was cancelled.',
            );
          }
          received += chunk.length;
          if (received > AppConfig.maxDownloadBytes) {
            throw const UpdateDownloadException(
              UpdateDownloadFailure.tooLarge,
              'The update package is larger than this app will download.',
              retryable: false,
            );
          }
          sink.add(chunk);
          digestInput.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      digestInput.close();
      digestInput = null;

      // Verify before the file is allowed to exist under its real name.
      final contentLength = response.contentLength;
      if (contentLength != null && received != contentLength) {
        throw UpdateDownloadException(
          UpdateDownloadFailure.lengthMismatch,
          'Expected $contentLength bytes but received $received.',
        );
      }
      if (advertised != null && received != advertised) {
        throw UpdateDownloadException(
          UpdateDownloadFailure.lengthMismatch,
          'The release lists $advertised bytes but $received were received.',
        );
      }

      final expectedDigest = asset.sha256;
      if (expectedDigest != null) {
        final actual = digestSink.value?.toString();
        if (actual == null || actual.toLowerCase() != expectedDigest) {
          throw const UpdateDownloadException(
            UpdateDownloadFailure.checksumMismatch,
            'The downloaded file did not match its published checksum.',
          );
        }
      }

      await _deleteIfExists(target);
      final installed = await _promote(partial, target);

      // Only now that a good package exists is the previous one removed, so a
      // failed download never leaves the app without a usable APK.
      await _removeOtherApks(directory, keep: installed.path);

      return DownloadedApk(
        filePath: installed.path,
        sizeBytes: received,
        release: release,
        asset: asset,
      );
    } on UpdateDownloadException {
      await _deleteIfExists(partial);
      rethrow;
    } on SocketException catch (error) {
      await _deleteIfExists(partial);
      throw UpdateDownloadException(
        UpdateDownloadFailure.network,
        'The download could not be completed.',
        cause: error,
      );
    } on http.ClientException catch (error) {
      await _deleteIfExists(partial);
      throw UpdateDownloadException(
        UpdateDownloadFailure.network,
        'The download could not be completed.',
        cause: error,
      );
    } on FileSystemException catch (error) {
      await _deleteIfExists(partial);
      throw UpdateDownloadException(
        UpdateDownloadFailure.storage,
        'The update package could not be written to storage.',
        cause: error,
      );
    } finally {
      // Closing twice is a no-op for the chunked conversion sink.
      digestInput?.close();
    }
  }

  /// Deletes every other APK in the private updates directory.
  ///
  /// Failures are ignored on purpose: the most likely reason a delete fails is
  /// that the system installer is still holding the previous package, and the
  /// spec forbids removing a file the installer is using.
  Future<void> _removeOtherApks(
    Directory directory, {
    required String keep,
  }) async {
    try {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path != keep && _isApk(entity.path)) {
          try {
            await entity.delete();
          } on FileSystemException {
            // Left in place deliberately.
          }
        }
      }
    } on FileSystemException {
      // Directory unreadable; nothing to clean up.
    }
  }

  /// Moves the verified partial file into place.
  Future<File> _promote(File partial, File target) async {
    try {
      return await partial.rename(target.path);
    } on FileSystemException {
      // Some platforms refuse to rename over an existing file.
      await _deleteIfExists(target);
      final copied = await partial.copy(target.path);
      await _deleteIfExists(partial);
      return copied;
    }
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best effort.
    }
  }

  static bool _isApk(String path) =>
      AppConfig.androidAssetPattern.hasMatch(path);

  /// Strips any directory component from an asset name so a hostile or
  /// malformed release cannot write outside the updates directory.
  static String _sanitizeFileName(String name) {
    final base = name.split(RegExp(r'[/\\]')).last.trim();
    if (base.isEmpty || base == '.' || base == '..') {
      return 'update.apk';
    }
    return base;
  }
}

/// Minimal [Sink] that captures the single digest produced by a chunked
/// conversion, avoiding a dependency on `package:convert`.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
