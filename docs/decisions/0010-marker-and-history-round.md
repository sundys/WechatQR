# 0010 — Second testing round: markers, frozen frames, history

Date: 2026-10-15
Status: Accepted

## 1. The camera is released again when the scan tab is left

ADR-0009 paused the camera on the way out to avoid the black frame while it was re-acquired. That is
reversed: the camera stayed open behind the other tabs, holding it against other applications and
keeping the system's camera indicator lit. Releasing is the behaviour that was asked for, and the
brief black frame on return is accepted as the cost.

## 2. Markers are larger, and the picture is held still

The green marker was too small to aim at, so the dot is 22→34 pt inside a 76 pt touch target.

More importantly, markers drifted off the codes. They are computed for **the frame the codes were
decoded from**, and a live preview moves on immediately; by the time the user looks, the marker is
somewhere else. The frame that produced the result is now kept, encoded as a PNG once per detection,
and shown in place of the live preview while markers are on screen. It is released when the sheet
closes and the preview starts moving again.

Two decisions worth recording:

* **The analysed frame, not a snapshot of the preview.** A view snapshot is a later frame, so it would
  reintroduce the same drift, only smaller. It also would not work here: `AVCaptureVideoPreviewLayer`
  does not draw its video frames into its backing store, so rendering it produces a blank image. The
  analysed frame is both the correctly aligned choice and the only one available.
* **Captured once per detection.** `_freezeFrame` keeps the first frame it obtains, so markers placed
  for one frame are never re-placed for another, and closing the sheet is what unfreezes.

If no frame can be captured, markers still appear over the live preview — worse, but not broken.

## 3. iOS markers exist now

ADR-0006 recorded that iOS reported null coordinates and drew no markers, because the engine wrapper
collected the detector's quads and threw them away. That is fixed.

`WeChatQRCodeEngine` now returns `WeChatQRCodeMatch` objects carrying each code's centre normalised to
the analysed image, and the view maps those onto the preview layer with the same
`.resizeAspectFill` scale-and-crop arithmetic the Android view uses, so both platforms place markers
identically.

One detail the C++ had to absorb: the detector's quadrangle output is not a guaranteed shape. It is
reshaped to a common form and converted to `double` before anything is read, rather than assuming a
4×2 float matrix.

## 4. Every code in a frame reaches the history

A frame that decoded several codes recorded only the one being presented, so the others were lost as
soon as the preview moved on — which is exactly when the user noticed them. All of them are now
recorded, including when the user taps one marker to choose it: the frame decoded them all, so the
history keeps them all. A picture from the gallery has no markers and falls back to its own results.

## 5. Release notes are curated, not generated

`gh release create --generate-notes` produces a list of commits, which is not something a user can
read. The release step now uses `docs/releases/<tag>.md` when that file exists and falls back to the
generated list when it does not.

## A mistake worth naming

The first version of the iOS frame capture did not compile: it used `@Volatile` on a property, which
is Kotlin, and checked a `disposed` flag, which the Android view has and the Swift one does not.
Both came from editing the two platform views in the same sitting and carrying the Kotlin shape
across. Swift expresses the first with a lock — taken in both accessors of `lastFramePng` — and has
no need for the second at all: this is a `FlutterPlatformView` with no `dispose` callback, and every
hop onto the session queue already captures `self` weakly.

The same round also assumed `UIKit` would make `CIImage` visible. It now imports `CoreImage`
explicitly rather than relying on transitive visibility.

## Not verified

* Nothing here was exercised on a device. Freezing, marker placement on both platforms, and the
  marker positions on iOS in particular are reasoned and compile-checked, not observed.
* The marker arithmetic uses the analysed image's dimensions after rotation. Getting that wrong
  displaces every marker by a constant, which is easy to spot on a device and impossible to spot here.
* Whether the black frame on returning to the scan tab is still objectionable: it is the behaviour
  that was asked for, but it is a visible cost.
