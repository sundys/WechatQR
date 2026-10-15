# 0006 — iOS / TrollStore: what is implemented and what is unverified

Date: 2026-10-15
Status: Accepted, **unverified on device**

## Context

CLAUDE.md §3.2 sets the iOS delivery target as an installable artifact for **TrollStore**, not App
Store distribution, and §14.3 requires unverified items to be listed explicitly rather than claimed
as passing.

This work was carried out on Windows. There is no macOS, no Xcode and no iOS device available here.
**Nothing on the iOS side has been compiled, signed, installed or run.**

## What exists

| Piece | File |
|---|---|
| Plugin registration, channels, permission, `Bundle` lookup | `ios/wechat_qrcode/Sources/wechat_qrcode/WeChatQrcodePlugin.swift` |
| Camera session, frame analysis, torch | `.../ScannerPlatformView.swift` |
| Shared camera state | `.../ScannerController.swift` |
| OpenCV C++ wrapper | `.../WeChatQRCodeEngine.mm` + `include/WeChatQRCodeEngine.h` |
| Model assets | `.../Resources/models/` (MD5-verified, same files as Android) |
| CocoaPods wiring | `ios/wechat_qrcode.podspec` |
| Swift Package wiring | `ios/wechat_qrcode/Package.swift` |
| Privacy manifest | `.../PrivacyInfo.xcprivacy` |
| Platform capabilities | `packages/platform_services/ios/.../PlatformServicesPlugin.swift` |
| Permission strings | `app/ios/Runner/Info.plist` |

The Dart API is identical on both platforms — `WeChatQrCode.initialize/decodeImageFile/startScanning/
pauseScanning/resumeScanning/setTorch/hasCameraPermission/release/buildScannerView` — so no app code
is platform-conditional except the update row.

## Design decisions carried over

* The engine wrapper is Objective-C++ because `cv::wechat_qrcode::WeChatQRCode` is a C++ API that
  Swift cannot call directly.
* Frames are requested as BGRA rather than YUV, letting CoreVideo do the conversion instead of
  hand-written NV21 arithmetic. Video frames and picked images therefore share one BGR path in
  `copyPixelBufferToBgr` / `copyCGImageToBgr`.
* Analysis drops late frames (`alwaysDiscardsLateVideoFrames`), mirroring the queue discipline in the
  vendored Android analyser.
* Pausing sets a flag that makes `captureOutput` return early, keeping the preview live — the iOS
  equivalent of detaching the CameraX analyser.
* Gallery images are normalised for EXIF orientation and downsampled via
  `UIGraphicsImageRenderer`, which is cleaner than the Android path (see decision 0004's known gaps).
* `installApk`, `canInstallPackages` and the install-permission screen return `unsupported`; the
  version row opens the Releases page instead (§3.2).

## Build procedure (to be performed on macOS)

Local:

```bash
scripts/build_opencv_ios.sh      # produces packages/wechat_qrcode/ios/opencv2.xcframework
cd app
flutter build ios --release --no-codesign
```

On CI, the manual workflow `.github/workflows/ios.yml` does the same and packages `Runner.app` into
`wechatqr-<version>.ipa`. It is a separate workflow from the Android release on purpose: a cold run
compiles OpenCV for iOS, which takes tens of minutes and would otherwise hold up every Android
release. Running it with `attach_to_release` set to a tag attaches the `.ipa` to that existing
release; leaving it empty only uploads a workflow artifact.

The `.ipa` is unsigned. That is deliberate — TrollStore applies its own signing on the device — and
not a gap to be closed later.

## What must be verified on a Mac and a real device

Nothing below has been checked:

1. **The OpenCV framework builds.** `scripts/build_opencv_ios.sh` was authored on Windows and has
   never run. Whether `BUILD_LIST=core,imgproc,objdetect,dnn,wechat_qrcode` produces a framework that
   links, and whether `wechat_qrcode.hpp` is reachable at the expected path, is unknown.
2. **The plugin compiles.** Swift/ObjC++ interop across the `include/` header, the
   `FlutterPlatformViewFactory` signatures and the `AVCaptureConnection.videoRotationAngle`
   availability branch are all unexercised.
3. **Resources resolve at runtime.** `modelsDirectory()` probes several bundles; which one actually
   holds `models/` under CocoaPods versus SPM has not been observed.
4. **Camera and decoding work on device**, including rotation handling and the torch.
5. **TrollStore installation.** Whether the exported `.ipa` installs and launches under TrollStore on
   the target iOS version is untested. iOS 17+ is the assumed minimum because
   `videoRotationAngle` is used when available; the deployment target is compiled at 13.0 with a
   fallback, but older versions are not otherwise validated.
6. **Photo library saving and vibration** on a real device.
7. **The open-source licence screen** renders the registered attribution correctly.

## Minimum supported iOS version

`IPHONEOS_DEPLOYMENT_TARGET` is 13.0, inherited from the Flutter template and matched by the podspec.
This is a **compilation setting, not a verified support claim**. Devices and iOS versions actually
supported under TrollStore will be recorded here once tested.

## Not claimed

* App Store review or normal signing distribution — explicitly out of scope per §3.2.
* That any TrollStore capability applies to all iOS devices.
