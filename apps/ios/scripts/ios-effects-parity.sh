#!/usr/bin/env bash
set -euo pipefail

# ios-effects-parity.sh — every Mac effect setting on iOS, 1:1 (2026-11-18).
#
#   apps/ios/scripts/ios-effects-parity.sh [outDir]
#
# 1. Builds an UNSANDBOXED scratch Mac Debug (ENABLE_APP_SANDBOX=NO, its own
#    derived data — never the owner's running app) and runs
#    `CaptureCat --effects-parity`: the REAL Mac Effects pane
#    (MotionSettingsPaneAppKit + EffectsSettingsPaneAppKit) and Motion pane
#    (MotionFeelPaneAppKit) in the editor's inspector column, listed LIVE for
#    every fixture state (StudioHarness/EffectsParity.states: nothing selected
#    with each effect off / on, a zoom, tilt, zoomtilt, highlight, depth focus
#    (Area, Tilt Shift) and blur (Blur, Pixelate) selected, the Motion tab) →
#    mac-inventory.txt; then every effect control driven to non-default values
#    → mac-values.txt. No ScreenCaptureKit.
# 2. Builds StudioLab and, on each simulator in DEVICES, runs `--effects-parity`:
#    the same states through the REAL editor — a phone through the drill-down
#    tool bar (pane key / a selection's Adjust, then EVERY sub-option's panel),
#    an iPad through the column — listed from the live UIKit controls; and the
#    same values script reached the same way, one undo step per edit. Both
#    lists must equal the Mac's line for line (iOS-only rows are named in
#    EffectsParity.iosOnly and printed).
# 3. On the first device, `--inject drop-control` (Curtain ▸ Tint Logo hidden)
#    must turn the inventory red and `--inject values-defect` (Parallax ▸
#    Strength writes a step too far) must turn the values red.
#
# Env: DEVICES="<udid> <udid>" (default: Studio 4d iPhone + Studio 4d iPad),
#      MAC_APP=<path to an unsandboxed CaptureCat.app> to skip the Mac build,
#      SHOTS=1 to save every panel as a PNG (<out>/<device>/lab/shots).

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="${DEVICES:-C393D60C-29EF-4F8D-94DE-C85FFAD28401 0ABB931E-467B-45DB-B4E9-D629A21F9BF4}"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-effects-parity}"
mkdir -p "$OUT"

if [[ -z "${MAC_APP:-}" ]]; then
  echo "ios-effects-parity: building an unsandboxed Mac Debug into $OUT/dd-mac"
  args=(-project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug
        -derivedDataPath "$OUT/dd-mac" CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO)
  (cd "$IOS/../macos" && xcodebuild "${args[@]}" build > "$OUT/mac-build.log" 2>&1) \
    || { grep -E '^/.*error:' "$OUT/mac-build.log" | head -20; echo "IOS-EFFECTS-PARITY FAIL (Mac build)"; exit 1; }
  MAC_APP="$OUT/dd-mac/Build/Products/Debug/CaptureCat.app"
fi
if codesign -d --entitlements - --xml "$MAC_APP" 2>/dev/null | plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null | grep -q true; then
  echo "ios-effects-parity: $MAC_APP is sandboxed — unset MAC_APP to build an unsandboxed copy" >&2
  exit 2
fi

echo "ios-effects-parity: the Mac panes (scratch build, its own process)"
MAC_DIR="$OUT/mac"
rm -rf "$MAC_DIR" && mkdir -p "$MAC_DIR"
"$MAC_APP/Contents/MacOS/CaptureCat" --effects-parity "$MAC_DIR" > "$MAC_DIR/run.log" 2>&1 &
mac_pid=$!
for _ in $(seq 1 240); do kill -0 "$mac_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$mac_pid" 2>/dev/null; then kill "$mac_pid"; echo "IOS-EFFECTS-PARITY FAIL (the Mac harness hung)"; exit 1; fi
grep -E '^EFFECTS-PARITY' "$MAC_DIR/run.log" || true
grep -q 'EFFECTS-PARITY MAC DONE' "$MAC_DIR/run.log" || { echo "IOS-EFFECTS-PARITY FAIL (Mac harness)"; exit 1; }
if grep -q 'unknown control' "$MAC_DIR/run.log"; then echo "IOS-EFFECTS-PARITY FAIL (the Mac walker met a control it does not know)"; exit 1; fi

echo "ios-effects-parity: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EFFECTS-PARITY FAIL (build)"; exit 1; }
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"

status=0
run() {  # run <device> <runDir> [extra args…]
  local device="$1" dir="$2"; shift 2
  rm -rf "$dir" && mkdir -p "$dir"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b > /dev/null
  xcrun simctl install "$device" "$APP"
  local extra=()
  [[ -n "${SHOTS:-}" ]] && extra+=(--shots)
  xcrun simctl launch --console-pty --terminate-running-process "$device" so.capturecat.ios.studiolab \
    --effects-parity "$dir/lab" --mac "$MAC_DIR" ${extra[@]+"${extra[@]}"} "$@" > "$dir/run.log" 2>&1 || true
  grep -E '^EFFECTS-PARITY (layout|[a-z-]+ (PASS|FAIL)|note|diff)|^EFFECTS-PARITY-GATE' "$dir/run.log" | head -80 || true
}

first=""
for device in $DEVICES; do
  [[ -z "$first" ]] && first="$device"
  name="$(xcrun simctl list devices | grep "$device" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/' | head -1)"
  echo "ios-effects-parity: $name ($device)"
  run "$device" "$OUT/$device"
  if grep -q '^EFFECTS-PARITY-GATE PASS' "$OUT/$device/run.log"; then echo "  → PASS"; else echo "  → FAIL"; status=1; fi
done

echo "ios-effects-parity: injected drop-control on $first (the inventory must catch it)"
run "$first" "$OUT/inject-drop" --inject drop-control
if grep -q '^EFFECTS-PARITY inventory FAIL' "$OUT/inject-drop/run.log" \
   && grep -q 'effects.curtainLogoTint' "$OUT/inject-drop/run.log"; then
  echo "  → the dropped control was caught"
else
  echo "  → the dropped control was NOT caught"; status=1
fi

echo "ios-effects-parity: injected values-defect on $first (the values must catch it)"
run "$first" "$OUT/inject-values" --inject values-defect
if grep -q '^EFFECTS-PARITY values FAIL' "$OUT/inject-values/run.log" \
   && grep -q 'parallaxStrength' "$OUT/inject-values/run.log"; then
  echo "  → the wrong value was caught"
else
  echo "  → the wrong value was NOT caught"; status=1
fi

echo "ios-effects-parity: lists $MAC_DIR/mac-{inventory,values}.txt vs $OUT/<device>/lab/ios-{inventory,values}.txt"
if [[ $status == 0 ]]; then echo "IOS-EFFECTS-PARITY PASS"; else echo "IOS-EFFECTS-PARITY FAIL"; fi
exit $status
