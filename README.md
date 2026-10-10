# SBaGen — maintained fork

**Sequenced Binaural Beat Generator.**

A maintained fork of [SBaGen](http://sbagen.sf.net/) 1.4.5 by **Jim Peters**
(`<jim@uazu.net>`), who wrote the original program and holds copyright to it.
All original copyright notices and the GPL v2 licence terms are preserved
unchanged; see [LICENSE](LICENSE) and the header of
[`dev/sbagen.c`](dev/sbagen.c).

This fork fixes a number of defects found while auditing the 1.4.5 code, adds
a regression test suite, and adds a working audio backend for modern Linux.

## What changed relative to upstream 1.4.5

### Defect fixes

The upstream release is from 2011 and predates a lot of what changed since.

| Symptom in 1.4.5 | Cause |
| --- | --- |
| Segfault on any sequence with no time lines — including an empty file | A null `Period` ring was dereferenced unconditionally |
| Stack corruption from `-p drop` with a long duration | `n_step` wrote past the fixed-size `beat[40]` array |
| Crash (SIGFPE) from `-p drop t1,...` | Division by `n_step-1` when there is a single step |
| Infinite loop / buffer overrun on a self-referential block | Unbounded `sprintf` and unbounded block recursion |
| **Silence** where audio was expected, from `-i` inside a `.sbg` file | `correctPeriods()` ran mid-parse and discarded the rest of the sequence |
| `-E` silently overrode an explicit `-L` | Two independent `if` statements instead of `if`/`else if` |
| Build failure at `-O0` and `-O3` | `inline` on `calcNow()`/`t_per*()` emits no out-of-line definition under C99 |
| Garbled parse of lines over 4096 characters | Lines were silently split, and the tail re-parsed as a bogus time |
| Possible click/wrap at high amplitude | `int` overflow in the mix accumulator |

Two more bugs surfaced during the work itself: `if (opt_L)` was true when
`opt_L == -1` ("not supplied"), which the old unconditional `-E` branch
happened to mask; and the first attempt at the overflow fix silently zeroed the
left channel, because `-0x80000000` is an *unsigned* literal and forced an
unsigned comparison.

### Build system

Upstream ships 19 one-line shell scripts (`mk`, `mk-mingw32`, `mk-macosx`, …).
These are replaced by a `Makefile`:

```
make            # build dev/sbagen-fixed (file output)
make alsa       # build with live ALSA output
make asan       # build with AddressSanitizer + UBSan
make test       # build, then run the regression suite
make test-alsa  # run the suite including live ALSA output
make check      # build at -O0/-O1/-O2/-O3/-Os
```

### Tests

`tests/run.sh` runs 87 checks: 74 golden hashes (10 rendered audio files and
all 64 bundled example sequences) captured from the **pristine** upstream
build, plus one regression test per fixed defect.

The suite is verified to have teeth — run against the unmodified 1.4.5 binary
it fails exactly the 8 defect tests while passing all 74 goldens:

```
$ make test
=== fixed build ===
passed: 87   failed: 0   skipped: 0

=== pristine 1.4.5 (defect tests must fail here) ===
passed: 76   failed: 8   skipped: 0
(expected: pristine fails the defect tests)
```

The upstream code is clean under ASan+UBSan across all bundled examples once
these defects are fixed.

### Compressed output

Upstream could only write raw audio or RIFF/WAV, which is about 0.6 GB per
hour of 16-bit stereo. A 21:00-to-07:00 sleep session is over 6 GB -- past
the 4 GB WAV ceiling and anyone's patience with an ffmpeg one-liner.

```
sbagen-fixed -S -w opus -o night.opus -L 10:00:00 -i '180+8/0.35 pink/0.12'
sbagen-fixed -S -w flac -o focus.flac -L 01:00:00 focus-10-a.sbg
```

| Format | Size vs WAV | Notes |
| --- | --- | --- |
| `flac` | ~7x smaller | Lossless; decodes back to identical samples |
| `opus` | ~13x smaller | Lossy; needs 48 kHz, selected automatically |

The same 10-hour sleep session comes to 462 MB instead of 6 GB, and renders
in under four minutes.

Both feed the encoder from the same `writeOut()` choke point the WAV path uses,
so the generated audio is identical; only the container differs. The test suite
verifies this by decoding the result and comparing against the WAV render.

Opus is defined for 48 kHz only. Rather than resample, the rate is raised to
48 kHz before the DSP runs -- `out_rate` drives the oscillator increments in
`corrVal()`, so the identical waveform is generated natively at the higher
rate. No filtering, no aliasing, and no resampler to get wrong. An explicit
`-r` is honoured and enforced; a rate Opus cannot represent is refused rather
than silently resampled.

Raw Opus packets have no framing, so a bare `.opus` file cannot be played.
`libopusfile` turned out to be a decode-only library with no write API, so the
Ogg container is written directly using libogg.

### ALSA backend

Upstream's `T_LINUX` build targets `/dev/dsp` (OSS), which no current kernel
provides, so there was no way to play audio on a modern Linux box. `make alsa`
builds a `T_POSIX_ALSA` target and adds a `-A` device option:

```
./dev/sbagen-fixed -L 00:30 -i '200+10/0.5'     # play for 30 minutes
./dev/sbagen-fixed -A hdmi -L 00:10 -i '...'   # choose a specific device
```

It reads back the sample rate the device actually granted rather than assuming
its request was met — the DSP increments derive from `out_rate`, so a mismatch
would silently detune every beat frequency. Underruns (`-EPIPE`) are recovered,
and the device is drained via `atexit` because `loop()` never returns.

Output through ALSA is byte-identical to the file output path.

## Building

Requires a C compiler, and `libasound2-dev` for the ALSA target
(`apt install libasound2-dev`, or `dnf install alsa-lib-devel`).

```
make
```

MP3/OGG mixing (`-m`) is not built here by default. Run `make codecs` once to
build the required 64-bit libraries -- see below.

Compressed output (`-w`) needs `libFLAC` and `libopus`, both detected with
`pkg-config`. Without them `-w` reports that no encoder is compiled in.

## Building the codec libraries

`make codecs` runs `tests/build-codecs.sh`, which builds 64-bit static
`libmad`, Ogg Vorbis Tremor and `libogg` into `dev/libs/`. They cannot come
from the system for two reasons:

- **libmad** is not packaged on Arch, and upstream's `libs/` only ships i686
  archives that cannot link into a 64-bit build.
- **Tremor** is required because `oggdec.c` is written against it.
  `ov_read()` in Tremor takes 4 arguments; the floating-point `libvorbisfile`
  that distributions ship takes 7. Linking against it compiles without
  complaint and then produces nothing but "Recoverable error in Ogg stream" at
  runtime, because the arguments land in the wrong registers.

Tremor's headers land in `dev/libs64/`, kept separate from the 2002-era
copies in `dev/libs/`. Those declare `ogg_sync_state` and `ogg_stream_state`
as pointers, making `OggVorbis_File` 448 bytes where the real one is 864;
mixing the old headers with a current library overflows the caller's struct
on the first `ov_open()` call. The build script asserts the size is 864 so the
old headers cannot quietly come back.

## Generating audio

`mksounds.sh` renders binaural tracks straight to MP3:

```
./mksounds.sh                                  # the standard set -> out/
./mksounds.sh mytrack '200+7/0.5' 00:30:00     # custom track and length
```

## Layout

```
dev/                 working copy of the source, with the fixes applied
  sbagen.c           the program (single translation unit)
  examples/          upstream's ~90 bundled sequences
sbagen-1.4.5/        pristine upstream tree, unmodified, kept as a reference
  sbagen-built       the regression oracle the tests compare against
tests/               regression suite and golden hashes
Makefile             replaces upstream's 19 mk* scripts
mksounds.sh          MP3 generation helper
```

## Licence

GPL v2 — see [LICENSE](LICENSE). Jim Peters' original copyright and licence
notice in `sbagen.c` are unmodified, as GPL v2 requires when redistributing.

Upstream: <http://sbagen.sf.net/> · <http://uazu.net/sbagen/>
