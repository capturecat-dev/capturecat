#!/usr/bin/env bash
# ios-export-parity: the Mac's render-parity fixtures re-exported on iOS (Studio 3a).
#
# The Mac binary writes its 23 render-parity fixtures (`--web-parity-fixtures`:
# project.json + media + the Mac exporter's LOSSLESS pre-encode frame taps and
# camera path). StudioLab decodes each project.json and exports it with the
# iOS VideoExporter — the same shared code, frame tap and camera dump —
# through StudioHarness/ExportParityHarness, the SAME scoring the Mac runs as
# its control (`CaptureCat --export-parity`). The Simulator reads host paths.
#
# Four runs:
#   1. Mac control      the Mac re-exports its fixtures: must be byte-identical.
#   2. Mac YUV ref      the Mac exports again with sources decoded to raw 4:2:0
#                       and converted by Core Image (`--source-yuv`).
#   3. iOS GATE         iOS exports with `--source-yuv` vs run 2. The decoder's
#                       4:2:0 planes are bit-identical on both platforms but
#                       VideoToolbox's YUV→BGRA conversion is not (measured:
#                       ±1 flat, up to 91/255 on chroma edges), so this run
#                       compares everything CaptureCat renders on equal pixels.
#   4. iOS production   iOS exports on the normal (VideoToolbox) path vs the
#                       fixture taps — REPORTED, not gated: the Simulator's
#                       converter is not a device's.
#
#   apps/ios/scripts/ios-export-parity.sh
#
# Env: APP=/path/CaptureCat.app  (unsandboxed Mac build; default: the scheme's Debug build)
#      DEVICE=<udid>             (default: the first booted simulator)
#      OUT=<dir>                 (default: $TMPDIR/capturecat-ios-export-parity)
#      FIXTURES=<dir>            (reuse fixtures already written by that APP)
#      ONLY=a,b  INJECT=padding  (passed to every run)
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-export-parity}"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-export-parity: boot a simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
FIX="${FIXTURES:-$OUT/fixtures}"
if [[ -z "${FIXTURES:-}" ]]; then
  rm -rf "$FIX"
  "$APP/Contents/MacOS/CaptureCat" --web-parity-fixtures "$FIX" | tail -1
fi

echo "ios-export-parity: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EXPORT-PARITY FAIL (build)"; exit 1; }

xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
echo "ios-export-parity: running on $DEVICE"
COMMON=()
[[ -n "${ONLY:-}" ]] && COMMON+=(--only "$ONLY")
[[ -n "${INJECT:-}" ]] && COMMON+=(--inject "$INJECT")
MAC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
summary() { grep -E '^(WORST|EXPORT-PARITY (PASS|FAIL))' "$1" | sed "s/^/  $2  /"; }

"$MAC" --export-parity "$FIX" --out "$OUT/mac" ${COMMON[@]+"${COMMON[@]}"} > "$OUT/mac-control.log" 2>&1 || true
summary "$OUT/mac-control.log" "1 Mac control     "
"$MAC" --export-parity "$FIX" --out "$OUT/mac-yuv" --source-yuv ${COMMON[@]+"${COMMON[@]}"} > "$OUT/mac-yuv.log" 2>&1 || true
echo "  2 Mac YUV ref       written to $OUT/mac-yuv (vs the VideoToolbox taps: $(grep -E '^WORST' "$OUT/mac-yuv.log" | cut -d' ' -f2-))"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-export-parity "$FIX" --out "$OUT/ios-yuv" --source-yuv --reference "$OUT/mac-yuv" ${COMMON[@]+"${COMMON[@]}"} \
  > "$OUT/ios-gate.log" 2>&1 || true
grep -E '^(EXPORT|CAMPATH) ' "$OUT/ios-gate.log" | grep -E 'FAIL|ERROR' | sed 's/^/    /' || true
summary "$OUT/ios-gate.log" "3 iOS GATE        "
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-export-parity "$FIX" --out "$OUT/ios" ${COMMON[@]+"${COMMON[@]}"} > "$OUT/ios-production.log" 2>&1 || true
summary "$OUT/ios-production.log" "4 iOS production  (reported)"
echo "ios-export-parity: logs $OUT/{mac-control,mac-yuv,ios-gate,ios-production}.log · taps $OUT/<run>/<fixture>/tap/"

grep -q '^EXPORT-PARITY PASS' "$OUT/mac-control.log" || { echo "IOS-EXPORT-PARITY FAIL (Mac control)"; exit 1; }
grep -q '^EXPORT-PARITY PASS' "$OUT/ios-gate.log" || { echo "IOS-EXPORT-PARITY FAIL"; exit 1; }
echo "IOS-EXPORT-PARITY PASS"
