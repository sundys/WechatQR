# 0005 — Update flow and release configuration

Date: 2026-10-15
Status: Accepted

## Context

CLAUDE.md §8.4 requires a release check against GitHub, semantic version comparison, a specific
state machine (§12.3), an install hand-off that never bypasses the system installer (§3.1), and — for
iOS — no in-app download at all (§3.2). It also requires the repository address, API endpoint and
asset-matching rules to be configured in one place.

## Configuration

Everything lives in `app/lib/config/app_config.dart`:

```dart
static const String githubOwner = 'sundys';
static const String githubRepo  = 'WechatQR';
static bool get isConfigured => ...;   // guards the check
```

While `isConfigured` is false the app reports 尚未配置更新仓库地址 and makes no network call. It is
false only if the constants are emptied or left as placeholders, which is what keeps the guard — and
its test — meaningful.

Release assets are produced by `.github/workflows/release.yml` under the names the matcher expects:

```
wechatqr-<version>-arm64-v8a.apk
wechatqr-<version>.ipa
```

Asset selection prefers, in order: `arm64-v8a`, `universal`, `armeabi-v7a`, then any `*.apk`. This
matches the ABI the app actually ships, so the downloaded package will install on the device that
asked for it.

## Version comparison

`SemVersion` implements the semver precedence rules rather than string ordering — `1.10.0` is newer
than `1.9.0`, and `1.0.0-rc.1` is older than `1.0.0`. It tolerates a leading prefix (`v1.2.3`,
`app-v1.2.3`) and missing minor/patch, and rejects anything else, including the four-part `1.2.3.4`
that would otherwise be silently truncated. Rejecting is deliberate: a malformed tag must not be
mistaken for a valid version and offered as an update.

The installed version is read from package metadata via `package_info_plus` and never hardcoded.

The release *list* endpoint is used rather than `/releases/latest`, because the latter returns a
pre-release when one is newest and the spec requires those to be ignored by default.

## State machine

`UpdateState` is a sealed hierarchy covering `Idle`, `Checking`, `UpToDate`, `Available`,
`Downloading`, `DownloadFailed`, `Downloaded`, `Installing`, `InstallInterrupted` and `Ignored`.
`UpdateController` is the only thing that constructs these states, which is what makes "never start a
second download or install" checkable in one place. UI dialogs render states; they never decide.

## Download verification

Before a package can be handed to the installer, all of the following must hold:

1. HTTP status is 200.
2. The byte count matches the response `Content-Length`.
3. The byte count matches the release API's advertised `size`.
4. If GitHub published a `digest`, the SHA-256 matches.
5. The size is under the configured cap.

A failure at any step deletes the partial file. Only after a good package exists is the previous one
removed, so a failed download never leaves the app without a usable APK. A package that cannot be
deleted — most likely because the installer is holding it — is left alone, per §3.1.

## Install hand-off

`platform_services` exposes the file through a `FileProvider` whose paths are limited to
`<filesDir>/updates`. `installApk` canonicalises the requested path and refuses anything outside that
directory, so a malformed or hostile path cannot reach the installer. The app always checks
`canRequestPackageInstalls()` first and offers the system *install unknown apps* screen when it is
not granted; it never installs silently.

## Interrupted installs

When the installer is launched, a `PendingInstall` marker (path plus release tag) is persisted. On
resume — or after a process restart, via `restorePendingInstall` — the installed version is compared
against the tag: equal means the update went through and the marker is cleared; otherwise the UI
offers 重新安装, and only while the package is still on disk.

## iOS

The version row opens the Releases page in the browser. `installApk`, `canInstallPackages` and the
install-permission screen report `unsupported` from the iOS implementation rather than pretending;
there is no APK installation path on iOS and none is claimed.

## Release pipeline

`.github/workflows/release.yml` builds the Android artifact this flow consumes and publishes it as a
GitHub Release. Android signing comes from repository secrets (`ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`); the keystore is written
only into the runner's temp directory and never echoed. A **tagged** run aborts if any of the four is
missing, so a debug-signed APK cannot be published by accident, while an untagged run falls back to
the debug key with a loud Gradle warning. A `v*` tag also checks that the tag equals the version in
`app/pubspec.yaml` before building.

The `.ipa` is produced separately by the manual `.github/workflows/ios.yml` and can be attached to an
existing release, so a slow iOS build never blocks an Android release.

The workflow asserts the properties this decision depends on, rather than trusting the build: the
release APK must contain `lib/arm64-v8a/libopencv_java4.so` and the four models, and must contain no
other ABI.

## Not verified

* No check has been run against a live release, because no release exists yet.
* The download, verify and install hand-off have never run on a device. Covered by unit tests with a
  mock HTTP client and a temporary directory, which is not the same thing.
* The workflows themselves have not run on GitHub. Their shell steps were dry-run against a locally
  built release APK, which is not the same as a green CI run.
