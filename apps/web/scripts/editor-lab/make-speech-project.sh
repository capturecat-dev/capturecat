#!/usr/bin/env bash
# Synthetic SPEECH project for the transcription harness (DEV ONLY, macOS):
# `say` speaks two paragraphs with a pause between them onto the LAST audio
# track (the microphone, like ScreenRecorder writes it), a quiet 440 Hz tone
# sits on the first (system audio), over an ffmpeg test pattern.
#
#   scripts/editor-lab/make-speech-project.sh <projects-root> [UUID]
#   CAPTURECAT_PROJECTS_ROOT=<projects-root> npx vite dev --port 3215
#   node scripts/editor-lab/transcribe.mjs --id <UUID> --reference <projects-root>/<UUID>/script.txt
#
# Needs `say` and ffmpeg. Writes only under <projects-root>/<UUID>/.
set -euo pipefail
WEB="$(cd "$(dirname "$0")/../.." && pwd)"

ROOT="${1:?usage: make-speech-project.sh <projects-root> [UUID]}"
ID="${2:-5B1D0C1E-7A11-4C0A-9E57-5AB717E50001}"
DIR="$ROOT/$ID"
mkdir -p "$DIR"
cd "$DIR"

cat > part1.txt <<'EOF'
Welcome to CaptureCat. In this short demo, I will show you how to record your screen and share it with your team.
First, open the editor and pick a background. Then add a zoom region where the cursor clicks the export button.
Is this working? Yes! The preview must match the export, exactly. That is the product.
EOF
cat > part2.txt <<'EOF'
Now let's talk about keyboard shortcuts. Press command shift S to show the keystroke overlay.
Why does this matter? Because nobody wants to watch you type a password for thirty seconds.
EOF
cat part1.txt part2.txt > script.txt

say -v Samantha -r 170 -o part1.aiff -f part1.txt
say -v Samantha -r 170 -o part2.aiff -f part2.txt
# 1 s silence · part 1 · 5 s silence · part 2 — 48 kHz mono.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -t 1 -i anullsrc=r=48000:cl=mono -i part1.aiff \
  -f lavfi -t 5 -i anullsrc=r=48000:cl=mono -i part2.aiff \
  -filter_complex "[1:a]aresample=48000,aformat=channel_layouts=mono[a];[3:a]aresample=48000,aformat=channel_layouts=mono[b];[0:a][a][2:a][b]concat=n=4:v=0:a=1[out]" \
  -map "[out]" mic.wav
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 mic.wav)
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=$DUR" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DUR,volume=0.05,aformat=channel_layouts=stereo" \
  -i mic.wav -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 30 -g 60 -c:a aac -b:a 128k -movflags +faststart recording.mov
rm -f part1.aiff part2.aiff mic.wav

# project.json from the core model's defaults (complete, Mac-decodable).
cd "$WEB"
npx vite-node --config vitest.config.ts scripts/editor-lab/speech-project.ts -- "$DIR" "$ID" "$DUR"
echo "$DIR ($DUR s)"
