#!/usr/bin/env bash
# ios-release-check: App Store readiness of the iOS app, checked on what SHIPS
# (Studio 6c, docs/ios-app-store.md). Builds a Release archive of the
# CaptureCat scheme (generic iOS device, unsigned — the same stripped binaries,
# Info.plists, Assets.car and privacy manifests the signed archive carries) and
# runs ios-release-check.py over it:
#
#   privacy manifests valid; every required-reason API the binaries call
#   (nm + the ObjC selector table) declared with an allowed reason; collected
#   types == the store answers in docs/ios-app-store.md · a usage string for
#   every privacy-sensitive API each binary links and none for one it doesn't ·
#   version/build set and equal across app + extensions, iOS 18 floor, launch
#   screen, iPad multitasking, ATS, ITSAppUsesNonExemptEncryption consistent
#   with the crypto in the binaries, background modes / BGTask ids only as used
#   · AppIcon complete (Any/Dark/Tinted, iPhone + iPad, glass stack, legacy
#   PNGs, not placeholder art) · no DEBUG harness flags, probe seams, dev URLs
#   or test keys in any binary; StudioLab not embedded; every entitlement used;
#   dSYMs archived · zero packaging warnings in the build log.
#
#   apps/ios/scripts/ios-release-check.sh             # build + check
#   SELFTEST=1 apps/ios/scripts/ios-release-check.sh  # + inject each defect into a COPY of the archive: every one must FAIL
#   ARCHIVE=<x.xcarchive> BUILD_LOG=<log> …           # check an existing archive (ios-archive.sh does this for the signed one)
#
# Env: OUT=<dir> (default $TMPDIR/capturecat-ios-release-check)
#      INJECT=<defect>  run ONE injected defect and report (exits 1 when caught — that is the point)
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$IOS/scripts/ios-release-check.py"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-release-check}"
mkdir -p "$OUT"

if [[ -z "${ARCHIVE:-}" ]]; then
  ARCHIVE="$OUT/CaptureCat.xcarchive"
  BUILD_LOG="$OUT/build.log"
  rm -rf "$ARCHIVE"
  echo "ios-release-check: archiving CaptureCat (Release, generic iOS, unsigned) → $ARCHIVE"
  if ! xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath "$OUT/dd" -archivePath "$ARCHIVE" \
      CODE_SIGNING_ALLOWED=NO archive > "$BUILD_LOG" 2>&1; then
    grep -E '(^/.*error:|error:)' "$BUILD_LOG" | head -20
    echo "IOS-RELEASE-CHECK FAIL (archive)"
    exit 1
  fi
fi
BUILD_LOG="${BUILD_LOG:?BUILD_LOG is required with ARCHIVE}"

# ---------------------------------------------------------------- defects
# Each defect is applied to a COPY of the archive (or of the entitlements) and
# names the check that must catch it.
expected_for() {
  case "$1" in
    drop-usage-string)    echo "App-usage-NSMicrophoneUsageDescription" ;;
    unused-usage-string)  echo "App-usage-NSCameraUsageDescription" ;;
    harness-string)       echo "App-no-harness-strings" ;;
    probe-seam)           echo "App-no-harness-strings" ;;
    dev-url)              echo "Share-no-harness-strings" ;;
    test-key)             echo "Broadcast-no-harness-strings" ;;
    drop-privacy-reason)  echo "App-required-reason-apis" ;;
    missing-manifest)     echo "Share-privacy-manifest" ;;
    tracking-on)          echo "Broadcast-privacy-manifest" ;;
    drop-icon)            echo "icon-AppIcon76x76@2x~ipad.png" ;;
    drop-encryption-key)  echo "encryption-key" ;;
    version-mismatch)     echo "Share-version-matches-app" ;;
    weak-ats)             echo "App-ats" ;;
    studiolab-embedded)   echo "studiolab-not-embedded" ;;
    dead-entitlement)     echo "App-entitlements" ;;
    unused-bgtask)        echo "bgtask-identifiers" ;;
    *) return 1 ;;
  esac
}
DEFECTS="drop-usage-string unused-usage-string harness-string probe-seam dev-url test-key drop-privacy-reason missing-manifest tracking-on drop-icon drop-encryption-key version-mismatch weak-ats studiolab-embedded dead-entitlement unused-bgtask"

