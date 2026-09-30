#!/usr/bin/env bash
# Copies render-parity fixtures written by `CaptureCat --web-parity-fixtures <dir>`
# into the gitignored apps/web/.fixtures/parity/.
#
#   apps/web/scripts/sync-parity-fixtures.sh [<dir printed by --web-parity-fixtures>]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$HOME/Library/Containers/so.capturecat.CaptureCat/Data/tmp/capturecat-web-parity}"
dest="$here/.fixtures/parity"
if [ ! -f "$src/manifest.json" ]; then
  echo "sync-parity-fixtures: no manifest.json at $src — run CaptureCat --web-parity-fixtures <dir> first" >&2
  exit 1
fi
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
echo "sync-parity-fixtures: synced $src -> $dest"
