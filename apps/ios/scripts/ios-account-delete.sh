#!/usr/bin/env bash
# ios-account-delete.sh — Delete Account (App Store Guideline 5.1.1(v)) end to
# end in the REAL app against the local mock API (Tests/mock_api.py; never
# production, never `wrangler dev`).
#
#   apps/ios/scripts/ios-account-delete.sh            the gate (must PASS)
#   INJECT=skip-wipe apps/ios/scripts/ios-account-delete.sh     must FAIL
#   INJECT=skip-signout apps/ios/scripts/ios-account-delete.sh  must FAIL
#
# The app is launched with `-apiBaseURL http://127.0.0.1:<port>
# -accountDeleteGate` (App/Fixtures/AccountDeleteGate.swift): the live stack in
# the real shell + window — Account screen entry reachable (hit-tested), the
# confirmation sheet sampled MID-FLIGHT (and the same check failing on an
# injected snap), the copy, DELETE typed to enable, 409 / 502 / dropped
# connection refusals (server text inline, still signed in, nothing wiped),
# then success: the DELETE reached the mock with the live bearer, the app is on
# the sign-in screen, the session + link key are gone and every seeded local
# file (studio projects, inbox, library caches, exports) is wiped; a retry with
# the dead token (401) counts as deleted.
#
# Env: DEVICE=<udid>   default: "Studio 6c iPhone" (3652CFA0-50A5-4ED8-8CA9-F59933178BA8)
#      OUT=<dir>       default: $TMPDIR/capturecat-ios-account-delete
#      INJECT=skip-wipe|skip-signout   a defect in the shipping path — must FAIL
#      SKIP_BUILD=1    reuse $OUT/dd's build
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-3652CFA0-50A5-4ED8-8CA9-F59933178BA8}"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-account-delete}"
BUNDLE=so.capturecat.ios
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-account-delete: building CaptureCat (Debug, simulator)"
  xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$OUT/dd" \
    ${CLONED_PACKAGES:+-clonedSourcePackagesDirPath "$CLONED_PACKAGES"} \
    build > "$OUT/build.log" 2>&1 \
    || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-ACCOUNT-DELETE FAIL (build)"; exit 1; }
fi
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/CaptureCat.app"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$IOS/Tests/mock_api.py" "$PORT" 2>"$OUT/mock.log" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/__session" >/dev/null && break; sleep 0.1; done

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$APP"

RUN="$OUT/run${INJECT:+-$INJECT}"
rm -rf "$RUN" && mkdir -p "$RUN"
echo "ios-account-delete: running on $DEVICE${INJECT:+ (inject $INJECT — must FAIL)}"
args=(-apiBaseURL "http://127.0.0.1:$PORT" -accountDeleteGate)
[[ -n "${INJECT:-}" ]] && args+=(-accountDeleteInject "$INJECT")
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE" "${args[@]}" > "$RUN/run.log" 2>&1 &
pid=$!
for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
  echo "ios-account-delete: timed out" >&2
fi
wait "$pid" || true

# Screens for review notes (account.png, confirm.png, signed-out.png).
container="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null || true)"
[[ -n "$container" && -d "$container/Documents/account-delete" ]] && cp "$container/Documents/account-delete/"*.png "$RUN/" 2>/dev/null || true

grep -E '^ACCOUNTDELETE' "$RUN/run.log" || tail -30 "$RUN/run.log"
echo "ios-account-delete: log $RUN/run.log · screens $RUN/*.png · mock $OUT/mock.log"
if grep -q '^ACCOUNTDELETE-GATE PASS' "$RUN/run.log"; then
  if [[ -n "${INJECT:-}" ]]; then echo "IOS-ACCOUNT-DELETE PASS (inject $INJECT — the defect went unnoticed)"; exit 0; fi
  echo "IOS-ACCOUNT-DELETE PASS"; exit 0
fi
echo "IOS-ACCOUNT-DELETE FAIL${INJECT:+ (inject $INJECT)}"
exit 1
