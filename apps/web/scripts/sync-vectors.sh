#!/usr/bin/env bash
# Copies golden vectors written by `CaptureCat --web-vectors <dir>` into the
# gitignored apps/web/.fixtures/vectors/ where the vitest suites read them.
#
#   apps/web/scripts/sync-vectors.sh [<dir printed by --web-vectors>]
#
# With no argument it uses the sandbox container's default fallback dir
# (the app is sandboxed, so an unwritable <dir> lands there).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$HOME/Library/Containers/so.capturecat.CaptureCat/Data/tmp/capturecat-web-vectors}"
dest="$here/.fixtures/vectors"
if [ ! -d "$src" ]; then
  echo "sync-vectors: no vectors at $src — run CaptureCat --web-vectors <dir> first" >&2
  exit 1
fi
shopt -s nullglob
files=("$src"/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "sync-vectors: $src contains no .json vectors" >&2
  exit 1
fi
mkdir -p "$dest"
cp "${files[@]}" "$dest/"
echo "sync-vectors: copied ${#files[@]} unit(s) from $src -> $dest"
