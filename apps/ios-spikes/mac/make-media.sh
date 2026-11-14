#!/usr/bin/env bash
set -euo pipefail
# Generates the spikes' synthetic media into Spikes/Media (gitignored; the
# synchronized folder bundles it into CCSpikes.app). Never user media.
#
#   apps/ios-spikes/mac/make-media.sh
cd "$(dirname "$0")/.."
out=Spikes/Media
mkdir -p "$out"
tools="${TMPDIR:-/tmp}/ccspikes-tools"
mkdir -p "$tools"
xcrun swiftc -O mac/make-hevc.swift -o "$tools/make-hevc"

# Mac-recording-sized screen content, 60 fps (what the recorder captures on a
# 16" MacBook Pro panel and on a 5K display). Bitrates in the range the Mac
# recorder produces for screen content.
[[ -f "$out/screen-3456x2234-60.mov" ]] || "$tools/make-hevc" "$out/screen-3456x2234-60.mov" 3456 2234 60 10 30000000
[[ -f "$out/screen-5120x2880-60.mov" ]] || "$tools/make-hevc" "$out/screen-5120x2880-60.mov" 5120 2880 60 10 45000000

# 60 s of synthetic speech for WhisperKit, plus the script it was read from.
if [[ ! -f "$out/speech-60s.wav" ]]; then
  cat > "$out/speech-60s.txt" <<'TXT'
Welcome to this short walkthrough of the editor. First, open the project browser and choose the recording you made this morning. The timeline at the bottom shows the video track, the zoom effects and the annotations. To trim the beginning, drag the left edge of the clip until the first click. Next, add a zoom on the settings panel so viewers can read the small print. Hold the zoom for about two seconds, then let it ease back out. If you made a mistake while typing, select that section and speed it up to three times. Captions can be generated automatically, and you can change their font, their weight and their position. When everything looks right, export the video at full resolution and share the link with your team. That is all it takes to turn a raw screen recording into something clear and easy to follow.
TXT
  say -v Samantha -r 175 -f "$out/speech-60s.txt" -o "$tools/speech.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tools/speech.aiff" "$out/speech-60s.wav"
fi
ls -la "$out"
