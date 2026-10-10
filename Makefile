# SBaGen - build, replacing the 19 hand-written mk* scripts of the 1.4.5 tree.
#
#   make              build dev/sbagen-fixed (file output)
#   make alsa         build with live ALSA output
#   make asan         build with AddressSanitizer + UBSan
#   make codecs       build the 64-bit libmad + Tremor needed for -m mixing
#   make test         build, then run the regression harness
#   make test-alsa    run the suite including live ALSA output
#   make check        -O0..-Os build matrix, to catch optimisation-level bugs
#   make clean
#
# MP3/OGG mixing (-m) is off by default: the 1.4.5 tree only ships i686
# archives, which cannot link into a 64-bit build.  Run 'make codecs' once to
# build proper 64-bit ones.

CC      ?= cc
SRCDIR   = dev
TARGET   = $(SRCDIR)/sbagen-fixed
SRC      = $(SRCDIR)/sbagen.c
# These are #include'd into sbagen.c rather than compiled separately, so they
# must be listed as prerequisites or edits to them will not trigger a rebuild.
INCLUDES = $(SRCDIR)/mp3dec.c $(SRCDIR)/oggdec.c $(SRCDIR)/encdec.c
ALSA_LIB ?= $(shell pkg-config --libs alsa 2>/dev/null)
ALSA_CFLAGS ?= $(shell pkg-config --cflags alsa 2>/dev/null)
HAVE_ALSA := $(shell pkg-config --exists alsa 2>/dev/null && echo yes)

CFLAGS_COMMON = -DT_POSIX -DANSI_TTY -Wall
LDLIBS  = -lm -lpthread

# Compressed output (-w flac / -w opus).  Both are optional: without them the
# -w option reports that no encoder is compiled in.
FLAC_CFLAGS := $(shell pkg-config --cflags flac 2>/dev/null)
FLAC_LIBS   := $(shell pkg-config --libs flac 2>/dev/null)
ifneq ($(FLAC_LIBS),)
CFLAGS_COMMON += -DHAVE_FLAC $(FLAC_CFLAGS)
LDLIBS += $(FLAC_LIBS)
endif

OPUS_CFLAGS := $(shell pkg-config --cflags opus 2>/dev/null)
OPUS_LIBS   := $(shell pkg-config --libs opus 2>/dev/null)
ifneq ($(OPUS_LIBS),)
CFLAGS_COMMON += -DHAVE_OPUS $(OPUS_CFLAGS)
LDLIBS += $(OPUS_LIBS)
endif

# The Opus path writes its own Ogg container, so it needs libogg.  Use the
# system library: 'make codecs' exists for the *decoder* side (libmad/Tremor),
# and -w opus should not depend on having run it.
OGG_SYS_LIBS := $(shell pkg-config --libs ogg 2>/dev/null)
ifneq ($(OPUS_LIBS)$(OGG_SYS_LIBS),$(OPUS_LIBS))
CFLAGS_COMMON += -DHAVE_OGG_SYSTEM
LDLIBS += $(OGG_SYS_LIBS)
endif

# MP3/OGG mixing.  The 1.4.5 libs/ directory ships i686 archives, which cannot
# be linked into a 64-bit build, so probe each archive for 64-bit ELF objects
# rather than merely testing that the file exists.  To enable codecs, build
# 64-bit libmad/libvorbisidec and drop them in as libs/linux-libmad.a and
# libs/linux-libvorbisidec.a.
ARCH := $(shell uname -m)

# An archive is usable only if its members are x86-64 ELF objects.  The
# upstream 1.4.5 libs/ directory ships i686 archives, which cannot be linked
# into a 64-bit build.
define codec_ok
$(shell [ -f $(1) ] && \
  ar t $(1) >/dev/null 2>&1 && \
  ar p $(1) $$(ar t $(1) | head -1) 2>/dev/null | od -An -tx1 -N20 | \
    tr -d ' \n' | grep -qi '7f454c4602' && echo yes)
endef

CODEC_LIBS =
CODEC_DEPS =
ifneq ($(call codec_ok,$(SRCDIR)/libs/linux-libmad64.a),)
CFLAGS_COMMON += -DMP3_DECODE
CODEC_LIBS += $(SRCDIR)/libs/linux-libmad64.a
CODEC_DEPS += $(SRCDIR)/libs/mad.h
endif
ifneq ($(call codec_ok,$(SRCDIR)/libs/linux-libvorbisidec64.a),)
CFLAGS_COMMON += -DOGG_DECODE
CODEC_LIBS += $(SRCDIR)/libs/linux-libvorbisidec64.a
CODEC_LIBS += $(SRCDIR)/libs/linux-libogg64.a
CODEC_DEPS += $(SRCDIR)/libs64/ivorbiscodec.h $(SRCDIR)/libs64/ivorbisfile.h
endif

