#!/usr/bin/env bash
#
# Builds the minimal OpenCV xcframework the iOS side of packages/wechat_qrcode
# links against.
#
# Why a custom build rather than a prebuilt OpenCV framework:
#
#   * `opencv_contrib/modules/wechat_qrcode/CMakeLists.txt` declares its
#     dependencies as `opencv_core opencv_imgproc opencv_objdetect opencv_dnn`.
#     Those five modules, and nothing else, are what this project may ship
#     (CLAUDE.md §1, §9.3).
#   * No published OpenCV iOS framework includes `wechat_qrcode`, so one has to
#     be built anyway.
#
# Requirements: macOS with Xcode command line tools, cmake >= 3.20, python3.
#
# Usage:
#   scripts/build_opencv_ios.sh
#   OPENCV_VERSION=4.12.0 scripts/build_opencv_ios.sh
#
# The output is placed at packages/wechat_qrcode/ios/opencv2.xcframework and is
# deliberately NOT committed (.gitignore excludes *.xcframework).
#
# ---------------------------------------------------------------------------
# STATUS: this script has not been executed. It was authored on Windows, where
# no macOS toolchain exists, so the iOS build in this repository is unverified.
# Run it on a Mac and report the result before claiming iOS support.
# ---------------------------------------------------------------------------

set -euo pipefail

OPENCV_VERSION="${OPENCV_VERSION:-4.12.0}"
OPENCV_CONTRIB_BRANCH="${OPENCV_CONTRIB_BRANCH:-4.x}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/scripts/opencv-ios-build}"
OUTPUT_DIR="$REPO_ROOT/packages/wechat_qrcode/ios"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"

# Only what wechat_qrcode needs. Adding a module here widens both the licence
# surface and the binary size, so keep this list short and justified.
MODULES="core,imgproc,objdetect,dnn,wechat_qrcode"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script needs macOS (Xcode toolchain). Current: $(uname -s)" >&2
  exit 1
fi

for tool in cmake python3 xcodebuild; do
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

if [[ ! -f "$CONTRIB_SRC/modules/wechat_qrcode/CMakeLists.txt" ]]; then
  echo "error: wechat_qrcode module not found in $CONTRIB_SRC/modules" >&2
  exit 1
fi

# ---------------------------------------------------------------- build

# $1 = cmake system name, $2 = architectures, $3 = build dir, $4 = extra args
build_slice() {
  local sysname="$1"
  local archs="$2"
  local build_dir="$3"

  echo "==> Building $sysname ($archs)"
  cmake -S "$OPENCV_SRC" -B "$build_dir" \
    -DCMAKE_SYSTEM_NAME="$sysname" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPENCV_EXTRA_MODULES_PATH="$CONTRIB_SRC/modules" \
    -DBUILD_LIST="$MODULES" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_opencv_framework=ON \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF \
    -DBUILD_DOCS=OFF \
    -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_CUDA=OFF \
    -DWITH_FFMPEG=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
    -DOPENCV_ENABLE_NONFREE=OFF

  cmake --build "$build_dir" --config Release --parallel "$(sysctl -n hw.ncpu)"
}

# Device slice.
build_slice "iOS" "arm64" "$WORK_DIR/build-ios"

# Simulator slice: both architectures in one framework so an Apple-silicon Mac
# can run the simulator build.
build_slice "iOS" "arm64;x86_64" "$WORK_DIR/build-simulator" \
  "-DCMAKE_OSX_SYSROOT=iphonesimulator"

# ---------------------------------------------------------------- xcframework

FRAMEWORK_DEVICE="$WORK_DIR/build-ios/lib/Release/opencv2.framework"
FRAMEWORK_SIM="$WORK_DIR/build-simulator/lib/Release/opencv2.framework"

if [[ ! -d "$FRAMEWORK_DEVICE" || ! -d "$FRAMEWORK_SIM" ]]; then
  echo "error: expected frameworks were not produced." >&2
  echo "  device:     $FRAMEWORK_DEVICE" >&2
  echo "  simulator:  $FRAMEWORK_SIM" >&2
  exit 1
fi

echo "==> Creating opencv2.xcframework"
rm -rf "$OUTPUT_DIR/opencv2.xcframework"
xcodebuild -create-xcframework \
  -framework "$FRAMEWORK_DEVICE" \
  -framework "$FRAMEWORK_SIM" \
  -output "$OUTPUT_DIR/opencv2.xcframework"

echo
echo "Done: $OUTPUT_DIR/opencv2.xcframework"
echo
echo "Verify before relying on it:"
echo "  - the xcframework contains only: $MODULES"
echo "  - 'cv::wechat_qrcode::WeChatQRCode' resolves (nm on the binary)"
echo "  - a clean 'flutter build ios --release' succeeds, then install the .ipa"
echo "    with TrollStore on the target device."
