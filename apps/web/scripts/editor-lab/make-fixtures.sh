#!/usr/bin/env bash
# Synthetic fixture clips for the web editor lab + harness (DEV ONLY).
#
# NEVER real user media: everything here is ffmpeg-generated (testsrc2 +
# a sine tone). Output lands in apps/web/.fixtures/ (gitignored).
#
# Frame layout (all sizes derive from the frame height H, so the harness
# decodes every resolution with the same normalized geometry — keep in sync
# with FIXTURE_GEOMETRY in src/editor/lab/fixtures.ts):
#   * a flat WHITE border band b = H/16 on all four sides — the card's
#     rounded corners sit on a known colour, so the parity check can compute
#     a CPU reference for the antialiased corner pixels;
#   * testsrc2 motion content inside the border;
#   * a frame-index strip at the top of the content: 16 equal cells across
#     the content width, height H/10. Cell i (0..11) = bit i of the frame
#     number (LSB first, white = 1); cells 12..15 are a fixed 1,0,1,0 sync
#     pattern. The harness reads the displayed frame index straight off the
#     rendered pixels.
#
# Usage: scripts/editor-lab/make-fixtures.sh
#   OUT=<dir> DUR=<seconds> to override (defaults .fixtures, 10).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${OUT:-.fixtures}
DUR=${DUR:-10}
FPS=60
mkdir -p "$OUT"

make_clip() { # name width height codec primaries [audio]
  local name=$1 W=$2 H=$3 codec=$4 prim=$5 audio=${6:-}
  local b=$((H / 16)) stripH=$((H / 10))
  local cw=$((W - 2 * b)) ch=$((H - 2 * b))
  local out="$OUT/$name.mp4"
  if [[ -f "$out" ]]; then echo "exists: $out"; return; fi
  local bit="floor(X*16/W)"
  local vfilter="[0:v]format=yuv420p[base];[1:v]format=gray,geq=lum='if(lt(${bit},12),255*mod(floor(N/pow(2,${bit})),2),255*(1-mod(${bit},2)))',format=yuv420p[strip];[base][strip]overlay=0:0:shortest=1,pad=${W}:${H}:${b}:${b}:white,setsar=1,setparams=color_primaries=${prim}:color_trc=iec61966-2-1:colorspace=bt709:range=tv[v]"
  local codec_args=()
  case $codec in
    h264) codec_args=(-c:v libx264 -preset medium -crf 18 -profile:v high -g 120 -keyint_min 120 -sc_threshold 0 -bf 2) ;;
    hevc) codec_args=(-c:v libx265 -preset fast -crf 20 -tag:v hvc1 -x265-params "keyint=120:min-keyint=120:scenecut=0:open-gop=0:bframes=2:log-level=error") ;;
  esac
  local extra_in=() maps=(-map "[v]") audio_args=()
  if [[ -n $audio ]]; then
    extra_in=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DUR")
    maps+=(-map 2:a)
    audio_args=(-c:a aac -b:a 128k)
  fi
  echo "making $out"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${cw}x${ch}:rate=$FPS:duration=$DUR" \
    -f lavfi -i "color=c=black:size=${cw}x${stripH}:rate=$FPS:duration=$DUR" \
    ${extra_in[@]+"${extra_in[@]}"} \
    -filter_complex "$vfilter" "${maps[@]}" \
    "${codec_args[@]}" -pix_fmt yuv420p \
    -color_primaries "$prim" -color_trc iec61966-2-1 -colorspace bt709 -color_range tv \
    ${audio_args[@]+"${audio_args[@]}"} -movflags +faststart "$out"
}

make_clip h264-1080p 1920 1080 h264 bt709 audio
make_clip hevc-1080p 1920 1080 hevc bt709
make_clip h264-4k 3840 2160 h264 bt709
make_clip hevc-4k 3840 2160 hevc bt709
make_clip hevc-1080p-p3 1920 1080 hevc smpte432
ls -la "$OUT"
