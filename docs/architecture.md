# Architecture

## Shape

```
┌───────────────────────────────────────────────────────────────┐
│ app/ — Flutter, shared by Android and iOS                     │
│                                                               │
│  ui/          scan page + result / history sheets, generate,   │
│               settings, about, licences, update dialog         │
│  state/       ScanController, HistoryController,               │
│               SettingsController, UpdateController             │
│  domain/      pure Dart: models, semver, URL classification,   │
│               de-duplication, result policy, update states     │
│  data/        settings, history and update-preference stores   │
│  services/    link opener, clipboard, release check, APK       │
│               download, app version                            │
└───────────────┬───────────────────────────┬───────────────────┘
                │ method / event channels   │ platform view
┌───────────────▼───────────────────────────▼───────────────────┐
│ packages/wechat_qrcode/     the recognition engine             │
│   Android: Kotlin, CameraX + vendored wechat-qrcode            │
│   iOS:     Swift + ObjC++ over cv::wechat_qrcode               │
├───────────────────────────────────────────────────────────────┤
│ packages/platform_services/ device capabilities                │
│   vibration, save-to-gallery, Android installer hand-off,      │
│   app settings screen                                          │
└───────────────────────────────────────────────────────────────┘
```

The split is by responsibility, not by convenience: the engine plugin knows nothing about history or
settings, and the platform plugin knows nothing about QR codes.

## Why the camera preview is a platform view

Frame analysis must run natively. The only Dart-side alternative — shipping every camera frame
across a method channel — would copy megabytes per second through the channel for no benefit.

So `wechat_qrcode/scanner` is a platform view: CameraX + `PreviewView` on Android,
`AVCaptureSession` + `AVCaptureVideoPreviewLayer` on iOS. Analysis runs on a dedicated serial queue
on both sides and only *decoded strings* cross back, via `wechat_qrcode/events`.

On Android the analysis is not reimplemented: it calls `WeChatScanningAnalyzer` from the reference
project's `wechat-qrcode-scanning` module, which already handles NV21 conversion, frame rotation and
the detector call. The reference scanning *UI* could not be reused because it is Activity-based and
cannot host a Flutter platform view; that is the sole reason this project has its own camera
plumbing.

## Pausing rather than stopping

Three distinct camera states, because collapsing them causes visible bugs:

| State | Effect |
|---|---|
| `stopScanning` | Camera released. Used when leaving the scan tab or backgrounding the app. |
| `pauseScanning` | Analyzer detached from CameraX / frames dropped on iOS. Preview stays live, camera stays open. Used while a result sheet or the history sheet is on screen. |
| `resumeScanning` | Analysis resumes if scanning was requested. |

`ScanController` also applies a short-window `ScanDedup` on top, so a code still in frame after the
sheet closes does not immediately re-open it.

## Choosing between several codes

The engine can return more than one code per frame. Rather than guessing which one the user meant,
the view marks every code with a green indicator, pauses analysis (keeping the preview live) and
waits three seconds:

```
several codes detected
        │
        ├── marker tapped  ──▶ that code alone becomes the result
        │
        └── 3s elapse      ──▶ every result is shown, as before
```

The markers are drawn in Flutter from normalised centres reported by the platform, so the indicator
and the tap that selects it live in the same layer and share one timer. `ViewfinderView` draws the
frame and the animated scan line; it draws no result points, precisely so there is only one place
that decides what a tap on a marker means. The window length is injectable for tests.

## Threading and cost control

* Detector construction and image decoding run off the UI thread on both platforms.
* `STRATEGY_KEEP_ONLY_LATEST` on Android and `alwaysDiscardsLateVideoFrames` on iOS mean frames are
  dropped rather than queued when decoding cannot keep up — the property that keeps memory flat.
* One detector instance is created and reused for the process lifetime.
* Analysis runs at 1280×720: high enough for dense codes at arm's length, low enough to stay fast.
* Gallery images are downsampled to a 2400 px longest edge before detection.

## Error model

Platform errors cross the channel as stable string codes that map one-to-one onto Dart enums
(`WeChatQrCodeError`, `PlatformServiceError`). `ui/error_messages.dart` is the single place that
turns those codes into user-facing text, so a new failure mode cannot silently degrade into a generic
message.

Engine initialisation failure is a first-class state, not an exception at startup: the scan tab shows
a retry panel. The vendored Android detector was changed specifically for this — upstream swallowed
the failure and left a `lateinit` value that crashed on first use.

## Data

Everything is local.

| Data | Store |
|---|---|
| Settings | `shared_preferences`, one JSON document under `scan_settings_v1` |
| History | JSON file in the app documents directory, written to a temp file and renamed |
| Ignored update version, pending install | `shared_preferences` |

History rows carry `id`, `content`, `contentType`, `scannedAt`, `isPinned` and `source`. Display
order (pinned first, then newest first, ties broken on `id`) is owned by `HistoryController`, not by
the store, so the ordering invariant holds for every storage implementation.

## Security posture

* Only `http` and `https` URLs are ever handed to the platform browser. `javascript:`, `file:`,
  `intent:`, `data:`, `content:` and friends are classified as `other`, shown as text, and never
  opened — see `ContentClassifier` and its tests.
* Scanned content is never executed or interpreted as an instruction.
* Link previews show the *parsed host*, so `https://user:pass@evil.example` cannot display as a
  trusted name.
* The installer is handed a content URI from a FileProvider limited to the app-private `updates`
  directory; arbitrary paths are rejected.
* Updates are only installed after HTTP status, byte length and (when GitHub publishes one) the
  SHA-256 digest all check out. A failed check deletes the file.
* Nothing is installed silently: the user always completes installation in the system UI.

## Where the platform implementations differ

| | Android | iOS |
|---|---|---|
| Camera | CameraX | AVFoundation |
| Frame format | YUV 420 → NV21 → BGR | BGRA → BGR |
| Torch | `CameraControl.enableTorch` | `AVCaptureDevice.torchMode` |
| Vibration | `Vibrator` / `VibratorManager` | `kSystemSoundID_Vibrate` |
| Save to gallery | MediaStore (API 29+), public Pictures (≤ 28) | `PHPhotoLibrary` |
| Update | GitHub Releases + system installer | Opens the Releases page only |
| ABI / arch | arm64-v8a (`x86_64` debug) | arm64 |

The iOS differences are not gaps to be closed later: there is no in-app install path on iOS, so the
version row deliberately opens a web page instead.

## Further reading

* [`docs/decisions/`](decisions/) — the decisions behind the above, and what remains unverified.
* [`docs/licenses/NOTICE`](licenses/NOTICE) — every third-party component and its licence.
