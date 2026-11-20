#!/usr/bin/env bash
# ios-agent-edit.sh — Connect AI + background AI edits end to end in the REAL
# app, against the LOCAL TEST API (apps/api/scripts/local-test-api: the real
# Worker — /mcp, the editor's op layer, the version rules — over in-memory
# D1/R2 with captured APNs; never production, never `wrangler dev`).
#
#   apps/ios/scripts/ios-agent-edit.sh                       the gate (must PASS)
#   INJECT=skip-notice apps/ios/scripts/ios-agent-edit.sh    must FAIL (no "Edited by" notice)
#   INJECT=undo-noop   apps/ios/scripts/ios-agent-edit.sh    must FAIL (Undo changes nothing)
#
# The app is launched with `-apiBaseURL http://127.0.0.1:<port> -agentEditGate`
# (App/Fixtures/AgentEditGate.swift): Account → Connect AI (hit-tested row,
# connected list, copy, animated guide swap, revoke, the Free plan's upgrade
# callout), then a cloud project open in the editor while "Claude" — an
# OAuth-connected client — calls apply_edits over HTTP: the captured "AI
# finished editing" push routed through the app's own handler, the edit landing
# without losing unsent local work, the notice rising mid-flight, Undo reverting
# only the agent's change; then a clean agent edit noticed on foreground, Undo
# restoring the previous version as a new server revision (nothing deleted).
#
# Env: DEVICE=<udid>   default: a private "CaptureCat AI iPhone" (created if missing)
#      OUT=<dir>       default: $TMPDIR/capturecat-ios-agent-edit
#      INJECT=skip-notice|undo-noop
#      SKIP_BUILD=1    reuse $OUT/dd's build
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
API="$IOS/../api"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-agent-edit}"
BUNDLE=so.capturecat.ios
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ -z "${DEVICE:-}" ]]; then
  DEVICE="$(xcrun simctl list devices available | grep -E '^ +CaptureCat AI iPhone \(' | head -1 | grep -oE '[0-9A-F-]{36}' || true)"
  if [[ -z "$DEVICE" ]]; then
    DEVICE="$(xcrun simctl create "CaptureCat AI iPhone" "iPhone 17 Pro")"
  fi
fi

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-agent-edit: building CaptureCat (Debug, simulator)"
  xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$OUT/dd" \
    ${CLONED_PACKAGES:+-clonedSourcePackagesDirPath "$CLONED_PACKAGES"} \
    build > "$OUT/build.log" 2>&1 \
    || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-AGENT-EDIT FAIL (build)"; exit 1; }
fi
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/CaptureCat.app"

# A real 4-second H.264 recording (the editor decodes it).
mkdir -p "$OUT/media"
if [[ ! -s "$OUT/media/recording.mov" ]]; then
  command -v ffmpeg >/dev/null || { echo "ios-agent-edit: needs ffmpeg (brew install ffmpeg)" >&2; exit 2; }
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 4 -c:v libx264 -pix_fmt yuv420p \
    -movflags +faststart "$OUT/media/recording.mov"
  ffmpeg -loglevel error -y -i "$OUT/media/recording.mov" -frames:v 1 -vf scale=480:-1 "$OUT/media/thumbnail.jpg"
fi

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(cd "$API" && exec npx vite-node --config scripts/local-test-api/vite.config.ts scripts/local-test-api/server.ts \
  -- --port "$PORT" --media "$OUT/media") > "$OUT/api.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; pkill -f "local-test-api/server.ts -- --port $PORT" 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do curl -s "http://127.0.0.1:$PORT/__health" >/dev/null && break; sleep 0.25; done
curl -s "http://127.0.0.1:$PORT/__health" >/dev/null || { tail -20 "$OUT/api.log"; echo "IOS-AGENT-EDIT FAIL (local test API didn't start)"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

RUN="$OUT/run${INJECT:+-$INJECT}"
rm -rf "$RUN" && mkdir -p "$RUN"
echo "ios-agent-edit: running on $DEVICE against http://127.0.0.1:$PORT${INJECT:+ (inject $INJECT — must FAIL)}"
args=(-apiBaseURL "http://127.0.0.1:$PORT" -agentEditGate)
[[ -n "${INJECT:-}" ]] && args+=(-agentEditInject "$INJECT")
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE" "${args[@]}" > "$RUN/run.log" 2>&1 &
pid=$!
for _ in $(seq 1 240); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
  echo "ios-agent-edit: timed out" >&2
fi
wait "$pid" || true

container="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null || true)"
[[ -n "$container" && -d "$container/Documents/agent-edit" ]] && cp "$container/Documents/agent-edit/"*.png "$RUN/" 2>/dev/null || true

grep -E '^AGENTEDIT' "$RUN/run.log" || tail -30 "$RUN/run.log"
echo "ios-agent-edit: log $RUN/run.log · screens $RUN/*.png · API $OUT/api.log"
if grep -q '^AGENTEDIT-GATE PASS' "$RUN/run.log"; then
  if [[ -n "${INJECT:-}" ]]; then echo "IOS-AGENT-EDIT PASS (inject $INJECT — the defect went unnoticed)"; exit 0; fi
  echo "IOS-AGENT-EDIT PASS"; exit 0
fi
echo "IOS-AGENT-EDIT FAIL${INJECT:+ (inject $INJECT)}"
exit 1
