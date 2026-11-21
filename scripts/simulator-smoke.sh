#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$PWD/.workspace-tools/bin:$PATH"
mkdir -p .build/ios
run=$(mktemp -d "$PWD/.build/ios/smoke.XXXXXXXX")
listener=
cleanup() {
  if [[ -n $listener ]]; then kill "$listener" 2>/dev/null || true; fi
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  osascript -e 'quit app "Simulator"' 2>/dev/null || killall Simulator 2>/dev/null || true
}
trap cleanup EXIT

sim=${1:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next((device["udid"] for runtime, group in devices.items() if "iOS" in runtime
            for device in group if device["name"].startswith("iPhone")), ""))
')}
if [[ -z $sim ]]; then echo "没有可用的 iPhone 模拟器" >&2; exit 1; fi
printf '%s\n' "$run"
xcrun simctl bootstatus "$sim" -b > "$run/boot.log" 2>&1
app="$PWD/.build/ios/iphonesimulator/ios-app/Release-iphonesimulator/OBS.app"
bundle=org.obsproject.studio.ios
xcrun simctl install "$sim" "$app"

url=rtmp://127.0.0.1:19351/obs
ffmpeg -hide_banner -nostdin -loglevel warning -listen 1 -i "$url/phase1" -c copy "$run/rtmp.flv" \
  > "$run/rtmp.log" 2>&1 &
listener=$!
name=${run##*/}
SIMCTL_CHILD_OBS_TEST_RTMP="$url" SIMCTL_CHILD_OBS_SMOKE_RUN="$name" \
  xcrun simctl launch --terminate-running-process --stdout="$run/stdout.log" --stderr="$run/stderr.log" \
    "$sim" "$bundle" --recording-smoke

data=$(xcrun simctl get_app_container "$sim" "$bundle" data)
for attempt in {1..20}; do
  if [[ -s "$data/Documents/phase1-$name.mp4" && -s "$run/rtmp.flv" ]] && ! kill -0 "$listener" 2>/dev/null; then
    break
  fi
  sleep 1
done

cp "$data/Documents/phase1-$name.mp4" "$run/phase1.mp4"
for file in "$run/phase1.mp4" "$run/rtmp.flv"; do
  ffprobe -v error -show_entries stream=codec_name,codec_type -of default=nw=1 "$file"
done
