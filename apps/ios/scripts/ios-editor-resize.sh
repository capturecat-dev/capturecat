#!/usr/bin/env bash
set -euo pipefail

# ios-editor-resize.sh — the editor folding and unfolding (iPhone Duo).
#
#   apps/ios/scripts/ios-editor-resize.sh [outDir] [--inject ignores-size-class|ignores-crease|ignores-side-strip]
#
# Builds StudioLab and runs `--editor-resize`: the real editor hosted at the
# Duo's outer-display size and size classes, given state (playhead,
# selection, an edit, playback running), resized live to the inner display
# and back. Checks the layout each size class calls for, that every region
# stays inside and clear of the others, History's matching style, and that
# the project, selection, undo stack and playback all survive. The phone
# layouts are checked FLAT (stage edge to edge at its canvas aspect, no
# rounded card) and the drill-down tool bar end to end: a pane tool swaps
# the bar to its sub-options (caught mid-flight, ‹ first), a sub-option opens
# a SHORT panel (one group, ≤ 30%, full width with only its top corners
# rounded, no card inside it, never over the stage or the toolbar row,
# mid-flight), a choice applies + undoes, ✓ closes, ‹ returns to the root.
# A system strip down one side (the Duo's folded shape): canvas, zoom chip and
# bars stay out of it and the chip leaves the captions clear.
# `--inject ignores-size-class` / `ignores-crease` / `ignores-side-strip` / `snap-panel` /
# `panel-over-toolbar` / `panel-uncapped` / `bar-snap` / `no-back` /
# `panel-card` / `card-in-card` / `stage-card` must make it FAIL.
# Liquid Glass (the floating chrome only): every floating key — header back,
# aspect, Export (tinted), the toolbar row, the zoom chip, the tool bar, a
# panel's ✓ and title — sits on a real UIGlassEffect view in the editor's own
# window chain; the stage, lanes and panel rows are not glass; Reduce
# Transparency swaps every glass surface for the opaque kit material (and
# back); Increase Contrast edges each with 1 pt; the bar's capsule morphs
# mid-flight between levels (iPad). `--inject flat-chrome` /
# `glass-ignores-reduce-transparency` / `glass-no-contrast-border` /
# `glass-on-content` (and `bar-snap` for the morph) must make it FAIL.
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
