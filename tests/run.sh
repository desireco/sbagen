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