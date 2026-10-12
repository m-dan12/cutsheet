#!/bin/sh
# Короткий тестовый ролик из 4 «планов» разных цветов (ffmpeg). usage: make_sample_video.sh [out.mp4]
set -e
OUT=${1:-sample.mp4}
ffmpeg -loglevel error -y \
  -f lavfi -i "color=c=0x2e7d32:s=320x180:d=2:r=25" \
  -f lavfi -i "color=c=red:s=320x180:d=3:r=25" \
  -f lavfi -i "color=c=white:s=320x180:d=2:r=25" \
  -f lavfi -i "color=c=0x0050c8:s=320x180:d=2:r=25" \
  -filter_complex "[0][1][2][3]concat=n=4:v=1:a=0,format=yuv420p" \
  -c:v libx264 -preset veryfast "$OUT"
echo "$OUT: 9 s, cuts at 2, 5, 7 s"
