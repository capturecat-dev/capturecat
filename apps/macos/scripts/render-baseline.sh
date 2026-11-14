#!/usr/bin/env bash
set -euo pipefail

# render-baseline.sh — byte/pixel-exact snapshot of what the Mac renderers
# produce, so a refactor can prove it changed NOTHING.
#
#   scripts/render-baseline.sh snapshot <dir>     capture into <dir>
#   scripts/render-baseline.sh compare <a> <b>    exit 0 only if identical
#
# Typical use (the iOS studio extraction, any "zero behaviour change" PR):
#
#   git switch main             && scripts/render-baseline.sh snapshot /tmp/base-main
#   git switch my-refactor      && scripts/render-baseline.sh snapshot /tmp/base-pr
#   scripts/render-baseline.sh compare /tmp/base-main /tmp/base-pr
#
# Same source in the same module must give identical output. A difference
# means behaviour changed: stop and find out why. This is NOT a tolerance
# gate and there is nothing to refreeze — the baseline is whatever the
# committed code produces today.
#
# What a snapshot holds (all from SYNTHETIC fixtures, never user media):
#
#   web-vectors/        --web-vectors: golden vectors from the real Swift
#                       math, incl. projectMerge over the committed
#                       apps/web merge fixtures                   (diff -r)
#   web-parity/         --web-parity-fixtures: each fixture's pre-encode
#                       BGRA frames from the exporter's lossless tap
#                       (CAPTURECAT_EXPORT_FRAME_TAP → frames/NNNN.png) and
#                       fixture.json                                (bytes)
#   camera-paths/       the exporter's per-frame camera path
#                       (CAPTURECAT_DUMP_CAMERA, as stored in fixture.json
#                       exporterCameraPath)                         (bytes)
#   cursor-sprites/     --web-cursor-sprites manifest.json: every cursor
#                       raster's premultiplied RGBA bytes            (bytes)
#   web-audio/          --web-audio-fixtures: sounds.json (bytes); the
#                       exporter's float32 mix (mix.f32) and its
#                       fixture.json                          (see "Audio")
#   preview-parity/     --preview-parity -ca.png CARenderer frames  (pixels)
#   raster-golden/      --raster-golden -cg.png CoreGraphics frames (pixels)
#
# Encoded media (export.mp4, the synthetic source movies) is deliberately
# NOT compared: MP4 bytes carry creation times and the export's HEVC comes
# from the hardware encoder; the tap frames above are what it was given.
#
# Audio is the one category that cannot be byte-exact. The mix is read back
# through AVAssetReaderAudioMixOutput, the same AVFoundation path the
# exporter encodes from, and on macOS 26.7 that path is not reproducible
# run to run (measured 2026-11-14, six runs): mixing/resampling varies by
# ≤ 2.4e-7 per sample (about 1 float ULP), and the `.timeDomain` time-pitch
# used for speed regions (ProjectAudioMix) renders differently inside the
# region and varies the mix length by up to ~660 frames. So:
#   • mix.f32 must have the same length and every |Δ| ≤ AUDIO_TOLERANCE
#     (1e-6 ≈ −120 dBFS, 30× below the 16-bit LSB the encoder receives);
#   • fixtures whose project has speed regions (time-pitch) are REPORTED but
#     not gated — no sample-level comparison of that path is meaningful;
#   • fixture.json / manifest.json compare byte-exact once the measured
#     frame count is dropped.
#
# One render jitter is tolerated: --preview-parity's motion SEQUENCE frames
# (motion-tilt-*) flipped one pixel by 1/255 on the tilted card's top edge
# in 2 of 5 runs of one binary (2026-11-14). Settled states never moved.
# The cause is below our code (CARenderer; CARendererSnapshot reads back
# after a fixed 60 ms and a barrier on a different Metal queue). motion-*
# frames may differ by ≤ 2 px at ≤ 1/255 and are listed when they do.
#
# Build: unless APP is set, builds an UNSANDBOXED Debug copy into its own
# DerivedData. The sandboxed Debug app writes harness output into its
# container, and reading the container from another process blocks on a
# privacy prompt. A separate DerivedData also keeps clear of an
# Xcode-attached Debug app.
#
# Env:
#   APP=/path/CaptureCat.app  use this (unsandboxed) build instead of building
#   DERIVED_DATA=<dir>        default: $TMPDIR/capturecat-render-baseline-dd
#   ONLY=a,b                  snapshot just these categories (names above)
#   KEEP_RAW=1                keep the harnesses' raw output (media etc.)
#   AUDIO_TOLERANCE=1e-6      per-sample tolerance for mix.f32
#
# Side effects worth knowing: --preview-parity opens an offscreen-ish window
# for a minute; --web-audio-fixtures briefly creates (and removes) a
# fixture-UUID folder under ~/Library/Application Support/CaptureCat/Projects
# because voice-overs resolve against project.projectDirectory.

