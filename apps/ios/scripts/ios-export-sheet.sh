#!/usr/bin/env bash
# ios-export-sheet.sh — exporting from the iOS editor (Studio 3d).
#
#   apps/ios/scripts/ios-export-sheet.sh
#
# StudioLab `--export-sheet` opens synthetic projects in the shipping
# EditorViewController (presented full screen in StudioLab's real window) and
# drives the REAL export sheet by touches — the header's Export key, the
# Format / Resolution / Frame Rate segments, Fast export, Export, Cancel
# Export, Save to Photos, Save to Files, Share, Done — each hit-tested in the
# window where a finger would land. It checks (ExportSheetLab.swift):
#
#   • MP4 (720p30), GIF and a PNG still: every pre-encode frame of the
#     sheet's export byte-identical to VideoExporter / StillImageExporter run
#     directly with the same settings (the exporter's lossless tap,
#     CAPTURECAT_EXPORT_FRAME_TAP); the file's size / samples / duration (GIF:
#     frames, delays) as the settings and the reference file;
#   • progress caught MID-FLIGHT (the bar's drawn fill vs every value shown);
#   • Cancel mid-export leaves no partial file; the sheet returns to its form;
#   • the background path (continued processing, else the beginBackgroundTask
#     fallback with the "keep the app open" note) entered and ended;
#   • ExportError.insufficientMemory as a house CCAlert with its message;
#   • the sheet's entrance mid-flight, docked on iPhone / centred on iPad, the
#     iPhone's 1080p30 default; delivery controllers presented.
#
# Env: DEVICE=<udid>   default: the first booted simulator. Use one no other
#                      session drives (StudioLab installs replace each other).
#      OUT=<dir>       default: $TMPDIR/capturecat-ios-export-sheet
#      INJECT=wrong-resolution|snap-progress|cancel-leaves-file|no-background
#                      the gate must FAIL
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-export-sheet}"
mkdir -p "$OUT"
DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-export-sheet: boot a simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "ios-export-sheet: building StudioLab"
  xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
    || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EXPORT-SHEET FAIL (build)"; exit 1; }
fi
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
# Save to Photos is add-only (what the app asks for); granted up front so no
# system prompt waits for a tap.
xcrun simctl privacy "$DEVICE" grant photos-add so.capturecat.ios.studiolab
RUN="$OUT/run${INJECT:+-$INJECT}"
rm -rf "$RUN" && mkdir -p "$RUN"
args=(--export-sheet "$RUN/work")
[[ -n "${INJECT:-}" ]] && args+=(--inject "$INJECT")
echo "ios-export-sheet: running on $DEVICE ${INJECT:+(inject $INJECT)}"
# Watchdog: a run stuck on system UI fails after 400 s instead of hanging.
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  "${args[@]}" > "$RUN/run.log" 2>&1 &
launch=$!
( sleep 400; kill "$launch" 2>/dev/null && xcrun simctl terminate "$DEVICE" so.capturecat.ios.studiolab 2>/dev/null \
    && echo "EXPORT-SHEET FAIL timed out after 400 s" >> "$RUN/run.log" ) > /dev/null 2>&1 &
watchdog=$!
wait "$launch" || true
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true

grep -oE '(EXPORT-SHEET|   background:).*' "$RUN/run.log" || true
grep -q '^EXPORT-SHEET-GATE PASS' "$RUN/run.log" && { echo "IOS-EXPORT-SHEET PASS"; exit 0; }
echo "IOS-EXPORT-SHEET FAIL"
exit 1