# NB: do not substitute the system libvorbisfile here.  oggdec.c is written
# against Ogg Vorbis *Tremor*, whose ov_read() takes 4 arguments; the
# floating-point libvorbisfile that ships with distributions takes 7.  Linking
# against it compiles but produces nothing but "Recoverable error in Ogg
# stream" at runtime.  Tremor must be built from Xiph's sources (see the
# `codecs` target).

.PHONY: all alsa asan test test-alsa check clean distclean help codecs

all: $(TARGET)

$(TARGET): $(SRC) $(INCLUDES) $(CODEC_DEPS)
	$(CC) $(CFLAGS_COMMON) -O2 $(CFLAGS) $(SRC) -o $@ $(CODEC_LIBS) $(LDLIBS)

# Live audio output via ALSA.  Falls back to a clear message if the ALSA
# development files are not installed.
alsa:
ifeq ($(HAVE_ALSA),yes)
	$(CC) $(filter-out -DANSI_TTY -DT_POSIX,$(CFLAGS_COMMON)) -DT_POSIX_ALSA $(ALSA_CFLAGS) -O2 $(SRC) -o $(TARGET) $(ALSA_LIB) $(LDLIBS) $(CODEC_LIBS)
	@echo "built $(TARGET) with ALSA output"
else
	@echo "ERROR: ALSA development files not found."
	@echo "  Debian/Ubuntu: apt install libasound2-dev"
	@echo "  Fedora:        dnf install alsa-lib-devel"
	@exit 1
endif

asan: $(SRCDIR)/sbagen-asan

$(SRCDIR)/sbagen-asan: $(SRC) $(INCLUDES) $(CODEC_DEPS)
	$(CC) $(CFLAGS_COMMON) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
	  $(SRC) -o $@ $(CODEC_LIBS) $(LDLIBS)

# Run the harness against both the fixed binary and, if present, the pristine
# 1.4.5 build.  The pristine run is expected to FAIL the defect tests; that is
# how we know the harness can actually detect the bugs.
test: all
	@echo "=== fixed build ==="
	@tests/run.sh $(TARGET)
	@echo
	@echo "=== pristine 1.4.5 (defect tests must fail here) ==="
	@if [ -x sbagen-1.4.5/sbagen-built ]; then \
	   tests/run.sh sbagen-1.4.5/sbagen-built; \
	   rc=$$?; \
	   if [ $$rc -eq 0 ]; then \
	     echo "UNEXPECTED: pristine passed every defect test - the harness is not testing anything"; \
	     exit 1; \
	   else \
	     echo "(expected: pristine fails the defect tests)"; \
	   fi; \
	 else echo "pristine build not present, skipping"; fi

# Full check including live ALSA output.  tests/alsa-pcm.sh sets up a
# file-backed ALSA PCM so the bytes reaching the device can be compared against
# the plain file output path.
test-alsa: alsa
	@tests/alsa-pcm.sh $(TARGET)

# The 1.4.5 sources failed to link at -O0 and -O3 because 'inline' on
# calcNow()/t_per*() emitted no out-of-line definition under C99 rules.
# Building at every level keeps that from coming back.
check:
	@for o in -O0 -O1 -O2 -O3 -Os; do \
	   printf '  %-4s: ' $$o; \
	   if $(CC) $(CFLAGS_COMMON) $$o $(SRC) -o /tmp/sbagen-check-$$o $(CODEC_LIBS) $(LDLIBS) 2>/tmp/err-$$o; then \
	     echo "links"; \
	   else \
	     echo "FAILED TO LINK"; cat /tmp/err-$$o; exit 1; \
	   fi; \
	   rm -f /tmp/sbagen-check-$$o; \
	 done

clean:
	rm -f $(TARGET) $(SRCDIR)/sbagen-asan

distclean: clean
	rm -f /tmp/err-*

help:
	@sed -n '2,12p' $(firstword $(MAKEFILE_LIST))
# Build the 64-bit libmad + Tremor + libogg static libraries needed for MP3/OGG
# mixing.  See tests/build-codecs.sh for why these cannot come from the system.
codecs:
	@tests/build-codecs.sh
	@$(MAKE) --no-print-directory clean
