import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wechatqr/config/app_config.dart';
import 'package:wechatqr/domain/release_info.dart';
import 'package:wechatqr/domain/sem_version.dart';
import 'package:wechatqr/services/release_service.dart';

/// A well-formed 64-character sha256 hex digest used as the sample value.
/// Built at runtime because `'a' * 64` is not a constant expression.
final String sha256HexDigest = 'a' * 64;

/// A realistic GitHub releases payload.
String releasesJson(List<Map<String, Object?>> releases) =>
    jsonEncode(releases);

Map<String, Object?> releaseJson({
  required String tag,
  bool draft = false,
  bool prerelease = false,
  String name = '',
  String body = 'notes',
  String? digest,
  List<Map<String, Object?>> assets = const [],
}) {
  return {
    'tag_name': tag,
    'name': name.isEmpty ? tag : name,
    'body': body,
    'draft': draft,
    'prerelease': prerelease,
    'html_url': 'https://github.com/o/r/releases/tag/$tag',
    'published_at': '2026-01-02T03:04:05Z',
    'assets': assets,
  };
}

Map<String, Object?> apkAssetJson({
  required String name,
  int size = 12,
  String? digest,
  bool withDigest = true,
}) {
  return {
    'name': name,
    'browser_download_url': 'https://example.test/$name',
    'size': size,
    'digest': withDigest ? (digest ?? 'sha256:$sha256HexDigest') : null,
  };
}

