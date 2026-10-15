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
release; leaving it empty only builds and verifies the .ipa, publishing nothing.

The `.ipa` is unsigned. That is deliberate — TrollStore applies its own signing on the device — and
not a gap to be closed later.

## What must be verified on a Mac and a real device

Nothing below has been checked:

1. ~~**The OpenCV framework builds.**~~ **Verified, 2026-10-15.** A CI run at `ce667c4` built it
   successfully in ~18 minutes: CMake reported `To be built: calib3d core dnn features2d flann
   imgproc objdetect wechat_qrcode`, compiled `opencv_wechat_qrcode` from `wechat_qrcode.cpp` for
   both the device and simulator slices, downloaded the four model files, and finished with
   `xcodebuild -create-xcframework`. The nine-module closure in ADR-0002 is confirmed against a real
   build.

   Getting there took three CI attempts, and the failures are worth recording because none of them
   were about OpenCV:

   * the script was committed without the executable bit — Git cannot read that bit from a Windows
     checkout, so it has to be set in the index;
   * the first script drove cmake by hand and passed `-DBUILD_opencv_framework=ON`, a flag that does
     not exist in OpenCV 4.12 — cmake treats unknown `-D` variables as unused, so no framework was
     ever produced;
   * the third attempt built the framework correctly and was failed by this project's own
     verification step, which looked for `wechat_qrcode` in `nm -gU` output. OpenCV compiles with
     `-fvisibility=hidden`, and `nm -g` filters by external linkage, so the check reported a healthy
     build as broken. It now checks the build log for the compiled target instead — evidence no
     compiler flag can defeat — and treats the symbol lookup as informational.

   The framework is ~18 minutes of work, so the workflow caches it under
   `opencv-ios-<version>-<arch>-v3`; later runs restore it and skip straight to the app build.
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
7. **Result indicators.** `WeChatQRCodeEngine` collects the quads its detector
   returns but does not surface them, so the iOS event payload carries null
   coordinates and no markers are drawn. Making it report them needs the same
   `resizeAspectFill` mapping the Android view does, plus a device to confirm it;
   see ADR-0007 for the Android implementation it would mirror.
8. **The open-source licence screen** renders the registered attribution correctly.

## Minimum supported iOS version

`IPHONEOS_DEPLOYMENT_TARGET` is 13.0, inherited from the Flutter template and matched by the podspec.
This is a **compilation setting, not a verified support claim**. Devices and iOS versions actually
supported under TrollStore will be recorded here once tested.

## Not claimed

* App Store review or normal signing distribution — explicitly out of scope per §3.2.
* That any TrollStore capability applies to all iOS devices.
