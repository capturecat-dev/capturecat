#!/usr/bin/env bash
set -euo pipefail
# The companion app's speed on a PHYSICAL device, with the signed-in user's
# real library (App/Fixtures/AppPerfProbe.swift; timings only). Builds the app
# OPTIMIZED (-O, whole module) with its DEBUG probe kept, installs it OVER the
# installed app (same bundle id; sign-in and caches survive an install), and
# launches it cold with -perfProbe.
#
#   apps/ios/scripts/ios-device-app-perf.sh <device-udid> [--open]   # --open: also open the newest project in the studio
#
# Unlock the device first.
cd "$(dirname "$0")/.."
udid="$1"; shift || true
args=(-perfProbe)
[[ "${1:-}" == "--open" ]] && args+=(-perfOpenProject)
out="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-device-app-perf}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
bundle=so.capturecat.ios

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-device-app-perf: building CaptureCat (optimized) for the device"
  xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$out/dd" -allowProvisioningUpdates \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s \
    build > "$out/build.log" 2>&1 || { grep -E 'error:' "$out/build.log" | head -20; echo "IOS-DEVICE-APP-PERF FAIL (build)"; exit 1; }
  xcrun devicectl device install app --device "$udid" "$out/dd/Build/Products/Debug-iphoneos/CaptureCat.app" >/dev/null
fi

wait_unlocked() {
  local said=""
  until xcrun devicectl device info lockState --device "$udid" 2>/dev/null | grep -q 'passcodeRequired: false'; do
    if [[ -z "$said" ]]; then echo "   waiting for the device to be unlocked…"; said=1; fi
    sleep 5
  done
}
for attempt in 1 2 3; do
  wait_unlocked
  xcrun devicectl device process launch --device "$udid" --terminate-existing "$bundle" -- "${args[@]}" > "$out/launch.log" 2>&1 || true
  grep -q 'BSErrorCodeDescription = Locked' "$out/launch.log" || break
  echo "   launch refused: device locked (attempt $attempt)"
done
for i in $(seq 1 90); do
  rm -rf "$out/back"; mkdir -p "$out/back"
  xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Documents/perf-app/result.txt --destination "$out/back/result.txt" >/dev/null 2>&1 || true
  grep -qE '^APPPERF(-PROBE DONE| FAIL)' "$out/back/result.txt" 2>/dev/null && break
  sleep 4
done
grep -E '^APPPERF' "$out/back/result.txt" 2>/dev/null || cat "$out/launch.log"
