#!/usr/bin/env bash
# ios-archive: the App Store archive of CaptureCat for iPhone and iPad, built
# and exported LOCALLY (Studio 6c, docs/ios-app-store.md "Shipping a build").
#
#   apps/ios/scripts/ios-archive.sh
#   MARKETING_VERSION=1.1 BUILD=7 apps/ios/scripts/ios-archive.sh
#
# 1. xcodebuild archive — Release, generic iOS, automatic signing with the
#    team in gen-xcodeproj.py, using the certificates and profiles ALREADY on
#    this Mac.
# 2. ios-release-check.py over that signed archive.
# 3. xcodebuild -exportArchive with Config/ExportOptions-AppStore.plist
#    (method app-store-connect, destination EXPORT): an .ipa on disk.
#
# By default it never talks to Apple: no -allowProvisioningUpdates (that flag
# lets xcodebuild create certificates / profiles / App IDs on the developer
# portal) unless the OWNER opts in below, and never an upload, altool,
# notarytool or Transporter. Uploading the .ipa is the owner's step (Xcode
# Organizer → Distribute, or Transporter).
#
# Env: OUT=<dir> (default $TMPDIR/capturecat-ios-archive)
#      MARKETING_VERSION / BUILD  override the generator's version + build
#      ALLOW_PROVISIONING_UPDATES=1  OWNER ONLY: lets the export create the
#        Apple Distribution certificate + App Store profiles on the developer
#        portal (this contacts Apple). Agents never set it.
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-archive}"
ARCHIVE="$OUT/CaptureCat.xcarchive"
EXPORT="$OUT/export"
mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT"

overrides=()
[[ -n "${MARKETING_VERSION:-}" ]] && overrides+=("MARKETING_VERSION=$MARKETING_VERSION")
[[ -n "${BUILD:-}" ]] && overrides+=("CURRENT_PROJECT_VERSION=$BUILD")

echo "ios-archive: archiving (Release, generic iOS, automatic signing) → $ARCHIVE"
if ! xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$OUT/dd" -archivePath "$ARCHIVE" \
    ${overrides[@]+"${overrides[@]}"} archive > "$OUT/archive.log" 2>&1; then
  grep -E 'error:' "$OUT/archive.log" | sort -u | head -20
  echo "IOS-ARCHIVE FAIL (archive) · $OUT/archive.log"
  exit 1
fi
app="$ARCHIVE/Products/Applications/CaptureCat.app"
echo "ios-archive: signed with: $(codesign -dvv "$app" 2>&1 | grep -m1 '^Authority=' | sed 's/Authority=//')"
echo "ios-archive: version $(plutil -extract CFBundleShortVersionString raw "$app/Info.plist") ($(plutil -extract CFBundleVersion raw "$app/Info.plist"))"

echo "ios-archive: release check on the signed archive"
ARCHIVE="$ARCHIVE" BUILD_LOG="$OUT/archive.log" OUT="$OUT/check" "$IOS/scripts/ios-release-check.sh" | tail -3 || {
  echo "IOS-ARCHIVE FAIL (release check) · $OUT/check/check.log"; exit 1; }

echo "ios-archive: exporting for App Store distribution (destination: export — no upload)"
provisioning=()
[[ "${ALLOW_PROVISIONING_UPDATES:-0}" == 1 ]] && provisioning=(-allowProvisioningUpdates)
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$IOS/Config/ExportOptions-AppStore.plist" ${provisioning[@]+"${provisioning[@]}"} > "$OUT/export.log" 2>&1; then
  grep -E 'error:|Error Domain|No (signing|profiles)|requires a provisioning profile' "$OUT/export.log" | sort -u | head -12
  echo "IOS-ARCHIVE PARTIAL — archive OK, export needs App Store signing this Mac doesn't have (docs/ios-app-store.md \"Shipping a build\") · $OUT/export.log"
  exit 2
fi
ipa="$(ls "$EXPORT"/*.ipa)"
echo "ios-archive: exported $ipa ($(du -h "$ipa" | cut -f1))"
work="$OUT/ipa"; rm -rf "$work"; mkdir -p "$work"; ditto -x -k "$ipa" "$work"
aps="$(codesign -d --entitlements :- "$work/Payload/CaptureCat.app" 2>/dev/null | plutil -extract aps-environment raw - 2>/dev/null || echo missing)"
echo "ios-archive: exported aps-environment = $aps (must be production)"
[[ "$aps" == production ]] || { echo "IOS-ARCHIVE FAIL (exported entitlements)"; exit 1; }
echo "IOS-ARCHIVE PASS · $ipa"
