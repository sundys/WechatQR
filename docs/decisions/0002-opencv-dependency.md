# 0002 — The OpenCV dependency boundary

Date: 2026-10-15
Status: Accepted

## Context

CLAUDE.md §1 and §9.3 are explicit: only the `wechat-qrcode` and `wechat-qrcode-scanning` parts of the
reference project may be used; OpenCV's other modules and general-purpose API must not be reached
for; and copying the whole OpenCV source or binary into the application is forbidden. §1 also requires
separating "a dependency the WeChatQRCode implementation needs internally" from "OpenCV features this
project chose to use", keeping only the minimum, and recording the reasoning (§18).

## What the engine actually requires — verified, not assumed

`opencv_contrib/modules/wechat_qrcode/CMakeLists.txt` declares:

```
ocv_define_module(wechat_qrcode opencv_core opencv_imgproc opencv_objdetect opencv_dnn
                  WRAP java objc python js)
```

So the transitive requirement is exactly **core, imgproc, objdetect, dnn**, plus the module itself.
Notably `imgcodecs` is *not* required: neither implementation decodes image files with OpenCV
(Android uses `BitmapFactory`, iOS uses `UIImage`), which is why gallery decoding does not pull that
module in.

## Decision — Android

Consume the published Maven Central artifacts:

```kotlin
implementation("com.github.jenly1314.WeChatQRCode:opencv:2.6.0")       // Java bindings
implementation("com.github.jenly1314.WeChatQRCode:opencv-armv64:2.6.0") // libopencv_java4.so
debugImplementation("com.github.jenly1314.WeChatQRCode:opencv-x86_64:2.6.0")
```

Both were verified reachable at version 2.6.0 before being adopted.

Rejected alternatives:

* **Copying `libopencv_java4.so` out of the local reference checkout.** It would put a full OpenCV
  binary into this repository's history and redistribute a binary whose contents we cannot
  describe — precisely what §9.3 forbids.
* **Building a minimal `libopencv_java4.so` from source** with
  `BUILD_LIST=core,imgproc,objdetect,dnn,wechat_qrcode`. This is the strictest reading of the
  minimal-dependency rule and would shrink the ~23 MB arm64 library. It was deferred, not dismissed:
  it is a long, fragile Windows build whose output would then have to be committed or hosted. If the
  APK size becomes a problem, this is the documented next step.

**Known cost, recorded honestly:** the published `libopencv_java4.so` is a monolithic full-OpenCV
build (23.5 MB for arm64-v8a). The project *calls* only `wechat_qrcode`, `imgproc` and `core` — but
the binary contains more, and this is a size and surface-area cost accepted in exchange for a
reproducible, source-free dependency.

## Decision — iOS

Build a minimal `opencv2.xcframework` with `scripts/build_opencv_ios.sh`
(`-DBUILD_LIST=core,imgproc,objdetect,dnn,wechat_qrcode`). No published OpenCV iOS framework
includes `wechat_qrcode`, so a custom build is unavoidable; making it minimal at the same time costs
nothing extra.

The framework is **not committed** (`.gitignore` excludes `*.xcframework`) and **has not been built**:
it requires macOS. The script is therefore unverified.

## Enforcement

* In the Android native code, only `org.opencv.wechat_qrcode.WeChatQRCode`, `org.opencv.core.{Mat,
  Core, CvType}`, `org.opencv.imgproc.Imgproc`, `org.opencv.android.Utils` and
  `org.opencv.android.OpenCVLoader` are referenced.
* `WeChatQRCodeDetector.init` loads the native library explicitly via `OpenCVLoader.initLocal()`.
  Upstream never did this, relying on the host app to do it first — a detail found by reading the
  reference sources, not by guessing.
* Nothing constructs an `opencv-qrcode` detector; that module of the reference project is unused.

## Consequences

* The Android APK ships a full-OpenCV native library; release builds are arm64-v8a only, enforced in
  `app/android/app/build.gradle.kts`.
* If sizing becomes a requirement, replace the AAR dependency with the minimal source build and
  update this record.
