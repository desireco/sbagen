#!/bin/bash
# Generate SBaGen binaural-beat tracks as MP3 files.
#
# Usage:
#   ./mksounds.sh                    # generate the standard set into ./out
#   ./mksounds.sh name '200+10/0.5'  # generate one custom 2-minute track
#   ./mksounds.sh name '...' 00:30:00
#   ./mksounds.sh focus10 dev/examples/focus/focus-10-a.sbg
#                                  # render a whole .sbg sequence file
#
# The length argument applies to immediate mode only; a sequence file is
# rendered for its full stated duration unless -E/--end is not what you want
# (set LENGTH= to override, e.g. LENGTH=01:00:00).
#
# Tone-spec syntax (immediate mode):  <carrier><sign><beat>/<amp>
#   200+10/0.5   -> 200Hz carrier, 10Hz beat (alpha), amplitude 0.5
#   pink/0.35    -> pink noise bed
#   spin:3+40/0.2-> modulated noise ("spinning")
#   bell+440/0.1 -> bell strike (needs a sequence file, not immediate mode)

set -e

SBAGEN=${SBAGEN:-$(dirname "$0")/dev/sbagen-fixed}
OUT=${OUT:-$(dirname "$0")/out}
FADE=${FADE:-3000}          # fade in/out in ms
RATE=${RATE:-192}           # mp3 bitrate in kbps
LENGTH=${LENGTH:-}          # override length for sequence files
KEEP_WAV=${KEEP_WAV:-0}      # set to 1 to also keep the intermediate wav

mkdir -p "$OUT"

render() {
  local name=$1 source=$2 len=${3:-}
  local wav="$OUT/$name.wav" mp3="$OUT/$name.mp3"

  if [ -f "$source" ]; then
    # A sequence file: rendered for its own duration (-E = up to the end),
    # unless LENGTH overrides it.
    local seqargs=(-Q -S -W -o "$wav" -F "$FADE" -E "$source")
    if [ -n "$LENGTH" ]; then
      seqargs=(-Q -S -W -o "$wav" -F "$FADE" -L "$LENGTH" "$source")
    fi
    "$SBAGEN" "${seqargs[@]}"
    local desc="$source"
  else
    local immargs=(-Q -S -W -o "$wav" -F "$FADE" -L "${len:-00:02:00}" -i "$source")
    "$SBAGEN" "${immargs[@]}"
    local desc="$source${len:+ (len $len)}"
  fi

  ffmpeg -hide_banner -loglevel error -y -i "$wav" \
    -codec:a libmp3lame -b:a "${RATE}k" "$mp3"
  if [ "$KEEP_WAV" != 1 ]; then rm -f "$wav"; fi
  printf '%-24s %s  %s\n' "$name.mp3" "$desc" \
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