#!/usr/bin/env bash
set -euo pipefail
ORVEX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=18' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=18' \
  -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=18' \
  -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -preset fast -crf 29 -pix_fmt yuv420p \
  -c:a aac -filter:a 'volume=0.03' \
  -metadata:s:a:0 title='Tone 440 Hz' -metadata:s:a:1 title='Tone 660 Hz' \
  -movflags +faststart -y "$ORVEX_ROOT/test/fixtures/generated.mp4"