cd "$(dirname "$0")/.."
MACOS_DIR="$PWD"
SCHEME=CaptureCat
REPO_ROOT="$(cd .. && cd .. && pwd)"
AUDIO_TOLERANCE="${AUDIO_TOLERANCE:-1e-6}"
CATEGORIES=(web-vectors web-parity camera-paths cursor-sprites web-audio preview-parity raster-golden)

die() { echo "render-baseline: $*" >&2; exit 2; }
usage() {
  sed -n '6,8p' "$0" | sed 's/^# //' >&2
  exit 64
}

wants() {
  [[ -z "${ONLY:-}" ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]]
}

# ---------------------------------------------------------------------------
# snapshot
# ---------------------------------------------------------------------------

resolve_app() {
  if [[ -n "${APP:-}" ]]; then
    echo "$APP"
    return
  fi
  local dd="${DERIVED_DATA:-${TMPDIR:-/tmp}/capturecat-render-baseline-dd}"
  local args=(-project CaptureCat.xcodeproj -scheme "$SCHEME" -configuration Debug
              -derivedDataPath "$dd"
              CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO)
  echo "render-baseline: building unsandboxed Debug into $dd" >&2
  if ! xcodebuild "${args[@]}" build >"$LOGS/build.log" 2>&1; then
    tail -20 "$LOGS/build.log" >&2
    die "build failed (log: $LOGS/build.log)"
  fi
  local products
  products="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null \
              | grep ' BUILT_PRODUCTS_DIR' | head -1 | sed 's/.*= //')"
  [[ -n "$products" ]] || die "could not resolve BUILT_PRODUCTS_DIR"
  echo "$products/$SCHEME.app"
}

assert_unsandboxed() {
  local sandboxed
  sandboxed="$(codesign -d --entitlements - --xml "$1" 2>/dev/null \
               | plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null || true)"
  if [[ "$sandboxed" == "true" ]]; then
    die "$1 is sandboxed — its harness output would land in the container. Unset APP to let this script build an unsandboxed copy."
  fi
}

# run <category> <log> -- <args…>: runs the binary, records the exit code.
run_harness() {
  local category="$1" log="$2"; shift 3
  local started=$SECONDS status=0
  printf '  %-16s ' "$category"
  "$BIN" "$@" >"$log" 2>&1 || status=$?
  printf 'exit %-3s %4ss\n' "$status" "$((SECONDS - started))"
  echo "$category exit=$status seconds=$((SECONDS - started))" >>"$OUT/meta/harness-exits.txt"
}

