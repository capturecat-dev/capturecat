#!/usr/bin/env bash
set -euo pipefail

# One-command release: gates → build both arches → sign/notarize → DMGs → R2.
#
#   ./release.sh              # stable release
#   ./release.sh --beta       # beta channel (only opted-in updaters see it)
#   SKIP_GATES=1 ./release.sh # emergencies only
#
# Version comes from MARKETING_VERSION in the Xcode project; bump it there
# first. Everything else — arm64 + x86_64 archives, codesign, notarization,
# Sparkle EdDSA signing, R2 upload, appcasts, index.json, git tag — is
# automatic (see create_release_dmg.sh and publish_release.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${SKIP_GATES:-}" != "1" ]]; then
  echo "==> Running verification gates..."
  "$SCRIPT_DIR/run-gates.sh"
fi

echo "==> Building, signing, notarizing both architectures..."
"$SCRIPT_DIR/create_release_dmg.sh"

echo "==> Publishing to R2..."
"$SCRIPT_DIR/publish_release.sh" "$@"
