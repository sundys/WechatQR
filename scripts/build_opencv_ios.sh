#!/usr/bin/env bash
#
# Builds the OpenCV xcframework the iOS side of packages/wechat_qrcode links
# against.
#
# Why a custom build at all:
#
#   * No published OpenCV iOS framework includes `wechat_qrcode` (it lives in
#     opencv_contrib), so one has to be built regardless.
#   * CLAUDE.md §1/§9.3 require keeping only what the engine needs.
#
# How the trimming works, and its limits:
#
#   OpenCV's official `platforms/apple/build_xcframework.py` has no module
#   *whitelist*, only `--without MODULE` exclusions. Unknown arguments are
#   parsed and then discarded ("will not be used"), so `-DBUILD_LIST=...` cannot
#   be injected through it. An earlier version of this script passed
#   `-DBUILD_opencv_framework=ON`; that flag does not exist in OpenCV 4.12, so
#   the variable was silently unused and no framework was ever produced — which
#   is how the first CI run failed.
#
#   The exclusions are therefore *computed*: every module in both source trees
#   that is not in the transitive dependency closure of `wechat_qrcode` is
#   passed to `--without`. The closure is read from each module's own
#   `ocv_define_module(...)` / `ocv_add_module(...)` declaration, so it tracks
#   the sources rather than a hard-coded list of names.
#
#   Note that the closure is larger than the five modules the module itself
#   names. `objdetect` pulls in `calib3d`, which pulls in `features2d` and
#   `flann`, and `core` itself pulls in `cudev` — verified against the real
#   4.12.0 sources. Those are genuine requirements, not padding.
#
# Only the arm64 simulator slice is built. The delivery target is a physical
# arm64 device installed through TrollStore, so the device slice is what matters
# and the arm64 simulator slice covers running on an Apple-silicon Mac. The
# x86_64 simulator slice would double the simulator half of a ~30 minute build
# for a use this project does not have.
#
# Requirements: macOS with Xcode command line tools, cmake >= 3.20, python3.
#
# Usage:
#   scripts/build_opencv_ios.sh
#   OPENCV_VERSION=4.12.0 scripts/build_opencv_ios.sh
#
# Output: packages/wechat_qrcode/ios/opencv2.xcframework, which is deliberately
# not committed (.gitignore excludes *.xcframework).
#
# ---------------------------------------------------------------------------
# STATUS: not yet verified end to end. The previous cmake-based implementation
# failed in CI; this one uses OpenCV's maintained build script, which is far
# more likely to work but has not been run on a Mac yet.
# ---------------------------------------------------------------------------

set -euo pipefail

OPENCV_VERSION="${OPENCV_VERSION:-4.12.0}"
OPENCV_CONTRIB_BRANCH="${OPENCV_CONTRIB_BRANCH:-4.x}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"

# What the engine needs, before the transitive closure is expanded.
MODULES="core imgproc objdetect dnn wechat_qrcode"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/scripts/opencv-ios-build}"
OUTPUT_DIR="$REPO_ROOT/packages/wechat_qrcode/ios"
BUILD_OUT="$WORK_DIR/xcframework"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script needs macOS (Xcode toolchain). Current: $(uname -s)" >&2
  exit 1
fi

for tool in python3 cmake xcodebuild nm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' not found." >&2
    exit 1
  fi
done

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---------------------------------------------------------------- sources

if [[ ! -d "opencv-$OPENCV_VERSION" ]]; then
  echo "==> Fetching OpenCV $OPENCV_VERSION sources"
  curl -L --fail -o "opencv-$OPENCV_VERSION.tar.gz" \
    "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VERSION.tar.gz"
  tar xzf "opencv-$OPENCV_VERSION.tar.gz"
fi

if [[ ! -d "opencv_contrib-$OPENCV_CONTRIB_BRANCH" ]]; then
  echo "==> Fetching opencv_contrib ($OPENCV_CONTRIB_BRANCH)"
  curl -L --fail -o "opencv_contrib.tar.gz" \
    "https://github.com/opencv/opencv_contrib/archive/refs/heads/$OPENCV_CONTRIB_BRANCH.tar.gz"
  tar xzf "opencv_contrib.tar.gz"
fi

OPENCV_SRC="$WORK_DIR/opencv-$OPENCV_VERSION"
CONTRIB_SRC="$WORK_DIR/opencv_contrib-$OPENCV_CONTRIB_BRANCH"
BUILD_XCFRAMEWORK_PY="$OPENCV_SRC/platforms/apple/build_xcframework.py"

for required in \
  "$CONTRIB_SRC/modules/wechat_qrcode/CMakeLists.txt" \
  "$BUILD_XCFRAMEWORK_PY"; do
  if [[ ! -f "$required" ]]; then
    echo "error: expected file not found: $required" >&2
    exit 1
  fi
done

# ------------------------------------------------- compute the --without list