void main() {
  GitHubReleaseService serviceReturning(
    String body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    return GitHubReleaseService(
      enabled: true,
      endpoint: Uri.parse('https://api.example.test/releases'),
      client: MockClient(
        (_) async => http.Response(
          body,
          status,
          headers: {'content-type': 'application/json', ...headers},
        ),
      ),
    );
  }

  group('selectLatestStable', () {
    test('picks the highest stable version, whatever the API order', () {
      final json =
          jsonDecode(
                releasesJson([
                  releaseJson(tag: 'v1.9.0'),
                  releaseJson(tag: 'v1.10.0'),
                  releaseJson(tag: 'v1.2.0'),
                ]),
              )
              as List;

      final latest = GitHubReleaseService.selectLatestStable(json);

      // String ordering would have chosen 1.9.0.
      expect(latest?.version, SemVersion.parse('1.10.0'));
    });

    test('ignores drafts and pre-releases', () {
      final json =
          jsonDecode(
                releasesJson([
                  releaseJson(tag: 'v2.0.0', prerelease: true),
                  releaseJson(tag: 'v3.0.0', draft: true),
                  releaseJson(tag: 'v1.5.0'),
                ]),
              )
              as List;

      expect(
        GitHubReleaseService.selectLatestStable(json)?.version,
        SemVersion.parse('1.5.0'),
      );
    });

    test('returns null when every release is a draft or pre-release', () {
      final json =
          jsonDecode(
                releasesJson([
                  releaseJson(tag: 'v2.0.0-rc.1', prerelease: true),
                  releaseJson(tag: 'v2.0.0', draft: true),
                ]),
              )
              as List;

      expect(GitHubReleaseService.selectLatestStable(json), isNull);
    });

    test('skips entries whose tag is not a comparable version', () {
      final json =
          jsonDecode(
                releasesJson([
                  releaseJson(tag: 'latest'),
                  releaseJson(tag: 'v1.0.0'),
                ]),
              )
              as List;

      expect(GitHubReleaseService.selectLatestStable(json)?.tagName, 'v1.0.0');
    });

    test('tolerates entries that are not maps', () {
      expect(
        GitHubReleaseService.selectLatestStable(const ['nonsense', 42]),
        isNull,
      );
    });
  });

  group('latestStable', () {
    test('parses a good response', () async {
      final service = serviceReturning(
        releasesJson([releaseJson(tag: 'v1.4.0', name: 'Release 1.4.0')]),
      );

      final release = await service.latestStable();

      expect(release?.tagName, 'v1.4.0');
      expect(release?.title, 'Release 1.4.0');
      expect(release?.version, SemVersion.parse('1.4.0'));
    });

    test('reports an unconfigured source without making a request', () async {
      var requests = 0;
      final service = GitHubReleaseService(
        enabled: false,
        endpoint: Uri.parse('https://api.example.test/releases'),
        client: MockClient((_) async {
          requests++;
          return http.Response('[]', 200);
        }),
      );

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.notConfigured,
          ),
        ),
      );
      expect(requests, 0);
    });

    test('maps 404 to notFound', () async {
      final service = serviceReturning('{}', status: 404);

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.notFound,
          ),
        ),
      );
    });

    test('maps an exhausted rate limit to rateLimited', () async {
      final service = serviceReturning(
        '{"message":"API rate limit exceeded"}',
        status: 403,
        headers: {'x-ratelimit-remaining': '0'},
      );

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.rateLimited,
          ),
        ),
      );
    });

    test('maps 429 to rateLimited as well', () async {
      final service = serviceReturning('{}', status: 429);

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.rateLimited,
          ),
        ),
      );
    });

    test('maps an unexplained status to httpError with the code', () async {
      final service = serviceReturning('{}', status: 500);

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>()
              .having(
                (e) => e.failure,
                'failure',
                ReleaseCheckFailure.httpError,
              )
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('maps a body that is not JSON to malformedResponse', () async {
      final service = serviceReturning('<html>nope</html>');

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.malformedResponse,
          ),
        ),
      );
    });

    test('maps a JSON object where a list was expected', () async {
      final service = serviceReturning('{"message":"Not Found"}');

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.malformedResponse,
          ),
        ),
      );
    });

    test('maps a dropped connection to networkUnavailable', () async {
      final service = GitHubReleaseService(
        enabled: true,
        endpoint: Uri.parse('https://api.example.test/releases'),
        client: MockClient(
          (_) async => throw const SocketException('no route to host'),
        ),
      );

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.networkUnavailable,
          ),
        ),
      );
    });
  });

  group('ReleaseInfo.fromGitHubJson', () {
    test('reads assets, including the sha256 digest', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [
            apkAssetJson(name: 'app-release.apk', size: 2048),
            apkAssetJson(name: 'notes.txt', withDigest: false),
          ],
        ),
      )!;

      expect(release.assets.length, 2);
      expect(release.assets.first.name, 'app-release.apk');
      expect(release.assets.first.sizeBytes, 2048);
      expect(release.assets.first.sha256, 'a' * 64);
      expect(release.assets.last.sha256, isNull);
      expect(release.publishedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('ignores a digest that is not a well-formed sha256', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [apkAssetJson(name: 'a.apk', digest: 'sha256:short')],
        ),
      )!;

      expect(release.assets.single.sha256, isNull);
    });

    test('ignores a digest of an unsupported algorithm', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [apkAssetJson(name: 'a.apk', digest: 'md5:${'b' * 32}')],
        ),
      )!;

      expect(release.assets.single.sha256, isNull);
    });

    test('rejects a release with no usable tag or page URL', () {
      expect(ReleaseInfo.fromGitHubJson(null), isNull);
      expect(ReleaseInfo.fromGitHubJson('nope'), isNull);
      expect(ReleaseInfo.fromGitHubJson({}), isNull);
      expect(ReleaseInfo.fromGitHubJson({'tag_name': 'v1.0.0'}), isNull);
      expect(
        ReleaseInfo.fromGitHubJson({'tag_name': 'v1.0.0', 'html_url': ''}),
        isNull,
      );
    });

    test('falls back to the tag when no release name is given', () {
      final json = releaseJson(tag: 'v9.9.9')..remove('name');
      expect(ReleaseInfo.fromGitHubJson(json)?.title, 'v9.9.9');
    });
  });

  group('AppConfig asset selection', () {
    test('names release assets the way the release workflow does', () {
      // Must stay in step with .github/workflows/release.yml; a mismatch means
      // the app would look for an asset that is never published.
      expect(
        AppConfig.androidAssetName('1.2.3'),
        'wechatqr-1.2.3-arm64-v8a.apk',
      );
      expect(AppConfig.iosAssetName('1.2.3'), 'wechatqr-1.2.3.ipa');
    });

    test('the configured APK name is matched by the download selector', () {
      // Round-trip: the name the workflow produces must be the name the app
      // picks out of a release.
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.2.3',
          assets: [
            apkAssetJson(name: AppConfig.androidAssetName('1.2.3')),
            apkAssetJson(name: 'source.zip'),
          ],
        ),
      )!;

      expect(
        AppConfig.selectAndroidAsset(release)?.name,
        'wechatqr-1.2.3-arm64-v8a.apk',
      );
    });

    test('the repository is configured, so the guard is meaningful', () {
      expect(AppConfig.isConfigured, isTrue);
      expect(AppConfig.githubOwner, 'sundys');
      expect(AppConfig.githubRepo, 'WechatQR');
      expect(
        AppConfig.releasesPageUri.toString(),
        'https://github.com/sundys/WechatQR/releases',
      );
      expect(
        AppConfig.releasesApiUri(30).toString(),
        'https://api.github.com/repos/sundys/WechatQR/releases?per_page=30',
      );
    });

    test('prefers arm64-v8a over other APKs', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [
            apkAssetJson(name: 'app-universal.apk'),
            apkAssetJson(name: 'app-arm64-v8a.apk'),
            apkAssetJson(name: 'app-armeabi-v7a.apk'),
          ],
        ),
      )!;

      expect(AppConfig.selectAndroidAsset(release)?.name, 'app-arm64-v8a.apk');
    });

    test('falls back to universal, then any APK', () {
      final universal = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [
            apkAssetJson(name: 'weird-name.apk'),
            apkAssetJson(name: 'app-universal.apk'),
          ],
        ),
      )!;
      expect(
        AppConfig.selectAndroidAsset(universal)?.name,
        'app-universal.apk',
      );

      final anything = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [apkAssetJson(name: 'weird-name.apk')],
        ),
      )!;
      expect(AppConfig.selectAndroidAsset(anything)?.name, 'weird-name.apk');
    });

    test('is case-insensitive about the extension', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [apkAssetJson(name: 'App.APK')],
        ),
      )!;

      expect(AppConfig.selectAndroidAsset(release)?.name, 'App.APK');
    });

    test('returns null when the release carries no APK', () {
      final release = ReleaseInfo.fromGitHubJson(
        releaseJson(
          tag: 'v1.0.0',
          assets: [apkAssetJson(name: 'source.tar.gz')],
        ),
      )!;

      expect(AppConfig.selectAndroidAsset(release), isNull);
    });
  });

  group('mirrors', () {
    test('try every mirror before the original address', () {
      final original = Uri.parse('https://api.github.com/repos/o/r/releases');
      final candidates = AppConfig.candidateUrls(
        original,
        AppConfig.githubApiMirrors,
      );

      expect(candidates.last, original, reason: 'the original must be last');
      expect(candidates.length, AppConfig.githubApiMirrors.length + 1);
    });

    test('substitute the address into a prefix template', () {
      const original = 'https://github.com/o/r/releases/download/v1/a.apk';
      final candidates = AppConfig.candidateUrls(
        Uri.parse(original),
        const <String>['https://gh-proxy.com/{url}'],
      );

      expect(candidates.first.toString(), 'https://gh-proxy.com/$original');
    });

    test('substitute the address into a query template', () {
      const original = 'https://api.github.com/repos/o/r/releases';
      final candidates = AppConfig.candidateUrls(
        Uri.parse(original),
        const <String>['https://github.akams.cn/?url={url}'],
      );

      expect(
        candidates.first.toString(),
        'https://github.akams.cn/?url=$original',
      );
    });

    test('keep the shapes these mirrors were verified with', () {
      // Each was exercised against the real release before being listed, and
      // they are not interchangeable: ghfast.top forwards downloads but answers
      // the API with 403, and github.akams.cn takes the address as a parameter.
      expect(
        AppConfig.githubApiMirrors,
        contains('https://gh-proxy.com/{url}'),
      );
      expect(
        AppConfig.githubDownloadMirrors,
        contains('https://ghfast.top/{url}'),
      );
      expect(
        AppConfig.githubDownloadMirrors,
        contains('https://github.akams.cn/?url={url}'),
      );
      expect(
        AppConfig.githubApiMirrors,
        isNot(contains('https://ghfast.top/{url}')),
      );
    });

    test('fall through a dead mirror to a working address', () async {
      final hosts = <String>[];
      final service = GitHubReleaseService(
        enabled: true,
        endpoint: Uri.parse('https://api.github.com/repos/o/r/releases'),
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host != 'api.github.com') {
            throw const SocketException('mirror unreachable');
          }
          return http.Response(releasesJson([releaseJson(tag: 'v1.1.0')]), 200);
        }),
      );

      final release = await service.latestStable();

      expect(release?.tagName, 'v1.1.0');
      expect(hosts.length, AppConfig.githubApiMirrors.length + 1);
      expect(hosts.last, 'api.github.com');
    });

    test('report a network failure when nothing is reachable', () async {
      final service = GitHubReleaseService(
        enabled: true,
        endpoint: Uri.parse('https://api.github.com/repos/o/r/releases'),
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      await expectLater(
        service.latestStable(),
        throwsA(
          isA<ReleaseCheckException>().having(
            (e) => e.failure,
            'failure',
            ReleaseCheckFailure.networkUnavailable,
          ),
        ),
      );
    });

    test('a mirror serving nonsense falls through as well', () async {
      final service = GitHubReleaseService(
        enabled: true,
        endpoint: Uri.parse('https://api.github.com/repos/o/r/releases'),
        client: MockClient((request) async {
          if (request.url.host != 'api.github.com') {
            return http.Response('<html>proxy error</html>', 200);
          }
          return http.Response(releasesJson([releaseJson(tag: 'v1.2.0')]), 200);
        }),
      );

      expect((await service.latestStable())?.tagName, 'v1.2.0');
    });
  });
}
