#!/usr/bin/env bash
set -euo pipefail
# The Studio 4e features gate on a PHYSICAL device (the Simulator's CoreML is
# not a device's Neural Engine — docs/ios-studio-plan.md, 4e transcription).
#
#   apps/ios/scripts/ios-device-features.sh <device-udid> <mac-features-dir> [whisper-base]
#
# <mac-features-dir> is the Mac reference `ios-features.sh` writes
# (`CaptureCat --features-reference <dir>`; its `<OUT>/mac`). The parts to run
# come from ONLY (default: transcription). <whisper-base> holds
# models/argmaxinc/whisperkit-coreml/openai_whisper-base.en (+ the tokenizer),
# needed for transcription. Inputs are copied into StudioLab's data container
# and named `@home/…` (StudioLab/LabPath.swift). Unlock the device first.
cd "$(dirname "$0")/.."
udid="$1"; ref="$2"; wb="${3:-}"
only="${ONLY:-transcription}"
out="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-device-features}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
bundle=so.capturecat.ios.studiolab

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-device-features: building StudioLab for the device"
  xcodebuild -project CaptureCat.xcodeproj -scheme StudioLab -configuration Debug \
    -destination "id=$udid" -derivedDataPath "$out/dd-lab" -allowProvisioningUpdates build \
    > "$out/lab-build.log" 2>&1 || { grep -E 'error:' "$out/lab-build.log" | head -20; echo "IOS-DEVICE-FEATURES FAIL (build)"; exit 1; }
fi
xcrun devicectl device install app --device "$udid" "$out/dd-lab/Build/Products/Debug-iphoneos/StudioLab.app" >/dev/null

copy() { # copy <host-path> <container-relative-destination>
  xcrun devicectl device copy to --device "$udid" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "$1" --destination "$2" >/dev/null
}
echo "ios-device-features: copying inputs"
for part in ${only//,/ }; do copy "$ref/$part" "Documents/ref/$part"; done
model_args=()
if [[ -n "$wb" ]]; then
  copy "$wb/models" "Documents/whisper/models"
  model_args=(--whisper-base "@home/Documents/whisper")
fi

inject=()
[[ -n "${INJECT:-}" ]] && inject=(--inject "$INJECT")
echo "ios-device-features: running ($only)${INJECT:+ inject=$INJECT}"
# Blocks until the device reports no passcode required (i.e. unlocked).
wait_unlocked() {
  local said=""
  until xcrun devicectl device info lockState --device "$udid" 2>/dev/null | grep -q 'passcodeRequired: false'; do
    if [[ -z "$said" ]]; then echo "   waiting for the device to be unlocked…"; said=1; fi
    sleep 5
  done
}
for attempt in 1 2 3 4 5; do
  wait_unlocked
  xcrun devicectl device process launch --device "$udid" --console --terminate-existing "$bundle" \
    --features "@home/Documents/run" --reference "@home/Documents/ref" --only "$only" \
    ${model_args[@]+"${model_args[@]}"} ${inject[@]+"${inject[@]}"} > "$out/run.log" 2>&1 || true
  grep -q 'BSErrorCodeDescription = Locked' "$out/run.log" || break
  echo "   launch refused: device locked (attempt $attempt)"
done

grep -E '^(FEATURE |FEATURE-SUMMARY|FEATURES-GATE)' "$out/run.log" || tail -30 "$out/run.log"
grep -q '^FEATURES-GATE PASS' "$out/run.log" && { echo "IOS-DEVICE-FEATURES PASS"; exit 0; }
echo "IOS-DEVICE-FEATURES FAIL"; exit 1