echo "==> Computing the module exclusion list (keeping: $MODULES)"
WITHOUT_FILE="$WORK_DIR/without_modules.txt"
python3 - "$OPENCV_SRC/modules" "$CONTRIB_SRC/modules" $MODULES > "$WITHOUT_FILE" <<'PY'
import os
import re
import sys

main_modules, contrib_modules = sys.argv[1], sys.argv[2]
keep = sys.argv[3:]

# Which modules exist at all. Anything that is not one of these names is a CMake
# keyword or a language binding (WRAP, OPTIONAL, java, objc, python, js, …) and
# is dropped automatically by filtering dependencies against this set.
available = set()
for root in (main_modules, contrib_modules):
    if not os.path.isdir(root):
        continue
    for name in os.listdir(root):
        if os.path.isfile(os.path.join(root, name, 'CMakeLists.txt')):
            available.add(name)

# Both spellings are in use: `ocv_define_module` in most modules and
# `ocv_add_module` in others (dnn, for example).
DECLARATION = re.compile(r'ocv_(?:define|add)_module\s*\(')
IDENTIFIER = re.compile(r'[A-Za-z0-9_]+')


def dependencies_of(path):
    """Returns the module names declared after the module's own name."""
    with open(path, 'r', errors='replace') as handle:
        text = handle.read()
    match = DECLARATION.search(text)
    if not match:
        return set()

    # Scan to the matching close paren; the argument list can span lines and
    # can contain nested parentheses.
    depth = 1
    index = match.end()
    while index < len(text) and depth:
        if text[index] == '(':
            depth += 1
        elif text[index] == ')':
            depth -= 1
        index += 1
    arguments = text[match.end():index - 1]

    # Drop `WRAP` and everything after it: those are binding languages, not
    # module dependencies.
    wrap = arguments.find('WRAP')
    if wrap != -1:
        arguments = arguments[:wrap]

    # Dependencies are written with an `opencv_` prefix (`opencv_calib3d`) while
    # the module directories are not (`calib3d`), so the prefix is stripped
    # before matching. Without this every dependency is discarded and the
    # closure collapses to the explicitly listed modules — which silently drops
    # real requirements such as objdetect's dependency on calib3d.
    names = IDENTIFIER.findall(arguments)
    normalised = {
        name[len('opencv_'):] if name.startswith('opencv_') else name
        for name in names
    }
    return {name for name in normalised if name in available}


deps = {}
for root in (main_modules, contrib_modules):
    if not os.path.isdir(root):
        continue
    for name in sorted(available):
        path = os.path.join(root, name, 'CMakeLists.txt')
        if os.path.isfile(path):
            deps[name] = dependencies_of(path)

missing = [name for name in keep if name not in available]
if missing:
    print('error: module(s) not found in the sources: %s' % ', '.join(missing),
          file=sys.stderr)
    sys.exit(1)

closure = set()
queue = list(keep)
while queue:
    current = queue.pop()
    if current in closure:
        continue
    closure.add(current)
    queue.extend(dep for dep in deps.get(current, ()) if dep not in closure)

kept = sorted(closure & available)
print('    keeping %d module(s): %s' % (len(kept), ' '.join(kept)),
      file=sys.stderr)

for name in sorted(available - closure):
    print('--without')
    print(name)
PY

if [[ ! -s "$WITHOUT_FILE" ]]; then
  echo "error: the exclusion list came out empty; refusing to build every module." >&2
  exit 1
fi

# Read one flag per line. A while-read loop rather than `mapfile`: macOS ships
# bash 3.2, which has no `mapfile`.
WITHOUT_ARGS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && WITHOUT_ARGS+=("$line")
done < "$WITHOUT_FILE"

echo "    excluding $(( ${#WITHOUT_ARGS[@]} / 2 )) module(s)"

# Unused backends and external dependencies: build time and link surface for no
# benefit here. `protobuf` is deliberately NOT disabled — dnn needs it to load
# the Caffe models this engine is built around.
DISABLE_ARGS=(
  --disable ffmpeg --disable gstreamer --disable gtk --disable qt
  --disable opencl --disable ipp --disable openmp --disable tbb
  --disable cuda --disable eigen
)

# ---------------------------------------------------------------- build

echo "==> Building the xcframework (device arm64, simulator arm64)"
rm -rf "$BUILD_OUT"

# The build output is captured rather than only streamed, because the useful
# error is almost never at the end: a failure during compilation reports the
# offending file far above the final make error, and CMakeError.log only covers
# configure-time compiler checks.
BUILD_LOG="$WORK_DIR/opencv-build.log"

