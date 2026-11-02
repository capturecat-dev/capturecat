#!/usr/bin/env bash
set -euo pipefail

# Package one .app into the drag-to-install DMG: CaptureCat on the left,
# an Applications link on the right, over the "recording in progress"
# background (dmg-resources/make-background.swift renders it; regenerate the
# two PNGs with `swift dmg-resources/make-background.swift dmg-resources`).
#
# Usage:
#   ./make_dmg.sh <path/to/CaptureCat.app> <out.dmg> [signing identity]
#
# appdmg is pinned (it writes the window layout straight into .DS_Store, no
# Finder automation needed). Icon centres must match make-background.swift.

APP_PATH="${1:?usage: make_dmg.sh <app> <out.dmg> [identity]}"
DMG_PATH="${2:?usage: make_dmg.sh <app> <out.dmg> [identity]}"
IDENTITY="${3:-}"
RESOURCES="$(cd "$(dirname "$0")" && pwd)/dmg-resources"
APPDMG_VERSION="0.6.6"

[[ -d "$APP_PATH" ]] || { echo "ERROR: no app at $APP_PATH"; exit 1; }
for f in background.png background@2x.png; do
  [[ -f "$RESOURCES/$f" ]] || { echo "ERROR: missing $RESOURCES/$f"; exit 1; }
done

SPEC="$(mktemp -t capturecat-appdmg).json"
trap 'rm -f "$SPEC"' EXIT

VOLUME_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
python3 - "$SPEC" "$APP_PATH" "$RESOURCES" "$VOLUME_ICON" "$IDENTITY" <<'PY'
import json, os, sys
spec_path, app, resources, icon, identity = sys.argv[1:6]
spec = {
    "title": "Install CaptureCat",
    "background": os.path.join(resources, "background.png"),  # background@2x.png is picked up beside it
    "icon-size": 128,
    "window": {"size": {"width": 720, "height": 460}},
    "contents": [
        {"x": 220, "y": 226, "type": "file", "path": app},
        {"x": 500, "y": 226, "type": "link", "path": "/Applications"},
    ],
}
if os.path.isfile(icon):
    spec["icon"] = icon
if identity:
    spec["code-sign"] = {"signing-identity": identity}
json.dump(spec, open(spec_path, "w"), indent=2)
PY

rm -f "$DMG_PATH"
npx --yes "appdmg@${APPDMG_VERSION}" "$SPEC" "$DMG_PATH"
echo "DMG: $DMG_PATH"
