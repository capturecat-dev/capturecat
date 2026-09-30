#!/usr/bin/env bash
# Regenerates the committed project-merge golden files from the REAL Swift
# (apps/macos/CaptureCat/Services/ProjectHistory) and proves every merged
# output opens on the Mac.
#
#   apps/web/scripts/merge-vectors.sh [<path to the CaptureCat binary>]
#
# 1. stages apps/web/src/editor/core/merge/fixtures/*.json into the app's
#    sandbox container tmp (the sandboxed binary cannot read the repo);
# 2. `CaptureCat --web-vectors <tmp> --only mergePolicy,mergeRandom,projectMerge
#    --merge-fixtures <staged>` — the Swift twin merges/diffs/summarizes every
#    fixture, decodes every merged output with the real Project Codable, and
#    fails on any identity-property violation;
# 3. copies mergePolicy.json, mergeRandom.json and projectMerge.json into
#    apps/web/src/editor/core/merge/golden/ (one case per line);
# 4. exports the TS merges web-serialized (mergeRoundtrip.test.ts) and runs
#    `CaptureCat --web-roundtrip-check` on each variant.
#
# Without an argument the binary is the Debug build's BUILT_PRODUCTS_DIR
# (agent worktrees each have their own DerivedData — never guess the path).
set -euo pipefail
web="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-}"
if [ -z "$bin" ]; then
  products="$(cd "$web/../macos" && xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')"
  bin="$products/CaptureCat.app/Contents/MacOS/CaptureCat"
fi
if [ ! -x "$bin" ]; then
  echo "merge-vectors: no binary at $bin — build apps/macos (Debug) first" >&2
  exit 1
fi

container_tmp="$HOME/Library/Containers/so.capturecat.CaptureCat/Data/tmp"
stage="$container_tmp/capturecat-merge-fixtures-$$"
vectors="$container_tmp/capturecat-web-vectors-merge-$$"
roundtrip="$container_tmp/capturecat-merge-roundtrip-$$"
cleanup() { rm -rf "$stage" "$vectors" "$roundtrip"; }
trap cleanup EXIT
mkdir -p "$stage" "$vectors"
cp "$web"/src/editor/core/merge/fixtures/*.json "$stage/"

"$bin" --web-vectors "$vectors" --only mergePolicy,mergeRandom,projectMerge --merge-fixtures "$stage"

golden="$web/src/editor/core/merge/golden"
mkdir -p "$golden"
for unit in mergePolicy mergeRandom projectMerge; do
  node -e '
    const fs = require("fs");
    const [src, dest] = process.argv.slice(1);
    const f = JSON.parse(fs.readFileSync(src, "utf8"));
    const head = JSON.stringify({ unit: f.unit, notes: f.notes, count: f.count });
    const cases = f.cases.map((c) => "  " + JSON.stringify(c)).join(",\n");
    fs.writeFileSync(dest, head.slice(0, -1) + ",\"cases\":[\n" + cases + "\n]}\n");
  ' "$vectors/$unit.json" "$golden/$unit.json"
done
echo "merge-vectors: golden written to $golden"

(cd "$web" && CC_MERGE_ROUNDTRIP_OUT="$roundtrip" npx vitest run src/editor/core/merge/mergeRoundtrip.test.ts >/dev/null)
status=0
for variant in default flipped reversed; do
  "$bin" --web-roundtrip-check "$roundtrip/$variant/web" --against "$roundtrip/$variant/originals" \
    > "$roundtrip/$variant.log" || status=1
  echo "merge-vectors: $variant: $(tail -1 "$roundtrip/$variant.log")"
  [ "$status" -eq 0 ] || grep -v " OK " "$roundtrip/$variant.log" | head -20
done
exit "$status"
