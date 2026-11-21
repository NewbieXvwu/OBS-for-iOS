#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$PWD/.workspace-tools/bin:$PATH"
mkdir -p .build/ios
run=$(mktemp -d "$PWD/.build/ios/smoke.XXXXXXXX")
listener=
websocket_config=
cleanup() {
  if [[ -n $listener ]]; then kill "$listener" 2>/dev/null || true; fi
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  osascript -e 'quit app "Simulator"' 2>/dev/null || killall Simulator 2>/dev/null || true
  if [[ -n $websocket_config ]]; then
    if [[ -f $websocket_config ]]; then mv "$websocket_config" "$run/websocket-test.json"; fi
    if [[ -f $run/websocket-original.json ]]; then mv "$run/websocket-original.json" "$websocket_config"; fi
  fi
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
data=$(xcrun simctl get_app_container "$sim" "$bundle" data)
if [[ ${OBS_TEST_WEBSOCKET:-0} == 1 ]]; then
  directory="$data/Library/Application Support/OBS/obs-websocket"
  mkdir -p "$directory"
  websocket_config="$directory/config.json"
  if [[ -f $websocket_config ]]; then mv "$websocket_config" "$run/websocket-original.json"; fi
  printf '%s\n' '{"first_load":false,"server_enabled":true,"server_port":19455,"auth_required":true,"server_password":"obs-ios-simulator"}' > "$websocket_config"
fi

url=rtmp://127.0.0.1:19351/obs
ffmpeg -hide_banner -nostdin -loglevel warning -listen 1 -i "$url/phase1" -c copy "$run/rtmp.flv" \
  > "$run/rtmp.log" 2>&1 &
listener=$!
name=${run##*/}
SIMCTL_CHILD_OBS_TEST_RTMP="$url" SIMCTL_CHILD_OBS_SMOKE_RUN="$name" \
  xcrun simctl launch --terminate-running-process --stdout="$run/stdout.log" --stderr="$run/stderr.log" \
    "$sim" "$bundle" --recording-smoke

if [[ -n $websocket_config ]]; then
  for attempt in {1..25}; do
    if grep -q 'OBS iOS frontend ready' "$run/stdout.log" 2>/dev/null; then break; fi
    sleep 1
  done
  node --input-type=module <<'NODE'
import { createHash } from "node:crypto";

const sha = value => createHash("sha256").update(value).digest("base64");
const socket = new WebSocket("ws://127.0.0.1:19455", "obswebsocket.json");
const requests = new Set(["GetVersion", "GetSceneList"]);
const timeout = setTimeout(() => {
  console.error("WebSocket 服务器响应超时", [...requests]);
  process.exit(1);
}, 10000);
socket.onerror = event => {
  console.error(event.message || "WebSocket 连接失败");
  process.exit(1);
};
socket.onmessage = event => {
  const { op, d } = JSON.parse(event.data);
  if (op === 0) {
    const { salt, challenge } = d.authentication;
    const authentication = sha(sha("obs-ios-simulator" + salt) + challenge);
    socket.send(JSON.stringify({ op: 1, d: { rpcVersion: 1, authentication } }));
  } else if (op === 2) {
    for (const requestType of requests)
      socket.send(JSON.stringify({ op: 6, d: { requestType, requestId: requestType } }));
  } else if (op === 7) {
    if (!d.requestStatus.result) throw new Error(JSON.stringify(d.requestStatus));
    console.log(d.requestType, d.responseData.obsWebSocketVersion ?? d.responseData.scenes.map(scene => scene.sceneName));
    requests.delete(d.requestType);
    if (!requests.size) {
      clearTimeout(timeout);
      socket.close();
    }
  }
};
NODE
fi
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