snapshot() {
  local target="$1"
  if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
    die "$target exists and is not empty"
  fi
  mkdir -p "$target"
  OUT="$(cd "$target" && pwd)"
  LOGS="$OUT/meta/logs"
  RAW="$OUT/raw"
  mkdir -p "$LOGS" "$RAW"

  local app
  app="$(resolve_app)"
  BIN="$app/Contents/MacOS/$SCHEME"
  [[ -x "$BIN" ]] || die "no binary at $BIN"
  assert_unsandboxed "$app"

  {
    echo "commit=$(git rev-parse HEAD)"
    echo "branch=$(git rev-parse --abbrev-ref HEAD)"
    if git diff --quiet HEAD -- . 2>/dev/null; then echo "dirty=no"; else echo "dirty=yes"; fi
    echo "binary=$BIN"
    echo "binary_sha256=$(shasum -a 256 "$BIN" | cut -d' ' -f1)"
    echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "hardware=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$OUT/meta/meta.txt"
  if grep -q '^dirty=yes' "$OUT/meta/meta.txt"; then
    echo "render-baseline: note — apps/macos has uncommitted changes; the snapshot reflects them" >&2
  fi

  echo "render-baseline: snapshot → $OUT"

  if wants web-vectors; then
    local merge_args=()
    if [[ -d "$REPO_ROOT/apps/web/src/editor/core/merge/fixtures" ]]; then
      merge_args=(--merge-fixtures "$REPO_ROOT/apps/web/src/editor/core/merge/fixtures")
    fi
    run_harness web-vectors "$LOGS/web-vectors.log" -- --web-vectors "$RAW/web-vectors" "${merge_args[@]+"${merge_args[@]}"}"
    mkdir -p "$OUT/web-vectors"
    cp "$RAW"/web-vectors/*.json "$OUT/web-vectors/" 2>/dev/null || true
  fi

  if wants web-parity || wants camera-paths; then
    run_harness web-parity "$LOGS/web-parity.log" -- --web-parity-fixtures "$RAW/web-parity"
    local fixture name
    for fixture in "$RAW"/web-parity/*/; do
      [[ -f "$fixture/fixture.json" ]] || continue
      name="$(basename "$fixture")"
      if wants web-parity; then
        mkdir -p "$OUT/web-parity/$name"
        cp "$fixture/fixture.json" "$OUT/web-parity/$name/"
        if [[ -d "$fixture/frames" ]]; then cp -R "$fixture/frames" "$OUT/web-parity/$name/"; fi
      fi
      if wants camera-paths; then
        mkdir -p "$OUT/camera-paths"
        jq -c '.exporterCameraPath[]' "$fixture/fixture.json" >"$OUT/camera-paths/$name.jsonl"
      fi
    done
    if wants web-parity && [[ -f "$RAW/web-parity/manifest.json" ]]; then
      cp "$RAW/web-parity/manifest.json" "$OUT/web-parity/"
    fi
  fi

  if wants cursor-sprites; then
    run_harness cursor-sprites "$LOGS/cursor-sprites.log" -- --web-cursor-sprites "$RAW/cursor-sprites"
    mkdir -p "$OUT/cursor-sprites"
    cp "$RAW/cursor-sprites/manifest.json" "$OUT/cursor-sprites/" 2>/dev/null || true
  fi

  if wants web-audio; then
    run_harness web-audio "$LOGS/web-audio.log" -- --web-audio-fixtures "$RAW/web-audio"
    mkdir -p "$OUT/web-audio"
    local f
    for f in manifest.json sounds.json; do
      if [[ -f "$RAW/web-audio/$f" ]]; then cp "$RAW/web-audio/$f" "$OUT/web-audio/"; fi
    done
    for fixture in "$RAW"/web-audio/*/; do
      [[ -f "$fixture/fixture.json" ]] || continue
      name="$(basename "$fixture")"
      mkdir -p "$OUT/web-audio/$name"
      cp "$fixture/fixture.json" "$OUT/web-audio/$name/"
      if [[ -f "$fixture/mix.f32" ]]; then cp "$fixture/mix.f32" "$OUT/web-audio/$name/"; fi
      # Speed regions route the mix through AVFoundation's time-pitch, which
      # is not reproducible (see "Audio" above): mark the fixture.
      if [[ -f "$fixture/project.json" ]] \
         && [[ "$(jq '(.speedRegions // []) | length' "$fixture/project.json")" != "0" ]]; then
        touch "$OUT/web-audio/$name/TIME-PITCH"
      fi
    done
  fi

  if wants preview-parity; then
    # The harness writes into NSTemporaryDirectory()/capturecat-parity-XXXXXX
    # (TMPDIR is not honoured) and prints the folder as CAPTUREDIR.
    run_harness preview-parity "$LOGS/preview-parity.log" -- --preview-parity
    local capdir
    capdir="$(awk '/^CAPTUREDIR /{print $2; exit}' "$LOGS/preview-parity.log")"
    mkdir -p "$OUT/preview-parity"
    if [[ -n "$capdir" && -d "$capdir" ]]; then
      cp "$capdir"/*-ca.png "$OUT/preview-parity/" 2>/dev/null || true
      if [[ "$capdir" == */capturecat-parity-* ]]; then rm -rf "$capdir"; fi
    else
      echo "render-baseline: preview-parity printed no CAPTUREDIR (see $LOGS/preview-parity.log)" >&2
    fi
  fi

  if wants raster-golden; then
    mkdir -p "$RAW/raster-golden"
    run_harness raster-golden "$LOGS/raster-golden.log" -- --raster-golden "$RAW/raster-golden"
    mkdir -p "$OUT/raster-golden"
    cp "$RAW"/raster-golden/*-cg.png "$OUT/raster-golden/" 2>/dev/null || true
  fi

  if [[ -z "${KEEP_RAW:-}" ]]; then rm -rf "$RAW"; fi

  echo
  local c n
  for c in "${CATEGORIES[@]}"; do
    [[ -d "$OUT/$c" ]] || continue
    n="$(find "$OUT/$c" -type f | wc -l | tr -d ' ')"
    printf '  %-16s %5s files\n' "$c" "$n"
  done
  if grep -qv ' exit=0 ' "$OUT/meta/harness-exits.txt"; then
    echo
    echo "render-baseline: some harnesses exited non-zero (gate red or crashed) — the artifacts are still"
    echo "what the code produced, but read the logs in $LOGS before trusting the snapshot:"
    grep -v ' exit=0 ' "$OUT/meta/harness-exits.txt" | sed 's/^/    /'
  fi
}

# ---------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------

DIFFTOOL=""
ensure_difftool() {
  if [[ -n "$DIFFTOOL" ]]; then return; fi
  local cache="${TMPDIR:-/tmp}/capturecat-render-baseline-tools"
  local src="$MACOS_DIR/scripts/render-baseline-diff.swift"
  local hash
  hash="$(shasum -a 256 "$src" | cut -c1-12)"
  DIFFTOOL="$cache/render-baseline-diff-$hash"
  if [[ ! -x "$DIFFTOOL" ]]; then
    mkdir -p "$cache"
    xcrun swiftc -O "$src" -o "$DIFFTOOL" >/dev/null || die "could not compile $src"
  fi
}

TOTAL_DIFF=0
compare_category() {
  local category="$1" mode="$2" a="$3/$1" b="$4/$1"
  if [[ ! -d "$a" && ! -d "$b" ]]; then
    printf '  %-16s %s\n' "$category" "not in either snapshot"
    return
  fi
  if [[ ! -d "$a" || ! -d "$b" ]]; then
    printf '  %-16s %s\n' "$category" "MISSING from $([[ -d "$a" ]] && echo B || echo A)"
    TOTAL_DIFF=$((TOTAL_DIFF + 1))
    return
  fi

  local list_a list_b
  list_a="$(cd "$a" && find . -type f | sort)"
  list_b="$(cd "$b" && find . -type f | sort)"
  local only_a only_b
  only_a="$(comm -23 <(echo "$list_a") <(echo "$list_b"))"
  only_b="$(comm -13 <(echo "$list_a") <(echo "$list_b"))"

  local files=0 same=0 differ=0 tolerated=0 reported=0 details=() notes=()
  local rel verdict
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    files=$((files + 1))
    if cmp -s "$a/$rel" "$b/$rel"; then
      same=$((same + 1))
      continue
    fi
    if [[ "$mode" == pixels && "$rel" == *.png ]]; then
      ensure_difftool
      if verdict="$("$DIFFTOOL" pixels "$a/$rel" "$b/$rel")"; then
        same=$((same + 1))
        continue
      fi
      # --preview-parity motion SEQUENCE frames jitter by one level on one
      # pixel of the tilted card's edge in ~1 of 3 runs of the same binary
      # (see the header). Tolerate exactly that, visibly; nothing else.
      if [[ "$category" == preview-parity && "$(basename "$rel")" == motion-* ]] \
         && [[ "$verdict" =~ ^([0-9]+)\ px\ differ.*worst\ ([0-9]+)/255 ]] \
         && (( BASH_REMATCH[1] <= 2 && BASH_REMATCH[2] <= 1 )); then
        notes+=("${rel#./}: edge jitter tolerated — $verdict")
        tolerated=$((tolerated + 1))
        continue
      fi
      details+=("${rel#./}: $verdict")
    elif [[ "$mode" == audio && "$rel" == */mix.f32 ]]; then
      ensure_difftool
      local dir="${rel%/mix.f32}"
      if [[ -f "$a/$dir/TIME-PITCH" || -f "$b/$dir/TIME-PITCH" ]]; then
        verdict="$("$DIFFTOOL" f32 "$a/$rel" "$b/$rel" "$AUDIO_TOLERANCE" || true)"
        notes+=("${rel#./}: not gated (speed-region time-pitch is not reproducible) — $verdict")
        reported=$((reported + 1))
        continue
      fi
      if verdict="$("$DIFFTOOL" f32 "$a/$rel" "$b/$rel" "$AUDIO_TOLERANCE")"; then
        notes+=("${rel#./}: $verdict")
        tolerated=$((tolerated + 1))
        continue
      fi
      details+=("${rel#./}: $verdict")
    elif [[ "$mode" == audio && "$rel" == *.json ]] \
         && cmp -s <(jq -S 'del(.mix.frames?) | if has("fixtures") then .fixtures |= map(del(.mix.frames?)) else . end' "$a/$rel") \
                   <(jq -S 'del(.mix.frames?) | if has("fixtures") then .fixtures |= map(del(.mix.frames?)) else . end' "$b/$rel"); then
      notes+=("${rel#./}: identical except the measured mix frame count")
      tolerated=$((tolerated + 1))
      continue
    else
      details+=("${rel#./}: bytes differ")
    fi
    differ=$((differ + 1))
  done < <(comm -12 <(echo "$list_a") <(echo "$list_b"))

  local missing=0
  if [[ -n "$only_a" ]]; then missing=$((missing + $(echo "$only_a" | wc -l))); fi
  if [[ -n "$only_b" ]]; then missing=$((missing + $(echo "$only_b" | wc -l))); fi

  if (( differ == 0 && missing == 0 )); then
    if (( tolerated + reported > 0 )); then
      printf '  %-16s %5d/%-5d identical, %d within tolerance, %d reported only (%s)\n' \
        "$category" "$same" "$files" "$tolerated" "$reported" "$mode"
      local n
      for n in "${notes[@]+"${notes[@]}"}"; do echo "      $n"; done
    else
      printf '  %-16s %5d/%-5d identical (%s)\n' "$category" "$same" "$files" "$mode"
    fi
  else
    printf '  %-16s %5d/%-5d identical, %d DIFFER, %d missing (%s)\n' \
      "$category" "$same" "$files" "$differ" "$missing" "$mode"
    TOTAL_DIFF=$((TOTAL_DIFF + differ + missing))
    local d
    for d in "${details[@]+"${details[@]}"}"; do echo "      $d"; done | head -40
    for d in "${notes[@]+"${notes[@]}"}"; do echo "      (ok) $d"; done | head -20
    if [[ -n "$only_a" ]]; then echo "$only_a" | sed 's|^\./|      only in A: |' | head -20; fi
    if [[ -n "$only_b" ]]; then echo "$only_b" | sed 's|^\./|      only in B: |' | head -20; fi
    if [[ "$mode" == "diff -r" ]] && (( differ > 0 )); then
      echo "      --- diff -r (first 30 lines) ---"
      diff -r "$a" "$b" | head -30 | cut -c1-200 | sed 's/^/      /' || true
    fi
  fi
}

