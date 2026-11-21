#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
release="$root/.build/release"
mkdir -p "$release"
stage=$(mktemp -d "$root/.build/package.XXXXXXXX")
trap 'rm -r -- "$stage"' EXIT

case "${1:-all}" in
  all|sideload) ;;
  *) echo "用法: $0 [all|sideload]" >&2; exit 2 ;;
esac

build_package() {
  local kind=$1 build=$2 build_flag=$3
  local work="$stage/$kind"
  local app="$work/Payload/OBS.app"
  OBS_PRIVILEGED_BUILD="$build_flag" scripts/build-libobs-ios.sh iphoneos
  mkdir -p "$work/Payload"
  ditto "$build/ios-app/Release-iphoneos/OBS.app" "$app"
  if [[ $kind == Privileged ]]; then
    local mux="$build/plugins/obs-ffmpeg/ffmpeg-mux/Release-iphoneos/obs-ffmpeg-mux.app/obs-ffmpeg-mux"
    cp "$mux" "$app/obs-ffmpeg-mux"
    codesign --force --sign - "$app/obs-ffmpeg-mux"
  fi
  codesign --force --sign - --entitlements "ios-app/Entitlements/$kind.entitlements" "$app"
  (cd "$work" && zip -qry -y "OBS-$kind.ipa" Payload)
}

build_package Sideload "$root/.build/ios/iphoneos" 0
if [[ ${1:-all} == sideload ]]; then
  mv "$stage/Sideload/OBS-Sideload.ipa" "$release/OBS-Sideload.ipa"
  printf '%s\n' "$release/OBS-Sideload.ipa"
  exit
fi
build_package Privileged "$root/.build/ios/privileged/iphoneos" 1

deb="$stage/deb"
mkdir -p "$deb/data/var/jb/Applications" "$deb/control"
ditto "$stage/Privileged/Payload/OBS.app" "$deb/data/var/jb/Applications/OBS.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$deb/data/var/jb/Applications/OBS.app/Info.plist")
cat > "$deb/control/control" <<EOF
Package: org.obsproject.studio.ios
Name: OBS Studio
Version: $version
Architecture: iphoneos-arm64
Description: OBS Studio for iOS
Maintainer: OBS-for-iOS
Section: Multimedia
EOF
cat > "$deb/control/postinst" <<'EOF'
#!/bin/sh
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -p /var/jb/Applications/OBS.app
fi
EOF
chmod 755 "$deb/control/postinst"
printf '2.0\n' > "$deb/debian-binary"
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 -czf "$deb/control.tar.gz" -C "$deb/control" .
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 -czf "$deb/data.tar.gz" -C "$deb/data" .
tar --format=arsvr4 -cf "$deb/OBS-Privileged.deb" -C "$deb" debian-binary control.tar.gz data.tar.gz

mv "$stage/Sideload/OBS-Sideload.ipa" "$release/OBS-Sideload.ipa"
mv "$stage/Privileged/OBS-Privileged.ipa" "$release/OBS-Privileged.ipa"
mv "$deb/OBS-Privileged.deb" "$release/OBS-Privileged.deb"
printf '%s\n' "$release/OBS-Sideload.ipa" "$release/OBS-Privileged.ipa" "$release/OBS-Privileged.deb"
