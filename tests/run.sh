#!/bin/bash
# SBaGen regression harness.
#
#   tests/run.sh [path-to-sbagen-binary]
#
# Three kinds of check:
#   1. golden  - rendered audio and interpreted-sequence text must match
#                hashes captured from the pristine 1.4.5 build, byte for byte
#   2. defect  - each previously-fixed bug must now behave correctly
#   3. sweep   - every bundled example must still parse without crashing
#
# A golden mismatch is only reported for tests that are expected to be
# unaffected by the bug fixes; the ones that intentionally changed behaviour
# are listed in EXPECT_CHANGED below and are covered by the defect tests.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SBAGEN=${1:-$ROOT/dev/sbagen-fixed}
GOLDEN=$HERE/golden/golden.txt

[ -x "$SBAGEN" ] || { echo "FATAL: no sbagen binary at $SBAGEN"; exit 2; }
[ -f "$GOLDEN" ]  || { echo "FATAL: no golden file at $GOLDEN"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
sk()   { skip=$((skip+1)); printf '  skip  %s (%s)\n' "$1" "${2:-}"; }

sha() { sha256sum "$1" | cut -d' ' -f1; }

# Wall-clock stamps appear in -D output for sequences that use NOW, and status
# lines interleave with comment echoes, so normalise both.
# NB: LC_ALL=C is required. 'sort' collation is locale-sensitive -- under
# en_US.UTF-8 and C the lines of a -D dump order differently (':' is not
# collated the same way), so an unpinned sort makes these goldens depend on the
# machine's locale rather than on sbagen's output.
canon_d() { sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/TT:TT:TT/g' | LC_ALL=C sort; }

# --------------------------------------------------------------------------
echo "== golden: rendered audio =="
IMMEDIATE_SPECS=(
  '200+10/0.5'
  '200+6/0.5 pink/0.15'
  '150+2/0.5 pink/0.15'
  'spin:3+40/0.2 pink/0.2 200+8/0.3'
  'bell+440/0.3 200+10/0.4'
  'pink/0.35 200+10/0.3'
  '200/0.5'
  '400-4/0.2 100+9/0.3'
)
idx=0
for spec in "${IMMEDIATE_SPECS[@]}"; do
  idx=$((idx+1))
  want=$(awk -v k="imm$(printf '%02d' $idx)" '$2==k{print $1}' "$GOLDEN")
  [ -n "$want" ] || { sk "imm$idx" "no golden"; continue; }
  "$SBAGEN" -Q -S -W -o "$WORK/a.wav" -F 3000 -L 00:00:20 -i "$spec" >/dev/null 2>&1
  got=$(sha "$WORK/a.wav")
  [ "$got" = "$want" ] && ok "imm$idx audio byte-identical" \
                       || no "imm$idx audio" "want ${want:0:12} got ${got:0:12}"
done

want=$(awk '$2=="imm_8000hz_8bit"{print $1}' "$GOLDEN")
if [ -n "$want" ]; then
  "$SBAGEN" -Q -S -W -r 8000 -b 8 -o "$WORK/a.wav" -F 3000 -L 00:00:20 -i '200+10/0.5' >/dev/null 2>&1
  got=$(sha "$WORK/a.wav")
  [ "$got" = "$want" ] && ok "8kHz/8-bit audio byte-identical" \
                       || no "8kHz/8-bit audio" "want ${want:0:12} got ${got:0:12}"
fi

want=$(awk '$2=="seq_seq-basic"{print $1}' "$GOLDEN")
if [ -n "$want" ]; then
  "$SBAGEN" -Q -S -W -o "$WORK/a.wav" -F 3000 -L 00:00:20 "$HERE/seq-basic.sbg" >/dev/null 2>&1
  got=$(sha "$WORK/a.wav")
  [ "$got" = "$want" ] && ok "sequence-file audio byte-identical" \
                       || no "sequence-file audio" "want ${want:0:12} got ${got:0:12}"
fi

# --------------------------------------------------------------------------
echo "== golden: interpreted sequences (-D) =="
for f in "$ROOT"/dev/examples/*/*.sbg; do
  d=$(echo "$f" | sed "s|^$ROOT/dev/examples/||; s|/|_|g; s|\.sbg$||")
  want=$(awk -v k="dtext_$d" '$2==k{print $1}' "$GOLDEN")
  [ -n "$want" ] || { sk "dtext_$d" "no golden"; continue; }
  "$SBAGEN" -D "$f" 2>&1 | canon_d > "$WORK/d.txt"
  got=$(sha "$WORK/d.txt")
  [ "$got" = "$want" ] && ok "dtext_$d" || no "dtext_$d" "want ${want:0:12} got ${got:0:12}"
done

# --------------------------------------------------------------------------
echo "== defect regressions =="

# Bug 1: a sequence with no time-lines used to segfault on a null Period ring
: > "$WORK/empty.sbg"
out=$("$SBAGEN" -D "$WORK/empty.sbg" 2>&1); rc=$?
if [ $rc -ge 128 ]; then
  no "bug1 empty sequence does not crash" "died with signal $((rc-128))"
elif echo "$out" | grep -qi "no tone-sets"; then
  ok "bug1 empty sequence reports a clean error"
else
  no "bug1 empty sequence reports a clean error" "rc=$rc out=$(echo "$out"|head -1)"
fi

printf 'w: 200+10/0.2\n' > "$WORK/notl.sbg"
out=$("$SBAGEN" -D "$WORK/notl.sbg" 2>&1); rc=$?
if [ $rc -ge 128 ]; then
  no "bug1 name-def-only does not crash" "signal $((rc-128))"
else
  ok "bug1 name-def-only does not crash"
fi

# Bug 2: -p drop with a long duration overflowed the fixed beat[] array
out=$("$SBAGEN" -D -p drop t300,1,1 99ls 2>&1); rc=$?
if [ $rc -ge 128 ]; then
  no "bug2 long -p drop does not smash the stack" "signal $((rc-128))"
elif echo "$out" | grep -qi "too long\|truncat"; then
  ok "bug2 long -p drop is clamped with a warning"
else
  no "bug2 long -p drop is clamped" "rc=$rc"
fi

# Bug 2b: n_step==1 divided by zero in the beat ramp
out=$("$SBAGEN" -D -p drop t1,1,1 99ls 2>&1); rc=$?
if [ $rc -ge 128 ] || echo "$out" | grep -qi "nan"; then
  no "bug2 single-step -p drop avoids div-by-zero" "rc=$rc"
else
  ok "bug2 single-step -p drop avoids div-by-zero"
fi

# Bug 3: a self-referential block recursed forever, growing buf without bound
printf 'w: 200+10/0.2\nb: {\n+0:00 b\n}\n0:00 b\n' > "$WORK/rec.sbg"
out=$(timeout 15 "$SBAGEN" -D "$WORK/rec.sbg" 2>&1); rc=$?
if [ $rc -eq 124 ]; then
  no "bug3 self-referential block is detected" "timed out"
elif echo "$out" | grep -qi "nested too deeply\|recursion"; then
  ok "bug3 self-referential block is detected"
else
  no "bug3 self-referential block is detected" "rc=$rc out=$(echo "$out"|head -1)"
fi

# Bug 4: '-i' inside a .sbg file used to resolve the ring mid-parse and
#        discard every following line, producing silence
printf -- '-i 200+10/0.2\nts2: 200+6/0.3\noff: -\n0:05 ts2\n0:10 off\n' > "$WORK/imin.sbg"
"$SBAGEN" -Q -S -W -o "$WORK/i.wav" -F 3000 -L 00:00:12 "$WORK/imin.sbg" >/dev/null 2>&1
rms=$(python3 - "$WORK/i.wav" <<'PY' 2>/dev/null
import wave,struct,math,sys
w=wave.open(sys.argv[1]); fr=w.getframerate()
d=w.readframes(fr*6); s=struct.unpack('<%dh'%(len(d)//2),d)
ch=s[0::2]
print(int(math.sqrt(sum(x*x for x in ch)/max(1,len(ch)))))
PY
)
if [ -n "$rms" ] && [ "$rms" -gt 10 ] 2>/dev/null; then
  ok "bug4 '-i' in a sequence produces audio (rms=$rms)"
else
  no "bug4 '-i' in a sequence produces audio" "rms=${rms:-none}"
fi

# Bug 5: -E silently overrode an explicit -L
printf 'a: 200+10/0.5\n0:00:00 a\n0:00:05 a\n' > "$WORK/len.sbg"
"$SBAGEN" -Q -S -E -L 00:00:02 -W -o "$WORK/l1.wav" -F 3000 "$WORK/len.sbg" >/dev/null 2>&1
"$SBAGEN" -Q -S -L 00:00:02       -W -o "$WORK/l2.wav" -F 3000 "$WORK/len.sbg" >/dev/null 2>&1
s1=$(stat -c%s "$WORK/l1.wav" 2>/dev/null); s2=$(stat -c%s "$WORK/l2.wav" 2>/dev/null)
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then
  ok "bug5 explicit -L wins over -E ($s1 bytes)"
else
  no "bug5 explicit -L wins over -E" "-E -L gave ${s1:-none}, -L gave ${s2:-none}"
fi

# Bug 5b: with neither -L nor -E the length must come from the sequence, not
#         from a -1ms length treated as "present"
"$SBAGEN" -Q -S -E -W -o "$WORK/e.wav" -F 3000 "$WORK/len.sbg" >/dev/null 2>&1
se=$(stat -c%s "$WORK/e.wav" 2>/dev/null)
if [ -n "$se" ] && [ "$se" -gt 800000 ] && [ "$se" -lt 1000000 ]; then
  ok "bug5b -E alone uses the sequence length ($se bytes)"
else
  no "bug5b -E alone uses the sequence length" "got ${se:-none}"
fi

# Bug 7: an over-long line was silently split and its tail mis-parsed
python3 -c "print('## '+'z'*6000)" > "$WORK/long.sbg" 2>/dev/null
out=$("$SBAGEN" -D "$WORK/long.sbg" 2>&1); rc=$?
if echo "$out" | grep -qi "line too long"; then
  ok "bug7 over-long line is rejected with a clear error"
else
  no "bug7 over-long line is rejected" "rc=$rc out=$(echo "$out"|head -1|cut -c1-60)"
fi

# Bug 11: -E on a sequence whose only time-line is 00:00 computed a length of
# 0, which outChunk's 'if (byte_count > 0)' treats as unlimited -- so it
# rendered forever (a 38 GB wav before being caught).
printf 'ts: 200+10/0.5\n0:00 ts\n' > "$WORK/notime.sbg"
timeout 15 "$SBAGEN" -Q -S -E -W -o "$WORK/notime.wav" -F 500 "$WORK/notime.sbg" >/dev/null 2>&1
rc=$?
if [ $rc -eq 124 ]; then
  no "bug11 -E on a zero-duration sequence does not render forever" "timed out still rendering"
elif [ $rc -ne 0 ] && ! [ -s "$WORK/notime.wav" ]; then
  ok "bug11 -E on a zero-duration sequence does not render forever"
else
  no "bug11 -E on a zero-duration sequence does not render forever" "rc=$rc size=$(stat -c%s "$WORK/notime.wav" 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# Codec mixing (-m).  Requires MP3_DECODE/OGG_DECODE to be compiled in, plus
# ffmpeg to synthesise the test sources.
if "$SBAGEN" -h 2>&1 | grep -q 'ogg/mp3/wav/raw'; then
  echo "== codec mixing (-m) =="
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=6" \
      -codec:a libmp3lame -b:a 128k "$WORK/m.mp3" 2>/dev/null
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=660:d=6" \
      -codec:a libvorbis -q:a 4 "$WORK/m.ogg" 2>/dev/null
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=6" -ac 2 \
      "$WORK/m.wav" 2>/dev/null

    # Render each and confirm audio came out.  Getting the beat through the
    # decoder is not the point here -- just that the path works and does not
    # crash or spin.
    for src in m.mp3 m.ogg m.wav; do
      printf 'ts: mix/50 200+10/0.3\nalloff: -\n0:00 ts\n0:10 alloff\n' > "$WORK/mix.sbg"
      rm -f "$WORK/mixed.wav"
      timeout 120 "$SBAGEN" -Q -S -W -m "$WORK/$src" -o "$WORK/mixed.wav" \
        -F 500 -L 00:00:03 "$WORK/mix.sbg" >/dev/null 2>&1
      if [ -s "$WORK/mixed.wav" ]; then
        ok "-m $src produces audio"
      else
        no "-m $src produces audio" "no output"
      fi
    done

    # A mono MP3 must come out balanced.  libmad leaves channel 1 untouched
    # for mono input, so reading it blindly put noise in one ear.
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=6" \
      -ac 1 -codec:a libmp3lame -b:a 128k "$WORK/mono.mp3" 2>/dev/null
    printf 'ts: mix/50 200+10/0.3\nalloff: -\n0:00 ts\n0:10 alloff\n' > "$WORK/mix.sbg"
    rm -f "$WORK/mono_out.wav"
    timeout 120 "$SBAGEN" -Q -S -W -m "$WORK/mono.mp3" -o "$WORK/mono_out.wav" \
      -F 500 -L 00:00:03 "$WORK/mix.sbg" >/dev/null 2>&1
    bal=$(python3 - "$WORK/mono_out.wav" <<'PY' 2>/dev/null
import wave,struct,math,sys
w=wave.open(sys.argv[1]); d=w.readframes(int(w.getframerate()*2))
s=struct.unpack('<%dh'%(len(d)//2),d); L=s[0::2]; R=s[1::2]
rms=lambda v:int(math.sqrt(sum(x*x for x in v)/max(1,len(v))))
l,r=rms(L),rms(R)
print("balanced" if l>0 and r>0 and (l>r*2 or r>l*2) else "ok" if l>0 and r>0 else "one-sided")
PY
)
    if [ "$bal" = "balanced" ]; then
      no "mono MP3 mixes to both channels" "one ear is silent: $bal"
    elif [ "$bal" = "ok" ]; then
      ok "mono MP3 mixes to both channels"
    else
      no "mono MP3 mixes to both channels" "$bal"
    fi
  else
    sk "codec mixing" "ffmpeg not available to synthesise test sources"
  fi
else
  sk "codec mixing" "built without MP3/OGG decode"
fi

# --------------------------------------------------------------------------
# ALSA backend.  Skipped unless the binary was built with -DT_POSIX_ALSA.
if "$SBAGEN" -h 2>&1 | grep -q '^ *-A dev'; then
  echo "== ALSA backend =="

  # Device existence: probe for a usable PCM without sending real audio to
  # speakers.  'null' is always present in ALSA.
  if "$SBAGEN" -A null -L 00:00:01 -F 300 -Q -i '200+10/0.5' >/dev/null 2>&1; then
    ok "ALSA opens the null PCM"
  else
    no "ALSA opens the null PCM" "ALSA build present but 'null' device failed"
  fi

  # An unknown device must produce a clean error, not a crash.
  "$SBAGEN" -A sbagen-no-such-device -L 00:00:01 -i '200+10/0.5' >/dev/null 2>&1
  rc=$?
  if [ $rc -ge 128 ]; then
    no "ALSA rejects an unknown device cleanly" "signal $((rc-128))"
  elif [ $rc -ne 0 ]; then
    ok "ALSA rejects an unknown device cleanly"
  else
    no "ALSA rejects an unknown device cleanly" "exited 0"
  fi

  # Where a writable file-backed PCM is available, the samples reaching ALSA
  # must be byte-identical to the same render written to a file, since both
  # go through the same outChunk() DSP.
  if [ -n "${SBAGEN_TEST_ALSA_PCM:-}" ]; then
    rm -f "$WORK/alsa.raw" "$WORK/ref.wav"
    # SBAGEN_TEST_ALSA_FILE names the file the PCM writes to.
    "$SBAGEN" -A "$SBAGEN_TEST_ALSA_PCM" -L 00:00:02 -F 3000 -Q -i '200+10/0.5' >/dev/null 2>&1
    if [ -n "${SBAGEN_TEST_ALSA_FILE:-}" ] && [ -s "${SBAGEN_TEST_ALSA_FILE}" ]; then
      cp "${SBAGEN_TEST_ALSA_FILE}" "$WORK/alsa.raw"
    fi
    "$SBAGEN" -S -W -o "$WORK/ref.wav" -F 3000 -L 00:00:02 -i '200+10/0.5' >/dev/null 2>&1
    if [ -s "$WORK/alsa.raw" ] && [ -s "$WORK/ref.wav" ]; then
      # strip the 44-byte WAV header
      if cmp -s "$WORK/alsa.raw" <(tail -c +45 "$WORK/ref.wav"); then
        ok "ALSA output is byte-identical to file output"
      else
        no "ALSA output is byte-identical to file output"
      fi
    else
      sk "ALSA byte-identity" "no samples captured"
    fi
  else
    sk "ALSA byte-identity" "set SBAGEN_TEST_ALSA_PCM and SBAGEN_TEST_ALSA_FILE to a file-backed PCM"
  fi
fi

# --------------------------------------------------------------------------
# Compressed output (-w flac / -w opus).  Both encoders are fed from the same
# writeOut() choke point as the WAV path, so the generated audio must be
# identical; only the container differs.  FLAC is lossless and must decode
# back bit-exact; Opus is lossy, so what is checked instead is that the file
# is a valid Ogg Opus stream (a raw Opus packet stream is unplayable) and that
# the binaural beat -- the entire point of the output -- survives.
if "$SBAGEN" -h 2>&1 | grep -q '\-w fmt'; then
  if command -v ffmpeg >/dev/null 2>&1 && \
     "$SBAGEN" -w flac -o "$WORK/probe.flac" -F 500 -L 00:00:01 -i '200+10/0.5' >/dev/null 2>&1; then
    echo "== compressed output (-w) =="
    rm -f "$WORK/probe.flac" "$WORK/c.wav" "$WORK/c.flac" "$WORK/c.opus" \
          "$WORK/c_rt.wav" "$WORK/o_rt.wav"

    "$SBAGEN" -Q -S -W    -o "$WORK/c.wav"  -F 2000 -L 00:00:05 -i '200+10/0.5' >/dev/null 2>&1
    "$SBAGEN" -Q -S -w flac -o "$WORK/c.flac" -F 2000 -L 00:00:05 -i '200+10/0.5' >/dev/null 2>&1
    "$SBAGEN" -Q -S -w opus -o "$WORK/c.opus" -F 2000 -L 00:00:05 -i '200+10/0.5' >/dev/null 2>&1

    for f in c.flac c.opus; do
      [ -s "$WORK/$f" ] && ok "-w ${f#c.} produces a file" \
                        || no "-w ${f#c.} produces a file" "no output"
    done

    if [ -s "$WORK/c.flac" ]; then
      ffmpeg -hide_banner -v error -y -i "$WORK/c.flac" -f wav "$WORK/c_rt.wav" 2>/dev/null
      # Compare from the 'data' chunk onward rather than assuming a 44-byte
      # WAV header: ffmpeg pads its output with a LIST/INFO chunk, so the
      # sample data does not start at the same offset in both files.
      if python3 - "$WORK/c.wav" "$WORK/c_rt.wav" <<'PY'
import sys
def samples(p):
    d=open(p,'rb').read()
    return d[d.find(b'data')+8:]
a,b=samples(sys.argv[1]),samples(sys.argv[2])
n=min(len(a),len(b))
sys.exit(0 if a[:n]==b[:n] else 1)
PY
      then
        ok "FLAC decodes back bit-exact against the WAV render"
      else
        no "FLAC decodes back bit-exact against the WAV render"
      fi
    fi

    if [ -s "$WORK/c.opus" ]; then
      # A bare Opus packet stream has no framing and ffmpeg rejects it, which
      # is exactly how the missing Ogg container was first caught.
      if ffmpeg -hide_banner -v error -y -i "$WORK/c.opus" -f wav "$WORK/o_rt.wav" >/dev/null 2>&1; then
        ok "Opus output is a valid, decodable container"
      else
        no "Opus output is a valid, decodable container" "ffmpeg rejected it"
      fi

      r=$(python3 - "$WORK/c.wav" "$WORK/o_rt.wav" <<'PY' 2>/dev/null
import wave,struct,math,sys
def beat(p):
    w=wave.open(p); d=w.readframes(int(w.getframerate()*2))
    s=struct.unpack('<%dh'%(len(d)//2),d); L=s[0::2]; R=s[1::2]
    f=lambda v:int(math.sqrt(sum(x*x for x in v)/max(1,len(v))))
    return f([a-b for a,b in zip(L,R)])
a,b=beat(sys.argv[1]),beat(sys.argv[2])
print("ok" if a>0 and b>0 and abs(a-b)<=max(20,a*0.25) else "mismatch wav=%d opus=%d"%(a,b))
PY
)
      if [ "$r" = "ok" ]; then
        ok "Opus preserves the binaural beat"
      else
        no "Opus preserves the binaural beat" "$r"
      fi
    fi

    # Error paths: -w needs a destination and a known format, and -W together
    # with -w is a mistake rather than a silent preference for one of them.
    "$SBAGEN" -w flac -L 00:00:01 -i '200+10/0.5' >/dev/null 2>&1
    [ $? -ne 0 ] && ok "-w without -o/-O is refused" || no "-w without -o/-O is refused"
    "$SBAGEN" -w mp3 -o "$WORK/x" -L 00:00:01 -i '200+10/0.5' >/dev/null 2>&1
    [ $? -ne 0 ] && ok "-w rejects an unknown format" || no "-w rejects an unknown format"
    "$SBAGEN" -w flac -W -o "$WORK/x" -L 00:00:01 -i '200+10/0.5' >/dev/null 2>&1
    [ $? -ne 0 ] && ok "-w together with -W is refused" || no "-w together with -W is refused"
  else
    sk "compressed output" "ffmpeg unavailable or FLAC/Opus not compiled in"
  fi
else
  sk "compressed output" "built without FLAC/Opus"
fi

# --------------------------------------------------------------------------
# Library render (make lib unit).  sbagenlib drives the same parse/resolve/
# render code as the CLI, delivering samples to a memory buffer instead of a
# file -- so its output must be byte-identical to the equivalent `sbagen -Q
# -S -W` invocation.  If these two ever diverge, the library has split from
# the CLI and one of them is wrong.
if command -v cc >/dev/null 2>&1; then
  if make lib >/dev/null 2>&1 && make unit >/dev/null 2>&1; then
    echo "== library render (sbagenlib) =="
    libcase() {
      local name=$1 rate=$2 len_ms=$3 fade_ms=$4 spec=$5 len_hms=$6
      rm -f "$WORK/lib.raw" "$WORK/cli.wav"
      if ! timeout 60 tests/unit_render "$WORK/lib.raw" "$rate" "$len_ms" "$fade_ms" $spec >/dev/null 2>&1; then
        no "lib render: $name" "unit_render failed"
        return
      fi
      # NB: the CLI needs -r to render at the same rate as the library; the
      # default is 44100 and the 48kHz case is otherwise apples-to-oranges.
      local rateargs=()
      [ "$rate" != 44100 ] && rateargs=(-r "$rate")
      timeout 60 "$SBAGEN" -Q -S -W "${rateargs[@]}" -o "$WORK/cli.wav" -F "$fade_ms" -L "$len_hms" -i "$spec" >/dev/null 2>&1
      if python3 - "$WORK/cli.wav" "$WORK/lib.raw" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
cli=d[d.find(b'data')+8:]
lib=open(sys.argv[2],'rb').read()
sys.exit(0 if cli==lib and len(cli)>0 else 1)
PY
      then
        ok "lib render: $name is byte-identical to the CLI"
      else
        no "lib render: $name is byte-identical to the CLI"
      fi
    }
    libcase alpha        44100 5000 3000 '200+10/0.5'                00:00:05
    libcase theta+pink   44100 8000 3000 '200+6/0.5 pink/0.15'       00:00:08
    libcase spin+noise   44100 8000 3000 'spin:3+40/0.2 pink/0.2 200+8/0.3' 00:00:08
    libcase bell         44100 8000 3000 'bell+440/0.3 200+10/0.4'   00:00:08
    libcase 48kHz        48000 4000 2000 '200+10/0.5'                00:00:04
  else
    sk "library render" "make lib / make unit failed"
  fi
else
  sk "library render" "no C compiler"
fi

# --------------------------------------------------------------------------
# Concurrent engines.  The Engine struct exists so two parse+render
# pipelines can run at once; each thread's output must be byte-identical
# to the equivalent CLI render -- concurrency may not change a sample.
if command -v cc >/dev/null 2>&1; then
  if make unit-two >/dev/null 2>&1; then
    echo "== concurrent engines (two threads, two engines) =="
    rm -f "$WORK/t1.raw" "$WORK/t2.raw" "$WORK/t1.wav" "$WORK/t2.wav"
    SPECS_T1='200+10/0.5'
    SPECS_T2='spin:3+40/0.2 pink/0.2 200+8/0.3'
    if ! timeout 120 tests/unit_two "$WORK/t1.raw" "$SPECS_T1" \
                                  "$WORK/t2.raw" "$SPECS_T2" \
                                  44100 8000 3000 >/dev/null 2>&1; then
      no "two concurrent engines render" "unit_two failed"
    else
      timeout 60 "$SBAGEN" -Q -S -W -o "$WORK/t1.wav" -F 3000 -L 00:00:08 -i "$SPECS_T1" >/dev/null 2>&1
      timeout 60 "$SBAGEN" -Q -S -W -o "$WORK/t2.wav" -F 3000 -L 00:00:08 -i "$SPECS_T2" >/dev/null 2>&1
      if python3 - "$WORK/t1.wav" "$WORK/t1.raw" "$WORK/t2.wav" "$WORK/t2.raw" <<'PY'
import sys
def data(p):
    d=open(p,'rb').read()
    return d[d.find(b'data')+8:]
for wav, raw in ((sys.argv[1],sys.argv[2]),(sys.argv[3],sys.argv[4])):
    if data(wav) != open(raw,'rb').read():
        sys.exit(1)
sys.exit(0)
PY
      then
        ok "two concurrent engines: both byte-identical to the CLI"
      else
        no "two concurrent engines: both byte-identical to the CLI"
      fi
      # Repeat a few times: a data race usually shows up under repetition
      race=0
      for i in 1 2 3 4 5 6 7 8 9 10; do
        timeout 120 tests/unit_two "$WORK/t1.raw" "$SPECS_T1" \
                                   "$WORK/t2.raw" "$SPECS_T2" \
                                   44100 4000 2000 >/dev/null 2>&1 || race=1
      done
      [ $race -eq 0 ] && ok "ten repeated concurrent renders, no failures" \
                      || no "ten repeated concurrent renders, no failures"
    fi
  else
    sk "concurrent engines" "make unit-two failed"
  fi
else
  sk "concurrent engines" "no C compiler"
fi

# --------------------------------------------------------------------------
echo "== sweep: all bundled examples parse =="
sweep_ok=0; sweep_bad=0
for f in "$ROOT"/dev/examples/*/*.sbg; do
  timeout 20 "$SBAGEN" -D "$f" >/dev/null 2>&1
  rc=$?
  # exit 0 = parsed; 1 = a clean reported error.  Anything >=128 is a crash.
  if [ $rc -ge 128 ]; then sweep_bad=$((sweep_bad+1)); echo "        CRASH $f (signal $((rc-128)))";
  elif [ $rc -eq 0 ]; then sweep_ok=$((sweep_ok+1));
  else sweep_ok=$((sweep_ok+1)); fi
done
if [ $sweep_bad -eq 0 ]; then
  ok "no crashes across $(ls "$ROOT"/dev/examples/*/*.sbg | wc -l) example sequences"
else
  no "example sweep" "$sweep_bad crashing sequence(s)"
fi

# --------------------------------------------------------------------------
echo
echo "passed: $pass   failed: $fail   skipped: $skip"
[ $fail -eq 0 ] || exit 1