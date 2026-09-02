#!/usr/bin/env bash
set -euo pipefail

# Runs every headless verification gate against the built app.
#
# These are the checks CLAUDE.md §3 describes: they score renderers against
# frozen references and assert structural and motion properties that a settled
# screenshot cannot see. They only mean anything if they actually run, which is
# why this exists as `turbo test` rather than something to remember by hand.
#
# Each gate exits non-zero on failure, but several also print PASS/FAIL lines
# for individual checks, so the exit code alone is not the whole story — the
# summary at the bottom counts what failed.

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-CaptureCat}"
CONFIG="${CONFIGURATION:-Debug}"

APP="$(xcodebuild -project CaptureCat.xcodeproj -scheme "$SCHEME" \
        -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/${SCHEME}.app"
BIN="$APP/Contents/MacOS/$SCHEME"

if [[ ! -x "$BIN" ]]; then
  echo "No built binary at $BIN — run 'npm run build' in apps/macos first." >&2
  exit 1
fi

GATES=(
  --auth-selftest
  --preview-parity
  --videotrack-math-test
  --voicetrack-test
  --keysound-test
  --playback-observer-test
  --raster-golden
  --editor-shell-shot
  --inspector-probe
  --recording-panel-shot
)

failed=0
for gate in "${GATES[@]}"; do
  printf '%-28s ' "$gate"
  if out="$("$BIN" "$gate" 2>&1)"; then
    # A zero exit is necessary but not sufficient: some gates report per-check
    # FAIL lines and still exit 0, so look for them explicitly.
    if grep -qE '(^|[[:space:]])FAIL' <<<"$out"; then
      echo "FAIL"
      grep -E '(^|[[:space:]])FAIL' <<<"$out" | head -5 | sed 's/^/    /'
      failed=$((failed + 1))
    else
      grep -oE '([0-9]+/[0-9]+ checks passed|PARITY PASS|RASTER-GOLDEN OK|PASS[^|]*)' <<<"$out" \
        | tail -1 || echo "ok"
    fi
  else
    echo "ERROR (exit $?)"
    tail -5 <<<"$out" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
done

echo
if (( failed )); then
  echo "$failed gate(s) failed."
  exit 1
fi
echo "All ${#GATES[@]} gates passed."
