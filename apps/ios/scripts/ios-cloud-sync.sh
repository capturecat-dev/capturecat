#!/usr/bin/env bash
# ios-cloud-sync.sh — the iOS studio's cloud sync (Studio Phase 5), against the Mac.
#
#   apps/ios/scripts/ios-cloud-sync.sh
#
# 1. ENGINE: the Mac binary runs `--cloud-sync-test` (its transcript is the
#    reference); StudioLab `--ios-cloud-sync` replays the same engine sections
#    (StudioHarness/CloudSyncHarness — the Mac's sync core from Studio/Sync,
#    compiled for iOS) against the same StubCloudServer. Every line iOS prints
#    must be a line the Mac prints, in order (ios-cloud-sync-compare.py; the
#    Mac prints more — its AppKit-only sections).
# 2. THE iOS STUDIO: StudioLab drives StudioCloudSync with the shipping
#    EditorViewController in a real window: clone on open, debounced
#    If-Match pushes from editor edits, media uploads, a concurrent change
#    merged into the open editor as one undo step, a 409 merged, the later
#    writer winning a same-field clash, Merge Review for a structural
#    conflict, the CLOUD's History (list + server restore), offline edits
#    queued and pushed (live, and after a relaunch), a moved container
#    re-pointing media, an inbox take uploading as a studio project, and the
#    header's sync dot sampled mid-flight.
# 3. ROUND TRIP: one stub cloud persisted on disk, handed between the REAL Mac
#    binary (`--cloud-sync-roundtrip --step 1|3|5`) and StudioLab
#    (`--ios-cloud-sync-roundtrip --step 2|4`): Mac creates → iOS edits →
#    Mac pulls + edits → iOS's offline edits merge (Merge Review) → Mac pulls
#    and re-merges iOS's triple itself (identical).
#
# Env: APP=/path/CaptureCat.app  an UNSANDBOXED Mac build (default: build one into $OUT/dd-mac)
#      DEVICE=<udid>             the simulator (default: the first booted iPad)
#      OUT=<dir>                 default: $TMPDIR/capturecat-ios-cloud-sync
#      MAC_REFERENCE=<file>      a passing `--cloud-sync-test` transcript of the same Mac
#                                build to compare with, instead of running it here
#      INJECT=drop-if-match|merge-wrong-side|lose-unknown-key   part 2 only, with that
#                                defect in the iOS client's outbound path — must FAIL
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-cloud-sync}"
TEMPLATE="$IOS/Core/ProjectTemplate.json"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-cloud-sync: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }

if [[ -z "${APP:-}" ]]; then
  echo "ios-cloud-sync: building an unsandboxed Mac Debug into $OUT/dd-mac"
  args=(-project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug
        -derivedDataPath "$OUT/dd-mac" CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO)
  (cd "$IOS/../macos" && xcodebuild "${args[@]}" build > "$OUT/mac-build.log" 2>&1) \
    || { grep -E '^/.*error:' "$OUT/mac-build.log" | head -20; echo "IOS-CLOUD-SYNC FAIL (Mac build)"; exit 1; }
  APP="$OUT/dd-mac/Build/Products/Debug/CaptureCat.app"
fi
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null | grep -q true; then
  echo "ios-cloud-sync: $APP is sandboxed — unset APP to build an unsandboxed copy" >&2
  exit 2
fi
MAC="$APP/Contents/MacOS/CaptureCat"

echo "ios-cloud-sync: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-CLOUD-SYNC FAIL (build)"; exit 1; }
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"

lab() {
  xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab "$@"
}

RUN="$OUT/run"
rm -rf "$RUN" && mkdir -p "$RUN"

if [[ -n "${INJECT:-}" ]]; then
  echo "ios-cloud-sync: part 2 with the defect '$INJECT' (must FAIL)"
  lab --ios-cloud-sync "$RUN" --template "$TEMPLATE" --inject "$INJECT" > "$RUN/run.log" 2>&1 || true
  grep -E '^(  ✘|IOS CLOUD SYNC|IOS-CLOUD-SYNC-GATE)' "$RUN/run.log" || true
  grep -q '^IOS-CLOUD-SYNC-GATE PASS' "$RUN/run.log" && { echo "IOS-CLOUD-SYNC PASS (inject $INJECT — the defect went unnoticed)"; exit 0; }
  echo "IOS-CLOUD-SYNC FAIL (inject $INJECT)"
  exit 1
fi

if [[ -n "${MAC_REFERENCE:-}" ]]; then
  # A passing transcript of the same Mac build (its UI sections are
  # load-sensitive when other sessions drive windows and simulators).
  echo "ios-cloud-sync: the Mac's --cloud-sync-test (reference: $MAC_REFERENCE)"
  cp "$MAC_REFERENCE" "$RUN/mac-cloud-sync.txt"
else
  echo "ios-cloud-sync: the Mac's --cloud-sync-test (reference)"
  "$MAC" --cloud-sync-test > "$RUN/mac-cloud-sync.txt" 2>&1 || true
fi
tail -1 "$RUN/mac-cloud-sync.txt"
grep -q '^CLOUD SYNC PASS' "$RUN/mac-cloud-sync.txt" || { echo "IOS-CLOUD-SYNC FAIL (the Mac's own gate failed)"; exit 1; }

echo "ios-cloud-sync: StudioLab on $DEVICE"
lab --ios-cloud-sync "$RUN" --template "$TEMPLATE" > "$RUN/run.log" 2>&1 || true
grep -E '^(== |CLOUD SYNC (PASS|FAIL)|IOS CLOUD SYNC|  ✘)' "$RUN/run.log" || true
ok=1
grep -q '^IOS-CLOUD-SYNC-GATE PASS' "$RUN/run.log" || ok=0
python3 "$IOS/scripts/ios-cloud-sync-compare.py" "$RUN/mac-cloud-sync.txt" "$RUN/run.log" "$RUN/compare.txt" || ok=0

echo "ios-cloud-sync: Mac ↔ iOS round trip"
RT="$RUN/roundtrip"
mkdir -p "$RT"
for step in 1 2 3 4 5; do
  if (( step % 2 == 1 )); then
    "$MAC" --cloud-sync-roundtrip "$RT" --step "$step" > "$RT/step$step.log" 2>&1 || true
  else
    lab --ios-cloud-sync-roundtrip "$RT" --step "$step" > "$RT/step$step.log" 2>&1 || true
  fi
  grep -E '^(  ✘|ROUNDTRIP STEP)' "$RT/step$step.log" || echo "ROUNDTRIP STEP $step: no result"
  grep -q "^ROUNDTRIP STEP $step PASS" "$RT/step$step.log" || { ok=0; break; }
done

echo "ios-cloud-sync: logs $RUN/run.log · compare $RUN/compare.txt · trace $RUN/sync-trace.txt · motion $RUN/motion.txt · round trip $RT"
if (( ok )); then echo "IOS-CLOUD-SYNC PASS"; exit 0; fi
echo "IOS-CLOUD-SYNC FAIL"
exit 1
