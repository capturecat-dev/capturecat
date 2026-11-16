#!/usr/bin/env bash
# kit-gallery: the studio's house controls (Studio 4a) — value slider, choice
# chips, toggle (+ row), stepper, color well / picker, dialog / confirmation
# sheet — in every state, in StudioLab's real UIWindow, in BOTH themes (live
# retheme), on compact AND regular width.
#
# StudioLab `--kit-gallery <dir>` (apps/ios/StudioLab/KitGalleryLab.swift)
# writes <dir>/{dark,light}/<page>.png and motion filmstrips <dir>/seq-*.png,
# and asserts structure (material fit, on-screen, 44 pt targets, VoiceOver,
# Dynamic Type, retheme), behaviour (steps, detents + haptics, tap-to-jump,
# hold acceleration, selection, hex/HSB) and MOTION as sequences — the
# animated value MID-FLIGHT in the presentation layer and in the captured
# pixels, growth overshoot with only the pushed edge moving — and proves the
# mid-flight check FAILS once with an injected snap (CCMotion.probeSnap).
#
#   apps/ios/scripts/kit-gallery.sh
#
# Env: DEVICES="<udid> …"  (default: the first booted iPhone + the first booted
#                            iPad — compact and regular width)
#      OUT=<dir>             (default: $TMPDIR/capturecat-kit-gallery)
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-kit-gallery}"
BUNDLE=so.capturecat.ios.studiolab
mkdir -p "$OUT"

if [[ -z "${DEVICES:-}" ]]; then
  booted="$(xcrun simctl list devices booted)"
  phone="$(printf '%s\n' "$booted" | grep -E 'iPhone' | head -1 | grep -oE '[0-9A-F-]{36}' || true)"
  pad="$(printf '%s\n' "$booted" | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)"
  DEVICES="$phone $pad"
fi
[[ -n "${DEVICES// /}" ]] || { echo "kit-gallery: boot an iPhone and/or iPad simulator first (or set DEVICES)" >&2; exit 2; }

echo "kit-gallery: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "KIT-GALLERY FAIL (build)"; exit 1; }
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"

status=0
for dev in $DEVICES; do
  name="$(xcrun simctl list devices | grep "$dev" | head -1 | sed -E 's/^ +//; s/ \([0-9A-F-]{36}\).*//')"
  dir="$OUT/$(printf '%s' "$name" | tr -c 'A-Za-z0-9.\n' '-')"
  rm -rf "$dir"
  mkdir -p "$dir"
  # Other studio sessions share these simulators: never pull StudioLab out
  # from under a run that is still going.
  for _ in $(seq 1 90); do
    xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "$BUNDLE" || break
    sleep 2
  done
  xcrun simctl install "$dev" "$APP"
  echo "kit-gallery: running on $name ($dev)"
  xcrun simctl launch --console-pty --terminate-running-process "$dev" "$BUNDLE" --kit-gallery "$dir" > "$dir/run.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 240); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    xcrun simctl terminate "$dev" "$BUNDLE" || true
    echo "kit-gallery: $name timed out" >&2
  fi
  wait "$pid" || true

  grep -E '^KITGALLERY .* FAIL' "$dir/run.log" || true
  if grep -q '^KITGALLERY SUMMARY PASS' "$dir/run.log"; then
    echo "kit-gallery: $name PASS — $(grep -cE '^KITGALLERY [a-z0-9-]+ PASS' "$dir/run.log") checks · $dir"
  else
    status=1
    grep -q '^KITGALLERY SUMMARY' "$dir/run.log" || { tail -20 "$dir/run.log"; echo "kit-gallery: $name gave no result"; }
    echo "kit-gallery: $name FAIL · $dir/run.log"
  fi
done

if [[ $status == 0 ]]; then echo "KIT-GALLERY PASS"; else echo "KIT-GALLERY FAIL"; fi
exit $status
