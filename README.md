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

MP3/OGG mixing is not built here by default: upstream's `libs/` contains i686
archives that cannot link into a 64-bit build. The Makefile probes each
archive's ELF class and skips them cleanly rather than failing the link. To
enable codecs, build 64-bit `libmad` and `libvorbisidec` and place them in
`dev/libs/` as `linux-libmad.a` and `linux-libvorbisidec.a`.

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
