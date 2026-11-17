#!/usr/bin/env bash
# ios-vectors: run the Mac's golden vectors on iOS and compare (Studio 1g).
#
# Builds an iOS Simulator executable from the shared studio core
# (apps/macos/CaptureCat/Studio/) plus the Mac's own `--web-vectors` unit
# files, runs it INSIDE a booted simulator with `simctl spawn` (iOS SDK,
# iOS frameworks underneath), and compares every unit it produced with the
# Mac's output: byte-identical, or doubles within 1e-12. A short list of
# units with documented iOS platform differences (system font metrics,
# ±1 GPU samples) is reported, not gated — see ios-vectors-compare.py.
# Units not compiled for iOS yet are named.
#
# Then the cursor rasters: every cursor style rasterized on iOS by the real
# CursorStyleProvider (the exporter's call) at 1×/2×/3× and at the
# exporter's pixel grids over a range of cursor scales, vs the Mac's
# `--web-cursor-sprites --verify-sizes` for the same grids — byte-identical,
# with the same point size and hotspot (ios-cursor-rasters-compare.py). The
# Hand is the Mac's NSCursor bitmap bundled on iOS (StudioResources/Cursors,
# copied next to the binary here as the app bundles it).
#
#   apps/ios/scripts/ios-vectors.sh [MAC_VECTORS_DIR]
#
# MAC_VECTORS_DIR: the Mac's `CaptureCat --web-vectors <dir>` output. When
# omitted, the script runs the Mac binary itself (APP=/path/CaptureCat.app,
# default: the scheme's Debug build — it must be unsandboxed to write). The
# cursor rasters always come from APP.
# Env: DEVICE=<simulator udid> (default: the first booted iPhone),
#      OUT=<dir> (default: $TMPDIR/capturecat-ios-vectors).
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$(cd "$IOS/../macos/CaptureCat" && pwd)"
WV="$MAC/Services/WebVectors"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-vectors}"
mkdir -p "$OUT"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -E 'iPhone' | head -1 | grep -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$DEVICE" ]] || { echo "ios-vectors: boot an iPhone simulator first (or set DEVICE)" >&2; exit 2; }

# The harness files that compile for iOS (see apps/ios/StudioVectors/ClusterShims.swift
# for the clusters that do not, and why).
UNITS=(
  WebVectorsHarness WebVectors+Time WebVectors+Layout WebVectors+LayoutExport
  WebVectors+CameraMotion WebVectors+CameraMotionOracle WebVectors+CameraLooks
  WebVectors+Regions WebVectors+Style WebVectors+StyleBackground WebVectors+StyleOracle
  WebVectors+StyleGeometry WebVectors+Model WebVectors+Cursor WebVectors+CursorOracle
  WebVectors+Overlay WebVectors+OverlayAnnotation WebVectors+OverlayDraw
  WebVectors+OverlayOracle WebVectors+OverlayRecorder WebVectors+ReferenceCanvas
)
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$MAC/Studio" -name '*.swift' | sort)
files+=("$MAC/Services/CameraMaskFixtures.swift")
for u in "${UNITS[@]}"; do files+=("$WV/$u.swift"); done
files+=("$IOS/StudioVectors/main.swift" "$IOS/StudioVectors/ClusterShims.swift" "$IOS/StudioVectors/CursorRasters.swift")

echo "ios-vectors: building ${#files[@]} files for the iOS Simulator (-Onone, the Mac Debug settings)"
xcrun -sdk iphonesimulator swiftc -Onone \
  -target arm64-apple-ios18.0-simulator \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -module-name CaptureCat "${files[@]}" -o "$OUT/ios-vectors-bin" > "$OUT/build.log" 2>&1 \
  || { grep ' error: ' "$OUT/build.log" | head -20; echo "IOS-VECTORS FAIL (build)"; exit 1; }
# The app's bundled resources (gen-xcodeproj.py RESOURCE_FILES), where
# Bundle.main finds them for a bare executable: next to it.
cp "$IOS"/StudioResources/Cursors/*.rgba "$OUT/"

if [[ -z "${APP:-}" ]]; then
  APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
          -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
fi
MAC_DIR="${1:-}"
if [[ -z "$MAC_DIR" ]]; then
  MAC_DIR="$OUT/mac"
  rm -rf "$MAC_DIR"; mkdir -p "$MAC_DIR"
  "$APP/Contents/MacOS/CaptureCat" --web-vectors "$MAC_DIR" > "$OUT/mac.log" 2>&1 \
    || { tail -5 "$OUT/mac.log"; echo "IOS-VECTORS FAIL (Mac vectors)"; exit 1; }
fi

rm -rf "$OUT/ios"; mkdir -p "$OUT/ios"
echo "ios-vectors: running on simulator $DEVICE"
xcrun simctl spawn "$DEVICE" "$OUT/ios-vectors-bin" --web-vectors "$OUT/ios" > "$OUT/ios.log" 2>&1 \
  || { tail -5 "$OUT/ios.log"; echo "IOS-VECTORS FAIL (iOS run)"; exit 1; }

status=0
python3 "$IOS/scripts/ios-vectors-compare.py" "$MAC_DIR" "$OUT/ios" || status=1

# Cursor rasters: the exporter's grids, ceil(point size × cursorRasterScale),
# for every style over a spread of scales (the hand's rep switch at 32/33 px
# and both reps up and down included).
SIZES="$(python3 -c '
import math
pts = {"macOS Arrow": (20, 28), "White Arrow": (20, 28), "Hand": (32, 32), "Dot": (24, 24), "Ring": (24, 24)}
scales = [0.5, 0.75, 0.97, 1.03, 1.25, 1.5, 1.875, 1.97, 2.03, 2.25, 2.5, 2.75, 3.34, 4, 5, 6.4]
out = []
for style, (w, h) in pts.items():
    for s in scales:
        out.append(f"{style}:{math.ceil(w * s)}x{math.ceil(h * s)}")
out += ["Hand:31x31", "Hand:33x33", "Hand:63x63", "Hand:65x65", "Hand:50x70"]
print(",".join(dict.fromkeys(out)))
')"
rm -rf "$OUT/mac-cursors" "$OUT/ios-cursors"; mkdir -p "$OUT/ios-cursors"
"$APP/Contents/MacOS/CaptureCat" --web-cursor-sprites "$OUT/mac-cursors" --verify-sizes "$SIZES" \
  > "$OUT/mac-cursors.log" 2>&1 || { tail -3 "$OUT/mac-cursors.log"; echo "IOS-VECTORS FAIL (Mac cursor sprites)"; exit 1; }
xcrun simctl spawn "$DEVICE" "$OUT/ios-vectors-bin" --cursor-rasters "$OUT/ios-cursors" --sizes "$SIZES" \
  > "$OUT/ios-cursors.log" 2>&1 || { tail -3 "$OUT/ios-cursors.log"; echo "IOS-VECTORS FAIL (iOS cursor rasters)"; exit 1; }
python3 "$IOS/scripts/ios-cursor-rasters-compare.py" "$OUT/mac-cursors" "$OUT/ios-cursors" || status=1
[[ $status -eq 0 ]] && echo "IOS-VECTORS + CURSOR-RASTERS PASS" || echo "IOS-VECTORS FAIL (see above)"
exit $status
