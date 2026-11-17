#!/usr/bin/env bash
# ios-editor-shell: the iOS studio editor (Studio 4b) in the real window chain,
# against the Mac.
#
#   apps/ios/scripts/ios-editor-shell.sh
#
# 1. The Mac binary dumps the preview-parity fixture (`--preview-parity-fixtures`)
#    and its LIVE `--preview-gesture-test` transcript (`--print`); the Mac gate
#    itself must pass (live == its frozen golden).
# 2. StudioLab `--editor-shell` opens each of the Mac's gesture scenarios as a
#    real project folder in the shipping EditorViewController (presented full
#    screen in a real UIWindow), drives the touch surface's own entry points,
#    and compares its transcript with the Mac's, scenario by scenario (the
#    `undo=` token is normalized on both sides — iOS registers an undo step
#    per canvas edit; undo is gated separately by unwinding every scenario to
#    its opening project). Then it plays a project and captures the stage as a
#    sequence: frames must advance, and no motion-blur still while playing.
#
# Env: APP=/path/CaptureCat.app  unsandboxed Mac build (default: the scheme's Debug build)
#      DEVICE=<udid>             default: the first booted iPad. Use a simulator no
#                                other session drives — StudioLab installs and
#                                relaunches replace each other.
#      OUT=<dir>                 default: $TMPDIR/capturecat-ios-editor-shell
#      ONLY=a,b                  scenarios (annotations,regions,zoom,tilt,chrome,stack,blurDraw,playback)
#      INJECT=touch|playing-blur|frozen-frames|page-follow   an injected defect; the gate must FAIL
#                                (page-follow: the timeline pages instead of keeping the playhead centred)
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-editor-shell}"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-editor-shell: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
MAC="$APP/Contents/MacOS/CaptureCat"
FIX="$OUT/fixture"
rm -rf "$FIX"
"$MAC" --preview-parity-fixtures "$FIX" | tail -1
"$MAC" --preview-gesture-test --print > "$OUT/mac-transcript.txt"
"$MAC" --preview-gesture-test | tail -1
"$MAC" --preview-gesture-test > /dev/null || { echo "IOS-EDITOR-SHELL FAIL (the Mac gesture gate itself fails)"; exit 1; }

echo "ios-editor-shell: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-EDITOR-SHELL FAIL (build)"; exit 1; }

xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
echo "ios-editor-shell: running on $DEVICE"
args=(--editor-shell "$FIX" --transcript "$OUT/mac-transcript.txt" --out "$OUT/run")
[[ -n "${ONLY:-}" ]] && args+=(--only "$ONLY")
[[ -n "${INJECT:-}" ]] && args+=(--inject "$INJECT")
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  "${args[@]}" > "$OUT/run.log" 2>&1 || true

grep -E '^(SCENARIO|TRANSCRIPT|PLAYBACK|CENTRED-PLAYBACK|FAIL|    line|               ios|   note|   real|   zoom-in)' "$OUT/run.log" || true
grep -E '^EDITOR-SHELL (PASS|FAIL)' "$OUT/run.log" || { tail -20 "$OUT/run.log"; echo "IOS-EDITOR-SHELL FAIL (no result)"; exit 1; }
echo "ios-editor-shell: full log $OUT/run.log · transcripts $OUT/run/ios-transcript*.txt · playback captures $OUT/run/playback/"
grep -q '^EDITOR-SHELL PASS' "$OUT/run.log"
