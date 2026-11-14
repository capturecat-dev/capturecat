#!/usr/bin/env bash
set -euo pipefail
# Spikes (d) and (h) on the REAL Mac compositor and editor shell, without
# touching the product tree: `git archive` apps/macos at HEAD into a scratch
# folder, apply scratch/scratch.patch there (a spike file + three env-gated
# hooks), build that copy unsandboxed, run, and copy results into
# results/mac/.
#
#   apps/ios-spikes/mac/run-scratch-spikes.sh [scratch-dir]
#
# (d) SPIKE_D=1 --preview-parity          motion blur + look dissolve, Mac vs iOS-without-filters
#     SPIKE_D_STRIP=1 --preview-parity    the whole gate rendered without CA filters
# (h) SPIKE_SHELL_SIZE=WxH --editor-shell-shot   preview canvas at several window sizes
cd "$(dirname "$0")"
here="$PWD"
repo="$(git rev-parse --show-toplevel)"
scratch="${1:-${TMPDIR:-/tmp}/ccspikes-scratch}"
out="$here/../results/mac"; mkdir -p "$out"
rm -rf "$scratch/src"; mkdir -p "$scratch/src"
git -C "$repo" archive HEAD apps/macos | tar -x -C "$scratch/src"
(cd "$scratch/src" && patch -p1 --quiet <"$here/scratch/scratch.patch")
macos="$scratch/src/apps/macos"
args=(-project "$macos/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug -derivedDataPath "$scratch/dd"
      CODE_SIGN_ENTITLEMENTS="$macos/scripts/release.entitlements" ENABLE_APP_SANDBOX=NO)
echo "== build scratch copy"
xcodebuild "${args[@]}" build >"$scratch/build.log" 2>&1 || { tail -20 "$scratch/build.log"; exit 1; }
bin="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | head -1 | sed 's/.*= //')/CaptureCat.app/Contents/MacOS/CaptureCat"

echo "== (h) editor canvas sizes"
: >"$out/h-canvas.txt"
for size in 1100x700 1280x800 1400x800 1728x1080 2560x1400; do
  SPIKE_SHELL_SIZE="$size" "$bin" --editor-shell-shot "$scratch/shell-$size" 2>&1 | grep -E '^SPIKE-H|^NATIVE  (preview|contentView)=' >>"$out/h-canvas.txt" || true
done
cat "$out/h-canvas.txt"

echo "== (d) motion blur + dissolve"
SPIKE_D=1 "$bin" --preview-parity >"$out/d-spike.log" 2>&1 || true
grep '^SPIKE-D' "$out/d-spike.log" | cut -c1-400
art="$(awk '/^CAPTUREDIR /{print $2; exit}' "$out/d-spike.log")"
[[ -f "$art/spike-d.json" ]] && cp "$art/spike-d.json" "$out/d-spike.json"
mkdir -p "$out/d-frames" && cp "$art"/spiked-*.png "$out/d-frames/" 2>/dev/null || true

echo "== (d) full gate without CA filters"
SPIKE_D_STRIP=1 "$bin" --preview-parity >"$out/d-strip.log" 2>&1 || true
grep -E '^(STATE|CAMERA-LOOK|WORST|PARITY)' "$out/d-strip.log" >"$out/d-strip-summary.txt" || true
tail -3 "$out/d-strip-summary.txt"
echo "== results in $out"
