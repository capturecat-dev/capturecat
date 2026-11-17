#!/usr/bin/env bash
set -euo pipefail
# Studio 3d's background export on a PHYSICAL device (the Simulator refuses
# BGContinuedProcessingTask). StudioLab `--background-export-probe` exports a
# synthetic 1080p project in the foreground, then again through the shipping
# StudioExportJob; this script sends the app to the background (opens
# Settings) once the second export starts, and the probe compares every 15th
# frame byte for byte (StudioLab/BackgroundExportProbe.swift).
#
#   apps/ios/scripts/ios-device-background-export.sh <device-udid> [seconds]
#
# Unlock the device first and leave it unlocked (the app keeps the screen awake
# while in front; Settings does not lock it within a minute).
cd "$(dirname "$0")/.."
udid="$1"; seconds="${2:-40}"
out="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-device-bg-export}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
bundle=so.capturecat.ios.studiolab

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-device-background-export: building StudioLab for the device"
  xcodebuild -project CaptureCat.xcodeproj -scheme StudioLab -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$out/dd-lab" -allowProvisioningUpdates build \
    > "$out/lab-build.log" 2>&1 || { grep -E 'error:' "$out/lab-build.log" | head -20; echo "IOS-DEVICE-BG-EXPORT FAIL (build)"; exit 1; }
fi
lab="${LAB_APP:-$out/dd-lab/Build/Products/Debug-iphoneos/StudioLab.app}"
xcrun devicectl device install app --device "$udid" "$lab" >/dev/null

wait_unlocked() {
  local said=""
  until xcrun devicectl device info lockState --device "$udid" 2>/dev/null | grep -q 'passcodeRequired: false'; do
    if [[ -z "$said" ]]; then echo "   waiting for the device to be unlocked…"; said=1; fi
    sleep 5
  done
}

log="$out/run.log"
for attempt in 1 2 3; do
  wait_unlocked
  : > "$log"
  xcrun devicectl device process launch --device "$udid" --console --terminate-existing "$bundle" \
    --background-export-probe "@home/Documents/bg-export" --seconds "$seconds" > "$log" 2>&1 &
  launch=$!
  # Background the app as soon as the shipping job starts.
  backgrounded=""
  while kill -0 "$launch" 2>/dev/null; do
    if [[ -z "$backgrounded" ]] && grep -q 'BG-EXPORT-STARTED' "$log"; then
      sleep 3
      echo "ios-device-background-export: opening Settings (app → background)"
      xcrun devicectl device process launch --device "$udid" com.apple.Preferences >/dev/null 2>&1 || true
      backgrounded=1
    fi
    sleep 1
  done
  wait "$launch" || true
  grep -q 'BSErrorCodeDescription = Locked' "$log" || break
  echo "   launch refused: device locked (attempt $attempt)"
done

# The console stream can drop once the app is in the background: wait for the
# probe to finish, then read its own result file back from the container.
for i in $(seq 1 120); do
  rm -rf "$out/back"; mkdir -p "$out/back"
  xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Documents/bg-export/result.txt --destination "$out/back/result.txt" >/dev/null 2>&1 || true
  grep -q '^BG-EXPORT-PROBE' "$out/back/result.txt" 2>/dev/null && break
  sleep 5
done
result="$out/back/result.txt"
grep -E '^BG-EXPORT (PASS|FAIL|NOTE|job|foreground|source|path)' "$result" 2>/dev/null || tail -30 "$log"
grep -q '^BG-EXPORT-PROBE PASS' "$result" 2>/dev/null && { echo "IOS-DEVICE-BG-EXPORT PASS"; exit 0; }
echo "IOS-DEVICE-BG-EXPORT FAIL"; exit 1
