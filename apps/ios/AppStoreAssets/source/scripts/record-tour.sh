#!/usr/bin/env bash
# record-tour.sh <udid> <name>
# (--mask=black: the screen corners / Dynamic Island come out black and preview/unmask.py
# paints them from their neighbours, as in the Strobia pipeline.)
# Records the app's scripted store tour (-uiStoreTour, App/Fixtures/StoreCreative.swift)
# with `simctl io recordVideo` and logs each STORETOUR step with its time from
# the start of the recording (source/footage/<name>.mov + <name>.steps.txt).
set -euo pipefail
UDID="$1"; NAME="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$(dirname "$0")/locale-args.sh"
OUT="$HERE/footage/$LOCALE"; mkdir -p "$OUT"   # LOCALE=<store locale> (default en-GB)
APP=so.capturecat.ios
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
# Fresh caches for this language (the fixture bakes project names into them).
DATA="$(xcrun simctl get_app_container "$UDID" "$APP" data)"
rm -rf "$DATA/Library/Caches/"* "$DATA/Library/Application Support/Studio" 2>/dev/null || true
# Warm the editor's movie cache so the tour isn't waiting on it.
xcrun simctl launch "$UDID" "$APP" -uiFixtures -uiFixtureNoInbox -uiStoreEditor zoom -uiStoreLocalizedContent "${LANG_ARGS[@]}" > /dev/null
sleep 16
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
# Start on the home screen? No: launch, then start recording once the library is up.
rm -f "$OUT/$NAME.mov"
xcrun simctl io "$UDID" recordVideo --codec h264 --mask=black --force "$OUT/$NAME.mov" > "$OUT/$NAME.rec.log" 2>&1 &
REC=$!
sleep 2.0
T0=$(python3 -c 'import time;print(time.time())')
xcrun simctl launch --console-pty "$UDID" "$APP" -uiFixtures -uiFixtureNoInbox -uiStoreAspect 4:3 -uiStoreTour -uiStoreLocalizedContent "${LANG_ARGS[@]}" > "$OUT/$NAME.console.log" 2>&1 &
LAUNCH=$!
: > "$OUT/$NAME.steps.txt"
python3 -u - "$T0" "$OUT/$NAME.console.log" "$OUT/$NAME.steps.txt" <<'PY'
import sys, time
t0, log, steps = float(sys.argv[1]), sys.argv[2], sys.argv[3]
seen = 0
deadline = time.time() + 400
while time.time() < deadline:
    lines = open(log, errors="replace").read().splitlines()
    for line in lines[seen:]:
        if "STORETOUR" in line:
            entry = "%.2f %s" % (time.time() - t0, line.strip())
            print(entry, flush=True)
            open(steps, "a").write(entry + "\n")
    seen = len(lines)
    if any("STORETOUR end" in l or "FAIL" in l for l in lines):
        break
    time.sleep(0.05)
PY
sleep 0.5
kill -INT $REC; wait $REC || true
kill $LAUNCH 2>/dev/null || true
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null || true
echo "recorded $OUT/$NAME.mov (recording started ~2.0 s before launch; step times are from launch)"
