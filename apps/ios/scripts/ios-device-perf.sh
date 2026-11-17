#!/usr/bin/env bash
set -euo pipefail
# The editor's speed on a PHYSICAL device: StudioLab `--perf-probe`
# (StudioLab/PerfProbe.swift) — open, play (frame pacing), scrub, step, close,
# export. Built OPTIMIZED (-O, whole module) with the DEBUG harness seams kept,
# so the numbers are a release build's, not an unoptimized one's.
#
#   apps/ios/scripts/ios-device-perf.sh <device-udid> [seconds] [--skip-export]
#
# Unlock the device first. Results: $OUT/back/result.txt (PERF lines).
cd "$(dirname "$0")/.."
udid="$1"; seconds="${2:-60}"; extra=("${@:3}")
out="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-device-perf}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
bundle=so.capturecat.ios.studiolab

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-device-perf: building StudioLab (optimized) for the device"
  xcodebuild -project CaptureCat.xcodeproj -scheme StudioLab -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$out/dd-lab" -allowProvisioningUpdates \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s \
    build > "$out/lab-build.log" 2>&1 || { grep -E 'error:' "$out/lab-build.log" | head -20; echo "IOS-DEVICE-PERF FAIL (build)"; exit 1; }
fi
xcrun devicectl device install app --device "$udid" "$out/dd-lab/Build/Products/Debug-iphoneos/StudioLab.app" >/dev/null

wait_unlocked() {
  local said=""
  until xcrun devicectl device info lockState --device "$udid" 2>/dev/null | grep -q 'passcodeRequired: false'; do
    if [[ -z "$said" ]]; then echo "   waiting for the device to be unlocked…"; said=1; fi
    sleep 5
  done
}
for attempt in 1 2 3; do
  wait_unlocked
  xcrun devicectl device process launch --device "$udid" --console --terminate-existing \
    --environment-variables '{"CAPTURECAT_RENDER_TIMING":"1"}' "$bundle" \
    --perf-probe "@home/Documents/perf" --seconds "$seconds" ${extra[@]+"${extra[@]}"} > "$out/run.log" 2>&1 || true
  grep -q 'BSErrorCodeDescription = Locked' "$out/run.log" || break
  echo "   launch refused: device locked (attempt $attempt)"
done
for i in $(seq 1 60); do
  rm -rf "$out/back"; mkdir -p "$out/back"
  xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Documents/perf/result.txt --destination "$out/back/result.txt" >/dev/null 2>&1 || true
  grep -q '^PERF-PROBE DONE' "$out/back/result.txt" 2>/dev/null && break
  sleep 5
done
grep -E '^PERF' "$out/back/result.txt" 2>/dev/null || tail -30 "$out/run.log"
