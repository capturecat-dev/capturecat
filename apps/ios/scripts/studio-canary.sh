#!/usr/bin/env bash
# Studio canary: typecheck the shared studio core against the iOS SDK.
#
# The iOS studio renders through the Mac's own code (docs/ios-studio-plan.md):
# everything under apps/macos/CaptureCat/Studio/ is compiled by the Mac app
# (synchronized folder) and must also compile for iOS. This typechecks that
# folder — and ONLY that folder, so a Studio file that reaches for a Mac-only
# type outside it fails here — with the Mac target's Swift settings (Swift 5
# mode, default MainActor isolation, member import visibility). No app, no
# simulator.
#
# Since Phase 1g the iOS App target compiles the folder too (gen-xcodeproj.py);
# this stays as the fast check, and ios-vectors.sh runs the vectors on iOS.
#
#   apps/ios/scripts/studio-canary.sh            # PASS / FAIL
set -euo pipefail

STUDIO="$(cd "$(dirname "$0")/../../macos/CaptureCat/Studio" && pwd)"
cd "$STUDIO"

files=()
while IFS= read -r f; do files+=("$f"); done < <(find . -name '*.swift' | sort)

out="$(xcrun -sdk iphonesimulator swiftc -typecheck \
  -target arm64-apple-ios26.0-simulator \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  "${files[@]}" 2>&1)" || true

errors="$(printf '%s\n' "$out" | grep -c ' error: ' || true)"
echo "studio canary: ${#files[@]} Studio/ files typechecked for iOS"
if [[ "$errors" != "0" ]]; then
  printf '%s\n' "$out" | grep ' error: ' | sed -E "s#^$STUDIO/##" | head -60
  echo "STUDIO CANARY: FAIL ($errors errors)"
  exit 1
fi
echo "STUDIO CANARY: PASS"
