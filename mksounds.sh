#!/bin/bash
# Generate SBaGen binaural-beat tracks as MP3 files.
#
# Usage:
#   ./mksounds.sh                    # generate the standard set into ./out
#   ./mksounds.sh name '200+10/0.5'  # generate one custom 2-minute track
#   ./mksounds.sh name '...' 00:30:00
#
# SBaGen output format is tone-specs:  <carrier><sign><beat>/<amp>
#   200+10/0.5   -> 200Hz carrier, 10Hz beat (alpha), amplitude 0.5
#   pink/0.35    -> pink noise bed
#   spin:3+40/0.2-> modulated noise ("spinning")
#   bell+440/0.1 -> bell strike (needs a sequence file, not immediate mode)

set -e

SBAGEN=${SBAGEN:-/home/zhex/Work/mindflyaway/sbagen/dev/sbagen-fixed}
OUT=${OUT:-/home/zhex/Work/mindflyaway/sbagen/out}
FADE=${FADE:-3000}          # fade in/out in ms
RATE=${RATE:-192}           # mp3 bitrate in kbps
KEEP_WAV=${KEEP_WAV:-0}      # set to 1 to also keep the intermediate wav

mkdir -p "$OUT"

render() {
  local name=$1 spec=$2 len=${3:-00:02:00}
  local wav="$OUT/$name.wav" mp3="$OUT/$name.mp3"
  rm -f "$wav"
  # -Q quiet, -S output from the start, -W wav, -i immediate tone-specs
  "$SBAGEN" -Q -S -W -o "$wav" -F "$FADE" -L "$len" -i "$spec"
  ffmpeg -hide_banner -loglevel error -y -i "$wav" \
    -codec:a libmp3lame -b:a "${RATE}k" "$mp3"
  if [ "$KEEP_WAV" != 1 ]; then rm -f "$wav"; fi
  printf '%-24s %s  %s\n' "$name.mp3" "$spec" \
    "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp3")s"
}

if [ $# -ge 2 ]; then
  render "$@"
  exit 0
fi

render alpha-10hz '200+10/0.5'
render theta-6hz  '200+6/0.5 pink/0.15'
render delta-2hz  '150+2/0.5 pink/0.15'
render beta-20hz  '250+20/0.4'
render gamma-40hz '300+40/0.3'
render focus-pink 'pink/0.35 200+10/0.3'
render spin-3hz   'spin:3+40/0.2 pink/0.2 200+8/0.3'
# Add --alsa to any of these to hear the result live instead of writing a file,
# e.g.:  ./mksounds.sh --alsa alpha10 '200+10/0.5'
#
# Requires the ALSA build:  make alsa
# Note that binaural beats only work properly through headphones.
