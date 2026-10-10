# SBaGen 1.4.5 — code audit

Notes from reading `sbagen.c` before changing anything. This records what the
code is, how it is put together, and which defects were found and how each was
confirmed. Nothing here is a change; it is the state of the upstream 1.4.5
release as received.

## What the program is

A binaural beat generator. It synthesises two sine tones at slightly different
frequencies, one per ear; the difference is perceived as a rhythmic pulse at the
"beat" frequency, without any actual amplitude modulation. A `.sbg` sequence
file describes how carriers, beat frequencies and amplitudes change over time,
and the program renders that into audio.

Alpha (10 Hz), theta (6 Hz), delta (2 Hz) and so on are the target states this
is used for. The carriers must be low enough that the two tones stay separable
— hence the `-p drop` mode walking carriers from 200 Hz down to 2 Hz.

## Shape and size

3,247 lines in a single translation unit. `oggdec.c` and `mp3dec.c` are not
separate build units — they are `#include`d into `sbagen.c`, so they can see
every file-scope variable and call `inbuf_start()` directly.

The parts:

| Area | Location | Notes |
| --- | --- | --- |
| Option parsing | `scanOptions()` sbagen.c:767 | Also how options inside `.sbg` files are handled, via `handleOptions()` |
| Sequence parser | `readSeq()`:2299, `readNameDef()`:2591, `readTimeLine()`:2782 | Line-oriented; `readLine()`/`getWord()` tokenise |
| Period resolution | `correctPeriods()`:2356 | Five passes over a circular doubly-linked list. **This is the heart of the program.** |
| Voice scheduling | `corrVal()`:1646 | Walks the period ring by wall-clock time, converting declarative `Voice` specs into integer `Channel` state |
| Sample generation | `outChunk()`:1409 | The actual DSP, plus TPDF dither |
| Output backends | `setup_device()`:1815, `writeOut()`:1557 | OSS, Win32, CoreAudio, or none |
| Mix input ring buffer | `inbuf_*`:492–622 | Producer thread plus consumer, for overlaying external audio |

### The declarative / imperative split

`Voice` (sbagen.c:333) holds doubles: type, amplitude, carrier, beat. `Channel`
(:341) holds the integer state used to actually generate samples: phase offsets
in 32.32 fixed point, phase increments, integer amplitudes. `corrVal()` is the
translator between them, run once per parameter-update interval (10 Hz by
default, `-R`).

This is a sound design, and the DSP is careful throughout — 32.32 fixed-point
accumulators, a 16,384-entry sine table, a 20-bit pipeline, dithering, and a
proportional clock-sync that re-syncs gently against real time rather than
stepping.

### The real complexity

Not the algorithms. The **shape**:

- ~60 mutable file-scope globals. `corrVal()` and `outChunk()` read nearly all
  of them, so neither can be instantiated or tested in isolation. This is the
  root problem; everything else follows from it.
- `N_CH 16` (sbagen.c:331) with the generator type overloaded into the sign of
  an int — `0`–`5` for off/binaural/pink/bell/spin/mix, and `-1`…`-100` for
  `wave00`…`wave99`. Adding a generator means editing **six** switch sites, and
  the negative range is already fully spoken for.
- Roughly 340 lines (10%) of `#ifdef` platform code across four audio backends.
- No Makefile, no autotools, no tests. 19 one-line shell scripts (`mk`,
  `mk-mingw32`, `mk-macosx`, …).
- `libs/` ships i686 archives only, so the one script that enables MP3/OGG
  (`mk`) forces `-m32` — unbuildable on a 64-bit-only system.
- `H24` (86,400,000) millisecond wall-clock integers everywhere. Times are
  `int`, so a sequence can never exceed 24 hours, and `calcNow()` couples the
  generator directly to the system clock, which is what a library build would
  have to unpick.

### Audio backends

`mk` builds `-DT_LINUX`, which selects OSS and writes to `/dev/dsp`. **No
current kernel provides `/dev/dsp`**, and there is no ALSA or PulseAudio
support anywhere in the tree (`TODO.txt:38-40` asks for JACK and notes the
core would need rewriting to fit a callback model). As received, the program
cannot play audio on a modern Linux box at all — file output is the only
working path.

## Defects found

Each was reproduced before being fixed; none is speculative. Line numbers refer
to the unmodified 1.4.5 source.

### 1. Segfault on any sequence with no time lines — sbagen.c:2362

`per` stays `0` if no time line is ever read, and `correctPeriods()`
dereferences it unconditionally in five separate `do { } while (pp != per)`
loops, plus `dispCurrPer()`:1064.

```
$ : > empty.sbg && sbagen -D empty.sbg
Segmentation fault (core dumped)
```

An empty file, a comment-only file, or a file of bare name definitions all
crash.

### 2. Stack overflow in `-p drop` — sbagen.c:3025, 3070

`double beat[40]` is filled in a loop of `n_step` iterations, where
`n_step = 1 + (len0-1)/steplen` is derived from the requested duration with no
upper bound.

```
$ sbagen -D -p drop t300,1,1 99ls
ERROR: AddressSanitizer: stack-buffer-overflow ... WRITE of size 8
    #0 create_drop sbagen.c:3099
```

This is also the real cause of the `-Wmaybe-uninitialized` warning that GCC
emits for `beat` — suppressing it would hide the bug rather than fix it.

### 3. Divide-by-zero on a single-step `-p drop` — sbagen.c:3099 and 3188

`a / (n_step-1)` with `n_step == 1`. One site is floating point (prints
`-nanHz`), the other integer, which raises SIGFPE and kills the process.

### 4. Unbounded buffer write and unbounded recursion — sbagen.c:2849

