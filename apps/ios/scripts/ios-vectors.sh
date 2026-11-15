#!/usr/bin/env bash
# ios-vectors: run the Mac's golden vectors on iOS and compare (Studio 1g).
#
# Builds an iOS Simulator executable from the shared studio core
# (apps/macos/CaptureCat/Studio/) plus the Mac's own `--web-vectors` unit
# files, runs it INSIDE a booted simulator with `simctl spawn` (iOS SDK,
# iOS frameworks underneath), and compares every unit it produced with the
# Mac's output: byte-identical, or doubles within 1e-12. A short list of
# units with documented iOS platform differences (system font metrics,
# cursor art, ±1 GPU samples) is reported, not gated — see
# ios-vectors-compare.py. Units not compiled for iOS yet are named.
#
#   apps/ios/scripts/ios-vectors.sh [MAC_VECTORS_DIR]
#
# MAC_VECTORS_DIR: the Mac's `CaptureCat --web-vectors <dir>` output. When
# omitted, the script runs the Mac binary itself (APP=/path/CaptureCat.app,
# default: the scheme's Debug build — it must be unsandboxed to write).
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
files+=("$IOS/StudioVectors/main.swift" "$IOS/StudioVectors/ClusterShims.swift")

echo "ios-vectors: building ${#files[@]} files for the iOS Simulator (-Onone, the Mac Debug settings)"
xcrun -sdk iphonesimulator swiftc -Onone \
  -target arm64-apple-ios18.0-simulator \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -module-name CaptureCat "${files[@]}" -o "$OUT/ios-vectors-bin" > "$OUT/build.log" 2>&1 \
  || { grep ' error: ' "$OUT/build.log" | head -20; echo "IOS-VECTORS FAIL (build)"; exit 1; }

MAC_DIR="${1:-}"
if [[ -z "$MAC_DIR" ]]; then
  if [[ -z "${APP:-}" ]]; then
    APP="$(xcodebuild -project "$IOS/../macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
            -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/CaptureCat.app"
  fi
  MAC_DIR="$OUT/mac"
  rm -rf "$MAC_DIR"; mkdir -p "$MAC_DIR"
  "$APP/Contents/MacOS/CaptureCat" --web-vectors "$MAC_DIR" > "$OUT/mac.log" 2>&1 \
    || { tail -5 "$OUT/mac.log"; echo "IOS-VECTORS FAIL (Mac vectors)"; exit 1; }
fi

rm -rf "$OUT/ios"; mkdir -p "$OUT/ios"
echo "ios-vectors: running on simulator $DEVICE"
xcrun simctl spawn "$DEVICE" "$OUT/ios-vectors-bin" --web-vectors "$OUT/ios" > "$OUT/ios.log" 2>&1 \
  || { tail -5 "$OUT/ios.log"; echo "IOS-VECTORS FAIL (iOS run)"; exit 1; }

python3 "$IOS/scripts/ios-vectors-compare.py" "$MAC_DIR" "$OUT/ios"
