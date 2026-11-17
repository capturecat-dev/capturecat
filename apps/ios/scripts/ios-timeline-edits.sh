#!/usr/bin/env bash
set -euo pipefail

# ios-timeline-edits.sh — the touch timeline's gate (Studio 4c).
#
#   apps/ios/scripts/ios-timeline-edits.sh [outDir] [--inject accordion-snap|selection-snap|touch-offset|filmstrip-offset|no-filmstrip]
#
# Builds StudioLab, installs it on the iPad simulator and runs
# `--timeline-edits`: the Mac `--timeline-edits-test` script replayed through
# the shipping StudioTimelineViewController in a real window (taps, drags,
# long-press house menus, toolbar keys, hardware-key commands, Undo key),
# scored against the Mac's frozen transcript (StudioHarness/TimelineEditsGoldens)
# with the shared recorder; then the lane open/close SEQUENCE and selection
# glide mid-flight checks, real touch drags against the Mac's values, and the
# VIDEO lane's FILMSTRIP (real frames from a synthetic recording: loaded, on an
# even time grid, each image the second it claims, each tile drawn at its x).
# `--inject` must make it FAIL (proves the motion checks can).
#
# Env: DEVICE=<simulator udid> (default: the iPad Pro 11 the studio uses).

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-A7A32ABF-068F-4AF5-92D1-E874D8B8D8B3}"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-timeline-edits}"
shift || true
INJECT=()
if [[ "${1:-}" == "--inject" && -n "${2:-}" ]]; then INJECT=(--inject "$2"); fi

mkdir -p "$OUT"
echo "ios-timeline-edits: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-TIMELINE-EDITS FAIL (build)"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
RUN="$OUT/run"
rm -rf "$RUN" && mkdir -p "$RUN"
echo "ios-timeline-edits: running on $DEVICE ${INJECT[*]+"${INJECT[*]}"}"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --timeline-edits "$RUN" ${INJECT[@]+"${INJECT[@]}"} > "$RUN/run.log" 2>&1 || true

grep -E '^(DRIVE|TIMELINE-EDITS (PASS|FAIL)|LANE-MOTION|SELECTION-GLIDE|TOUCH-DRAG|FILMSTRIP|PROBLEM|FAIL)' "$RUN/run.log" | head -80 || true
echo "ios-timeline-edits: transcript $RUN/ios-transcript.txt · drive log $RUN/drive.txt · frames $RUN/*.png"
grep -q '^TIMELINE-GATE PASS' "$RUN/run.log" && { echo "IOS-TIMELINE-EDITS PASS"; exit 0; }
echo "IOS-TIMELINE-EDITS FAIL"
exit 1
