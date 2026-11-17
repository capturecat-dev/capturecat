#!/usr/bin/env bash
# ios-a11y: the whole iOS app with assistive technology (Studio 6a), in the
# REAL window chain, on an iPad and an iPhone.
#
#   apps/ios/scripts/ios-a11y.sh
#
# 1. StudioLab `--a11y` (apps/ios/StudioLab/A11yLab.swift): the shipping
#    editor presented full screen in StudioLab's real UIWindow and every studio
#    screen opened from it (all nine inspector panes, top and scrolled to the
#    end; an open lane; a selected zoom; the timeline's long-press menu;
#    History; Merge Review; the four feature sheets; a confirmation dialog; the
#    colour picker; the sync dot — and the Export sheet once it registers in
#    `A11yLab.extraScreens`). Per screen, at the default AND the largest
#    accessibility text size: what VoiceOver reaches (labels, interactive
#    traits, adjustable values), hit targets ≥ 44 pt MEASURED through
#    UIWindow.hitTest, no overlapping focusable frames, and at the largest size
#    every visible text fits (no truncation / overlap / clipping) and grew.
#    Then timeline blocks and stage objects: activation and each custom action
#    vs the touch path (same project bytes, same undo steps); the transport;
#    announcements; Reduce Motion sampled MID-FLIGHT (opacity between its
#    endpoints, no travel or scale) for the rail chip, pane switch, slider,
#    lane opening, selection outline, dialog and History entrances; keyboard
#    commands through the responder chain; inspector focus; pointer hover;
#    Increase Contrast, Reduce Transparency, Differentiate Without Color, Bold
#    Text.
# 2. The app (`-uiFixtures -uiA11yAudit`, App/Fixtures/FixtureA11yAudit.swift):
#    the companion screens — library (recordings, screenshots, shares), a
#    project, a share, capture (with the inbox), account, sign-in, a dialog, an
#    action sheet, a toast — audited by the same CCAccessibilityAudit.
# 3. Gate power: each injected defect must turn the StudioLab gate RED —
#    missing-label, tiny-target, truncation, snap-under-reduce-motion,
#    action-not-undoable.
#
# The simulators' app-accessibility runtime is switched on for the run
# (com.apple.Accessibility ApplicationAccessibilityEnabled — what Accessibility
# Inspector does) so UIKit's own accessibility answers exist, as with
# VoiceOver; it is switched back off at the end.
#
# Env: DEVICES="<udid> <udid>"  (default: the Studio 6a iPad + iPhone)
#      OUT=<dir>                (default: $TMPDIR/capturecat-ios-a11y)
#      INJECT="a b"             defects to prove (default: all five; "none" skips)
#      SKIP_APP=1               StudioLab only
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="${DEVICES:-B485AFD6-0EB6-4C8C-B139-A552C76723AE E480B7FC-E935-45F2-A089-4F3B2503992A}"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-a11y}"
INJECT="${INJECT:-missing-label tiny-target truncation snap-under-reduce-motion action-not-undoable}"
LAB=so.capturecat.ios.studiolab
APPID=so.capturecat.ios
mkdir -p "$OUT"

echo "ios-a11y: building StudioLab + the app (Debug)"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build-lab.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build-lab.log" | head -20; echo "IOS-A11Y FAIL (StudioLab build)"; exit 1; }
if [[ -z "${SKIP_APP:-}" ]]; then
  xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build-app.log" 2>&1 \
    || { grep -E '^/.*error:' "$OUT/build-app.log" | head -20; echo "IOS-A11Y FAIL (app build)"; exit 1; }
fi
LABAPP="$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
APPAPP="$OUT/dd/Build/Products/Debug-iphonesimulator/CaptureCat.app"

ax() {  # ax <device> on|off — the app-accessibility runtime
  if [[ "$2" == on ]]; then
    xcrun simctl spawn "$1" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
  else
    xcrun simctl spawn "$1" defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled 2>/dev/null || true
  fi
}

status=0
lab() {  # lab <device> <dir> [args…] — one StudioLab --a11y run; prints its verdict line
  local device="$1" dir="$2"; shift 2
  rm -rf "$dir" && mkdir -p "$dir"
  xcrun simctl launch --console-pty --terminate-running-process "$device" "$LAB" --a11y "$dir/lab" "$@" > "$dir/run.log" 2>&1 || true
  grep -aE '^A11Y-GATE' "$dir/run.log" | tail -1 | tr -d '\r' || echo "A11Y-GATE (no result)"
}

first=""
for device in $DEVICES; do
  [[ -z "$first" ]] && first="$device"
  name="$(xcrun simctl list devices | grep "$device" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/' | head -1)"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b > /dev/null
  ax "$device" on
  xcrun simctl install "$device" "$LABAPP"
  echo "ios-a11y: StudioLab on $name ($device)"
  verdict="$(lab "$device" "$OUT/$device")"
  grep -aE '^A11Y [a-z].* FAIL' "$OUT/$device/run.log" | cut -c1-400 || true
  echo "  checks: $(grep -acE '^A11Y [a-z].* PASS' "$OUT/$device/run.log") pass, $(grep -acE '^A11Y [a-z].* FAIL' "$OUT/$device/run.log") fail — $verdict"
  [[ "$verdict" == "A11Y-GATE PASS" ]] || status=1

  if [[ -z "${SKIP_APP:-}" ]]; then
    echo "ios-a11y: the app's screens on $name"
    mkdir -p "$OUT/$device/app"
    xcrun simctl install "$device" "$APPAPP"
    xcrun simctl launch --console-pty --terminate-running-process "$device" "$APPID" \
      -uiFixtures -uiA11yAudit > "$OUT/$device/app/run.log" 2>&1 || true
    grep -aE '^APPA11Y [a-z].* FAIL' "$OUT/$device/app/run.log" | cut -c1-400 || true
    appverdict="$(grep -aE '^APPA11Y-GATE' "$OUT/$device/app/run.log" | tail -1 | tr -d '\r' || true)"
    echo "  app checks: $(grep -acE '^APPA11Y [a-z].* PASS' "$OUT/$device/app/run.log") pass, $(grep -acE '^APPA11Y [a-z].* FAIL' "$OUT/$device/app/run.log") fail — ${appverdict:-APPA11Y-GATE (no result)}"
    [[ "$appverdict" == "APPA11Y-GATE PASS" ]] || status=1
  fi
done

if [[ "$INJECT" != none && -n "$first" ]]; then
  for defect in $INJECT; do
    verdict="$(lab "$first" "$OUT/inject-$defect" --inject "$defect")"
    failed="$(grep -aE '^A11Y [a-z].* FAIL' "$OUT/inject-$defect/run.log" | head -3 | cut -c1-160 | tr '\n' ' ')"
    if [[ "$verdict" == "A11Y-GATE FAIL"* ]]; then
      echo "ios-a11y: --inject $defect → RED as it must ($(grep -acE '^A11Y [a-z].* FAIL' "$OUT/inject-$defect/run.log") checks): $failed"
    else
      echo "ios-a11y: --inject $defect → NOT caught ($verdict)"; status=1
    fi
  done
fi

for device in $DEVICES; do ax "$device" off; done
echo "ios-a11y: logs $OUT/<device>/run.log · element transcripts $OUT/<device>/lab/run.txt · captures $OUT/<device>/lab/xxxl/"
if [[ $status == 0 ]]; then echo "IOS-A11Y PASS"; else echo "IOS-A11Y FAIL"; fi
exit $status
