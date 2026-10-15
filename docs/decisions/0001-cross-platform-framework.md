# 0001 — Cross-platform framework: Flutter

Date: 2026-10-15
Status: Accepted

## Context

The repository was empty when this work started (branch `main`, no commits). Nothing was already
decided, so CLAUDE.md §2 required an explicit evaluation: could `wechat-qrcode` be wrapped as a
natively callable module on each platform and reused behind a shared UI layer?

The recognition engine is native either way — OpenCV's WeChatQRCode is a C++ library consumed through
the Java bindings on Android and directly on iOS. What was actually in question was how much of the
*app* could be written once.

## Options

1. **Flutter.** Shared Dart UI and business logic; a platform plugin per side for the engine and for
   device capabilities.
2. **Two native apps.** Kotlin/Compose on Android (able to reuse `wechat-qrcode-scanning`'s
   Activity-based UI directly) and Swift/SwiftUI on iOS, sharing only the recogniser and models.
3. **Kotlin Multiplatform.** Shared Kotlin logic, native UI.

## Decision

Flutter.

Reasoning:

* The feature set is UI-heavy and almost entirely identical across platforms — three tabs, a result
  sheet, a history list with pin/delete, a generate page, a settings tree, theming. Option 2 would
  have written all of it twice.
* The genuinely platform-specific parts are narrow and already isolated: the camera session, the
  torch, vibration, gallery saving and the Android installer. Option 2's advantage (reusing the
  reference scanning UI) turned out to be small: that UI is `Activity`-based, so it cannot host a
  Flutter platform view, and the project needs a bottom navigation bar with the camera inline. Only
  the *analyser* was reusable, and it is reusable from Flutter just as well.
* Option 3 cannot link iOS targets from Windows (`Kotlin/Native` needs macOS), so it would have been
  the most expensive option in this environment for less sharing than option 1.
* Business logic that CLAUDE.md §14.2 requires to be testable — semver comparison, history
  management, settings persistence, the update state machine, URL classification — is pure Dart and
  runs under `flutter test` with no device. That produced 149 tests that run in seconds.

## Consequences

* Toolchain: Flutter 3.44.5 / Dart 3.12.2, JDK 17, AGP 9.0.1, Gradle 9.1.0, compileSdk 36, minSdk 24.
* The QR engine plugin is federated: one Dart API (`packages/wechat_qrcode/lib`), two native
  implementations.
* Android-only capabilities (APK installation) sit behind `packages/platform_services`, whose iOS
  implementation reports `unsupported` rather than pretending.
* A second UI framework will not be introduced; the shared Dart layer is the only UI.
