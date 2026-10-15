# 0009 — Fixes from testing the iOS build on iOS 14

Date: 2026-10-15
Status: Accepted

## Context

The `.ipa` produced by the pipeline was installed through TrollStore on iOS 14 and exercised. Four
problems came back, three of which are also reproducible on Android.

Before that, the first successful end-to-end run was checked rather than assumed: the published
`.ipa` was downloaded and its SHA-256 matched GitHub's digest, the four model files were found at
`Frameworks/wechat_qrcode.framework/wechat_qrcode.bundle/models/` — the exact path `modelsDirectory()`
probes — and the plugin binary contains `wechat_qrcode`, `cv::` and `opencv` symbols, so OpenCV really
is linked in. The 13.45 MB total is consistent with its parts (Flutter 9.27 MB, plugin with OpenCV
10.20 MB, Dart AOT 6.51 MB).

## 1. Black preview on first launch, until the app is relaunched

The camera never came up the first time the permission was granted; menus worked, so Flutter was fine
and only the capture session was not running. Relaunching fixed it, which points at a start that
either failed once or raced the app's return to the foreground — `startRunning()` can return without
the session having started when the app is still becoming active, which is precisely the state right
after a permission dialog is dismissed.

The start path is now restartable and verified:

* `start()` never refuses a second attempt;
* after `startRunning()` the session is **checked**, and a session that did not come up is retried
  up to three times, 0.4 s apart;
* a persistent failure is reported to Dart instead of leaving a black screen;
* `AVCaptureSessionRuntimeError` is observed and answered with a restart, since a frozen preview is
  indistinguishable from a black one to the user;
* `isRunning` now reflects what the session reports rather than being set optimistically after the
  call — the previous code marked the session running whether or not it was.

The UI also stopped hiding the problem: a camera error now appears as a banner over the preview with a
retry button. Before this, only engine-*initialisation* failures had a panel, so a runtime camera
failure was recorded and never shown.

**Not confirmed on a device.** The cause is inferred from the symptom and from how `startRunning()`
behaves during a foreground transition; whether the retry actually clears it needs the same phone.

## 2. Generate page: keyboard stayed up, and labels wrapped on a small screen

Two separate problems.

**Keyboard.** Tapping 粘贴 / 生成 / 清空 left the field focused, so the keyboard kept covering the
lower half of a 320 pt screen — hiding the QR code the user had just asked for. All three handlers
now unfocus first.

**Labels.** Three buttons in a row on a 320 pt screen leave about 88 pt each, and an icon plus a
two-character label at the default padding and icon gap needs more than that, so each label broke
across lines and its characters stacked vertically. The buttons are now built from an explicit row
with tightened metrics, a smaller icon, and `softWrap: false` on the label so it cannot break at any
width.

## 3. Flicker when returning to the scan tab

Both platforms. Leaving the tab called `stopScanning()`, which releases the camera; coming back
re-acquires it, and the preview is black until it is running again.

The spec asks for the camera to be **paused** when the page is left and reserves releasing it for
backgrounding, so `ScanPage` now pauses on the way out and resumes on the way back, and `AppShell`
still stops the camera when the app leaves the foreground. The preview stays live behind the other
tabs and is there the instant the scan tab returns.

The cost is worth stating: while the other tabs are open the camera is still open, so the system's
camera indicator stays lit and the device holds the camera against other applications. That is the
price of not paying to re-acquire it, and it is bounded — backgrounding the app still releases it.

## 4. Update check fails where GitHub is unreachable

Forwarders were added ahead of GitHub's own address, tried in order with the original last. The
shapes differ between them — `ghfast.top` forwards downloads but answers the API with 403, and
`github.akams.cn` takes the address as a query parameter — so each was exercised against the real
v1.0.2 release before being listed, and those shapes are asserted in tests. See ADR-0005, which also
records that the digest check is a corruption check and that Android's own signature verification is
what actually prevents a substituted package being installed.

## Not verified

* The iOS camera fix, as above: no iOS device was available for any of this work.
* The retry timings (three attempts, 0.4 s apart) are reasoned, not measured.
* Whether the flicker is fully gone on iOS: the pause path removes the release/re-acquire cycle, but
  the platform view is still rebuilt when the scan tab's widget tree changes.
* `flutter test` covers the update changes; nothing here covers the camera, the keyboard or the
  layout on a device.
