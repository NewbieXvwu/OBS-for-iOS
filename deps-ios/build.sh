#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
export PATH="$PWD/.workspace-tools/bin:$PATH"
source deps-ios/versions.sh

case "${1:-all}" in
  all) sdks=(iphoneos iphonesimulator) ;;
  iphoneos|iphonesimulator) sdks=("$1") ;;
  *) echo "用法: $0 [all|iphoneos|iphonesimulator] [依赖名称 ...]" >&2; exit 2 ;;
esac
if (($#)); then shift; fi
if (($#)); then
  deps=("$@")
else
  deps=(simde uthash jansson x264 x265 mbedtls speexdsp rnnoise freetype curl srt librist libdatachannel asio websocketpp json ffmpeg)
fi

jobs=${JOBS:-$(sysctl -n hw.logicalcpu)}
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export TMPDIR="$root/.deps-build/tmp"
mkdir -p .deps-src "$TMPDIR" .deps-prebuilt

fetch() (
  local name=$1 version=$2 destination=$3
  if [[ -d $destination ]]; then return; fi
  local staged
  staged=$(mktemp -d "$root/.deps-src/$name.XXXXXXXX")
  trap 'rm -rf "$staged"' EXIT
  if [[ $name == libdatachannel ]]; then
    git clone --quiet --depth 1 --branch "v$version" --recurse-submodules --shallow-submodules \
      https://github.com/paullouisageneau/libdatachannel.git "$staged/source"
  else
    curl -fLsS --retry 2 --retry-all-errors "$(dep_url "$name" "$version")" -o "$staged/archive"
    mkdir "$staged/source"
    tar -xf "$staged/archive" --strip-components=1 -C "$staged/source"
    case "$name" in
      rnnoise)
        # RNNoise 0.2's ARM NEON header references the old Opus names.
        sed -i '' -e 's/"os_support.h"/"common.h"/' -e 's/OPUS_CLEAR/RNN_CLEAR/' \
          "$staged/source/src/vec_neon.h" ;;
      mbedtls)
        # libdatachannel needs DTLS-SRTP for WebRTC media transport.
        sed -i '' 's,^//#define MBEDTLS_SSL_DTLS_SRTP$,\#define MBEDTLS_SSL_DTLS_SRTP,' \
          "$staged/source/include/mbedtls/mbedtls_config.h" ;;
    esac
  fi
  mv "$staged/source" "$destination"
)

build_cmake() {
  local source=$1
  shift
  cmake -S "$source" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_FIND_ROOT_PATH="$prefix;$sysroot" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY -DBUILD_SHARED_LIBS=OFF "$@"
  cmake --build "$build" --parallel "$jobs"
  cmake --install "$build"
}

build_make() (
  cd "$build"
  export CC="$clang" CXX="$clangxx" AR="$ar" RANLIB="$ranlib"
  export CFLAGS="$flags -O2 -fPIC -I$prefix/include"
  export LDFLAGS="$flags -L$prefix/lib"
  "$@"
  make -j"$jobs"
  make install
)

build_rist() {
  cat > "$build/cross.ini" <<EOF
[binaries]
c = ['$clang', '-target', '$target', '-isysroot', '$sysroot']
ar = '$ar'
strip = '$strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
  meson setup "$build/meson" "$source" --cross-file "$build/cross.ini" \
    --prefix "$prefix" --libdir lib --buildtype release --default-library static \
    -Dtest=false -Dbuilt_tools=false -Dbuiltin_cjson=true
  meson compile -C "$build/meson" -j "$jobs"
  meson install -C "$build/meson"
}

for sdk in "${sdks[@]}"; do
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  clang=$(xcrun --sdk "$sdk" --find clang)
  clangxx=$(xcrun --sdk "$sdk" --find clang++)
  ar=$(xcrun --sdk "$sdk" --find ar)
  ranlib=$(xcrun --sdk "$sdk" --find ranlib)
  strip=$(xcrun --sdk "$sdk" --find strip)
  target="arm64-apple-ios$IPHONEOS_DEPLOYMENT_TARGET"
  if [[ $sdk == iphonesimulator ]]; then target+=-simulator; fi
  flags="-target $target -isysroot $sysroot"
  prefix="$root/.deps-prebuilt/$sdk-arm64"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=
  mkdir -p "$prefix/include"

  for dep in "${deps[@]}"; do
    key="version_$dep"
    version=${!key:?未知依赖 $dep}
    source="$root/.deps-src/$dep-$version"
    build="$root/.deps-build/$sdk-arm64/$dep-$version"
    printf '\n== %s %s (%s) ==\n' "$dep" "$version" "$sdk"
    fetch "$dep" "$version" "$source"
    mkdir -p "$build"

    case "$dep" in
      simde) cp -R "$source/simde" "$prefix/include/" ;;
      uthash) cp "$source/src"/*.h "$prefix/include/" ;;
      asio) cp -R "$source/asio/include/"* "$prefix/include/" ;;
      websocketpp) cp -R "$source/websocketpp" "$prefix/include/" ;;
      json) build_cmake "$source" -DJSON_BuildTests=OFF ;;
      jansson) build_cmake "$source" -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON ;;
      x264) build_make "$source/configure" --prefix="$prefix" --host=aarch64-apple-darwin \
        --extra-asflags="$flags" --enable-static --enable-pic --disable-cli --disable-opencl ;;
      x265) build_cmake "$source/source" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
        -DASM_FLAGS="-target;$target;-isysroot;$sysroot" ;;
      mbedtls) build_cmake "$source" -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF ;;
      speexdsp|rnnoise) build_make "$source/configure" --prefix="$prefix" --host=aarch64-apple-darwin \
        --enable-static --disable-shared ;;
      freetype) build_cmake "$source" -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON ;;
      curl) build_cmake "$source" -DBUILD_CURL_EXE=OFF -DCURL_USE_MBEDTLS=ON \
        -DCURL_USE_OPENSSL=OFF -DCURL_USE_LIBPSL=OFF -DHTTP_ONLY=ON -DHAVE_PIPE2=OFF ;;
      srt) build_cmake "$source" -DENABLE_APPS=OFF -DENABLE_SHARED=OFF -DUSE_ENCLIB=mbedtls ;;
      librist) build_rist ;;
      libdatachannel) build_cmake "$source" -DUSE_MBEDTLS=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON ;;
      ffmpeg) build_make "$source/configure" --prefix="$prefix" --arch=aarch64 --target-os=darwin \
        --enable-cross-compile --sysroot="$sysroot" --cc="$clang" --cxx="$clangxx" \
        --ar="$ar" --ranlib="$ranlib" --strip="$strip" --extra-cflags="$flags -I$prefix/include" \
        --extra-ldflags="$flags -L$prefix/lib" --extra-libs=-lc++ --pkg-config-flags=--static \
        --enable-static --disable-shared --disable-programs --disable-doc --disable-debug --disable-autodetect \
        --enable-pic --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-mbedtls \
        --enable-gpl --enable-version3 --enable-libx264 --enable-libx265 --enable-libsrt --enable-librist ;;
    esac
  done
done
