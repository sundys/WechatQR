# 0003 — Model files: provenance and redistribution

Date: 2026-10-15
Status: Accepted

## Context

The WeChatQRCode engine needs four model files. Unlike a library dependency, these are *assets* that
are copied into the application and redistributed, so CLAUDE.md §9.2 requires their location,
licence, filenames and loading method to be established — and §1/§9.3 require licence compliance
before shipping them.

## Provenance — verified by hash

The models come from the WeChat Computer Vision Team via
`https://github.com/WeChatCV/opencv_3rdparty`, at commit `a8b69ccc738421293254aec5ddb38bd523503252`.
That commit hash and the expected MD5s are declared in
`opencv_contrib/modules/wechat_qrcode/CMakeLists.txt`, which is what OpenCV itself downloads.

The four files in this repository were compared against those MD5s:

| File | MD5 | Matches upstream |
|---|---|---|
| `detect.caffemodel` | `238e2b2d6f3c18d6c3a30de0c31e23cf` | yes, byte-for-byte |
| `detect.prototxt` | `6fb4976b32695f9f5c6305c19f12537d` | yes, after CRLF→LF normalisation |
| `sr.caffemodel` | `cbfcd60361a73beb8c583eea7e8e6664` | yes, byte-for-byte |
| `sr.prototxt` | `69db99927a70df953b471daaba03fbef` | yes, after CRLF→LF normalisation |

The two `.prototxt` files arrived with CRLF line endings from a Windows checkout (`core.autocrlf`
was `true` on the source clone), so their raw MD5 differed. They were normalised to LF when vendored;
`.gitattributes` marks them `-text` so Git cannot reintroduce the conversion.

One intermediate error is worth recording: a first pass piped the **binary** `.caffemodel` files
through `tr -d '\r'`, which silently corrupted them. The MD5 check caught it — which is the reason
the check is recorded here rather than being a one-off.

## Licence — verified from the source, not inferred

`WeChatCV/opencv_3rdparty` `LICENSE` states:

> WeChat QRCode is licensed under the Apache License Version 2.0, except for the third-party
> components listed below.

Copyright (C) 2021 THL A29 Limited, a Tencent company. The only third-party component listed is
**zxing** (Apache-2.0, Copyright (c) zxing authors and contributors).

**Conclusion: the models are redistributable**, provided attribution, the licence text, and any
NOTICE contents are carried along. That is satisfied by:

* `docs/licenses/WeChat-QRCode-LICENSE.txt` — the full licence text, including the zxing entry.
* `docs/licenses/NOTICE` — the component-by-component attribution.
* `docs/licenses/Apache-2.0.txt`.
* The in-app 开源许可 screen, which registers the vendored-code and model attribution with Flutter's
  `LicenseRegistry` so it appears on the standard licence page.

Distributing under Apache-2.0 grants no trademark rights, so the WeChat/腾讯 names are used only
descriptively in these notices.

## Packaging — where the files live

The models must be inside the installed app; no development-machine path is referenced at runtime.

| Platform | Location | Loading |
|---|---|---|
| Android | `packages/wechat_qrcode/android/src/main/assets/models/` | Extracted once into the app's **internal** `filesDir`, then handed to `WeChatQRCode` by absolute path |
| iOS | `packages/wechat_qrcode/ios/wechat_qrcode/Sources/wechat_qrcode/Resources/models/` | Located in the plugin bundle (`Bundle.module` under SPM, the resource bundle under CocoaPods) and passed by path |

Two copies exist because the platforms package assets differently. Both are byte-identical to the
upstream files (same MD5s as above), so they cannot drift without the hash check failing.

The Android extraction target is `context.filesDir`, not the external files directory used by the
upstream implementation: external storage can be unmounted or read-only, and the models are private
to the app. Extraction is skipped when all four files are already present and non-empty, so a
partially written directory is refilled rather than trusted.

## Failure handling

Missing, unreadable or rejected models produce an explicit, retryable error
(`WeChatQrCodeError.modelLoadFailed`) that the scan tab surfaces with a retry button — not a crash
and not a silent no-op. See decision 0004.

## If a licence problem ever appears

If any of the above were found to be inaccurate, the correct action is to stop shipping the assets
and raise the alternative, not to ignore the licence. The models are the one part of this project
that cannot be swapped out without changing what the engine does.
