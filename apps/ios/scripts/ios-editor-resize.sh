#!/usr/bin/env bash
set -euo pipefail

# ios-editor-resize.sh — the editor folding and unfolding (iPhone Duo).
#
#   apps/ios/scripts/ios-editor-resize.sh [outDir] [--inject ignores-size-class|ignores-crease]
#
# Builds StudioLab and runs `--editor-resize`: the real editor hosted at the
# Duo's outer-display size and size classes, given state (playhead,
# selection, an edit, playback running), resized live to the inner display
# and back. Checks the layout each size class calls for, that every region
# stays inside and clear of the others, History's matching style, and that
# the project, selection, undo stack and playback all survive.
# `--inject ignores-size-class` / `ignores-crease` / `snap-panel` / `panel-tab-row` /
# `panel-over-toolbar` / `panel-uncapped` / `drag-grabber-only` must make it FAIL.
#
# Env: DEVICE=<simulator udid> (an iPad: the inner display needs the width).

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-editor-resize: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-editor-resize}"
shift || true
INJECT=()
if [[ "${1:-}" == "--inject" && -n "${2:-}" ]]; then INJECT=(--inject "$2"); fi
mkdir -p "$OUT"
echo "ios-editor-resize: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EDITOR-RESIZE FAIL (build)"; exit 1; }
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --editor-resize "$OUT/run" ${INJECT[@]+"${INJECT[@]}"} > "$OUT/run.log" 2>&1 || true
grep -E '^EDITOR-RESIZE' "$OUT/run.log" || true
grep -q '^EDITOR-RESIZE-GATE PASS' "$OUT/run.log" && echo "IOS-EDITOR-RESIZE PASS" || { echo "IOS-EDITOR-RESIZE FAIL"; exit 1; }
