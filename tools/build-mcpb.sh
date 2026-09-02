#!/bin/sh
# Builds the downloadable CaptureCat MCP bundle (.mcpb) into apps/web/public/.
# A .mcpb is a zip: manifest.json + a launcher that finds the installed app.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apps/web/public/CaptureCat.mcpb"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cat > "$STAGE/capturecat-mcp.sh" <<'SH'
#!/bin/sh
# CaptureCat MCP launcher — finds the app and starts its MCP server.
for BIN in \
  "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat" \
  "$HOME/Applications/CaptureCat.app/Contents/MacOS/CaptureCat"; do
  [ -x "$BIN" ] && exec "$BIN" --mcp
done
APP=$(mdfind 'kMDItemCFBundleIdentifier == "so.capturecat.CaptureCat"' 2>/dev/null | head -1)
[ -n "$APP" ] && [ -x "$APP/Contents/MacOS/CaptureCat" ] && exec "$APP/Contents/MacOS/CaptureCat" --mcp
echo "CaptureCat.app not found — download it from capturecat.so first" >&2
exit 1
SH
chmod 755 "$STAGE/capturecat-mcp.sh"

# The real app icon, so extension lists show the cat instead of a monogram.
cp "$ROOT/apps/macos/CaptureCat/Assets.xcassets/AppIcon.appiconset/icon_256.png" "$STAGE/icon.png"

cat > "$STAGE/manifest.json" <<'JSON'
{
  "manifest_version": "0.2",
  "name": "capturecat",
  "display_name": "CaptureCat",
  "icon": "icon.png",
  "version": "1.0.0",
  "description": "Drive CaptureCat: record the screen, edit recordings (zooms, annotations, styles), see rendered frames, read transcripts, and export — the app's real engine, not a wrapper.",
  "author": { "name": "CaptureCat", "url": "https://capturecat.so" },
  "homepage": "https://capturecat.so/agents",
  "server": {
    "type": "binary",
    "entry_point": "capturecat-mcp.sh",
    "mcp_config": {
      "command": "${__dirname}/capturecat-mcp.sh",
      "args": []
    }
  }
}
JSON

rm -f "$OUT"
/usr/bin/ditto -c -k --sequesterRsrc "$STAGE" "$OUT"
echo "built: $OUT ($(wc -c < "$OUT") bytes)"