set +e
python3 "$BUILD_XCFRAMEWORK_PY" \
  --out "$BUILD_OUT" \
  --framework_name opencv2 \
  --iphoneos_archs arm64 \
  --iphonesimulator_archs arm64 \
  --build_only_specified_archs \
  --iphoneos_deployment_target "$DEPLOYMENT_TARGET" \
  --contrib "$CONTRIB_SRC" \
  "${DISABLE_ARGS[@]}" \
  "${WITHOUT_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
  # Reported three ways, because each reaches a different reader:
  #   * stderr, for a human watching the log
  #   * the job summary, which is readable through the public API without a
  #     token — that is what makes a failure diagnosable without a round trip
  #   * the CMake logs, for configure-time failures specifically
  {
    echo "## OpenCV xcframework build failed (exit $BUILD_STATUS)"
    echo
    echo "Modules deliberately kept: \`${MODULES}\` (plus their transitive closure)."
    echo
    echo "### Compiler / make errors"
    echo '```'
    grep -nE "error:|fatal error|Error [0-9]+|FAILED|undefined symbol" "$BUILD_LOG" 2>/dev/null | head -40
    echo '```'
    echo "### Last 60 lines of the build output"
    echo '```'
    tail -n 60 "$BUILD_LOG" 2>/dev/null
    echo '```'
  } > "$WORK_DIR/failure-summary.md" 2>/dev/null || true

  cat "$WORK_DIR/failure-summary.md" >&2 || true
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$WORK_DIR/failure-summary.md" >> "$GITHUB_STEP_SUMMARY"
  fi

  echo "::error::the OpenCV xcframework build failed (exit $BUILD_STATUS)" >&2
  while IFS= read -r log; do
    echo "----- ${log} (last 40 lines) -----" >&2
    tail -n 40 "$log" >&2
  done < <(find "$BUILD_OUT" \( -name 'CMakeError.log' -o -name 'CMakeOutput.log' \) 2>/dev/null | head -4)
  echo "----- module exclusion list that was used -----" >&2
  echo "keeping: ${MODULES}" >&2
  tr '\n' ' ' < "$WITHOUT_FILE" >&2
  echo >&2
  exit $BUILD_STATUS
fi

PRODUCED="$BUILD_OUT/opencv2.xcframework"
if [[ ! -d "$PRODUCED" ]]; then
  echo "error: $PRODUCED was not produced." >&2
  exit 1
fi

# ---------------------------------------------------------------- verify

echo "==> Verifying the framework carries the WeChat QRCode engine"

# The device slice is located by shape rather than by name: Xcode names slices
# after the platform and architectures (ios-arm64, ios-arm64-simulator, …), and
# hard-coding that would be one more assumption to be wrong about.
DEVICE_SLICE=""
for candidate in "$PRODUCED"/*/; do
  case "$candidate" in
    *-simulator/) continue ;;
  esac
  if find "$candidate" -type f -name opencv2 2>/dev/null | grep -q .; then
    DEVICE_SLICE="$candidate"
    break
  fi
done

if [[ -z "$DEVICE_SLICE" ]]; then
  echo "error: the xcframework has no device slice." >&2
  ls -la "$PRODUCED" >&2
  exit 1
fi
echo "    device slice: ${DEVICE_SLICE#$PRODUCED/}"

# Checked against the build log, not the produced binary. OpenCV compiles with
# -fvisibility=hidden and `nm -g` filters by external linkage, so the module's
# symbols do not appear in `nm -gU` output even when the module is present and
# correctly compiled. An earlier version of this script failed an entirely
# healthy 18-minute build exactly that way. "opencv_wechat_qrcode was compiled"
# is direct evidence and no compiler flag can defeat it.
if ! grep -q 'opencv_wechat_qrcode' "$BUILD_LOG"; then
  echo "error: the build log shows wechat_qrcode was never compiled." >&2
  echo "       The --without list removed a module it was meant to keep." >&2
  exit 1
fi
echo "    wechat_qrcode was compiled into opencv_wechat_qrcode"

# Informational only. This can legitimately find nothing, so it must never
# decide the outcome.
DEVICE_BINARY="$(find "$DEVICE_SLICE" -type f -name opencv2 2>/dev/null | head -1)"
if [[ -n "$DEVICE_BINARY" ]] && nm "$DEVICE_BINARY" 2>/dev/null | grep -q 'wechat_qrcode'; then
  echo "    the device slice references wechat_qrcode symbols"
else
  echo "    note: no wechat_qrcode symbols visible in the device binary (expected under -fvisibility=hidden)"
fi

# ---------------------------------------------------------------- install

# Copied rather than built in place: build_xcframework.py leaves intermediate
# folders next to its output, and those must not land in the repository.
rm -rf "$OUTPUT_DIR/opencv2.xcframework"
cp -R "$PRODUCED" "$OUTPUT_DIR/opencv2.xcframework"

echo
echo "Done: $OUTPUT_DIR/opencv2.xcframework"
echo "      binary: $BINARY"
echo
echo "Next: cd app && flutter build ios --release --no-codesign"
echo "      then install the resulting .ipa with TrollStore."
