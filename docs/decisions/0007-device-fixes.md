# 0007 — Fixes from the first round of device testing

Date: 2026-10-15
Status: Accepted

## Context

The first Android build (v1.0.0) was tested on a OnePlus device running ColorOS 15. Four problems
were reported, all of them real and all of them things that could not have been found by running the
test suite:

1. Tapping **允许使用相机** on first launch did nothing — the camera permission could only be granted
   by opening system settings by hand.
2. No focus indicator on a detected code, no autofocus, no scanning animation.
3. Several codes in one frame were all presented at once instead of letting the user choose.
4. Long-press menus were in English.

## 1. The permission dialog was never requested

**Cause, verified.** `WeChatQrcodePlugin` created its permission launcher with:

```kotlin
(activity as? ComponentActivity)?.registerForActivityResult(RequestPermission())
```

`FlutterActivity` extends `android.app.Activity`, **not**
`androidx.activity.ComponentActivity` (confirmed by reading
`engine/src/flutter/shell/platform/android/io/flutter/embedding/android/FlutterActivity.java`).
The cast therefore returned `null`, no launcher was created, and `startScanning` fell through to the
`CAMERA_UNAVAILABLE` branch. Dart stored that as an engine error, the scan page kept showing the
permission panel, and the user saw a button that did nothing — the system dialog was never asked for.
No amount of unit testing could catch this; it only exists on a device.

**Fix.** Register a `PluginRegistry.RequestPermissionsResultListener` on the
`ActivityPluginBinding` and call `ActivityCompat.requestPermissions`. That is the plug-in API that
works with a plain `Activity`, and it is what the embedding actually supports.

A second guard was added: if a request is already outstanding, a repeat call reports an error rather
than stacking a second prompt.

## 2. Indicators, autofocus, scan animation

**Viewfinder frame and animated scan line** are reused from the reference stack:
`com.github.jenly1314:viewfinderview` (Apache-2.0), the same widget the upstream scanning layout
uses, added as `ViewfinderView` over the CameraX preview. It is decoration only — `clickable` and
`focusable` are cleared so it cannot swallow touches meant for the Flutter layer above it.

**Result indicators** are drawn in Flutter, not by `ViewfinderView.showResultPoints`. The reason is
decision 3: the same tap that would select a code has to drive a three-second timer in Dart, and
splitting one interaction across a native view and a Flutter overlay invites gesture conflicts. The
cost is that the native code must report *where* each code was.

So the analysis now runs with `WeChatScanningAnalyzer(isOutputVertices = true)`, and the view maps
each code's vertex quad to the centre of the preview, normalised to `0.0..1.0`, before sending it
alongside the payload. The mapping undoes the `FILL_CENTER` scaling and centre crop; the event
payload is `{text, x, y}` per code, with `x`/`y` null when the engine returned no quad for that code
(in which case no indicator is drawn rather than a misplaced one).

Notes:
* The Dart parser still accepts a bare string, so an implementation that reports no positions keeps
  working.
* iOS currently reports `null` coordinates: the engine wrapper collects vertex output but does not
  yet surface it. Indicators are therefore Android-only for now, and the licence/about screens do not
  claim otherwise.

**Autofocus.** CameraX starts with continuous AF, but on several builds — Chinese vendor ROMs
in particular — that can settle at infinity and stay there, which matches the reported "no
autofocus". The view now re-triggers `startFocusAndMetering` on the centre of the preview every
2.5 seconds while scanning, which is what actually keeps a code sharp.

## 3. Multi-code frames now ask instead of guessing

Previously any frame with several codes was presented with all of them at once. New behaviour:

| Situation | Behaviour |
|---|---|
| One code | Presented immediately, marker shown |
| Several codes | All marked, analysis paused, preview live, **3 second** window |
| A marker tapped within the window | That code alone is presented; the side effects (copy, history, auto-open) apply to it alone |
| Window elapses | Every result is presented, as before |
| A frame arrives during the window | Ignored, so the markers cannot move under the user |

Markers stay on screen while the result sheet is open and are cleared when it closes. The window
length is injectable (`ScanController.selectionWindow`) so tests do not wait three seconds.

## 4. English long-press menus

`MaterialApp` registered no localisation delegates, so every string owned by a built-in widget —
text-selection menus ("Copy", "Select all"), text-field long-press menus ("Paste"), date pickers —
fell back to English even though every string this app writes is Chinese.

Fixed by adding `flutter_localizations` and pinning `locale: Locale('zh')` with the three global
delegates. The locale is pinned rather than resolved from the device because the interface is
Chinese-only; a device set to English would otherwise show Chinese screens with English system menus.

## Not verified

The autofocus interval, the indicator placement (the `FILL_CENTER` maths in particular) and the
marker tap routing all need a device to confirm. The permission fix addresses a cause that was
verified by reading the embedding source, but the fix itself has not run on ColorOS.
