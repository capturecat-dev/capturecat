#!/bin/sh
# Regenerate the WebMCP catalog from the Mac app's MCP server so browser and
# desktop agents always see identical tools, schemas and playbook.
#
#   apps/web/scripts/sync-mcp-catalog.sh
#
# Builds nothing: run a Debug build of the Mac app first. Resolves the binary
# through xcodebuild (never a DerivedData glob — several CaptureCat-* dirs exist).
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PRODUCTS="$(xcodebuild -project "$ROOT/apps/macos/CaptureCat.xcodeproj" -scheme CaptureCat \
  -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
BIN="$PRODUCTS/CaptureCat.app/Contents/MacOS/CaptureCat"
[ -x "$BIN" ] || { echo "Build the Mac app first (missing $BIN)" >&2; exit 1; }
OUT="$("$BIN" --mcp-catalog-json | awk '/^MCP-CATALOG /{print $2}')"
cp "$OUT" "$ROOT/apps/web/src/editor/webmcp/catalog.generated.json"
echo "synced $(basename "$OUT") -> apps/web/src/editor/webmcp/catalog.generated.json"
