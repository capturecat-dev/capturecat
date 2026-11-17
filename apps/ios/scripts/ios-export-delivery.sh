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
#     library through the shipping ExportDelivery, reads each asset's ORIGINAL
#     resource back out of Photos and checks it is the file that went in
#     (type; GIF frames / size / delays; PNG size; movie size / duration /
#     samples), then presents the Files export picker and the share sheet
#     (`--ios-delivery-test`).
#
# Photo access (the read-back needs FULL access; the app asks for add-only):
# granted before launch with `simctl privacy`, then the photos row in the
# Simulator's TCC.db is stamped `auth_version = 2`. `simctl privacy grant
# photos` writes auth_version 1, and on the iOS 26+ Simulator Photos treats
# that grant as add-only and shows "… is requesting additional access to your
# Photo Library" (Limit / Allow Full / Keep Add Only) on the first read — the
# hang this gate used to time out on. A user's "Allow Full Access" tap writes
# auth_version 2 (measured 2026-11-17: reason 2, version 2, flags 16; version
# 2 alone is what clears the prompt). The test FAILS, never prompts, if the
# grant is not in place (PHPhotoLibrary.authorizationStatus is checked first).
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
# Both Photos services: add-only (what ExportDelivery asks for) and full
# (so the test can read the saved assets back) — see the header for why the
# full grant is re-stamped as version 2.
xcrun simctl privacy "$DEVICE" reset photos so.capturecat.ios.studiolab 2>/dev/null || true
xcrun simctl privacy "$DEVICE" grant photos-add so.capturecat.ios.studiolab
xcrun simctl privacy "$DEVICE" grant photos so.capturecat.ios.studiolab
TCC="$(xcrun simctl getenv "$DEVICE" HOME)/Library/TCC/TCC.db"
sqlite3 "$TCC" "update access set auth_version = 2 where service = 'kTCCServicePhotos' and client = 'so.capturecat.ios.studiolab';"
sqlite3 "$TCC" "select 'photos grant: auth_value ' || auth_value || ', auth_version ' || auth_version from access
                where service = 'kTCCServicePhotos' and client = 'so.capturecat.ios.studiolab';" | sed 's/^/  /'
# Watchdog: a test stuck on system UI fails after 180 s instead of hanging.
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-delivery-test "$OUT/ios" --movie "$FIX/01-baseline-gradient/export.mp4" > "$OUT/delivery.log" 2>&1 &
launch=$!
( sleep 180; kill "$launch" 2>/dev/null && xcrun simctl terminate "$DEVICE" so.capturecat.ios.studiolab 2>/dev/null \
    && echo "DELIVERY FAIL timed out after 180 s (system UI waiting?)" >> "$OUT/delivery.log" ) > /dev/null 2>&1 &
watchdog=$!
wait "$launch" || true
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
grep -E '^DELIVERY' "$OUT/delivery.log" | sed 's/^/  iOS  /'
ok=1
grep -q '^EXPORT-FORMATS WROTE reference' "$OUT/mac.log" || { echo "IOS-EXPORT-DELIVERY FAIL (Mac reference)"; ok=0; }
grep -q '^EXPORT-FORMATS-PARITY PASS' "$OUT/formats.log" || ok=0
grep -q '^DELIVERY-TEST PASS' "$OUT/delivery.log" || ok=0
(( ok )) && echo "IOS-EXPORT-DELIVERY PASS" || { echo "IOS-EXPORT-DELIVERY FAIL"; exit 1; }
