#!/bin/bash
# Run the regression harness with live ALSA output enabled.
#
# Defines a file-backed ALSA PCM so that the samples actually handed to the
# device can be compared byte-for-byte against the same render written to a
# file.  Both go through outChunk(), so they must match exactly -- this is what
# proves the ALSA backend did not alter the generated audio.
#
#   tests/alsa-pcm.sh [path-to-sbagen-binary]

set -u
SBAGEN=${1:-$(cd "$(dirname "$0")/.." && pwd)/dev/sbagen-fixed}

CONF=$(mktemp)
RAW=/tmp/sbagen_test.raw
trap 'rm -f "$CONF" "$RAW"' EXIT

# Start from the system ALSA config so built-in definitions (null, default,
# the hardware cards) remain available.
[ -f /usr/share/alsa/alsa.conf ] && cp /usr/share/alsa/alsa.conf "$CONF" || : > "$CONF"

cat >> "$CONF" <<EOF

pcm.sbagentest {
    type file
    slave.pcm "null"
    file "$RAW"
    format "raw"
}
EOF

rm -f "$RAW"
SBAGEN_TEST_ALSA_PCM=sbagentest \
SBAGEN_TEST_ALSA_FILE="$RAW" \
ALSA_CONFIG_PATH="$CONF" \
  "$(dirname "$0")/run.sh" "$SBAGEN"