# 0004 — Engine integration and the changes made to vendored code

Date: 2026-10-15
Status: Accepted

## Context

CLAUDE.md §1 allows the use of the `wechat-qrcode` and `wechat-qrcode-scanning` parts of the
reference project, and §4.1 says to prefer reusing them. §9.2 then adds requirements the upstream code
does not meet. This records what was reused verbatim, what was changed, and why.

## Interface actually reused

From `wechat-qrcode`, the real API (read from source, not assumed):

```kotlin
object WeChatQRCodeDetector {
    fun init(context: Context)
    fun detectAndDecode(bitmap: Bitmap): List<String>
    fun detectAndDecodeResult(bitmap: Bitmap, isOutputVertices: Boolean = false): DecodeResult
    fun setScaleFactor(scalingFactor: Float)
}
```

From `wechat-qrcode-scanning`, the frame pipeline:

```kotlin
open class WeChatScanningAnalyzer(isOutputVertices: Boolean = false)
    : Analyzer<DecodeResult>
```

`WeChatScanningAnalyzer` converts a CameraX `ImageProxy` to NV21, applies the frame's rotation, calls
the detector and reports through `Analyzer.OnAnalyzeListener`. This is the genuinely reusable piece
and it is used **unmodified**: pausing is implemented by detaching the analyser from CameraX
(`ImageAnalysis.clearAnalyzer()`), so the analyser needs no pause flag and therefore no edit.

The reference's `WeChatCameraScanActivity` / `WeChatCameraScanFragment` are *not* used: they are
Activity-bound and cannot host a Flutter platform view. That is the only reason this project has its
own CameraX plumbing.

## Changes to `WeChatQRCodeDetector.kt`

Vendored into `packages/wechat_qrcode/android/src/main/kotlin/com/king/wechat/qrcode/`, with the
modifications marked in the file header as Apache-2.0 §4(b) requires.

1. **Initialisation failure is reported, not swallowed.** Upstream wrapped `init` in
   `catch (e: Exception) { LogX.e(e) }` and left a `lateinit var` uninitialised, so the next call
   threw `UninitializedPropertyAccessException` with no way for the app to react. This version throws
   `QrEngineInitException` describing the failing step; the plugin maps it to `modelLoadFailed` and
   the scan tab offers a retry (CLAUDE.md §9.2).
2. **Models are extracted into internal storage.** Upstream used `getExternalFilesDirs`, which can be
   unavailable or read-only. `context.filesDir` is always present and private.
3. **Init is `@Synchronized` and idempotent.** Repeated or concurrent calls reuse one detector instead
   of racing to reload the models (§9.2: do not re-initialise per frame).
4. **The OpenCV native library is loaded explicitly** via `OpenCVLoader.initLocal()`. Upstream never
   did this — the reference *demo app* called it in `MainActivity.onCreate`, so the detector only
   worked if the host remembered. Making `init` self-contained was found by reading the demo's
   source.
5. **Streams are closed with `use {}`.** Upstream leaked file handles if extraction failed part-way.

The detection API is otherwise unchanged. Copying the upstream implementation of the detector (three
small files) was chosen over depending on the published AAR, because the fixes above are behavioural
and the models must be shipped anyway.

## Threading and lifecycle

| Concern | Handling |
|---|---|
| Detector creation, image decoding | Off the UI thread (`workExecutor` / `workQueue`) |
| Frame analysis | Dedicated serial executor / queue; frames dropped rather than queued when busy |
| Concurrent decodes | The vendored analyser's single-slot queue allows at most one in flight |
| Image closing | Every `ImageProxy` is closed in a `finally`, or the CameraX pipeline stalls |
| Leaving the tab / backgrounding | `stopScanning` releases the camera (`ScannerController` + `AppShell` lifecycle) |
| Result sheet open | `pauseScanning` detaches the analyser; the preview keeps running |

The last two are separate states on purpose — releasing the camera for a sheet that the user will close
in two seconds would cause a visible restart.

## Error codes

Stable strings cross the channel and map one-to-one onto `WeChatQrCodeError`:
`notInitialized`, `modelLoadFailed`, `cameraPermissionDenied`, `cameraPermissionPermanentlyDenied`,
`cameraUnavailable`, `invalidImage`, `unsupportedImageFormat`, `decodeFailed`.

Camera permission is requested natively rather than from Dart, because only the platform can
distinguish "denied" from "denied and will not be asked again", and that decides whether the UI
offers *retry* or *open system settings* (CLAUDE.md §5).

## Known gaps

* Android gallery decoding does not apply EXIF orientation. QR decoding tolerates all four
  rotations, so a rotated photo still decodes; iOS normalises orientation explicitly via
  `UIGraphicsImageRenderer`. Recorded rather than silently accepted.
* iOS is implemented but has never been compiled — see decision 0006.
