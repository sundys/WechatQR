import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wechatqr/domain/release_info.dart';
import 'package:wechatqr/services/apk_downloader.dart';

import '../support/fakes.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wechatqr-downloader-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  final payload = utf8.encode('a small pretend apk');
  final payloadDigest = sha256.convert(payload).toString();

  ApkDownloader downloaderReturning({
    required List<int> body,
    int status = 200,
    Object? throwInstead,
    Map<String, String> headers = const {},
  }) {
    return ApkDownloader(
      updatesDirectoryProvider: () async => tempDir,
      client: MockClient((_) async {
        if (throwInstead != null) {
          throw throwInstead;
        }
        return http.Response.bytes(body, status, headers: headers);
      }),
    );
  }

  ReleaseAsset assetFor({
    String name = 'app-arm64-v8a.apk',
    int? sizeBytes,
    String? sha256,
  }) {
    return ReleaseAsset(
      name: name,
      downloadUrl: Uri.parse('https://example.test/$name'),
      sizeBytes: sizeBytes,
      sha256: sha256,
    );
  }

  group('download', () {
    test('writes a verified file and reports its size', () async {
      final downloader = downloaderReturning(body: payload);
      final release = buildRelease('v1.0.0');

      final result = await downloader.download(
        assetFor(sizeBytes: payload.length, sha256: payloadDigest),
        release: release,
      );

      expect(result.filePath, endsWith('app-arm64-v8a.apk'));
      expect(result.sizeBytes, payload.length);
      final file = File(result.filePath);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), payload);
      // No partial file is left behind.
      expect(await File('${result.filePath}.part').exists(), isFalse);
    });

    test('reports progress and the expected total', () async {
      final downloader = downloaderReturning(body: payload);
      final progress = <int>[];

      await downloader.download(
        assetFor(sizeBytes: payload.length),
        release: buildRelease('v1.0.0'),
        onProgress: (received, total) => progress.add(received),
      );

      expect(progress.first, 0);
      expect(progress.last, payload.length);
    });

    test('rejects a checksum mismatch and deletes the file', () async {
      final downloader = downloaderReturning(body: payload);

      await expectLater(
        downloader.download(
          // Correct length, wrong digest: only the checksum can catch this.
          assetFor(sizeBytes: payload.length, sha256: 'f' * 64),
          release: buildRelease('v1.0.0'),
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.checksumMismatch,
          ),
        ),
      );

      expect(await File('${tempDir.path}/app-arm64-v8a.apk').exists(), isFalse);
      expect(
        await File('${tempDir.path}/app-arm64-v8a.apk.part').exists(),
        isFalse,
      );
    });

    test('rejects a length mismatch against the release metadata', () async {
      final downloader = downloaderReturning(body: payload);

      await expectLater(
        downloader.download(
          // The release claims more bytes than the server sent.
          assetFor(sizeBytes: payload.length + 100),
          release: buildRelease('v1.0.0'),
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.lengthMismatch,
          ),
        ),
      );

      expect(await File('${tempDir.path}/app-arm64-v8a.apk').exists(), isFalse);
    });

    test('maps a non-200 status and marks 404 as non-retryable', () async {
      final notFound = downloaderReturning(body: const [], status: 404);
      await expectLater(
        notFound.download(assetFor(), release: buildRelease('v1.0.0')),
        throwsA(
          isA<UpdateDownloadException>()
              .having(
                (e) => e.failure,
                'failure',
                UpdateDownloadFailure.httpStatus,
              )
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );

      final serverError = downloaderReturning(body: const [], status: 500);
      await expectLater(
        serverError.download(assetFor(), release: buildRelease('v1.0.0')),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });

    test('maps a dropped connection to a network failure', () async {
      final downloader = downloaderReturning(
        body: const [],
        throwInstead: const SocketException('offline'),
      );

      await expectLater(
        downloader.download(assetFor(), release: buildRelease('v1.0.0')),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.network,
          ),
        ),
      );
    });

    test('refuses an asset larger than the configured cap', () async {
      final downloader = downloaderReturning(body: payload);

      await expectLater(
        downloader.download(
          assetFor(sizeBytes: 1024 * 1024 * 1024 * 2),
          release: buildRelease('v1.0.0'),
        ),
        throwsA(
          isA<UpdateDownloadException>()
              .having(
                (e) => e.failure,
                'failure',
                UpdateDownloadFailure.tooLarge,
              )
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('a cancelled download leaves nothing behind', () async {
      final token = DownloadCancelToken()..cancel();
      final downloader = downloaderReturning(body: payload);

      await expectLater(
        downloader.download(
          assetFor(),
          release: buildRelease('v1.0.0'),
          cancelToken: token,
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.cancelled,
          ),
        ),
      );

      expect(await File('${tempDir.path}/app-arm64-v8a.apk').exists(), isFalse);
    });

    test('strips any directory component from the asset name', () async {
      final downloader = downloaderReturning(body: payload);

      final result = await downloader.download(
        assetFor(name: '../../escape.apk'),
        release: buildRelease('v1.0.0'),
      );

      // The file lands inside the updates directory, not above it.
      expect(result.filePath, endsWith('escape.apk'));
      expect(
        File(result.filePath).parent.resolveSymbolicLinksSync(),
        tempDir.resolveSymbolicLinksSync(),
      );
    });
  });

  group('storage housekeeping', () {
    test('a successful download removes the previous package', () async {
      final stale = File('${tempDir.path}/app-old.apk');
      await stale.writeAsBytes([1, 2, 3]);

      final downloader = downloaderReturning(body: payload);
      final result = await downloader.download(
        assetFor(),
        release: buildRelease('v1.0.0'),
      );

      expect(await stale.exists(), isFalse);
      expect(await File(result.filePath).exists(), isTrue);
    });

    test('a failed download does not remove the previous package', () async {
      final stale = File('${tempDir.path}/app-old.apk');
      await stale.writeAsBytes([1, 2, 3]);

      final downloader = downloaderReturning(body: const [], status: 500);
      await expectLater(
        downloader.download(assetFor(), release: buildRelease('v1.0.0')),
        throwsA(isA<UpdateDownloadException>()),
      );

      // The user is never left without a usable package.
      expect(await stale.exists(), isTrue);
    });

    test('pendingApk returns the newest package or null', () async {
      final downloader = downloaderReturning(body: payload);
      expect(await downloader.pendingApk(), isNull);

      await File('${tempDir.path}/older.apk').writeAsBytes([1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newer = File('${tempDir.path}/newer.apk');
      await newer.writeAsBytes([2, 3]);

      final pending = await downloader.pendingApk();
      // Compared by name because `Directory.list()` yields platform-native
      // separators while the literal above may use '/'.
      expect(pending?.uri.pathSegments.last, 'newer.apk');
    });
  });
}
