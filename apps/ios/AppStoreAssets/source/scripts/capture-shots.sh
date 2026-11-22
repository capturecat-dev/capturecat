#!/usr/bin/env bash
# capture-shots.sh <udid> <family> [display] [only-key]
#   LOCALE=<store locale> (default en-GB): the app runs in that language
#   (-AppleLanguages / -AppleLocale) with the fixture's own content localized
#   (-uiStoreLocalizedContent); shots land in source/shots/<locale>/<family>/.
# Launches real app screens (Debug fixture driver / StudioLab demo editor) on a
# Store simulator and screenshots each to source/shots/<family>/<key>.png.
# Needs a Debug build of CaptureCat.app + StudioLab.app installed on <udid>.
# Never calls ScreenCaptureKit; only simctl.
set -euo pipefail
UDID="$1"; FAMILY="$2"; DISPLAY_ARG="${3:-}"; ONLY="${4:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$(dirname "$0")/locale-args.sh"
OUT="$HERE/shots/$LOCALE/$FAMILY"; mkdir -p "$OUT"
APP=so.capturecat.ios; LAB=so.capturecat.ios.studiolab
shot() { # shot <key> <bundle> <wait> args...
  local key="$1" bundle="$2" wait="$3"; shift 3
  [[ -n "$ONLY" && "$ONLY" != "$key" ]] && return 0
  xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$LAB" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$bundle" "$@" "${LANG_ARGS[@]}" -uiStoreLocalizedContent > /dev/null
  sleep "$wait"
  if [[ -n "$DISPLAY_ARG" ]]; then
    xcrun simctl io "$UDID" screenshot --display="$DISPLAY_ARG" "$OUT/$key.png" > /dev/null 2>&1
  else
    xcrun simctl io "$UDID" screenshot "$OUT/$key.png" > /dev/null 2>&1
  fi
  echo "shot $LOCALE/$FAMILY/$key"
}
# A clean start per locale: the fixture draws its project names into the
# thumbnails and movies it caches, so drop the caches (app data only), then let
# one launch rebuild them before the first shot.
if [[ -z "$ONLY" ]]; then
  xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
  DATA="$(xcrun simctl get_app_container "$UDID" "$APP" data)"
  rm -rf "$DATA/Library/Caches/"* "$DATA/Library/Application Support/Studio" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$APP" -uiFixtures -uiFixtureNoInbox "${LANG_ARGS[@]}" -uiStoreLocalizedContent > /dev/null
  sleep 16
fi
# Fixture flags: -uiFixtureNoInbox, -uiFixtureInboxUploadingOnly and -uiStore* come from
# App/Fixtures/StoreCreative.swift + FixtureWorld.swift (DEBUG only; see README "App changes").
FX=(-uiFixtures -uiFixtureNoInbox)
# Editor shots: a 4:3 canvas (taller stage), the timeline zoomed in so chip labels clear the
# playhead, and a real panel open under the timeline (on iPad / Duo inner the inspector column).
ED=(-uiStoreAspect 4:3)
shot editor     "$APP" 14 "${FX[@]}" "${ED[@]}" -uiStoreEditor zoom -uiStoreTime 4.5 -uiStoreTimelineZoom 2 -uiStorePanelOption "blocks.section.zoom/blocks.zoomLevel"
shot background "$APP" 14 "${FX[@]}" "${ED[@]}" -uiStoreEditor background -uiStorePane -uiStoreTimelineZoom 1
shot captions   "$APP" 14 "${FX[@]}" "${ED[@]}" -uiStoreEditor captions -uiStorePane -uiStoreTimelineZoom 1
if [[ "$FAMILY" == ipad* ]]; then
  # Regular width: the full sidebar (the shell's own wide layout) and the project detail.
  shot library  "$APP" 11 "${FX[@]}" -uiSidebarFull -uiFixtureScreen project
  shot stream   "$APP" 11 -uiFixtures -uiFixtureInboxUploadingOnly -uiSidebarFull -uiFixtureScreen capture -uiFixturePresence connected
  shot share    "$APP" 9 "${FX[@]}" -uiSidebarFull -uiFixtureScreen share
elif [[ "$FAMILY" == duo-inner ]]; then
  # Duo open, portrait (669 pt wide): the rail layout; the project/share split views are too
  # narrow there (truncated keys), so the library stands alone.
  shot library  "$APP" 11 "${FX[@]}"
  shot stream   "$APP" 11 "${FX[@]}" -uiFixtureScreen capture -uiFixturePresence connected
  shot share    "$APP" 9 "${FX[@]}" -uiFixtureScreen share
else
  shot library  "$APP" 11 "${FX[@]}"
  shot stream   "$APP" 11 "${FX[@]}" -uiFixtureScreen capture -uiFixturePresence connected
  shot share    "$APP" 9 "${FX[@]}" -uiFixtureScreen share
fi
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$LAB" 2>/dev/null || true
