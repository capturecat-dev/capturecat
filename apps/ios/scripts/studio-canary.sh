#!/usr/bin/env bash
# Studio canary: typecheck the Mac studio core against the iOS SDK.
#
# The iOS studio renders through the Mac's own code (docs/ios-studio-plan.md),
# so every file the core is made of must compile for iOS. This typechecks the
# extracted set — no app, no simulator — with the Mac target's Swift settings
# (Swift 5 mode, default MainActor isolation, member import visibility).
#
# Phase 1 grows the set slice by slice; Phase 1g replaces this with the iOS
# App target compiling apps/macos/CaptureCat/Studio/ directly.
#
#   apps/ios/scripts/studio-canary.sh            # PASS / FAIL
set -euo pipefail

MAC="$(cd "$(dirname "$0")/../../macos/CaptureCat" && pwd)"
cd "$MAC"

# Pure dependencies of the models that live elsewhere today; they move into
# Studio/ with the rest of the core in Phase 1f.
DEPS=(
  Services/OklabGradient.swift          # SRGBA (CodableColor.srgba)
  Services/FocusMath.swift              # FocusRegion
  Services/CurtainUnveilMath.swift      # CurtainUnveilCorner (ProjectSettings)
  Services/ContinuousRoundedRect.swift  # used by CurtainUnveilMath
  Services/IntroSlideMath.swift         # IntroSlideStyle (ProjectSettings)
  Services/StillMovieWriter.swift       # Project (still captures)
  Services/ClickSoundPlayer.swift       # ClickSoundStyle (ProjectSettings)
  Services/KeySoundPlayer.swift         # KeySoundStyle (ProjectSettings)
)

# Mac-only files inside otherwise-shared folders.
EXCLUDE='^(Models/CaptureSource|Models/SubtitlePreset|Extensions/CodableColor\+AppKit)\.swift$'

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  { ls Studio/Platform/*.swift Models/*.swift Extensions/*.swift
    printf '%s\n' "${DEPS[@]}"
  } | grep -v '^$' | grep -vE "$EXCLUDE" | sort -u)

out="$(xcrun -sdk iphonesimulator swiftc -typecheck \
  -target arm64-apple-ios26.0-simulator \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  "${files[@]}" 2>&1)" || true

errors="$(printf '%s\n' "$out" | grep -c ' error: ' || true)"
echo "studio canary: ${#files[@]} files typechecked for iOS"
if [[ "$errors" != "0" ]]; then
  printf '%s\n' "$out" | grep ' error: ' | sed -E "s#^$MAC/##" | head -60
  echo "STUDIO CANARY: FAIL ($errors errors)"
  exit 1
fi
echo "STUDIO CANARY: PASS"
