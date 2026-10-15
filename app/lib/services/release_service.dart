import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../domain/release_info.dart';

/// Why a release check could not be completed.
enum ReleaseCheckFailure {
  /// The GitHub owner/repo placeholders have not been replaced yet.
  notConfigured,

  /// No network, DNS failure, TLS failure, timeout.
  networkUnavailable,

  /// GitHub rate limit exhausted for this client (unauthenticated requests are
  /// limited per IP).
  rateLimited,

  /// The repository or its releases do not exist.
  notFound,

  /// A non-success HTTP status that is not otherwise classified.
  httpError,

  /// The response was not the JSON shape this code expects.
  malformedResponse,
}

class ReleaseCheckException implements Exception {
  const ReleaseCheckException(
    this.failure,
    this.message, {
    this.statusCode,
    this.cause,
  });

  final ReleaseCheckFailure failure;
  final String message;
  final int? statusCode;

  /// The originating exception, kept for diagnostics. Never shown to the user.
  final Object? cause;

  @override
  String toString() =>
      'ReleaseCheckException(${failure.name}, status: $statusCode, $message)';
}

/// Looks up the newest stable release of the configured repository.
abstract interface class ReleaseService {
  /// Returns the newest stable release, or `null` when the repository has no
  /// stable release yet. Throws [ReleaseCheckException] on failure.
  Future<ReleaseInfo?> latestStable();
}

class GitHubReleaseService implements ReleaseService {
  /// [enabled] defaults to [AppConfig.isConfigured]. It is injectable so the
  /// transport and parsing can be tested against an explicit endpoint, and so
  /// the "no repository configured" path is covered too.
  GitHubReleaseService({
    http.Client? client,
    Duration? timeout,
    Uri? endpoint,
    bool? enabled,
  }) : _client = client ?? http.Client(),
       _timeout = timeout ?? const Duration(seconds: 20),
       _endpoint =
           endpoint ?? AppConfig.releasesApiUri(AppConfig.releasePageSize),
       _enabled = enabled ?? AppConfig.isConfigured;

  final http.Client _client;
  final Duration _timeout;
  final Uri _endpoint;
  final bool _enabled;

  @override
  Future<ReleaseInfo?> latestStable() async {
    if (!_enabled) {
      throw const ReleaseCheckException(
        ReleaseCheckFailure.notConfigured,
        'The GitHub repository for release checks has not been configured.',
      );
    }

    // Mirrors first, the original address last. A network that can reach GitHub
    // directly therefore still talks to GitHub; one that cannot gets the same
    // bytes through a forwarder (project spec: the release source must work
    // where GitHub is unreachable).
    ReleaseCheckException? lastFailure;
    for (final endpoint in AppConfig.candidateUrls(
      _endpoint,
      AppConfig.githubApiMirrors,
    )) {
      try {
        return await _fetch(endpoint);
      } on ReleaseCheckException catch (error) {
        lastFailure = error;
      }
    }

    throw lastFailure ??
        const ReleaseCheckException(
          ReleaseCheckFailure.networkUnavailable,
          'The release check could not reach GitHub or any of its mirrors.',
        );
  }

  /// One attempt against a single address.
  Future<ReleaseInfo?> _fetch(Uri endpoint) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            endpoint,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              // GitHub rejects requests without a User-Agent.
              'User-Agent': 'WeChatQR-UpdateChecker',
            },
          )
          // The shorter of the two: a mirror that is down should hand over to the
          // next candidate rather than holding the check for the full timeout.
          .timeout(
            _timeout < AppConfig.mirrorAttemptTimeout
                ? _timeout
                : AppConfig.mirrorAttemptTimeout,
          );
    } on TimeoutException catch (error) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.networkUnavailable,
        'The release check timed out.',
        cause: error,
      );
    } on SocketException catch (error) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.networkUnavailable,
        'The release check could not reach GitHub.',
        cause: error,
      );
    } on http.ClientException catch (error) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.networkUnavailable,
        'The release check could not reach GitHub.',
        cause: error,
      );
    }

    _ensureSuccess(response);

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.malformedResponse,
        'The release response was not valid JSON.',
        statusCode: response.statusCode,
        cause: error,
      );
    }

    if (decoded is! List) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.malformedResponse,
        'The release response was not a list of releases.',
        statusCode: response.statusCode,
      );
    }

    return selectLatestStable(decoded);
  }

  void _ensureSuccess(http.Response response) {
    final status = response.statusCode;
    if (status == 200) {
      return;
    }

    if (status == 403 || status == 429) {
      final remaining = response.headers['x-ratelimit-remaining'];
      if (status == 429 || remaining == '0') {
        throw ReleaseCheckException(
          ReleaseCheckFailure.rateLimited,
          'GitHub rate limit reached. Try again later.',
          statusCode: status,
        );
      }
    }

    if (status == 404) {
      throw ReleaseCheckException(
        ReleaseCheckFailure.notFound,
        'The configured repository or its releases could not be found.',
        statusCode: status,
      );
    }

    throw ReleaseCheckException(
      ReleaseCheckFailure.httpError,
      'GitHub returned HTTP $status.',
      statusCode: status,
    );
  }

  /// Picks the newest stable release from a GitHub releases list.
  ///
  /// Drafts and pre-releases are ignored, as are entries whose tag is not a
  /// version this app can compare. Returns `null` when nothing usable remains
  /// (project spec §8.4).
  static ReleaseInfo? selectLatestStable(List<Object?> releasesJson) {
    ReleaseInfo? newest;

    for (final entry in releasesJson) {
      if (entry is! Map) {
        continue;
      }
      if (entry['draft'] == true || entry['prerelease'] == true) {
        continue;
      }

      final release = ReleaseInfo.fromGitHubJson(entry);
      if (release == null) {
        continue;
      }

      if (newest == null || release.version.isNewerThan(newest.version)) {
        newest = release;
      }
    }

    return newest;
  }
}
