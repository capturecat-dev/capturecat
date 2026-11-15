#!/usr/bin/env bash
# ios-preview-parity: the Mac's preview-parity matrix, run on iOS (Studio 2b).
#
# The SAME script the Mac gate runs (apps/macos/CaptureCat/StudioHarness/
# PreviewParityHarness*.swift) — every state, fixture mutation, motion
# sequence with its mid-flight spring assertion, structural camera-look probe
# and injected-defect self-test — executed in StudioLab against the shipping
# iOS PreviewStageView in a real UIWindow, and scored against the Mac's
# frozen PreviewGoldens with the Mac's own bar. Inputs are the Mac's: the
# fixture is dumped by the Mac binary (`--preview-parity-fixtures`).
#
#   apps/ios/scripts/ios-preview-parity.sh
#
# Env: APP=/path/CaptureCat.app  (unsandboxed Mac build; default: the scheme's
#                                  Debug build)
#      DEVICE=<udid>             (default: the first booted iPad — the 720×405
#                                  pane must fit at magnification 1)
#      OUT=<dir>                 (default: $TMPDIR/capturecat-ios-preview-parity)
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-preview-parity}"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-preview-parity: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
FIX="$OUT/fixture"
rm -rf "$FIX"
"$APP/Contents/MacOS/CaptureCat" --preview-parity-fixtures "$FIX" | tail -1

echo "ios-preview-parity: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-PREVIEW-PARITY FAIL (build)"; exit 1; }

xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
echo "ios-preview-parity: running on $DEVICE"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-preview-parity "$FIX" > "$OUT/run.log" 2>&1 || true

grep -E '^(STATE|SEQ|BLOBS|CAMERA-LOOK|CAMERA-STYLE|SCRUB-MOTION|TILT-MOTION|CURSOR-SPRING|WINDOW-GEOMETRY|MOTIONBLUR)' "$OUT/run.log" \
  | grep -E 'FAIL|NOT MID-FLIGHT' || true
grep -E '^(WORST|PARITY)' "$OUT/run.log" || { tail -20 "$OUT/run.log"; echo "IOS-PREVIEW-PARITY FAIL (no result)"; exit 1; }
echo "ios-preview-parity: full log $OUT/run.log · captures $FIX/*-ca.png"
grep -q '^PARITY PASS' "$OUT/run.log"
