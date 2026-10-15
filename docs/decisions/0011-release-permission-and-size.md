# 0011 — The release APK had no network access, and was twice the size it needed to be

Date: 2026-10-15
Status: Accepted

## The update check never worked in a release build

Reported as "the update check says there is no network". There was no network permission:

```
$ aapt2 dump permissions wechatqr-1.0.3-arm64-v8a.apk
  VIBRATE, REQUEST_INSTALL_PACKAGES, WRITE_EXTERNAL_STORAGE, READ_EXTERNAL_STORAGE,
  CAMERA, FLASHLIGHT          <- no INTERNET
```

Flutter's template declares `android.permission.INTERNET` in the **debug** and **profile** manifests
only, on the assumption that an application declares it for itself when it needs it. This one never
did. Every request in a release build failed before it left the device, so the check has been broken
in every published build since 1.0.0 — and the mirrors added in ADR-0009 could not have helped,
because the failure was never reaching GitHub in the first place.

**Why no test caught it.** `flutter test` runs against a mocked HTTP client, and the debug APK — the
one used for local checks — carries the permission from the debug manifest. The permission list of a
*release* artifact is the only place this is visible, and nothing was looking at it. The release
workflow now does: it asserts the APK declares INTERNET, alongside the ABI and model checks it
already made.

## The package was 44.4 MB

| Part | Stored | Notes |
|---|---|---|
| `libopencv_java4.so` | 23.51 MB | 53% of the download, already stripped |
| `libflutter.so` | 11.58 MB | Flutter engine, unavoidable |
| `libapp.so` | 6.36 MB | Dart AOT, unavoidable |
| everything else | ~2.9 MB | |

The library has no debug sections and no symbol table, so stripping it would have saved nothing —
worth checking rather than assuming. It does deflate to 9.16 MB.

Native libraries are stored **uncompressed** so the loader can map them straight out of the APK.
Release builds now store them deflated (`jniLibs.useLegacyPackaging = true`), which takes the package
to **18.9 MB, 57% smaller**.

The cost, stated rather than buried: the libraries are extracted into internal storage at install
(about 41 MB), and the first start is slightly slower because the loader reads from the extracted
copy. Debug builds keep the uncompressed behaviour, where install time matters more than download
size.

## What was not done

The deeper fix for the OpenCV contribution is the minimal source build deferred in ADR-0002: the
published `libopencv_java4.so` contains every OpenCV module, while this app calls nine. The iOS
counterpart of that idea produced a 10.2 MB plugin framework, so an Android equivalent could halve
the library again. It needs a from-source build and somewhere to host the output, and it was not
attempted in this round.

## Re-tagging

`gh release create` fails when the release already exists, so correcting a published version would
have required burning a new version number. The publish step now updates an existing release in
place — same asset name, `--clobber`, notes rewritten from the curated file — which is how 1.0.3 was
corrected after these two fixes.
