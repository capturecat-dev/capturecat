#!/usr/bin/env bash
set -euo pipefail

# Publishes built DMGs to Cloudflare R2, signs them with Sparkle EdDSA,
# updates latest.json, generates a signed appcast.xml, and tags the git commit.
#
# Version is automatically read from the Xcode project (MARKETING_VERSION).
# Release notes are auto-generated from git commits since the last release tag.
#
# Prerequisites:
#   - Run create_release_dmg.sh first
#   - wrangler CLI authenticated (npx wrangler login)
#   - Sparkle EdDSA key in Keychain (run generate_keys once)
#
# Usage:
#   ./publish_release.sh                          # stable: auto version + auto release notes
#   ./publish_release.sh --beta                   # beta channel: only opted-in updaters see it
#   NOTES="Custom release notes" ./publish_release.sh   # auto version + custom notes
#
# Channels (Sparkle 2 official mechanism): beta releases are published into the
# SAME per-arch appcasts, tagged <sparkle:channel>beta</sparkle:channel> — the
# app only offers them to users who enabled "Beta updates" in Settings. Every
# release (both channels) is appended to releases/index.json, which the API
# serves as the public version history; old DMGs stay downloadable forever at
# /api/releases/<version>/CaptureCat-<arch>.dmg.

CHANNEL="stable"
for arg in "$@"; do
  case "$arg" in
    --beta) CHANNEL="beta" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_DIR/build/release}"
BUCKET="capturecat"
API_BASE="https://api.capturecat.so"
TODAY="$(date +%Y-%m-%d)"
PUB_DATE="$(date -R)"

# ── Read version from Xcode project ──────────────────────────────────────────
XCODE_VERSION=$(xcodebuild -scheme CaptureCat -showBuildSettings 2>/dev/null \
  | grep MARKETING_VERSION | awk '{print $NF}')
XCODE_BUILD=$(xcodebuild -scheme CaptureCat -showBuildSettings 2>/dev/null \
  | grep CURRENT_PROJECT_VERSION | awk '{print $NF}')

if [[ -z "$XCODE_VERSION" ]]; then
  echo "ERROR: Could not read MARKETING_VERSION from Xcode project."
  exit 1
fi

# Normalize version: "1.0" → "1.0.0", "1.1" → "1.1.0"
VERSION="$XCODE_VERSION"
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  VERSION="${VERSION}.0"
fi

BUILD="$XCODE_BUILD"
MIN_OS="${MIN_OS:-14.0}"

echo "==> Version: ${VERSION} (build ${BUILD}) from Xcode project"

# ── Auto-generate release notes from git commits ─────────────────────────────
if [[ -z "${NOTES:-}" ]]; then
  REPO_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)"
  LAST_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")"

  if [[ -n "$LAST_TAG" ]]; then
    echo "    Generating notes from commits since $LAST_TAG..."
    NOTES=$(git -C "$REPO_ROOT" log "${LAST_TAG}..HEAD" --pretty=format:"- %s" \
      --no-merges -- apps/macos/ | head -20)
  else
    echo "    Generating notes from recent commits (no previous tag found)..."
    NOTES=$(git -C "$REPO_ROOT" log --pretty=format:"- %s" \
      --no-merges -20 -- apps/macos/)
  fi

  if [[ -z "$NOTES" ]]; then
    NOTES="Bug fixes and improvements"
  fi
fi

echo ""
echo "    Release notes:"
echo "$NOTES" | sed 's/^/      /'
echo ""

# ── Find Sparkle sign_update tool ────────────────────────────────────────────
SIGN_TOOL="$(find ~/Library/Developer/Xcode/DerivedData/CaptureCat-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name sign_update -maxdepth 1 2>/dev/null | head -1)"
if [[ -z "$SIGN_TOOL" ]]; then
  echo "ERROR: Sparkle sign_update not found. Build the project in Xcode first."
  exit 1
fi

# ── Verify DMGs exist ────────────────────────────────────────────────────────
ARM_DMG="$BUILD_ROOT/CaptureCat-arm64.dmg"
INTEL_DMG="$BUILD_ROOT/CaptureCat-x86_64.dmg"

for f in "$ARM_DMG" "$INTEL_DMG"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: $f not found. Run create_release_dmg.sh first."
    exit 1
  fi
done

# ── Sign DMGs with Sparkle EdDSA ─────────────────────────────────────────────
echo "==> Signing DMGs..."
ARM_SIG_OUTPUT=$("$SIGN_TOOL" "$ARM_DMG")
INTEL_SIG_OUTPUT=$("$SIGN_TOOL" "$INTEL_DMG")