compare() {
  local a b
  a="$(cd "$1" && pwd)" || die "no snapshot at $1"
  b="$(cd "$2" && pwd)" || die "no snapshot at $2"
  [[ -f "$a/meta/meta.txt" && -f "$b/meta/meta.txt" ]] || die "both arguments must be snapshot folders"

  echo "A: $a"; grep -E '^(commit|dirty|binary_sha256|macos)=' "$a/meta/meta.txt" | sed 's/^/    /'
  echo "B: $b"; grep -E '^(commit|dirty|binary_sha256|macos)=' "$b/meta/meta.txt" | sed 's/^/    /'
  if [[ "$(grep '^macos=' "$a/meta/meta.txt")" != "$(grep '^macos=' "$b/meta/meta.txt")" ]]; then
    echo "note: different macOS builds — system frameworks (CoreImage, fonts) can move pixels on their own"
  fi
  local exits
  for exits in "$a" "$b"; do
    if grep -qv ' exit=0 ' "$exits/meta/harness-exits.txt" 2>/dev/null; then
      echo "note: $(basename "$exits") had non-zero harness exits:"
      grep -v ' exit=0 ' "$exits/meta/harness-exits.txt" | sed 's/^/    /'
    fi
  done
  echo

  compare_category web-vectors    "diff -r" "$a" "$b"
  compare_category web-parity     bytes     "$a" "$b"
  compare_category camera-paths   bytes     "$a" "$b"
  compare_category cursor-sprites bytes     "$a" "$b"
  compare_category web-audio      audio     "$a" "$b"
  compare_category preview-parity pixels    "$a" "$b"
  compare_category raster-golden  pixels    "$a" "$b"

  echo
  if (( TOTAL_DIFF == 0 )); then
    echo "RENDER-BASELINE IDENTICAL"
    exit 0
  fi
  echo "RENDER-BASELINE DIFFERS ($TOTAL_DIFF file(s)) — behaviour changed; do not refreeze anything, find out why."
  exit 1
}

case "${1:-}" in
  snapshot) [[ $# -eq 2 ]] || usage; snapshot "$2" ;;
  compare)  [[ $# -eq 3 ]] || usage; compare "$2" "$3" ;;
  *) usage ;;
esac
