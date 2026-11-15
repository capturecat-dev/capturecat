#!/usr/bin/env bash
# ios-preview-export-parity: the iOS preview against the iOS export (Studio 3c).
#
# The Mac dumps its preview-parity fixture (`--preview-parity-fixtures`) and
# runs the shared StudioHarness/PreviewExportParityHarness as the CONTROL
# (`CaptureCat --preview-export-parity`: the Mac's PreviewCompositorView vs the
# Mac exporter). StudioLab runs the same harness with the shipping
# PreviewStageView in a real UIWindow vs the iOS exporter, and must be no
# worse than the Mac on any case (whole frame: mean +0.5/255, >8 px +0.5%);
# the cursor's drawn box must match within 4 px size / 6 px position.
# The Mac control's own whole-frame results are reported: cases above 3/255
# there are Mac preview≠export findings (docs/ios-studio-plan.md, 3c).
#
#   apps/ios/scripts/ios-preview-export-parity.sh
#
# Env: APP=/path/CaptureCat.app  DEVICE=<udid> (an iPad: the 720×405 stage
#      must fit at magnification 1)  OUT=<dir>  INJECT=1 (export-only defect:
#      the gate must fail)
set -euo pipefail
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-preview-export-parity}"
mkdir -p "$OUT"
DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPad' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-preview-export-parity: boot an iPad simulator first (or set DEVICE)" >&2; exit 2; }
if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
MAC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
FIX="$OUT/fixture"
rm -rf "$FIX" "$OUT/mac" "$OUT/ios"
"$MAC" --preview-parity-fixtures "$FIX" | tail -1
INJ=()
[[ -n "${INJECT:-}" ]] && INJ=(--inject)
"$MAC" --preview-export-parity "$FIX" --out "$OUT/mac" > "$OUT/mac.log" 2>&1 || true
grep -E '^PREVIEW-EXPORT ' "$OUT/mac.log" | sed 's/^/  Mac control  /'
echo "ios-preview-export-parity: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-PREVIEW-EXPORT-PARITY FAIL (build)"; exit 1; }
xcrun simctl install "$DEVICE" "$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --ios-preview-export-parity "$FIX" --out "$OUT/ios" --reference "$OUT/mac/results.json" ${INJ[@]+"${INJ[@]}"} \
  > "$OUT/ios.log" 2>&1 || true
grep -E '^PREVIEW-EXPORT' "$OUT/ios.log" | sed 's/^/  iOS          /' \
  || { tail -20 "$OUT/ios.log"; echo "IOS-PREVIEW-EXPORT-PARITY FAIL (no result)"; exit 1; }
echo "ios-preview-export-parity: logs $OUT/{mac,ios}.log · captures $OUT/{mac,ios}/*-preview.png|*-export.png"
grep -q '^PREVIEW-EXPORT-PARITY PASS' "$OUT/ios.log" && echo "IOS-PREVIEW-EXPORT-PARITY PASS" || { echo "IOS-PREVIEW-EXPORT-PARITY FAIL"; exit 1; }