ARM_ED_SIG=$(echo "$ARM_SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ARM_SIZE=$(echo "$ARM_SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
INTEL_ED_SIG=$(echo "$INTEL_SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
INTEL_SIZE=$(echo "$INTEL_SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

echo "    ARM64 signature:  ${ARM_ED_SIG:0:20}..."
echo "    Intel signature:  ${INTEL_ED_SIG:0:20}..."

# ── Upload DMGs to R2 ────────────────────────────────────────────────────────
echo "==> Uploading to R2..."

echo "    Apple Silicon DMG ($(( ARM_SIZE / 1048576 )) MB)..."
npx wrangler r2 object put "${BUCKET}/releases/${VERSION}/CaptureCat-arm64.dmg" \
  --file "$ARM_DMG" \
  --content-type "application/octet-stream" \
  --remote

echo "    Intel DMG ($(( INTEL_SIZE / 1048576 )) MB)..."
npx wrangler r2 object put "${BUCKET}/releases/${VERSION}/CaptureCat-x86_64.dmg" \
  --file "$INTEL_DMG" \
  --content-type "application/octet-stream" \
  --remote

# ── Update the persistent release index ─────────────────────────────────────
# releases/index.json is the source of truth: one entry per published release,
# both channels, newest first. The appcasts below are DERIVED from it, so the
# feed can carry the latest stable item alongside newer beta items.
NOTES_JSON=$(echo "$NOTES" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")

INDEX_TMP="$BUILD_ROOT/index.json"
if ! npx wrangler r2 object get "${BUCKET}/releases/index.json" \
    --file "$INDEX_TMP" --remote 2>/dev/null; then
  echo '{"releases": []}' > "$INDEX_TMP"
fi

python3 - "$INDEX_TMP" <<EOF
import json, sys
path = sys.argv[1]
index = json.load(open(path))
entry = {
    "version": "${VERSION}",
    "build": int("${BUILD}"),
    "channel": "${CHANNEL}",
    "date": "${TODAY}",
    "pubDate": "${PUB_DATE}",
    "minOS": "${MIN_OS}",
    "notes": ${NOTES_JSON},
    "downloads": {
        "arm64": "${API_BASE}/api/releases/${VERSION}/CaptureCat-arm64.dmg",
        "x86_64": "${API_BASE}/api/releases/${VERSION}/CaptureCat-x86_64.dmg",
    },
    "signatures": {
        "arm64": {"edSignature": "${ARM_ED_SIG}", "length": int("${ARM_SIZE}")},
        "x86_64": {"edSignature": "${INTEL_ED_SIG}", "length": int("${INTEL_SIZE}")},
    },
}
# Re-publishing the same build replaces its entry instead of duplicating it.
index["releases"] = [r for r in index.get("releases", []) if r.get("build") != entry["build"]]
index["releases"].append(entry)
index["releases"].sort(key=lambda r: r["build"], reverse=True)
json.dump(index, open(path, "w"), indent=2)
EOF

echo "    index.json (${CHANNEL} ${VERSION})..."
npx wrangler r2 object put "${BUCKET}/releases/index.json" \
  --file "$INDEX_TMP" --content-type "application/json" --remote

# latest.json keeps meaning "latest STABLE" (the website download button);
# betas publish latest-beta.json instead.
LATEST_TMP="$BUILD_ROOT/latest-${CHANNEL}.json"
python3 - "$INDEX_TMP" "$LATEST_TMP" "${CHANNEL}" <<'EOF'
import json, sys
index = json.load(open(sys.argv[1]))
channel = sys.argv[3]
latest = next((r for r in index["releases"] if r["channel"] == channel), None)
if latest is not None:
    json.dump(latest, open(sys.argv[2], "w"), indent=2)
EOF
if [[ "$CHANNEL" == "stable" ]]; then
  echo "    latest.json..."
  npx wrangler r2 object put "${BUCKET}/releases/latest.json" \
    --file "$LATEST_TMP" --content-type "application/json" --remote
else
  echo "    latest-beta.json..."
  npx wrangler r2 object put "${BUCKET}/releases/latest-beta.json" \
    --file "$LATEST_TMP" --content-type "application/json" --remote
fi

# ── Generate signed appcasts from the index ─────────────────────────────────
# One appcast PER ARCHITECTURE (a Sparkle <item> carries a single <enclosure>
# and Sparkle has no architecture predicate; see UpdateFeedDelegate).
#
# Items come from index.json: the latest STABLE release plus every BETA newer
# than it, beta items tagged <sparkle:channel>beta</sparkle:channel>. Stable
# users therefore always keep an eligible item, and opted-in beta users are
# offered whichever is newest for them. Older items are history, not feed.
python3 - "$INDEX_TMP" "$BUILD_ROOT" "$API_BASE" <<'EOF'
import html, json, sys
index_path, build_root, api_base = sys.argv[1], sys.argv[2], sys.argv[3]
releases = json.load(open(index_path))["releases"]  # newest first
stable = next((r for r in releases if r["channel"] == "stable"), None)
items = [r for r in releases if r["channel"] == "beta"
         and (stable is None or r["build"] > stable["build"])]
if stable is not None:
    items.append(stable)

def notes_html(r):
    text = html.escape(r.get("notes", ""))
    return "<br>".join(line.replace("- ", "• ", 1) for line in text.splitlines())

for arch in ("arm64", "x86_64"):
    parts = ['<?xml version="1.0" encoding="utf-8"?>',
             '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">',
             "  <channel>",
             f"    <title>CaptureCat Updates ({arch})</title>",
             f"    <link>{api_base}/api/releases/appcast-{arch}.xml</link>",
             "    <language>en</language>"]
    for r in items:
        sig = r["signatures"][arch]
        beta = r["channel"] == "beta"
        title = f"Version {r['version']}" + (" (Beta)" if beta else "")
        parts += [
            "    <item>",
            f"      <title>{title}</title>",
            f"      <pubDate>{r['pubDate']}</pubDate>",
        ]
        if beta:
            parts.append("      <sparkle:channel>beta</sparkle:channel>")
        parts += [
            f"      <sparkle:version>{r['build']}</sparkle:version>",
            f"      <sparkle:shortVersionString>{r['version']}</sparkle:shortVersionString>",
            f"      <sparkle:minimumSystemVersion>{r['minOS']}</sparkle:minimumSystemVersion>",
            f"      <description><![CDATA[<h2>What's New in {r['version']}</h2><p>{notes_html(r)}</p>]]></description>",
            f'      <enclosure url="{api_base}/api/releases/{r["version"]}/CaptureCat-{arch}.dmg"',
            f'                 sparkle:edSignature="{sig["edSignature"]}"',
            f'                 length="{sig["length"]}"',
            '                 type="application/octet-stream"',
            '                 sparkle:os="macos" />',
            "    </item>",
        ]
    parts += ["  </channel>", "</rss>", ""]
    open(f"{build_root}/appcast-{arch}.xml", "w").write("\n".join(parts))
    print(f"    appcast-{arch}.xml ({len(items)} item(s))")
EOF

for arch in arm64 x86_64; do
  npx wrangler r2 object put "${BUCKET}/releases/appcast-${arch}.xml" \
    --file "$BUILD_ROOT/appcast-${arch}.xml" --content-type "application/xml" --remote
done

# `appcast.xml` stays for anything still pointed at the old URL (Info.plist's
# SUFeedURL fallback). Serve the x86_64 feed there: an Intel Mac cannot run an
# arm64 build at all, whereas an Apple Silicon Mac CAN run x86_64 under Rosetta.
# Defaulting to arm64 hard-breaks Intel; defaulting to x86_64 degrades Apple
# Silicon to a translated build until it picks up the arch-specific feed.
cp "$BUILD_ROOT/appcast-x86_64.xml" "$BUILD_ROOT/appcast.xml"
echo "    appcast.xml (compat -> x86_64)..."
npx wrangler r2 object put "${BUCKET}/releases/appcast.xml" \
  --file "$BUILD_ROOT/appcast.xml" --content-type "application/xml" --remote

# ── Tag the git commit ───────────────────────────────────────────────────────
# Betas tag as v<version>-beta.<build> so the same version can later ship
# stable under the plain v<version> tag without a collision.
TAG="v${VERSION}"
if [[ "$CHANNEL" == "beta" ]]; then
  TAG="v${VERSION}-beta.${BUILD}"
fi
REPO_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)"
if git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
  echo "    Git tag $TAG already exists, skipping."
else
  echo "    Tagging git commit as $TAG..."
  git -C "$REPO_ROOT" tag -a "$TAG" -m "Release ${VERSION} (${CHANNEL})"
  echo "    Don't forget to push the tag: git push origin $TAG"
fi

echo ""
echo "========================================"
echo "  CaptureCat v${VERSION} (build ${BUILD}, ${CHANNEL}) published!"
echo "========================================"
echo ""
echo "  ARM64:   ${API_BASE}/api/releases/${VERSION}/CaptureCat-arm64.dmg"
echo "  x86_64:  ${API_BASE}/api/releases/${VERSION}/CaptureCat-x86_64.dmg"
echo "  Latest:  ${API_BASE}/api/releases/latest"
echo "  Appcast: ${API_BASE}/api/releases/appcast.xml"
echo "  Git tag: v${VERSION}"
echo ""
