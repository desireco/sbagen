#!/bin/bash
# Build the 64-bit static libraries needed for MP3/OGG mixing, and install
# them into dev/libs* so the Makefile picks them up.
#
#   tests/build-codecs.sh [install-prefix]
#
# Both libraries are built from Xiph/upstream sources rather than taken from
# the system, for two reasons:
#
#   libmad   - not packaged on Arch, and upstream's libs/ only ships i686
#              archives that cannot link into a 64-bit build.
#   Tremor   - oggdec.c is written against Ogg Vorbis *Tremor*, whose
#              ov_read() takes 4 arguments.  The floating-point libvorbisfile
#              that distributions ship takes 7.  Linking against it compiles
#              cleanly and then produces nothing but "Recoverable error in
#              Ogg stream" at runtime, because the arguments land in the
#              wrong registers.
#
# Headers for both land in dev/libs64/, kept separate from dev/libs/ (the
# upstream 1.4.5 copies).  Those are 2002-era: they declare ogg_sync_state
# and ogg_stream_state as pointers, making OggVorbis_File 448 bytes where the
# real one is 864.  Mixing the old headers with a current library overflows
# the caller's struct on the first ov_open() call.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
PREFIX=${1:-/tmp/sbagen-codecs}
WORK=$PREFIX/build
LIBS=$ROOT/dev/libs
LIBS64=$ROOT/dev/libs64

LIBMAD_VER=0.15.1b
TREMOR_URL=https://gitlab.xiph.org/xiph/tremor/-/archive/master/tremor-master.tar.gz
OGG_VER=1.3.5

mkdir -p "$WORK" "$LIBS64"

fetch() { curl -sSL --max-time 120 -o "$2" "$1"; }

echo "==> libmad $LIBMAD_VER"
if [ ! -d "$WORK/libmad-$LIBMAD_VER" ]; then
  fetch "https://sourceforge.net/projects/mad/files/libmad/$LIBMAD_VER/libmad-$LIBMAD_VER.tar.gz/download" \
        "$WORK/libmad.tar.gz"
  tar -C "$WORK" -xzf "$WORK/libmad.tar.gz"
fi
cd "$WORK/libmad-$LIBMAD_VER"
if [ ! -f .libs/libmad.a ]; then
  # --with-audio=none drops the OSS dependency; we only want the decoder.
  ./configure --prefix="$WORK/libmad-install" --disable-shared --enable-static \
    --with-audio=none --without-iconv --without-gnu-ld >/dev/null
  # libmad 0.15.1b passes -fforce-mem, which GCC dropped years ago.
  sed -i 's/-fforce-mem//g' Makefile
  make -j"$(nproc)" >/dev/null 2>&1 || make >/dev/null
fi
cp .libs/libmad.a "$LIBS/linux-libmad64.a"
cp mad.h "$LIBS/mad.h"
echo "    -> dev/libs/linux-libmad64.a"

echo "==> libogg $OGG_VER (Tremor's bitstream layer)"
if [ ! -d "$WORK/libogg-$OGG_VER" ]; then
  fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VER.tar.gz" \
        "$WORK/libogg.tar.gz"
  tar -C "$WORK" -xzf "$WORK/libogg.tar.gz"
fi
cd "$WORK/libogg-$OGG_VER"
if [ ! -f src/.libs/libogg.a ]; then
  ./configure --prefix="$WORK/libogg-install" --disable-shared --enable-static >/dev/null
  make -j"$(nproc)" >/dev/null 2>&1
fi
cp src/.libs/libogg.a "$LIBS/linux-libogg64.a"
cp include/ogg/ogg.h "$LIBS64/ogg.h"
echo "    -> dev/libs/linux-libogg64.a"

echo "==> Tremor"
if [ ! -d "$WORK/tremor-master" ]; then
  fetch "$TREMOR_URL" "$WORK/tremor.tar.gz"
  tar -C "$WORK" -xzf "$WORK/tremor.tar.gz"
fi
cd "$WORK/tremor-master"
if [ ! -f .libs/libvorbisidec.a ]; then
  [ -f configure ] || autoreconf -fi >/dev/null 2>&1
  ./configure --prefix="$WORK/tremor-install" --disable-shared --enable-static >/dev/null
  make -j"$(nproc)" >/dev/null 2>&1
fi
cp .libs/libvorbisidec.a "$LIBS/linux-libvorbisidec64.a"
cp ivorbisfile.h ivorbiscodec.h "$LIBS64/"
# Flatten <ogg/ogg.h> so the headers work included as "libs64/xxx.h".
sed -i 's|#include <ogg/ogg.h>|#include "ogg.h"|' "$LIBS64/ivorbisfile.h" "$LIBS64/ivorbiscodec.h"
echo "    -> dev/libs/linux-libvorbisidec64.a, dev/libs64/"

echo
echo "Done.  Now run:  make clean && make"
echo
echo "Sanity check -- OggVorbis_File must match what the library was built against:"
cd "$ROOT/dev"
cat > /tmp/_sz.c <<'EOF'
#include <stdio.h>
#include "libs64/ivorbisfile.h"
int main(){ printf("  sizeof(OggVorbis_File) = %zu\n", sizeof(OggVorbis_File)); return 0; }
EOF
gcc -I. -Ilibs64 /tmp/_sz.c -o /tmp/_sz && /tmp/_sz
rm -f /tmp/_sz /tmp/_sz.c
echo "  (864 is correct for current Tremor; 448 means the 2002 headers leaked back in)"