Block expansion does `sprintf(lin, "%s%s", prep, bd->lin)` into the global
`buf[4096]`, where `prep` grows with each level of nesting, and
`readTimeLine()` recurses into itself with no depth limit. Blocks may nest by
design, so this is reachable from documented input:

```
$ sbagen -D rec.sbg        # block containing a reference to itself
ERROR: AddressSanitizer: global-buffer-overflow ... WRITE of size 4097
    #0 vsprintf
    #2 readTimeLine sbagen.c:2849
    #3 readTimeLine sbagen.c:2851   (repeats unbounded)
```

Both a global buffer overflow and stack exhaustion.

### 5. `-i` inside a `.sbg` file discards the rest of the sequence — sbagen.c:2291

`readSeqImm()` calls `correctPeriods()` itself. When `-i` appears inside a
sequence file, `handleOptions()` re-enters it mid-parse, so the ring is
resolved after only two periods have been built — and with `-D` the program
prints that partial ring and `exit(0)`s, discarding every subsequent line.

Worse, without `-D` the partially-resolved ring is mutated a second time by
the `correctPeriods()` at the end of `readSeq()`, producing five periods instead
of seven in the wrong order. The audible result is **silence** where a ramp
should be:

```
per-second RMS, '-i' inside a .sbg : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
per-second RMS, hand-equivalent     : [114, 320, 535, 752, 971, ...]
```

This one is already noted in `TODO.txt:8-13`, but without a diagnosis.

### 6. `-E` overrides an explicit `-L` — sbagen.c:1346

```
$ sbagen -S -E -L 00:00:02 -W -o out.wav seq.sbg   # writes the full sequence
$ sbagen -S -L 00:00:02       -W -o out.wav seq.sbg   # 352844 bytes, correct
```

### 7. Build failure at some optimisation levels — sbagen.c:173-175, 184, 206

`calcNow()`, `t_per24()`, `t_per0()`, `t_mid()` and `userTime()` are declared
`inline` with no matching `extern` declaration in the same translation unit.
Under C99 rules that means no out-of-line definition is emitted, so the link
fails:

```
$ cc -DT_POSIX -O3 sbagen.c
undefined reference to `calcNow'
undefined reference to `t_per0'
```

It links at `-O2` only because GCC happens to inline everything there; `-O0`
and `-O3` both fail. `mk-msvc.txt` works around it by instructing users to
compile the file as C++.

### 8. Over-long lines silently mis-parsed — sbagen.c:2194

`readLine()` uses `fgets` into a 4096-byte buffer. A longer line is split, and
the tail is then read as a fresh line — so a long `##` comment becomes
`Badly constructed time "zzz..."`. No error is raised for the truncation.

### 9. `H24` off-by-one — sbagen.c:1370

`if (now > H24) now -= H24;` uses `>` where it needs `>=`, so `now == 86400000`
escapes normalisation and fails every subsequent `t_per0()` comparison.

### 10. `int` overflow in the mix accumulator — sbagen.c:1435

The mix input is scaled by `<< 12` and generated tones use `amp*ST_AMP`; two
loud channels sum past `INT_MAX`. Nothing clamps, and `SBAGEN.txt:1190` only
warns in prose that amplitudes "should not exceed 100".

### Two more found during the work

- **`if (opt_L)` is true when `opt_L == -1`** (:1349). `-1` is the "not
  supplied" sentinel, but it is non-zero, so the `-L` branch always ran and
  computed `4 * (int)(-1 * 0.001 * 44100)` = `-176`. The old unconditional `-E`
  branch overwrote the result, which is why nobody noticed; fixing #6 naively
  exposed it.
- **A second `n_step-1` division** at :3188, found only after :3099 was fixed
  and the SIGFPE case still crashed.

Also worth recording: the obvious fix for #10, clamping to `-0x80000000`, is
wrong. The literal is *unsigned*, so the comparison is promoted to unsigned and
every non-negative value tests as "less than" it — which silently zeroed the
left channel. It needs `INT_MIN`. The golden tests caught this; the ASan build
did not.

## Verification method

Before changing anything, 74 golden hashes were captured from the pristine
build: 10 rendered audio files across the generator types, and the `-D`
interpreted output of all 64 bundled example sequences. After each fix the
outputs are compared byte-for-byte, so any unintended change to the DSP shows
up immediately.

The sweep is worth noting: all 64 bundled examples are clean under ASan and
UBSan as received. None of the defects above are reachable from the shipped
examples — they only show up with empty files, long `-p drop` durations,
recursive blocks, or `-i` inside a sequence file.

## Summary

The DSP is good work and the declarative/imperative split is sound. The
problems are structural: global state that makes the code untestable, a 2011
platform assumption (`/dev/dsp`) that no longer exists, no build system, no
tests, and ten defects — one of which silently produces no audio at all.

## Not attempted here

Recorded so the omissions are decisions rather than oversights:

- The ~60 globals are still globals. `corrVal()` and `outChunk()` remain
  untestable in isolation. `TODO.txt:53-54` proposes a `sbagenlib`; that is a
  large, mostly mechanical change and the foundation for everything else, but
  it is its own project.
- MP3/OGG mixing remains unbuildable without 64-bit `libmad`/`libvorbisidec`.
- No RF64/W64, so WAV output is capped at 4 GB by `writeWAV()`:2170.
- `mixbeat:` and `mixspin:` from `TODO.txt:41-45` are not implemented.
- No MIDI/OSC control, no FLAC/Opus output, no wasm build.
- `waveNN` custom waveforms are documented upstream as never having worked
  satisfactorily (`SBAGEN.txt:1470-1480`).
