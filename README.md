# WeChatQR

A QR code app for **Android** (full feature set) and **iOS via TrollStore**, built with Flutter.
Recognition is powered by OpenCV's **WeChatQRCode** engine — the CNN detector, super-resolution
model and decoder contributed by the WeChat Computer Vision Team.

See [`CLAUDE.md`](CLAUDE.md) for the project's development rules; this README describes what the
repository actually contains and what has actually been verified.

---

## Status

| Area | State |
|---|---|
| Dart unit tests | **149 passing** (`flutter test`) |
| `flutter analyze` | **Clean** across `app`, `packages/wechat_qrcode`, `packages/platform_services` |
| Android debug build | **Succeeds** — APK verified to contain `libopencv_java4.so` and all four models |
| Android release build | **Succeeds** — arm64-v8a only, 43.3 MB, models verified byte-identical to upstream |
| Android on-device behaviour | **Not verified** — no device or emulator was available |
| iOS build | **Not verified** — requires macOS; no Mac was available |
| Release workflow | **Not verified** — CI has not run yet; the steps were validated locally against a real APK |
| Update flow against a live release | **Not verified** — no release exists yet |

Nothing in this table is aspirational: items marked *not verified* have working code and tests but
have never been compiled or run on their target platform.

The release APK was built with the debug signing key, because no upload key exists on this machine —
which is exactly the case the release workflow refuses to publish.

---

## What the app does

Three tabs, with the scan tab as the launch destination.

**扫描 (Scan)** — full-bleed live camera preview that starts as soon as camera permission is
available, with the reference project's viewfinder frame and animated scan line. Each detected code
is marked with a green indicator. Decoded results appear in a scrollable, non-fullscreen sheet with
copy and (for validated `http`/`https` URLs) open-in-browser actions. Bottom-left **历史** opens the
history sheet; bottom-right **相册** picks one picture and decodes it. A torch toggle sits top-right.

When several codes are in one frame the app does not guess: it marks them all and waits **3 seconds**
for a tap on one of the markers. Tapping shows that code alone; letting the window elapse shows every
result.

**生成 (Generate)** — multi-line input with 粘贴 / 生成 / 清空, renders a QR code, and offers
save-to-gallery and share.

**设置 (Settings)** — theme (跟随系统 / 浅色 / 暗色), four scan switches (自动打开网站, 连续扫描,
自动复制剪贴板, 振动), plus 介绍, 开源许可 and 应用版本与更新.

History and settings are stored on the device only. Nothing is uploaded.

---

## Layout

```
WechatQR/
├── CLAUDE.md                     development rules for this repository
├── app/                          Flutter application (shared UI + logic)
├── packages/wechat_qrcode/        Flutter plugin wrapping the native engine
│   ├── lib/                       Dart API
│   ├── android/                   Kotlin: vendored wechat-qrcode + CameraX scanner
│   └── ios/                       Swift + ObjC++ wrapper over cv::wechat_qrcode
├── packages/platform_services/    Flutter plugin for device capabilities
├── scripts/build_opencv_ios.sh    macOS-only: builds opencv2.xcframework (unverified)
├── docs/                          architecture, decisions, licence notices
└── WeChatQRCode/                  local reference checkout — NEVER committed
```

`WeChatQRCode/` is the upstream project used for reading and integration reference only. It is
listed in `.gitignore` and must never be pushed.

---

## Build and run

Prerequisites: Flutter 3.44+ (Dart 3.12+), JDK 17, Android SDK with platform 36 and build-tools 36.

```bash
cd app
flutter pub get
flutter test          # 149 unit tests
flutter analyze
```

### Android

```bash
cd app

# Debug: arm64-v8a + x86_64, so it also runs on an emulator.
flutter build apk --debug

# Release: arm64-v8a only — the ABI libopencv_java4.so is shipped for.
flutter build apk --release --target-platform android-arm64
```

Only `arm64-v8a` (and `x86_64` in debug) are packaged. This is enforced in
`app/android/app/build.gradle.kts`, because the WeChatQRCode engine is a prebuilt native library:
an APK built for another ABI would install and then fail at runtime. 32-bit-only devices are
therefore **not supported** by this build.

### iOS (TrollStore)

Cannot be built on Windows. On macOS:

```bash
# 1. Produce the OpenCV framework this plugin links against (not committed).
scripts/build_opencv_ios.sh

# 2. Build the app.
cd app
flutter build ios --release          # then archive/export an .ipa
```