inject() { # <defect> <archive copy> <entitlements copy dir>
  local d="$1" a="$2" e="$3"
  local app="$a/Products/Applications/CaptureCat.app"
  case "$d" in
    drop-usage-string)   plutil -remove NSMicrophoneUsageDescription "$app/Info.plist" ;;
    unused-usage-string) plutil -insert NSCameraUsageDescription -string "CaptureCat records video from your camera." "$app/Info.plist" ;;
    harness-string)      python3 "$CHECK" --inject-string "$app/CaptureCat" "--editor-shell" ;;
    probe-seam)          python3 "$CHECK" --inject-string "$app/CaptureCat" "probeForceSnap" ;;
    dev-url)             python3 "$CHECK" --inject-string "$app/PlugIns/CaptureCatShare.appex/CaptureCatShare" "http://localhost:3200" ;;
    test-key)            python3 "$CHECK" --inject-string "$app/PlugIns/CaptureCatBroadcast.appex/CaptureCatBroadcast" "sk_test_51AbCdEfGh" ;;
    drop-privacy-reason) plutil -remove NSPrivacyAccessedAPITypes.0 "$app/PrivacyInfo.xcprivacy" ;;
    missing-manifest)    rm "$app/PlugIns/CaptureCatShare.appex/PrivacyInfo.xcprivacy" ;;
    tracking-on)         plutil -replace NSPrivacyTracking -bool YES "$app/PlugIns/CaptureCatBroadcast.appex/PrivacyInfo.xcprivacy" ;;
    drop-icon)           rm "$app/AppIcon76x76@2x~ipad.png" ;;
    drop-encryption-key) plutil -remove ITSAppUsesNonExemptEncryption "$app/Info.plist" ;;
    version-mismatch)    plutil -replace CFBundleVersion -string "999" "$app/PlugIns/CaptureCatShare.appex/Info.plist" ;;
    weak-ats)            plutil -insert NSAppTransportSecurity.NSAllowsArbitraryLoads -bool YES "$app/Info.plist" ;;
    studiolab-embedded)  mkdir -p "$app/StudioLab.app" && cp "$app/Info.plist" "$app/StudioLab.app/Info.plist" ;;
    dead-entitlement)    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.healthkit bool true" "$e/App.entitlements" ;;
    unused-bgtask)       plutil -insert BGTaskSchedulerPermittedIdentifiers -json '["so.capturecat.ios.nothing"]' "$app/Info.plist" ;;
  esac
}

run_defect() { # <defect> → 0 when the defect was caught by its check
  local d="$1" want
  want="$(expected_for "$d")" || { echo "unknown defect $d" >&2; return 2; }
  local work="$OUT/inject/$d"
  rm -rf "$work"; mkdir -p "$work/ent"
  ditto "$ARCHIVE" "$work/CaptureCat.xcarchive"
  cp "$IOS"/Config/*.entitlements "$work/ent/"
  inject "$d" "$work/CaptureCat.xcarchive" "$work/ent" || { echo "SELFTEST $d FAIL — could not inject"; return 1; }
  local status=0
  ENTITLEMENTS_DIR="$work/ent" python3 "$CHECK" "$work/CaptureCat.xcarchive" "$BUILD_LOG" > "$work/check.log" 2>&1 || status=$?
  rm -rf "$work/CaptureCat.xcarchive"
  if [[ $status -ne 0 ]] && grep -q "^RELEASECHECK $want FAIL" "$work/check.log"; then
    echo "SELFTEST $d PASS — caught: $(grep "^RELEASECHECK $want FAIL" "$work/check.log" | head -1 | cut -c1-200)"
    return 0
  fi
  echo "SELFTEST $d FAIL — $want did not fail (exit $status) · $work/check.log"
  return 1
}

if [[ -n "${INJECT:-}" ]]; then
  if run_defect "$INJECT"; then echo "IOS-RELEASE-CHECK FAIL (injected $INJECT, caught as it must be)"; exit 1; fi
  echo "IOS-RELEASE-CHECK PASS despite injected $INJECT — the gate is BLIND to it"; exit 3
fi

status=0
python3 "$CHECK" "$ARCHIVE" "$BUILD_LOG" | tee "$OUT/check.log" || status=1

if [[ "${SELFTEST:-0}" == 1 ]]; then
  caught=0; total=0
  for d in $DEFECTS; do
    total=$((total + 1))
    if run_defect "$d"; then caught=$((caught + 1)); else status=1; fi
  done
  echo "SELFTEST $caught/$total injected defects caught"
fi

if [[ $status == 0 ]]; then echo "IOS-RELEASE-CHECK PASS · $ARCHIVE"; else echo "IOS-RELEASE-CHECK FAIL · $OUT/check.log"; fi
exit $status
