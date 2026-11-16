#!/usr/bin/env bash
set -euo pipefail

# ios-features.sh — the Studio 4e features gate: Voice-over, Transcription,
# Auto Zoom and Background removal on iOS against the Mac, same fixtures.
#
#   apps/ios/scripts/ios-features.sh [outDir] [--inject <defect>]
#
# 1. The Mac (an UNSANDBOXED Debug build) writes every fixture and its own
#    results: `CaptureCat --features-reference <out>/mac`
#    (Services/FeaturesReferenceRunner.swift; StudioHarness/FeaturesHarness*).
# 2. StudioLab `--features` runs each feature through the shipping iOS sheet
#    (apps/ios/StudioUI/Features) in a real window and scores it against the
#    Mac's (StudioLab/FeaturesLab.swift). See FeaturesHarness.swift for what
#    each check compares and its bar.
#
# Inputs: synthetic media, `say` speech (never user audio) and iMovie's
# bundled trailer clip as the camera (read from /Applications, never copied
# into the repository). Transcription needs WhisperKit's base.en model on
# disk (WHISPER_MODELS=<dir holding openai_whisper-base.en>); without it the
# transcription feature is skipped and the gate cannot pass.
#
# `--inject` takes a FeaturesHarness.Inject name (autozoom-shift,
# voice-offset, mix-gain, transcript-timing, mask-ignored, mask-alpha,
# progress-snap) and must make the gate FAIL.
#
# Env:
#   DEVICE=<simulator udid>  (default: the 4e iPad)
#   APP=<CaptureCat.app>     an unsandboxed Mac build to use instead of building
#   WHISPER_MODELS=<dir>     WhisperKit model root (…/openai_whisper-base.en inside)
#   ONLY=a,b                 autozoom,voiceover,transcription,cutout
#   REUSE_MAC=1              keep an existing <out>/mac reference

IOS="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$(cd "$IOS/../macos" && pwd)"
DEVICE="${DEVICE:-7A222C8F-22CD-4EB0-8D6E-B7C3B5C1DD4D}"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-features}"
shift || true
INJECT=()
if [[ "${1:-}" == "--inject" && -n "${2:-}" ]]; then INJECT=(--inject "$2"); fi
ONLY_ARGS=()
if [[ -n "${ONLY:-}" ]]; then ONLY_ARGS=(--only "$ONLY"); fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
MAC_OUT="$OUT/mac"

# --- The Mac reference ------------------------------------------------------
if [[ -z "${APP:-}" ]]; then
  echo "ios-features: building the unsandboxed Mac app"
  xcodebuild -project "$MACOS/CaptureCat.xcodeproj" -scheme CaptureCat -configuration Debug \
    -derivedDataPath "$OUT/dd-mac" CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO \
    build > "$OUT/mac-build.log" 2>&1 || { grep -E 'error:' "$OUT/mac-build.log" | head -20; echo "IOS-FEATURES FAIL (Mac build)"; exit 1; }
  APP="$OUT/dd-mac/Build/Products/Debug/CaptureCat.app"
fi
BIN="$APP/Contents/MacOS/CaptureCat"

SPEECH_ARGS=()
MODEL_ARGS=()
if [[ -n "${WHISPER_MODELS:-}" && -f "$WHISPER_MODELS/openai_whisper-base.en/config.json" ]]; then
  # Known speech, synthesized (the default system voice; never user audio).
  cat > "$OUT/speech.txt" <<'TEXT'
Welcome to the editor. Today we will record a short demo of the new export panel.
First, open the project you want to share. Then choose a size and a format.
When the export finishes, the file is saved next to your recording.
That is all it takes. Thanks for watching, and see you next time.
TEXT
  say -o "$OUT/speech.aiff" -f "$OUT/speech.txt"
  SPEECH_ARGS=(--speech "$OUT/speech.aiff" --script "$OUT/speech.txt")
  MODEL_ARGS=(--whisper-models "$WHISPER_MODELS")
else
  echo "ios-features: no WhisperKit model at \${WHISPER_MODELS}/openai_whisper-base.en — transcription will be skipped"
fi

if [[ "${REUSE_MAC:-}" != "1" || ! -d "$MAC_OUT" ]]; then
  echo "ios-features: Mac reference → $MAC_OUT"
  # Regenerate only the features asked for; keep the others' references.
  if [[ -n "${ONLY:-}" ]]; then
    for part in ${ONLY//,/ }; do rm -rf "$MAC_OUT/$part"; done
  else
    rm -rf "$MAC_OUT"
  fi
  "$BIN" --features-reference "$MAC_OUT" ${SPEECH_ARGS[@]+"${SPEECH_ARGS[@]}"} ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} > "$OUT/mac-reference.log" 2>&1 \
    || { grep '^FEATURES-REFERENCE' "$OUT/mac-reference.log" | tail -20; echo "IOS-FEATURES FAIL (Mac reference)"; exit 1; }
  grep '^FEATURES-REFERENCE' "$OUT/mac-reference.log"
fi

# --- StudioLab on the simulator ---------------------------------------------
echo "ios-features: building StudioLab"
xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme StudioLab -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd-lab" \
  ${CLONED_PACKAGES:+-clonedSourcePackagesDirPath "$CLONED_PACKAGES"} \
  build > "$OUT/lab-build.log" 2>&1 \
  || { grep -E '^/.*error:' "$OUT/lab-build.log" | head -20; echo "IOS-FEATURES FAIL (StudioLab build)"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl install "$DEVICE" "$OUT/dd-lab/Build/Products/Debug-iphonesimulator/StudioLab.app"
RUN="$OUT/ios"
rm -rf "$RUN" && mkdir -p "$RUN"
echo "ios-features: running on $DEVICE ${INJECT[*]+"${INJECT[*]}"}"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" so.capturecat.ios.studiolab \
  --features "$RUN" --reference "$MAC_OUT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} ${INJECT[@]+"${INJECT[@]}"} > "$RUN/run.log" 2>&1 || true

grep -E '^(FEATURE |FEATURE-SUMMARY|FEATURES-GATE)' "$RUN/run.log" || tail -20 "$RUN/run.log"
grep -q '^FEATURES-GATE PASS' "$RUN/run.log" && { echo "IOS-FEATURES PASS"; exit 0; }
echo "IOS-FEATURES FAIL"
exit 1
