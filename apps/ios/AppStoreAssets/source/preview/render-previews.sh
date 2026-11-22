#!/usr/bin/env bash
# render-previews.sh <iphone|ipad> [locale…] — one localized preview per locale
# (each from its own take in footage/<locale>/), strictly one after another:
# a lock stops a second runner (two runners shared work folders and hung),
# and each locale gets TIMEOUT seconds (default 900) before its whole process
# tree is killed and the run fails, so a hang fails fast.
set -uo pipefail
cd "$(dirname "$0")"
DEVICE="$1"; shift
LOCALES="${*:-en-GB en-US de-DE fr-FR es-ES es-MX it pt-BR nl-NL ja ko zh-Hans}"
TIMEOUT="${TIMEOUT:-900}"
LOCK="../build/preview/.render.lock"
mkdir -p ../build/preview
if ! mkdir "$LOCK" 2>/dev/null; then echo "another render-previews.sh is running ($LOCK)"; exit 2; fi
trap 'rm -rf "$LOCK"' EXIT

killtree() { local p; for p in $(pgrep -P "$1"); do killtree "$p"; done; kill -9 "$1" 2>/dev/null; }

render_one() {  # render_one <locale> → 0 ok, 1 failed, 124 timed out
  local log="../build/preview/$DEVICE-$1.log"
  node render.mjs --device "$DEVICE" --locale "$1" > "$log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
    if (( waited >= TIMEOUT )); then killtree "$pid"; echo "TIMEOUT $DEVICE $1 after ${TIMEOUT}s (log: $log)"; return 124; fi
  done
  wait "$pid"; local rc=$?
  tr '\r' '\n' < "$log" | grep -v '^base ' | grep -E "late shots|: out/|done in|failed" | sed "s/^/  /"
  return $rc
}

for l in $LOCALES; do
  echo "== $DEVICE $l"
  render_one "$l" || { echo "retrying $DEVICE $l"; render_one "$l"; } || { echo "FAILED $DEVICE $l"; exit 1; }
done
echo "ALL DONE $DEVICE"
