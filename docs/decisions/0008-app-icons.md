# 0008 — Application icons

Date: 2026-10-15
Status: Accepted

## Source

`app/assets/icon/app_icon.png` — 273×273, RGBA. A rounded-rectangle design: the corners are
transparent (5.1% of the pixels, a corner radius of roughly 22% of the side, close to iOS's own icon
shape), the edge is a blue (`#408CBE` at the top edge, `#205081` at the left) and the centre is a
mint green (`#65E6AD`).

## Tool

`flutter_launcher_icons` 0.14.4 (MIT), a **dev-only** dependency. It generates the Android mipmaps
and the iOS `AppIcon` set from one source image; the results are committed, so the shipped build has
no dependency on it and it does not appear in the in-app licence list.

## Two derived images, and why

The source cannot be used directly for either platform:

* **iOS icons must be opaque.** The design's transparent corners would be filled with an arbitrary
  colour by the generator. `app_icon_opaque.png` is the design flattened onto the average colour of
  its own boundary pixels (`#234C7B`), so the fill is derived from the artwork rather than chosen.
  iOS then applies its own corner mask, which is nearly the same shape as the design's, so the fill is
  almost entirely hidden.
* **Android adaptive icons need both layers**, and the artwork is full-bleed, so it belongs in the
  *background* layer where the launcher's mask crops it. `flutter_launcher_icons` requires a
  foreground as well; `app_icon_foreground.png` is a fully transparent 432×432 image, which lets the
  background show through unaltered. Putting the design in the foreground instead would shrink it
  into the 66% safe zone and leave a tile-inside-a-tile.

## Configuration

```yaml
flutter_launcher_icons:
  android: true
  ios: true
  image_path: assets/icon/app_icon_opaque.png
  adaptive_icon_background: assets/icon/app_icon_opaque.png
  adaptive_icon_foreground: assets/icon/app_icon_foreground.png
```

Generated and committed:

| Platform | Files |
|---|---|
| Android legacy | `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` (48…192 px) |
| Android adaptive | `mipmap-anydpi-v26/ic_launcher.xml` + `drawable-*dpi/ic_launcher_{background,foreground}.png` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` — 21 images, all RGB (no alpha) |

`AndroidManifest.xml` references only `@mipmap/ic_launcher`; there is no `roundIcon`, so no round
assets are needed.

## The tool also edits the Xcode project, incorrectly

`flutter_launcher_icons` rewrites two build settings in `project.pbxproj`, changing

```
ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
```

to `= AppIcon`. That setting is a boolean — whether Xcode generates Swift accessors for asset
catalog symbols — and `AppIcon` is not a value it accepts; the value belongs to
`ASSETCATALOG_COMPILER_APPICON_NAME`, which already exists and was already correct. It looks like the
tool patched the wrong key, and it left the third occurrence of the setting untouched, so the file
ended up inconsistent as well.

Both edits were reverted. **Re-check this after any future run of the generator**: the icon set is
referenced by `ASSETCATALOG_COMPILER_APPICON_NAME` and needs nothing else.

## Known limitation

**273 px is small for a source image.** The largest iOS icons (1024×1024 and 180×180@3x) are
upscaled from it and will look slightly soft on a high-density screen. The Android legacy icons
(≤192 px) and all adaptive layers are within the source resolution and are unaffected.

If a 1024×1024 original becomes available, replacing `app/assets/icon/app_icon.png`, re-deriving the
two files above and re-running `dart run flutter_launcher_icons` is the whole change.

## Not done

* No `adaptive_icon_monochrome`, so Android 13+ themed icons will fall back to the launcher's default
  treatment. A monochrome layer would have to be designed; it cannot be derived from this artwork.
* No splash screen was touched; `drawable/launch_background.xml` still holds the template's plain
  background.