The resulting `.ipa` is intended for installation with **TrollStore**. It is not built for App Store
distribution and no App Store review path is claimed. See
[`docs/decisions/0006-ios-trollstore.md`](docs/decisions/0006-ios-trollstore.md) for what remains to
be verified on a device.

---

## Update source

Configured in one place, `app/lib/config/app_config.dart`:

```dart
static const String githubOwner = 'sundys';
static const String githubRepo  = 'WechatQR';
static bool get isConfigured => ...;   // guards the check
```

Release assets must follow the naming the app's matcher expects:

```
wechatqr-<version>-arm64-v8a.apk
wechatqr-<version>.ipa
```

The ABI is part of the APK name so `AppConfig.androidAbiPreference` can match it and so nobody
installs an arm64 package on a device it cannot run on. `.github/workflows/release.yml` produces
exactly these names.

Where GitHub is unreachable, the check and the download fall through a list of forwarders in
`AppConfig`, trying GitHub's own address last so a working connection never goes through a third
party. The forwarders were each verified against a real release before being listed; see
[ADR-0005](docs/decisions/0005-update-flow.md), which also explains why the digest check is a
corruption check and that Android's own signature verification is what prevents a substituted
package from being installed.

---

## Releasing

Three workflows, all in `.github/workflows/`:

* **`ci.yml`** — on every push to `main` and every PR: formatting, `flutter analyze` across all three
  packages, `flutter test`, plus a debug APK build that asserts the APK really contains
  `libopencv_java4.so` and the four model files.
* **`release.yml`** — on a `v*` tag: builds the Android APK and publishes a GitHub Release. Also
  runnable manually, which builds the APK without publishing anything.
* **`ios.yml`** — **manual only**. Builds the TrollStore `.ipa` and can attach it to an existing
  release.

iOS is kept out of the tag pipeline on purpose: a cold run has to compile OpenCV for iOS, which takes
tens of minutes and would hold up every Android release. Build the `.ipa` when you want it.

### Before the first tagged release

Android signing configuration must exist as repository secrets. Until then, run `release.yml`
manually: it builds and verifies the APK and **publishes nothing**. Note that a manual run leaves no
downloadable output — artifacts are published only through releases, so use a tag when you want a
file.

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | The `.jks`, base64-encoded: `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Store password |
| `ANDROID_KEY_ALIAS` | Key alias |
| `ANDROID_KEY_PASSWORD` | Key password |

The keystore is decoded only into the runner's temporary directory, and its contents are never
echoed. A **tagged** build fails immediately if any of the four is missing, so a debug-signed APK
cannot be published by accident; an untagged build falls back to the debug key and says so loudly in
the Gradle log.

### Cutting an Android release

```bash
# 1. Set the version — the tag must match it exactly.
#    app/pubspec.yaml:  version: 1.0.0+1

# 2. Commit, then tag and push.
git tag v1.0.0
git push origin v1.0.0
```

`release.yml` then:

1. verifies the tag matches `app/pubspec.yaml`;
2. builds `wechatqr-<version>-arm64-v8a.apk`, signed with the upload key, and fails the job if the
   APK contains any ABI other than arm64-v8a or is missing the engine or models;
3. creates a GitHub Release with that APK and generated release notes.

### Building the iOS .ipa

Actions → **iOS build (manual)** → *Run workflow*.

| Input | Effect |
|---|---|
| `attach_to_release` set to a tag, e.g. `v1.0.2` | Builds the `.ipa` and attaches `wechatqr-<version>.ipa` to that release |
| `attach_to_release` left empty | Builds and verifies the `.ipa`, then publishes nothing — useful for checking that the iOS build still works |

Workflow artifacts are deliberately not used: everything published lives on the release page, so there
is one place to look for a downloadable build.

The job builds a minimal OpenCV framework first (`scripts/build_opencv_ios.sh`), cached under
`opencv-ios-<version>`, so that step runs once per OpenCV version rather than per build. It then runs
`flutter build ios --release --no-codesign` and packages `Runner.app` into an `.ipa`, failing if the
models are not inside the app bundle.

The `.ipa` is **unsigned** on purpose: it targets TrollStore, which applies its own signing on the
device. There is no App Store or normal signing path here, and none is claimed.

---

## Licences

The app is Apache-2.0. It redistributes the WeChat QRCode CNN models and links against OpenCV, both
Apache-2.0. Every third-party component, with its licence, copyright line and the reason it is
included, is recorded in [`docs/licenses/NOTICE`](docs/licenses/NOTICE); full licence texts are in
[`docs/licenses/`](docs/licenses/).
