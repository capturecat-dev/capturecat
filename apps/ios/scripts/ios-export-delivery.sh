#!/usr/bin/env bash
# ios-export-delivery: GIF and PNG exports on iOS vs the Mac, then delivery
# into Photos / Files / the share sheet (Studio 3d).
#
#  1. The Mac writes one render-parity fixture and exports it as an animated
#     GIF and a PNG still (`--export-formats-parity`, sources on raw 4:2:0 so
#     both platforms start from identical pixels) — the reference.
#  2. StudioLab does the same with the iOS exporter (`--ios-export-formats`):
#     the same frame count, size and per-frame delays; frames and still
#     within mean 1/255, ≤ 1% px > 8.
#  3. StudioLab saves the iOS GIF, PNG and a movie into the Simulator's photo
#     library through the shipping ExportDelivery and reads each asset back,
#     then presents the Files export picker and the share sheet
#     (`--ios-delivery-test`). Photo access is granted with `simctl privacy`.
#
#   apps/ios/scripts/ios-export-delivery.sh
#
# Env: APP=/path/CaptureCat.app  DEVICE=<udid>  OUT=<dir>
set -euo pipefail
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-export-delivery}"
mkdir -p "$OUT"
DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-export-delivery: boot a simulator first (or set DEVICE)" >&2; exit 2; }
if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
MAC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
FIX="$OUT/fixtures"
rm -rf "$FIX" "$OUT/mac" "$OUT/ios"
"$MAC" --web-parity-fixtures "$FIX" --only 01-baseline-gradient | tail -1
"$MAC" --export-formats-parity "$FIX" --out "$OUT/mac" > "$OUT/mac.log" 2>&1 || true
grep -E '^EXPORT-FORMATS' "$OUT/mac.log" | sed 's/^/  Mac  /'
echo "ios-export-delivery: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EXPORT-DELIVERY FAIL (build)"; exit 1; }
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-export-formats "$FIX" --out "$OUT/ios" --reference "$OUT/mac" > "$OUT/formats.log" 2>&1 || true
grep -E '^EXPORT-FORMATS' "$OUT/formats.log" | sed 's/^/  iOS  /'
# Both Photos services: add-only (what ExportDelivery asks for) and read
# (so the test can fetch the saved assets back) — an ungranted service leaves
# a system prompt waiting for a tap.
xcrun simctl privacy "$DEVICE" grant photos-add so.capturecat.ios.studiolab
xcrun simctl privacy "$DEVICE" grant photos so.capturecat.ios.studiolab
# Watchdog: a test stuck on system UI fails after 180 s instead of hanging.
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-delivery-test "$OUT/ios" --movie "$FIX/01-baseline-gradient/export.mp4" > "$OUT/delivery.log" 2>&1 &
launch=$!
( sleep 180; kill "$launch" 2>/dev/null && xcrun simctl terminate "$DEVICE" so.capturecat.ios.studiolab 2>/dev/null \
    && echo "DELIVERY FAIL timed out after 180 s (system UI waiting?)" >> "$OUT/delivery.log" ) &
watchdog=$!
wait "$launch" || true
kill "$watchdog" 2>/dev/null || true
grep -E '^DELIVERY' "$OUT/delivery.log" | sed 's/^/  iOS  /'
ok=1
grep -q '^EXPORT-FORMATS WROTE reference' "$OUT/mac.log" || { echo "IOS-EXPORT-DELIVERY FAIL (Mac reference)"; ok=0; }
grep -q '^EXPORT-FORMATS-PARITY PASS' "$OUT/formats.log" || ok=0
grep -q '^DELIVERY-TEST PASS' "$OUT/delivery.log" || ok=0
(( ok )) && echo "IOS-EXPORT-DELIVERY PASS" || { echo "IOS-EXPORT-DELIVERY FAIL"; exit 1; }
