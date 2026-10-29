#!/bin/bash
. "$(dirname "$0")/lib.sh"

# process transcribes mic.m4a and call.m4a on their own and merges them with the
# real mb-transcript into a Me and Them transcript. speech-analyzer and fm are faked.

# The real helper: tests/run.sh builds it into MB_TEST_BIN. Run alone, build it here.
if [ -n "${MB_TEST_BIN:-}" ] && [ -x "$MB_TEST_BIN/mb-transcript" ]; then
  TRANSCRIPT_BIN="$MB_TEST_BIN/mb-transcript"
else
  TRANSCRIPT_BIN="$HOME/mb-transcript"
  swiftc -suppress-warnings -o "$TRANSCRIPT_BIN" "$ROOT"/native/transcript/*.swift \
    || { fail "mb-transcript does not compile"; finish; }
fi

FIX="$ROOT/tests/fixtures"
SA_FAIL=""      # none | call | both

have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }
notify() { :; }
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  for a in "$@"; do :; done   # the audio is the last argument
  case " $* " in
    *" -f json "*)
      case "$a" in
        *mic.m4a)  [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
        *call.m4a) [ "$SA_FAIL" = both ] || [ "$SA_FAIL" = call ] && return 1; cat "$FIX/sa-call.json" ;;
        *) return 1 ;;
      esac ;;
    *) echo "a plain transcript of the whole mix" ;;
  esac
}
fm() {
  case "$1" in
    count-tokens) cat >/dev/null; echo 100 ;;
    respond) cat >> "$HOME/fm-input.txt"; echo "the minutes" ;;
    *) return 1 ;;
  esac
}

meeting() {
  d="$HOME/$1"; shift
  mkdir -p "$d"
  for f in "$@"; do printf 'aac' > "$d/$f"; done
  printf '%s' "$d"
}

# --- three files: a labelled transcript, the echo heard once ---
d="$(meeting m1 audio.m4a mic.m4a call.m4a)"
: > "$HOME/fm-input.txt"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
t="$d/transcript.txt"
if [ "$rc" -eq 0 ] && [ -s "$t" ] && ! grep -qvE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] (Me|Them): ' "$t" \
   && grep -q '] Me: ' "$t" && grep -q '] Them: ' "$t"; then
  pass "three files give [HH:MM:SS] Me/Them lines"
else fail "three files give [HH:MM:SS] Me/Them lines (rc $rc): $out $(cat "$t" 2>/dev/null)"; fi
if [ "$(grep -o 'sounds good' "$t" | wc -l | tr -d ' ')" = 1 ]; then pass "the echoed words appear once"
else fail "the echoed words appear once: $(cat "$t")"; fi
if [ -s "$d/mic.words.json" ] && [ -s "$d/call.words.json" ]; then pass "word timings kept in the meeting folder"
else fail "word timings kept in the meeting folder"; fi

# --- what fm read has no timestamps ---
if [ -s "$HOME/fm-input.txt" ] && ! grep -q '\[00:' "$HOME/fm-input.txt" \
   && grep -q '^Me: ' "$HOME/fm-input.txt"; then
  pass "fm gets the transcript without timestamps, labels kept"
else fail "fm gets the transcript without timestamps, labels kept: $(cat "$HOME/fm-input.txt")"; fi
if [ -n "$(cat "$d/notes.md" 2>/dev/null)" ] && ! ls -a "$d" | grep -q '^\.work'; then
  pass "minutes written, working folder cleaned up"
else fail "minutes written, working folder cleaned up"; fi

# --- the call side fails: carry on with Me only, and say so ---
d="$(meeting m2 audio.m4a mic.m4a call.m4a)"
SA_FAIL=call
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
t="$d/transcript.txt"
if [ "$rc" -eq 0 ] && [ -s "$t" ] && ! grep -qv '] Me: ' "$t"; then pass "call side failing: transcript is all Me"
else fail "call side failing: transcript is all Me (rc $rc): $out"; fi
if printf '%s' "$out" | grep -q 'warn.*call.m4a'; then pass "call side failing: a warning names it"
else fail "call side failing: a warning names it: $out"; fi

# --- both fail: die with mb-transcript's message, audio left alone ---
d="$(meeting m3 audio.m4a mic.m4a call.m4a)"
SA_FAIL=both
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no speech found on either channel'; then
  pass "both sides failing dies with no speech found"
else fail "both sides failing dies with no speech found (rc $rc): $out"; fi
if [ -s "$d/audio.m4a" ] && [ -s "$d/mic.m4a" ] && [ -s "$d/call.m4a" ] && [ ! -e "$d/transcript.txt" ]; then
  pass "both sides failing leaves the audio and writes no transcript"
else fail "both sides failing leaves the audio and writes no transcript"; fi
SA_FAIL=""

# --- only audio.m4a: the v1.2 path, one plain speech-analyzer call ---
d="$(meeting m4 audio.m4a)"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
n="$(grep -c '^speech-analyzer ' "$HOME/calls.log")"
if [ "$rc" -eq 0 ] && [ "$n" = 1 ] && ! grep -q -- '-f json' "$HOME/calls.log" \
   && grep -q 'plain transcript' "$d/transcript.txt"; then
  pass "audio.m4a alone takes the old path"
else fail "audio.m4a alone takes the old path (rc $rc, $n calls): $out"; fi

# --- --no-keep-audio bins all three m4a files ---
d="$(meeting m5 audio.m4a mic.m4a call.m4a)"
KEEP_AUDIO=0
(process "$d/audio.m4a") >/dev/null 2>&1
if [ -s "$d/transcript.txt" ] && [ ! -e "$d/audio.m4a" ] && [ ! -e "$d/mic.m4a" ] && [ ! -e "$d/call.m4a" ]; then
  pass "--no-keep-audio removes audio, mic and call"
else fail "--no-keep-audio removes audio, mic and call"; fi
KEEP_AUDIO=1

# --- split_chunks keeps line breaks and ends a chunk at a line end ---
# 10 words a line and n=14: past n at the end of line 2 (20 words), under the
# hard cap of 21, so the first chunk is lines 1 and 2 and the second is line 3.
f="$HOME/lines.txt"
for l in 1 2 3; do
  printf 'w%s1 w%s2 w%s3 w%s4 w%s5 w%s6 w%s7 w%s8 w%s9 w%s10\n' $l $l $l $l $l $l $l $l $l $l
done > "$f"
split_chunks "$f" "$HOME/chunks" 14 > "$HOME/chunks.list"
ok_chunks=1; n=0
while IFS= read -r c; do
  n=$((n + 1))
  # every line in a chunk is a whole input line
  grep -qvE '^w([0-9])1( w\1[0-9]+)* w\110$' "$c" && ok_chunks=0
done < "$HOME/chunks.list"
if [ "$n" = 2 ] && [ "$ok_chunks" = 1 ] && [ "$(wc -l < "$(head -n 1 "$HOME/chunks.list")" | tr -d ' ')" = 2 ]; then
  pass "split_chunks ends each chunk at a line end"
else fail "split_chunks ends each chunk at a line end ($n chunks): $(cat "$HOME"/chunks/*)"; fi

# a line with no end in sight still splits at n * 1.5
printf 'a b c d e f g h i j k l m n o p q r s t u v w x y z\n' > "$f"
split_chunks "$f" "$HOME/chunks2" 10 > "$HOME/chunks2.list"
if [ "$(grep -c . "$HOME/chunks2.list")" = 2 ] && [ "$(wc -w < "$HOME/chunks2/chunk-001.txt" | tr -d ' ')" = 15 ]; then
  pass "split_chunks still cuts a long line at n * 1.5"
else fail "split_chunks still cuts a long line at n * 1.5: $(cat "$HOME"/chunks2/*)"; fi

finish
