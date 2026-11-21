#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
export PATH="$PWD/.workspace-tools/bin:$PATH"

case "${1:-all}" in
  all) sdks=(iphoneos iphonesimulator) ;;
  iphoneos|iphonesimulator) sdks=("$1") ;;
  *) echo "用法: $0 [all|iphoneos|iphonesimulator] [CMake 参数 ...]" >&2; exit 2 ;;
esac
if (($#)); then shift; fi

ca_bundle="$root/.deps-src/cacert-2026-11-05.pem"
if [[ ! -f $ca_bundle ]]; then
  mkdir -p "$root/.deps-src"
  curl -fLsS https://curl.se/ca/cacert-2026-11-05.pem -o "$ca_bundle.part"
  mv "$ca_bundle.part" "$ca_bundle"
fi

for sdk in "${sdks[@]}"; do
  prefix="$root/.deps-prebuilt/$sdk-arm64"
  build="$root/.build/ios/$sdk"
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig" PKG_CONFIG_PATH=
  cmake -S obs-studio -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_FIND_ROOT_PATH="$prefix;$sdk_path" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DOBS_VERSION_OVERRIDE=33.0.0-ios \
    -DOBS_IOS_APP_SOURCE_DIR="$root/ios-app" -DOBS_IOS_CA_BUNDLE="$ca_bundle" \
    -DENABLE_WEBSOCKET=ON "$@"
  cmake --build "$build" --config Release --parallel "${JOBS:-$(sysctl -n hw.logicalcpu)}"
done
