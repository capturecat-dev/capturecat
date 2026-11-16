#!/usr/bin/env bash
# ios-history.sh — the iOS studio's project History (Studio 4f), against the Mac.
#
#   apps/ios/scripts/ios-history.sh
#
# 1. The Mac binary writes its history VALUES from the real Mac code
#    (`--history-transcript`): --history-panel-shot's fixture through the real
#    CloudProjectSync / CloudHistoryClient / HistoryRowView (rows), the real
#    VersionCompareDialog (compare), the real restore, and every apps/web merge
#    fixture through the real MergeReviewDialog — plus the REPLAY (the saves its
#    stub server turned into versions, and the fixture's media).
# 2. StudioLab `--history` records the replay into a real on-device
#    LocalProjectHistory, opens the fixture in the shipping EditorViewController
#    and drives the real History views: rows, compare (from the row action
#    sheets), preview on the live stage, restore (one undo step), Merge Review
#    (every control flipped, Apply), "Changed outside this editor". Its
#    transcript must equal the Mac's line for line. Motion: the panel / sheet
#    entrance, the preview's dissolve + banner, the compare slide and the
#    Merge Review entrance are sampled as sequences and asserted mid-flight.
#    An in-process self-test injects each defect and requires its check to trip.
#
# Env: APP=/path/CaptureCat.app  an UNSANDBOXED Mac build (default: build one into $OUT/dd-mac)
#      DEVICE=<udid>             default: the first booted iPad. Use a simulator no other
#                                session drives — StudioLab installs replace each other.
#      OUT=<dir>                 default: $TMPDIR/capturecat-ios-history
#      INJECT=snap-panel|snap-compare|snap-preview|merge-pick   the gate must FAIL
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$IOS/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-history}"
FIXTURES="$REPO/apps/web/src/editor/core/merge/fixtures"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-history: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${APP:-}" ]]; then
  echo "ios-history: building an unsandboxed Mac Debug into $OUT/dd-mac"
  args=(-project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug
        -derivedDataPath "$OUT/dd-mac" CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO)
  (cd "$IOS/../macos" && xcodebuild "${args[@]}" build > "$OUT/mac-build.log" 2>&1) \
    || { grep -E '^/.*error:' "$OUT/mac-build.log" | head -20; echo "IOS-HISTORY FAIL (Mac build)"; exit 1; }
  APP="$OUT/dd-mac/Build/Products/Debug/CaptureCat.app"
fi
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null | grep -q true; then
  echo "ios-history: $APP is sandboxed — unset APP to build an unsandboxed copy" >&2
  exit 2
fi
MAC="$APP/Contents/MacOS/CaptureCat"
"$MAC" --history-transcript "$OUT/mac" --merge-fixtures "$FIXTURES" | tail -1
[[ -s "$OUT/mac/mac-transcript.txt" ]] || { echo "IOS-HISTORY FAIL (no Mac transcript)"; exit 1; }

echo "ios-history: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-HISTORY FAIL (build)"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
RUN="$OUT/run"
rm -rf "$RUN" && mkdir -p "$RUN"
args=(--history "$RUN" --replay "$OUT/mac/replay" --transcript "$OUT/mac/mac-transcript.txt" --merge-fixtures "$FIXTURES")
[[ -n "${INJECT:-}" ]] && args+=(--inject "$INJECT")
echo "ios-history: running on $DEVICE ${INJECT:+(inject $INJECT)}"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  "${args[@]}" > "$RUN/run.log" 2>&1 || true

grep -E '^(HISTORY|  ✓|  ✘|    line|      mac|      ios|  ·)' "$RUN/run.log" || true
echo "ios-history: transcripts $OUT/mac/mac-transcript.txt vs $RUN/ios-transcript.txt · motion $RUN/motion.txt · shots $RUN/*.png"
grep -q '^HISTORY-GATE PASS' "$RUN/run.log" && { echo "IOS-HISTORY PASS"; exit 0; }
echo "IOS-HISTORY FAIL"
exit 1
