#!/bin/bash
set -euo pipefail

media_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
media_root="$(cd -- "$media_dir/../.." && pwd)"
media_output="$media_root/.build/candidate-review"
"$media_dir/.build/RenderMedia" "$media_root/art/candidates/proof-v01" "$media_output"
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$media_output/media-frames/%04d.png" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$media_output/comparison.mp4"
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$media_output/media-frames/%04d.png" \
    -filter_complex '[0:v]split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a' \
    -loop 0 "$media_output/comparison.gif"
printf 'Review media: %s\n' "$media_output/comparison.mp4"
