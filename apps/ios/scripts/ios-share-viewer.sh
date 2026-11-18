#!/usr/bin/env bash
# ios-share-viewer.sh — the in-app share viewer (App/ShareViewer) end to end in
# the REAL app against the local mock API (Tests/mock_api.py; never production).
#
#   apps/ios/scripts/ios-share-viewer.sh                 the gate (must PASS)
#   INJECT=marker-offset|no-rollback|seek-ignored|drop-token|snap|no-landscape|
#          annotation-marker-offset|drawing-box-rect|drawing-ignores-fill|
#          serializer-drift|toggle-no-rollback  ...                              must FAIL
#   SELFTEST=1 apps/ios/scripts/ios-share-viewer.sh      the gate, then every
#                                                        injected defect (each must FAIL)
#
# What runs:
#  1. Seeds public shares in the mock (an ffmpeg test video): open (comments,
#     reactions, AI title / summary / chapters, transcript), password, expired,
#     view limit, paused, private, the signed-in user's own private, removed,
#     comments off.
#  2. In-app gate (`-shareViewerGate`, App/Fixtures/ShareViewerGate.swift):
#     universal link + custom scheme through the real SceneDelegate entry
#     points (WARM), playback, markers at the right x, chip / marker seeks,
#     reactions (optimistic, rollback, toggle), signed-out comment, sign-in
#     prompt, signed-in reply, tabs, captions, every state, motion sampled
#     mid-flight, Reduce Motion, the accessibility audit (default + XXXL);
#     the owner's annotation markers (ranges ±1 pt, pills, Summary rows, tap
#     snaps to a range start), a seeded comment DRAWING on the picture's real
#     pixels in portrait, landscape fit and landscape fill (captures diffed),
#     drawing → posting a comment, and the share-detail "Allow comments"
#     switch (optimistic, rolled back + toast on a 500, plan-gated).
#     When it prints `await-openurl <url>` this script fires a REAL
#     `xcrun simctl openurl` at the running app; `await-shot <name>` takes a
#     REAL simulator screenshot ($RUN/<name>.png — video pixels included).
#  2b. The drawing the gate made, through the WEB's serializer
#     (Tests/share_annotation_web.mjs → apps/web/src/lib/share/annotation.ts):
#     the comment the app POSTed must carry exactly those bytes.
#  3. COLD launches (no harness in the process; observed through the app's
#     DEBUG route log + the mock's request log + a screenshot):
#       custom scheme — app terminated, `simctl openurl capturecat://share/<id>`
#       universal link — `-shareViewerColdLink https://capturecat.so/share/<id>`:
#       the SAME NSUserActivity iOS delivers in the scene's connection options.
#     Real universal links can't reach a Simulator build until
#     apps/web/public/.well-known/apple-app-site-association is live on
#     capturecat.so, so that one leg is injected (a DEBUG seam), not tapped.
#
# Env: DEVICE=<udid>  default: "Studio Share iPhone" (27F23664-B41A-4E75-AB26-5D93AD096F4D)
#      OUT=<dir>      default: $TMPDIR/capturecat-ios-share-viewer
#      SKIP_BUILD=1   reuse $OUT/dd's build
# A fresh simulator asks "Open in “CaptureCat”?" the FIRST time any app opens
# the capturecat:// scheme; accept it once (the choice is remembered).
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-27F23664-B41A-4E75-AB26-5D93AD096F4D}"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-share-viewer}"
BUNDLE=so.capturecat.ios
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ "${SELFTEST:-}" == "1" ]]; then
  SELFTEST= "$0" || { echo "IOS-SHARE-VIEWER SELFTEST FAIL (the gate itself failed)"; exit 1; }
  blind=()
  injects=(marker-offset no-rollback seek-ignored drop-token snap no-landscape
           annotation-marker-offset drawing-box-rect drawing-ignores-fill serializer-drift toggle-no-rollback)
  for inject in "${injects[@]}"; do
    if SELFTEST= SKIP_BUILD=1 INJECT=$inject "$0" > "$OUT/selftest-$inject.log" 2>&1; then
      blind+=("$inject")
      echo "ios-share-viewer: inject $inject — gate PASSED (blind)"
    else
      echo "ios-share-viewer: inject $inject — gate FAILED as it must: $(grep -E '^SHAREVIEWER .* FAIL' "$OUT/selftest-$inject.log" | head -3 | cut -c1-160 | tr '\n' ' ')"
    fi
  done
  [[ ${#blind[@]} -eq 0 ]] && { echo "IOS-SHARE-VIEWER SELFTEST PASS (${#injects[@]}/${#injects[@]} injected defects caught)"; exit 0; }
  echo "IOS-SHARE-VIEWER SELFTEST FAIL (blind to: ${blind[*]})"; exit 1
fi

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "ios-share-viewer: building CaptureCat (Debug, simulator)"
  xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$OUT/dd" \
    ${CLONED_PACKAGES:+-clonedSourcePackagesDirPath "$CLONED_PACKAGES"} \
    build > "$OUT/build.log" 2>&1 \
    || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "IOS-SHARE-VIEWER FAIL (build)"; exit 1; }
fi
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/CaptureCat.app"

# A deterministic test video: 12 s, frame counter burned in.
[[ -f "$OUT/share.mp4" ]] || ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -t 12 \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/share.mp4"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$IOS/Tests/mock_api.py" "$PORT" 2>"$OUT/mock.log" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/__session" >/dev/null && break; sleep 0.1; done

python3 - "$PORT" "$OUT/share.mp4" <<'EOF'
import base64, json, sys, urllib.request
port, video = sys.argv[1], sys.argv[2]
media = base64.b64encode(open(video, "rb").read()).decode()
def seed(vid, **kw):
    body = {"videoId": vid, "file": media, "durationSeconds": 12, **kw}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/__viewer-share", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req).read()
seed("svOpen01", fileName="release-walkthrough.mp4", aiTitle="Setting up the release pipeline",
     aiSummary="A quick walk through the release checklist.", allowDownload=True,
     aiChapters=[{"start": 0, "label": "Intro"}, {"start": 5, "label": "Checklist"}],
     transcript=[{"start": 0, "end": 2.5, "text": "Hi, this is the release walkthrough."},
                 {"start": 2.5, "end": 6, "text": "First we open the checklist."},
                 {"start": 6, "end": 12, "text": "Then we cut the release build."}],
     comments=[{"commentId": "c1", "authorName": "Alex Kim", "body": "Love the zoom here", "videoTime": 3, "createdAt": "2026-11-10T10:00:00.000Z"},
               {"commentId": "c2", "parentId": "c1", "authorName": "Sam", "body": "Agreed", "videoTime": 3, "createdAt": "2026-11-11T10:00:00.000Z"},
               {"commentId": "c3", "authorName": "Jo Park", "body": "Where is this setting?", "videoTime": 9, "createdAt": "2026-11-12T10:00:00.000Z"}],
     reactions=[{"emoji": "\U0001F44D", "videoTime": 2}, {"emoji": "\U0001F525", "videoTime": 7}, {"emoji": "\U0001F44D", "videoTime": 8}])
seed("svLock01", fileName="Q3 numbers.mp4", password="opensesame")
seed("svExp01", gate="expired")
seed("svView01", gate="view_limit")
seed("svPause01", gate="paused")
seed("svPriv01", isPrivate=True)
seed("svMine01", fileName="My private take.mp4", isPrivate=True, ownedByMock=True)
seed("svGone01", removed="This video was removed for violating CaptureCat's terms.")
seed("svQuiet01", fileName="capturecat-share-1A2B3C4D-0000.mp4", commentsEnabled=False)
# Annotations: the owner's markers (a range, a labelled point, an unlabelled
# one at 0:00 — a range, no pill) and a comment carrying a drawing (a box
# from 30 %,30 % to 70 %,60 % of the frame).
seed("svDraw01", fileName="drawing-review.mp4",
     annotations=[{"start": 2, "end": 4, "label": "Intro"}, {"start": 7.5, "end": 7.5, "label": "Settings"}, {"start": 0, "end": 1}],
     comments=[{"commentId": "d1", "authorName": "Riley Chen", "body": "This box", "videoTime": 5, "createdAt": "2026-11-13T10:00:00.000Z",
                "annotation": {"v": 1, "shapes": [{"kind": "rect", "color": "#22c55e", "size": 3, "from": [0.3, 0.3], "to": [0.7, 0.6]}]}}])
# The signed-in user's own share (in GET /api/videos), comments off: the
# share-detail switch.
seed("svToggle01", fileName="toggle-me.mp4", commentsEnabled=False, listed=True, ownedByMock=True)
print("ios-share-viewer: seeded 11 shares")
EOF

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
# The app-accessibility runtime (what Accessibility Inspector switches on), so
# the audit sees UIKit's own elements — as ios-a11y.sh does; off again at exit.
xcrun simctl spawn "$DEVICE" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
trap 'kill $MOCK 2>/dev/null || true; xcrun simctl spawn "$DEVICE" defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled 2>/dev/null || true' EXIT
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true

RUN="$OUT/run${INJECT:+-$INJECT}"
rm -rf "$RUN" && mkdir -p "$RUN"
container() { xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data; }
routes() { cat "$(container)/Documents/share-viewer/routes.log" 2>/dev/null || true; }
meta_hits() { curl -s "http://127.0.0.1:$PORT/__state" | python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin)['viewer']['log'] if e['route']=='meta' and e['videoId']=='$1'))"; }

# ── 2. the in-app gate (warm paths) ────────────────────────────────────────
echo "ios-share-viewer: in-app gate on $DEVICE${INJECT:+ (inject $INJECT — must FAIL)}"
args=(-apiBaseURL "http://127.0.0.1:$PORT" -shareViewerGate)
[[ -n "${INJECT:-}" ]] && args+=(-shareViewerInject "$INJECT")
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE" "${args[@]}" > "$RUN/run.log" 2>&1 &
pid=$!
fired=
shots=0
for _ in $(seq 1 480); do
  kill -0 "$pid" 2>/dev/null || break
  # `await-shot <name>`: a real simulator screenshot while the gate holds still.
  want=$(grep -c '^SHAREVIEWER await-shot' "$RUN/run.log" 2>/dev/null || true)
  while [[ $shots -lt ${want:-0} ]]; do
    shots=$((shots + 1))
    name=$(grep '^SHAREVIEWER await-shot' "$RUN/run.log" | sed -n "${shots}p" | awk '{print $3}' | tr -d '\r')
    xcrun simctl io "$DEVICE" screenshot "$RUN/$name.png" >/dev/null 2>&1 || true
  done
  if [[ -z "$fired" ]] && url=$(grep -m1 -o 'SHAREVIEWER await-openurl [^ ]*' "$RUN/run.log" 2>/dev/null | awk '{print $3}' | tr -d '\r'); [[ -n "${url:-}" ]]; then
    fired=1
    sleep 0.5
    xcrun simctl openurl "$DEVICE" "$url" || true
  fi
  sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
  xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
  echo "ios-share-viewer: gate timed out" >&2
fi
wait "$pid" || true
cp "$(container)/Documents/share-viewer/"*.png "$RUN/" 2>/dev/null || true
cp "$(container)/Documents/share-viewer/drawn-raw.json" "$RUN/" 2>/dev/null || true
grep -E '^SHAREVIEWER' "$RUN/run.log" | grep -v '^SHAREVIEWER await' || tail -30 "$RUN/run.log"
gate_ok=0; grep -q '^SHAREVIEWER-GATE PASS' "$RUN/run.log" && gate_ok=1

# ── 2b. the drawing, through the WEB's serializer ───────────────────────────
web_fail=1
if [[ -f "$RUN/drawn-raw.json" ]] && command -v node >/dev/null; then
  node "$IOS/Tests/share_annotation_web.mjs" "$RUN/drawn-raw.json" > "$RUN/drawn-web.json" 2>"$RUN/drawn-web.err" || true
  curl -s "http://127.0.0.1:$PORT/__state" > "$RUN/state.json"
  if python3 - "$RUN/drawn-web.json" "$RUN/state.json" <<'EOF'
import json, sys
web = open(sys.argv[1]).read().strip()
log = json.load(open(sys.argv[2]))["viewer"]["log"]
posts = [e for e in log if e["route"] == "comments" and e["method"] == "POST" and e["videoId"] == "svDraw01" and (e.get("raw") or "").startswith('{"annotation":')]
raw = posts[-1]["raw"] if posts else ""
posted = json.dumps(json.loads(raw)["annotation"], separators=(",", ":"), ensure_ascii=False) if raw else "-"
ok = web not in ("", "null") and raw.startswith('{"annotation":' + web + ",")
print(f"SHAREVIEWER drawing-payload-web {'PASS' if ok else 'FAIL'} the web's serializeAnnotation over the gate's raw marks "
      f"({len(web)} bytes) {'== the bytes the app posted' if ok else '!= what the app posted'}"
      + ("" if ok else f"\n    web:    {web[:300]}\n    posted: {posted[:300]}"))
sys.exit(0 if ok else 1)
EOF
  then web_fail=0; fi
else
  echo "SHAREVIEWER drawing-payload-web FAIL no drawn-raw.json from the gate (or no node: $(command -v node || echo missing))"
fi

# ── 3. cold launches ────────────────────────────────────────────────────────
cold_fail=0
cold() {  # name, expected route line, video id, launch command...
  local name=$1 want=$2 vid=$3; shift 3
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  rm -f "$(container)/Documents/share-viewer/routes.log"
  local before; before=$(meta_hits "$vid")
  "$@" > "$RUN/$name.log" 2>&1 || true
  local got="" after=$before
  for _ in $(seq 1 40); do
    got=$(routes); after=$(meta_hits "$vid")
    [[ "$got" == *"$want"* && "$after" -gt "$before" ]] && break
    sleep 0.25
  done
  sleep 2.5
  xcrun simctl io "$DEVICE" screenshot "$RUN/$name.png" >/dev/null 2>&1 || true
  if [[ "$got" == *"$want"* && "$after" -gt "$before" ]]; then
    echo "SHAREVIEWER $name PASS route \"$want\", meta requested $((after - before))× → $RUN/$name.png"
  else
    echo "SHAREVIEWER $name FAIL routes=[$(echo "$got" | tr '\n' ';')] meta hits $before→$after"; cold_fail=1
  fi
}
cold custom-scheme-cold "custom-scheme cold svQuiet01" svQuiet01 \
  xcrun simctl openurl "$DEVICE" "capturecat://share/svQuiet01"
cold universal-link-cold "universal-link cold svOpen01 t=3.0" svOpen01 \
  xcrun simctl launch "$DEVICE" "$BUNDLE" -apiBaseURL "http://127.0.0.1:$PORT" -shareViewerColdLink "https://capturecat.so/share/svOpen01?t=3"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true

echo "ios-share-viewer: log $RUN/run.log · screens $RUN/*.png · mock $OUT/mock.log"
if [[ $gate_ok == 1 && $cold_fail == 0 && $web_fail == 0 ]]; then
  if [[ -n "${INJECT:-}" ]]; then echo "IOS-SHARE-VIEWER PASS (inject $INJECT — the defect went unnoticed)"; exit 0; fi
  echo "IOS-SHARE-VIEWER PASS"; exit 0
fi
echo "IOS-SHARE-VIEWER FAIL${INJECT:+ (inject $INJECT)}"
exit 1
