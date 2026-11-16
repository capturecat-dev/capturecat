#!/usr/bin/env bash
set -euo pipefail

# ios-inspector.sh — the iOS inspector's gate (Studio 4d).
#
#   apps/ios/scripts/ios-inspector.sh [outDir]
#
# Builds StudioLab and, on each simulator in DEVICES (an iPad — the side
# column — and an iPhone — the bottom sheet), runs `--inspector`: every
# control of the nine panes driven through the real editor and held to the
# Mac's frozen transcript (StudioHarness/InspectorValuesGoldens, recorded by
# the Mac `--inspector-values-test`), one undo step per edit, structure
# (touch targets, VoiceOver, Dynamic Type, live re-theme, layout) and motion
# SEQUENCES asserted mid-flight. Then, on the first device, `--inject snap`
# snaps the pane switch and the growth: the motion checks must catch it.
#
# Env: DEVICES="<udid> <udid>" (default: the Studio 4d iPad + iPhone).

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="${DEVICES:-0ABB931E-467B-45DB-B4E9-D629A21F9BF4 C393D60C-29EF-4F8D-94DE-C85FFAD28401}"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-inspector}"
mkdir -p "$OUT"

echo "ios-inspector: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-INSPECTOR FAIL (build)"; exit 1; }
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"

status=0
run() {  # run <device> <runDir> [extra args…]
  local device="$1" dir="$2"; shift 2
  rm -rf "$dir" && mkdir -p "$dir"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b > /dev/null
  xcrun simctl install "$device" "$APP"
  xcrun simctl launch --console-pty --terminate-running-process "$device" so.capturecat.ios.studiolab \
    --inspector "$dir/lab" "$@" > "$dir/run.log" 2>&1 || true
  grep -E '^INSPECTOR (layout|[a-z-]+ (PASS|FAIL)|diff|note)|^INSPECTOR-GATE' "$dir/run.log" | head -120 || true
}

first=""
for device in $DEVICES; do
  [[ -z "$first" ]] && first="$device"
  name="$(xcrun simctl list devices | grep "$device" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/' | head -1)"
  echo "ios-inspector: $name ($device)"
  run "$device" "$OUT/$device"
  if grep -q '^INSPECTOR-GATE PASS' "$OUT/$device/run.log"; then echo "  → PASS"; else echo "  → FAIL"; status=1; fi
done

echo "ios-inspector: injected snap on $first (the motion checks must catch it)"
run "$first" "$OUT/inject" --inject snap
if grep -q '^INSPECTOR-GATE PASS' "$OUT/inject/run.log" && grep -q 'catches-snap PASS' "$OUT/inject/run.log"; then
  echo "  → the snap was caught"
else
  echo "  → the snap was NOT caught"; status=1
fi

echo "ios-inspector: transcripts $OUT/<device>/lab/ios-transcript.txt · captures $OUT/<device>/lab/{dark,light,xl,motion}"
if [[ $status == 0 ]]; then echo "IOS-INSPECTOR PASS"; else echo "IOS-INSPECTOR FAIL"; fi
exit $status
