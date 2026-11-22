#!/bin/bash
# Tile out/still-*.png into 3x2 contact sheets (out/sheet-N.png) for quick review.
cd "$(dirname "$0")/out" || exit 1
rm -f sheet-*.png
files=($(ls still-*.png | sort -t- -k3 -g))
n=0
for ((i = 0; i < ${#files[@]}; i += 6)); do
  args=()
  for ((j = 0; j < 6; j++)); do
    f=${files[$((i + j))]}
    if [ -n "$f" ]; then args+=(-i "$f"); else args+=(-f lavfi -i color=black:s=1080x1080); fi
  done
  ffmpeg -y -loglevel error "${args[@]}" -filter_complex \
    "[0]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[a];[1]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[b];[2]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[c];[3]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[d];[4]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[e];[5]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1[f];[a][b][c][d][e][f]xstack=inputs=6:layout=0_0|640_0|1280_0|0_360|640_360|1280_360" \
    -frames:v 1 "sheet-$n.png"
  echo "out/sheet-$n.png"
  n=$((n + 1))
done
