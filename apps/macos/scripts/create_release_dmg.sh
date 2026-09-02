#!/usr/bin/env bash
set -euo pipefail

# Build, code sign, notarize, and package DMGs for arm64 and x86_64.
#
# Prerequisites:
#   - "Developer ID Application" certificate in Keychain
#   - Notarization credentials stored: xcrun notarytool store-credentials "CaptureCat"
#
# Usage:
#   ./create_release_dmg.sh              # builds both architectures
#   ARCH=arm64 ./create_release_dmg.sh   # build only Apple Silicon

SCHEME="${SCHEME:-CaptureCat}"
PRODUCT_NAME="${PRODUCT_NAME:-CaptureCat}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/release}"
SIGNING_IDENTITY="Developer ID Application: Michael Garland (E52HU87CX9)"
NOTARY_PROFILE="CaptureCat"

build_dmg_for_arch() {
  local arch="$1"
  local label="$2"
  local archive_path="$BUILD_ROOT/${PRODUCT_NAME}-${arch}.xcarchive"
  local app_dir="$BUILD_ROOT/app-${arch}"
  local app_path="$app_dir/$PRODUCT_NAME.app"
  local dmg_path="$BUILD_ROOT/${PRODUCT_NAME}-${arch}.dmg"

  echo "==> Building $label ($arch)..."
  xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    clean archive

  rm -rf "$app_dir"
  mkdir -p "$app_dir"
  cp -R "$archive_path/Products/Applications/$PRODUCT_NAME.app" "$app_path"

  # Verify architecture
  local binary_path="$app_path/Contents/MacOS/$PRODUCT_NAME"
  local built_archs
  built_archs="$(lipo -archs "$binary_path")"
  echo "    Binary architectures: $built_archs"

  if [[ "$built_archs" != *"$arch"* ]]; then
    echo "ERROR: binary does not contain $arch"
    exit 1
  fi

  # ── Code sign with Developer ID ──────────────────────────────────────────
  echo "    Code signing with Developer ID..."
  codesign --deep --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$app_path"

  # Verify signing
  codesign --verify --verbose "$app_path" 2>&1 | tail -1
  echo "    Code signing verified."

  # ── Create DMG ──────────────────────────────────────────────────────────
  echo "    Creating DMG..."
  rm -f "$dmg_path"

  npx create-dmg@latest \
    --overwrite \
    --identity "$SIGNING_IDENTITY" \
    --no-version-in-filename \
    --dmg-title "$PRODUCT_NAME" \
    "$app_path" \
    "$BUILD_ROOT/"

  # Rename to arch-specific filename
  local generated_dmg="$BUILD_ROOT/${PRODUCT_NAME}.dmg"
  if [[ -f "$generated_dmg" ]]; then
    mv "$generated_dmg" "$dmg_path"
  else
    local found_dmg
    found_dmg="$(ls -t "$BUILD_ROOT"/${PRODUCT_NAME}*.dmg 2>/dev/null | head -1)"
    if [[ -n "$found_dmg" && "$found_dmg" != "$dmg_path" ]]; then
      mv "$found_dmg" "$dmg_path"
    fi
  fi

  # ── Notarize ─────────────────────────────────────────────────────────────
  echo "    Submitting for notarization (this takes 2-5 minutes)..."
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  # Staple the notarization ticket to the DMG
  echo "    Stapling notarization ticket..."
  xcrun stapler staple "$dmg_path"

  echo "    Done: $dmg_path (signed + notarized)"
}

mkdir -p "$BUILD_ROOT"

if [[ -n "${ARCH:-}" ]]; then
  case "$ARCH" in
    arm64) build_dmg_for_arch "arm64" "Apple Silicon" ;;
    x86_64) build_dmg_for_arch "x86_64" "Intel" ;;
    *) echo "ERROR: ARCH must be arm64 or x86_64"; exit 1 ;;
  esac
else
  build_dmg_for_arch "arm64" "Apple Silicon"
  build_dmg_for_arch "x86_64" "Intel"
fi

echo ""
echo "==> Release DMGs ready in $BUILD_ROOT (signed + notarized)"
ls -lh "$BUILD_ROOT"/*.dmg
