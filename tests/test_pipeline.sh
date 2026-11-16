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
SA_FAIL=""      # none | call | both | garbled

have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }
notify() { :; }
chime() { echo "chime $1" >> "$HOME/calls.log"; }
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  for a in "$@"; do :; done   # the audio is the last argument
  case " $* " in
    *" -f json "*)
      case "$a" in
        *mic.m4a)  [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
        *call.m4a) [ "$SA_FAIL" = both ] || [ "$SA_FAIL" = call ] && return 1
                   if [ "$SA_FAIL" = garbled ]; then printf '{"words":[{"start":1'; return 0; fi
                   cat "$FIX/sa-call.json" ;;
        *audio.m4a) [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
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
if [ "$rc" -eq 0 ] && [ -s "$t" ] && ! grep -qvE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] [A-Za-z][A-Za-z0-9 ]*: ' "$t" \
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
if grep -q '^chime done$' "$HOME/calls.log"; then pass "minutes ready plays the done sound"
else fail "minutes ready plays the done sound"; fi
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

# --- the call side writes broken JSON but says it worked: still Me only, and say so ---
d="$(meeting m2b audio.m4a mic.m4a call.m4a)"
SA_FAIL=garbled
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
t="$d/transcript.txt"
if [ "$rc" -eq 0 ] && [ -s "$t" ] && ! grep -qv '] Me: ' "$t" && printf '%s' "$out" | grep -q 'call.words.json'; then
  pass "a garbled call side still gives the Me transcript, with a warning"
else fail "a garbled call side still gives the Me transcript, with a warning (rc $rc): $out"; fi
SA_FAIL=""

# --- both fail: most likely Speech Recognition is off, so say so; audio left alone ---
d="$(meeting m3 audio.m4a mic.m4a call.m4a)"
SA_FAIL=both
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'failed on both sides. Check Speech Recognition in Privacy settings' \
   && ! printf '%s' "$out" | grep -q 'no speech found'; then
  pass "both sides failing points at Speech Recognition"
else fail "both sides failing points at Speech Recognition (rc $rc): $out"; fi
if [ -s "$d/audio.m4a" ] && [ -s "$d/mic.m4a" ] && [ -s "$d/call.m4a" ] && [ ! -e "$d/transcript.txt" ]; then
  pass "both sides failing leaves the audio and writes no transcript"
else fail "both sides failing leaves the audio and writes no transcript"; fi
SA_FAIL=""

# --- Apple's transcriber refused on both sides, whisper there: use whisper instead ---
d="$(meeting m3b audio.m4a mic.m4a call.m4a)"
SA_FAIL=both
have() { case "$1" in speech-analyzer|fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
find_whisper_model() { echo "$HOME/model.bin"; }
ffmpeg() { for a in "$@"; do :; done; printf 'wav' > "$a"; }
whisper-cli() {
  echo "whisper-cli $*" >> "$HOME/calls.log"
  local prev="" a o=""
  for a in "$@"; do [ "$prev" = --output-file ] && o="$a"; prev="$a"; done
  cp "$FIX/whisper.json" "$o.json"
}
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$d/transcript.txt" ] && [ "$(grep -c '^whisper-cli' "$HOME/calls.log")" = 2 ] \
   && printf '%s' "$out" | grep -q 'trying whisper'; then
  pass "Apple's transcriber failing on both sides falls back to whisper"
else fail "Apple's transcriber failing on both sides falls back to whisper (rc $rc): $out"; fi
SA_FAIL=""
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }

# --- only audio.m4a: a recording kept as one file, its words with their times from Apple's (Task 11A) ---
d="$(meeting m4 audio.m4a)"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
n="$(grep -c '^speech-analyzer ' "$HOME/calls.log")"
if [ "$rc" -eq 0 ] && [ "$n" = 1 ] && grep -q '^speech-analyzer .*-f json .*audio\.m4a$' "$HOME/calls.log" \
   && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Hi everyone can you hear me sounds good" ] \
   && cmp -s "$d/words.json" "$FIX/sa-mic.json" && [ ! -e "$d/mic.words.json" ] \
   && printf '%s' "$out" | grep -q 'Parakeet is not set up, so speakers are not told apart: the transcript says Unknown'; then
  pass "audio.m4a alone: Apple's words with their times, Unknown lines (no speech helper), and words.json kept"
else fail "audio.m4a alone: Apple's words with their times, Unknown lines (no speech helper), and words.json kept (rc $rc, $n calls): $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi

# --- --no-keep-audio bins all three m4a files ---
d="$(meeting m5 audio.m4a mic.m4a call.m4a)"
KEEP_AUDIO=0
(process "$d/audio.m4a") >/dev/null 2>&1
if [ -s "$d/transcript.txt" ] && [ ! -e "$d/audio.m4a" ] && [ ! -e "$d/mic.m4a" ] && [ ! -e "$d/call.m4a" ]; then
  pass "--no-keep-audio removes audio, mic and call"
else fail "--no-keep-audio removes audio, mic and call"; fi
# ...but only once the minutes exist: a run that fails after transcribing keeps every file
d="$(meeting m5b audio.m4a mic.m4a call.m4a)"
have() { case "$1" in speech-analyzer) return 0 ;; *) return 1 ;; esac; }   # no fm: summarise fails
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }
if [ "$rc" -ne 0 ] && [ -s "$d/transcript.txt" ] && [ -s "$d/audio.m4a" ] && [ -s "$d/mic.m4a" ] && [ -s "$d/call.m4a" ]; then
  pass "--no-keep-audio never removes audio from a run that fails before the minutes"
else fail "--no-keep-audio never removes audio from a run that fails before the minutes (rc $rc): $(ls "$d") $out"; fi
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

# ======================================================= the processing lock, result and progress

# As the script reads it: in UTC, so a reader in another time zone reads the same text.
lstart_of() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
sa_calls() { grep -c '^speech-analyzer ' "$HOME/calls.log" | tr -d ' '; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }
# A PID that has finished: nothing runs under it now.
sh -c 'exit 0' & dead_pid=$!; wait "$dead_pid"
# Nothing of the lock's own making left in the folder: no lock, no temp, no stale copy.
lock_clean() { ! ls -a "$1" | grep -q '^\.processing\|^\.process-result\.'; }

# --- success: the result names the attempt and status 0, written privately; the lock is gone ---
d="$(meeting r1 audio.m4a mic.m4a call.m4a)"
out="$( (MB_ATTEMPT=attempt-one; export MB_ATTEMPT; process "$d/audio.m4a") 2>&1 )"; rc=$?
r="$(cat "$d/.process-result" 2>/dev/null)"
if [ "$rc" -eq 0 ] && printf '%s' "$r" | grep -qE '^attempt=attempt-one status=0 started=[0-9T:+Z-]+ finished=[0-9T:+Z-]+$'; then
  pass "a finished process writes .process-result with MB_ATTEMPT and status 0"
else fail "a finished process writes .process-result with MB_ATTEMPT and status 0 (rc $rc): [$r] $out"; fi
if [ "$(mode_of "$d/.process-result")" = 600 ]; then pass ".process-result is 0600"
else fail ".process-result is 0600: $(mode_of "$d/.process-result")"; fi
if [ ! -e "$d/.processing" ] && lock_clean "$d"; then pass "the lock is gone after success"
else fail "the lock is gone after success: $(ls -a "$d")"; fi

# --- from a terminal, with no MB_ATTEMPT ---
d="$(meeting r2 audio.m4a mic.m4a call.m4a)"
(process "$d/audio.m4a") >/dev/null 2>&1
if grep -q '^attempt=terminal status=0 ' "$d/.process-result" 2>/dev/null; then pass "with no MB_ATTEMPT the result says terminal"
else fail "with no MB_ATTEMPT the result says terminal: $(cat "$d/.process-result" 2>/dev/null)"; fi

# --- failure: the result carries the failing status; the lock is gone ---
d="$(meeting r3 audio.m4a mic.m4a call.m4a)"
SA_FAIL=both
out="$( (MB_ATTEMPT=attempt-two; export MB_ATTEMPT; process "$d/audio.m4a") 2>&1 )"; rc=$?
SA_FAIL=""
if [ "$rc" -ne 0 ] && grep -q "^attempt=attempt-two status=$rc " "$d/.process-result" 2>/dev/null; then
  pass "a failed process writes .process-result with its exit status"
else fail "a failed process writes .process-result with its exit status (rc $rc): $(cat "$d/.process-result" 2>/dev/null)"; fi
if [ ! -e "$d/.processing" ] && lock_clean "$d"; then pass "the lock is gone after failure"
else fail "the lock is gone after failure: $(ls -a "$d")"; fi

# --- the result is written aside and moved into place ---
if grep -q 'process-result' "$ROOT/meetingbox" && grep -q 'mv -f "$tmp_result" "$result"' "$ROOT/meetingbox"; then
  pass ".process-result is written to a temp file, then moved"
else fail ".process-result is written to a temp file, then moved"; fi

# --- a lock held by a live owner: refused, nothing run, nothing written, lock untouched ---
d="$(meeting l1 audio.m4a mic.m4a call.m4a)"
mkdir "$d/.processing"
printf '%s %s\n' "$$" "$(lstart_of $$)" > "$d/.processing/owner"
before="$(cat "$d/.processing/owner")"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already being processed' && [ "$(sa_calls)" = 0 ] \
   && [ ! -e "$d/transcript.txt" ] && [ ! -e "$d/.process-result" ] && [ "$(cat "$d/.processing/owner")" = "$before" ]; then
  pass "a live owner's lock is refused: already being processed, nothing run or written"
else fail "a live owner's lock is refused: already being processed, nothing run or written (rc $rc): $out"; fi
if [ "$rc" = 75 ]; then pass "the refusal exits 75, so the app can tell it from a failure"
else fail "the refusal exits 75, so the app can tell it from a failure (rc $rc)"; fi

# --- the same PID with a different start time is a reused PID: stale ---
printf '%s %s\n' "$$" "Thu Jan  1 00:00:00 2026" > "$d/.processing/owner"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$d/notes.md" ] && [ ! -e "$d/.processing" ] && lock_clean "$d"; then
  pass "a live PID with another start time is a reused PID: the lock is stale and replaced"
else fail "a live PID with another start time is a reused PID: the lock is stale and replaced (rc $rc): $out"; fi

# --- a dead owner: stale, replaced, and removed after ---
d="$(meeting l2 audio.m4a mic.m4a call.m4a)"
mkdir "$d/.processing"
printf '%s %s\n' "$dead_pid" "Thu Jan  1 00:00:00 2026" > "$d/.processing/owner"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$d/notes.md" ] && [ ! -e "$d/.processing" ] && lock_clean "$d"; then
  pass "a dead owner's lock is stale, taken over, and gone after"
else fail "a dead owner's lock is stale, taken over, and gone after (rc $rc): $out $(ls -a "$d")"; fi

# --- no owner yet and a fresh change time: someone is between mkdir and writing owner ---
d="$(meeting l3 audio.m4a mic.m4a call.m4a)"
mkdir "$d/.processing"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" = 75 ] && printf '%s' "$out" | grep -q 'already being processed' && [ "$(sa_calls)" = 0 ] && [ -d "$d/.processing" ]; then
  pass "a lock with no owner and a fresh change time is respected"
else fail "a lock with no owner and a fresh change time is respected (rc $rc): $out"; fi
# ...and once it is older than the grace, it is stale
PROCESS_LOCK_GRACE=0
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
PROCESS_LOCK_GRACE=10
if [ "$rc" -eq 0 ] && [ ! -e "$d/.processing" ] && lock_clean "$d"; then
  pass "a lock with no owner past the grace is stale and replaced"
else fail "a lock with no owner past the grace is stale and replaced (rc $rc): $out"; fi

# --- a second process while the first is running: refused, the first finishes ---
SA_SLOW=0.4
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  if [ -n "$SA_SLOW" ]; then
    mkdir "$HOME/inside" 2>/dev/null || echo "OVERLAP" >> "$HOME/calls.log"
    sleep "$SA_SLOW"
    rmdir "$HOME/inside" 2>/dev/null
  fi
  for a in "$@"; do :; done
  case "$a" in
    *mic.m4a)  cat "$FIX/sa-mic.json" ;;
    *call.m4a) cat "$FIX/sa-call.json" ;;
    *) return 1 ;;
  esac
}
d="$(meeting l4 audio.m4a mic.m4a call.m4a)"
: > "$HOME/calls.log"
(process "$d/audio.m4a") >"$HOME/first.out" 2>&1 & first=$!
for _ in $(seq 1 100); do [ -s "$d/.processing/owner" ] && break; sleep 0.02; done
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
wait "$first"; rc1=$?
if [ "$rc" = 75 ] && printf '%s' "$out" | grep -q 'already being processed' && [ "$rc1" -eq 0 ] \
   && [ "$(sa_calls)" = 2 ] && ! grep -q OVERLAP "$HOME/calls.log" && [ ! -e "$d/.processing" ] && lock_clean "$d"; then
  pass "a second process on a folder being processed is refused; the first finishes alone"
else fail "a second process on a folder being processed is refused; the first finishes alone (rc $rc, first $rc1): $out $(cat "$HOME/calls.log")"; fi

# --- I1: the holder and the second worker in different time zones: still refused ---
d="$(meeting tz audio.m4a mic.m4a call.m4a)"
: > "$HOME/calls.log"
(TZ=Pacific/Kiritimati; export TZ; process "$d/audio.m4a") >"$HOME/first.out" 2>&1 & first=$!
for _ in $(seq 1 100); do [ -s "$d/.processing/owner" ] && break; sleep 0.02; done
out="$( (unset TZ; process "$d/audio.m4a") 2>&1 )"; rc=$?
wait "$first"; rc1=$?
if [ "$rc" = 75 ] && [ "$rc1" -eq 0 ] && [ "$(sa_calls)" = 2 ] && ! grep -q OVERLAP "$HOME/calls.log" && lock_clean "$d"; then
  pass "a holder in another time zone is still seen as alive: refused, one run"
else fail "a holder in another time zone is still seen as alive: refused, one run (rc $rc, first $rc1, $(sa_calls) calls): $out"; fi

# --- M5: a worker that cannot read its own start time takes no lock ---
eval "$(declare -f pid_lstart | sed '1s/pid_lstart/real_pid_lstart/')"
pid_lstart() { :; }
d="$(meeting m5x audio.m4a mic.m4a call.m4a)"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
eval "$(declare -f real_pid_lstart | sed '1s/real_pid_lstart/pid_lstart/')"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "could not read this process's start time" && [ "$(sa_calls)" = 0 ] \
   && [ ! -e "$d/.processing" ] && ! ls -a "$d" | grep -q '^\.process'; then
  pass "with no start time of its own, process takes no lock and runs nothing"
else fail "with no start time of its own, process takes no lock and runs nothing (rc $rc): $out $(ls -a "$d")"; fi

# --- two workers finding the same stale lock at once: exactly one runs ---
# The liveness check is slowed, so both read the stale owner before either replaces it.
if declare -f processing_lock_alive >/dev/null; then
  eval "$(declare -f processing_lock_alive | sed '1s/processing_lock_alive/real_processing_lock_alive/')"
  processing_lock_alive() { real_processing_lock_alive "$@"; local r=$?; sleep 0.3; return $r; }
fi
race_ok=1; race_log=""
for off in 0 0.05 0.15 0.35; do
  d="$(meeting "race$off" audio.m4a mic.m4a call.m4a)"
  mkdir "$d/.processing"
  printf '%s %s\n' "$dead_pid" "Thu Jan  1 00:00:00 2026" > "$d/.processing/owner"
  : > "$HOME/calls.log"
  (process "$d/audio.m4a") >"$HOME/a.out" 2>&1 & pa=$!
  sleep "$off"
  (process "$d/audio.m4a") >"$HOME/b.out" 2>&1 & pb=$!
  wait "$pa"; ra=$?; wait "$pb"; rb=$?
  pair="$ra $rb"
  if { [ "$pair" = "0 75" ] || [ "$pair" = "75 0" ]; } && [ "$(sa_calls)" = 2 ] && ! grep -q OVERLAP "$HOME/calls.log" \
     && cat "$HOME/a.out" "$HOME/b.out" | grep -q 'already being processed' && [ ! -e "$d/.processing" ] && lock_clean "$d"; then :
  else race_ok=0; race_log="$race_log [offset $off: $pair, $(sa_calls) calls, $(ls -a "$d" | tr '\n' ' ') $(cat "$HOME/a.out" "$HOME/b.out" | grep error)]"; fi
done
if [ "$race_ok" = 1 ]; then pass "two workers on one stale lock: exactly one runs, the other refuses"
else fail "two workers on one stale lock: exactly one runs, the other refuses:$race_log"; fi

# --- the winner keeps its own owner text, though a loser holds the owner file aside ---
# The contract is asserted on every run: one worker runs, the other exits 75, no lock is left,
# no bare cat/mv/ln error. Whether the loser got as far as holding the file aside is not part of
# it (a loser whose mv finds no file refuses with 75 too), so that is only counted in the name.
# The overrides below steer the loser towards holding it. The loser (the worker whose moved file is not the dead owner) holds the
# owner file aside until released, and the winner waits at its first clean-up until the loser
# is holding it. So the winner always looks for its owner file while it is missing. The order
# is fixed by mv, not by the clock: the first worker to move the stale owner waits until the
# second has also reached its mv (so both have read the stale owner), and the second waits until
# the first's owner is in place. Run without set -e (as the other tests do) and under
# set -euo pipefail (as the real script does).
dead_owner="$dead_pid Thu Jan  1 00:00:00 2026"
cat() {
  case "$*" in
    *.processing-stale.*)
      if [ "$(command cat "$@")" != "$dead_owner" ]; then : > "$HOME/loser.held"; sleep 0.6; fi ;;
  esac
  command cat "$@"
}
rm() {
  case "$*" in
    *.processing-stale.*)
      if [ ! -e "$HOME/loser.held" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
          [ -e "$HOME/loser.held" ] && break; sleep 0.1
        done
      fi ;;
  esac
  command rm "$@"
}
# Barrier: a worker that has judged the lock stale (the stale owner is in $2) waits, up to 30 s,
# until the other worker has too. Neither can then have seen the other's owner before its mv.
bar_alive() {
  local n
  real_processing_lock_alive "$@" && return 0
  if [ "$2" = "$dead_owner" ]; then
    if mkdir "$HOME/bar.1" 2>/dev/null; then
      for n in $(seq 1 600); do [ -d "$HOME/bar.2" ] && break; sleep 0.05; done
    else
      mkdir "$HOME/bar.2" 2>/dev/null
      for n in $(seq 1 600); do [ -d "$HOME/bar.1" ] && break; sleep 0.05; done
    fi
  fi
  return 1
}
eval "$(declare -f processing_lock_alive | sed '1s/processing_lock_alive/prev_processing_lock_alive/')"
eval "$(declare -f bar_alive | sed '1s/bar_alive/processing_lock_alive/')"
mv() {
  case "$*" in
    */owner\ *.processing-stale.*)
      local n
      if mkdir "$HOME/mv.first" 2>/dev/null; then
        for n in $(seq 1 600); do [ -d "$HOME/mv.second" ] && break; sleep 0.05; done
      else
        mkdir "$HOME/mv.second" 2>/dev/null
        for n in $(seq 1 600); do
          [ -e "$1" ] && [ "$(command cat "$1" 2>/dev/null)" != "$dead_owner" ] && break; sleep 0.05
        done
      fi ;;
  esac
  command mv "$@"
}
hold_ok=1; hold_log=""; held_n=0
for mode in "set +e" "set -euo pipefail"; do
  d="$(meeting "hold${mode// /}" audio.m4a mic.m4a call.m4a)"
  mkdir "$d/.processing"
  printf '%s\n' "$dead_owner" > "$d/.processing/owner"
  command rm -rf "$HOME/loser.held" "$HOME/mv.first" "$HOME/mv.second" "$HOME/bar.1" "$HOME/bar.2"
  : > "$HOME/calls.log"
  ( $mode; process "$d/audio.m4a" ) >"$HOME/a.out" 2>&1 & pa=$!
  ( $mode; process "$d/audio.m4a" ) >"$HOME/b.out" 2>&1 & pb=$!
  wait "$pa"; ra=$?; wait "$pb"; rb=$?
  pair="$ra $rb"
  if { [ "$pair" = "0 75" ] || [ "$pair" = "75 0" ]; } && [ "$(sa_calls)" = 2 ] && ! grep -q OVERLAP "$HOME/calls.log" \
     && ! cat "$HOME/a.out" "$HOME/b.out" | grep -Eq '(^|[^a-z])(cat|mv|ln|rm): |No such file' \
     && [ ! -e "$d/.processing" ] && lock_clean "$d"; then [ ! -e "$HOME/loser.held" ] || held_n=$((held_n + 1))
  else hold_ok=0; hold_log="$hold_log [$mode: $pair, $(sa_calls) calls, $(ls -a "$d" | tr '\n' ' ') $(cat "$HOME/a.out" "$HOME/b.out" | grep error)]"; fi
done
unset -f cat rm mv
eval "$(declare -f prev_processing_lock_alive | sed '1s/prev_processing_lock_alive/processing_lock_alive/')"
unset -f prev_processing_lock_alive
if [ "$hold_ok" = 1 ]; then pass "the winner keeps its own owner text while a loser holds the owner file: one runs, no lock left, with and without set -e (loser held it aside in $held_n of 2 runs)"
else fail "the winner keeps its own owner text while a loser holds the owner file:$hold_log"; fi

# --- M6: a TERM while a live owner's file is moved aside does not lose it ---
# The worker reads a stale owner, a live one replaces it, the worker moves the live one aside,
# and is sent TERM just then. It must put the live owner back and refuse.
d="$(meeting term1 audio.m4a mic.m4a call.m4a)"
mkdir "$d/.processing"
printf '%s %s\n' "$dead_pid" "Thu Jan  1 00:00:00 2026" > "$d/.processing/owner"
live="$$ $(lstart_of $$)"
cat() {
  case "$*" in *.processing-stale.*) kill -TERM "$(command cat "$HOME/worker.pid")"; sleep 0.1 ;; esac
  command cat "$@"
}
: > "$HOME/calls.log"
( sh -c 'printf "%s" "$PPID"' > "$HOME/worker.pid"; process "$d/audio.m4a" ) >"$HOME/term.out" 2>&1 & w=$!
sleep 0.15
printf '%s\n' "$live" > "$d/live.tmp"; mv "$d/live.tmp" "$d/.processing/owner"
wait "$w"; rc=$?
unset -f cat
if [ "$rc" = 75 ] && [ "$(cat "$d/.processing/owner" 2>/dev/null)" = "$live" ] && ! ls -a "$d" | grep -q '^\.processing-' \
   && [ "$(sa_calls)" = 0 ]; then
  pass "TERM while a live owner is moved aside: it is put back, and the worker refuses"
else fail "TERM while a live owner is moved aside: it is put back, and the worker refuses (rc $rc): $(ls -a "$d") $(cat "$HOME/term.out")"; fi
rm -f "$d/.processing/owner" "$d"/.processing-stale.* "$d"/.processing-owner.*; rmdir "$d/.processing"

if declare -f real_processing_lock_alive >/dev/null; then
  eval "$(declare -f real_processing_lock_alive | sed '1s/real_processing_lock_alive/processing_lock_alive/')"
fi
SA_SLOW=""

# --- progress: the stages in order with MB_PROGRESS_FILE, nothing without it ---
d="$(meeting p1 audio.m4a mic.m4a call.m4a)"
(MB_PROGRESS_FILE="$HOME/progress-p1"; export MB_PROGRESS_FILE; process "$d/audio.m4a") >/dev/null 2>&1
if [ "$(tr '\n' ' ' < "$HOME/progress-p1" 2>/dev/null)" = "transcribing speakers minutes done " ]; then
  pass "MB_PROGRESS_FILE gets transcribing, speakers, minutes, done in order"
else fail "MB_PROGRESS_FILE gets transcribing, speakers, minutes, done in order: $(cat "$HOME/progress-p1" 2>/dev/null)"; fi
d="$(meeting p2 audio.m4a mic.m4a call.m4a)"
before="$(ls -a "$HOME" | tr '\n' ' ')"
(process "$d/audio.m4a") >/dev/null 2>&1
if [ "$(ls -a "$HOME" | tr '\n' ' ')" = "$before" ] && ! ls -a "$d" | grep -qi progress; then
  pass "without MB_PROGRESS_FILE no progress file is written"
else fail "without MB_PROGRESS_FILE no progress file is written: $(ls -a "$d")"; fi

# --- every file process writes is private, even one an app it opens creates (Gate 1) ---
mkdir -p "$SA_APP/Contents/MacOS"
open() {
  local o="" prev="" a last=""
  for a in "$@"; do [ "$prev" = -o ] && o="$a"; prev="$a"; last="$a"; done
  # another app: it does not inherit our umask
  case "$last" in
    *mic.m4a)  (umask 022; cat "$FIX/sa-mic.json" > "$o") ;;
    *call.m4a) (umask 022; cat "$FIX/sa-call.json" > "$o") ;;
  esac
  return 0
}
fm() {
  case "$1" in
    count-tokens) cat >/dev/null; echo 100 ;;
    respond) cat >/dev/null
             case " $* " in *" --schema "*) echo '{"summary": "the brief"}' ;; *) echo "the minutes" ;; esac ;;
    schema) echo '{}' ;;
    *) return 1 ;;
  esac
}
d="$(meeting u1 audio.m4a mic.m4a call.m4a)"
(umask 022; process "$d/audio.m4a") >/dev/null 2>&1
bad=""
for f in mic.words.json call.words.json transcript.txt notes.md notes-raw.md brief.json .notes-written .process-result; do
  [ -e "$d/$f" ] || { bad="$bad $f(missing)"; continue; }
  [ "$(mode_of "$d/$f")" = 600 ] || bad="$bad $f($(mode_of "$d/$f"))"
done
if [ -z "$bad" ]; then pass "words.json, transcript, minutes, .notes-written and result are all 0600"
else fail "words.json, transcript, minutes, .notes-written and result are all 0600:$bad"; fi
# M4: and on failure too, when the transcriber wrote a file and then said Error
open() {
  local o="" e="" prev="" a
  for a in "$@"; do [ "$prev" = -o ] && o="$a"; [ "$prev" = --stderr ] && e="$a"; prev="$a"; done
  (umask 022; printf 'half' > "$o"; printf 'Error: it broke\n' > "$e")
  return 0
}
printf 'aac' > "$HOME/m4.m4a"
sa_run "$HOME/m4.words.json" "$HOME/m4.m4a" -f json 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ] && [ "$(mode_of "$HOME/m4.words.json")" = 600 ]; then pass "a transcriber's output is made 0600 on failure too"
else fail "a transcriber's output is made 0600 on failure too (rc $rc, $(mode_of "$HOME/m4.words.json"))"; fi
unset -f open
rmdir "$SA_APP/Contents/MacOS" "$SA_APP/Contents" "$SA_APP"

# === Parakeet: the default transcriber, with Apple's and then whisper behind it per side ===

# --- parse_args: the app's arguments, and --model still meaning whisper ---
got="$( (ENGINE=auto; WHISPER_MODEL=""; WRITER=""; parse_args process X --parakeet --writer apple
         printf '%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$WRITER" "$WHISPER_MODEL") 2>&1 )"
if [ "$got" = "process|X|parakeet|apple|" ]; then pass "parse_args: --parakeet --writer apple"
else fail "parse_args: --parakeet --writer apple: $got"; fi
got="$( (ENGINE=auto; WHISPER_MODEL=""; parse_args process X --model /x; printf '%s|%s' "$ENGINE" "$WHISPER_MODEL") 2>&1 )"
if [ "$got" = "whisper|/x" ]; then pass "parse_args: --model still means whisper"; else fail "parse_args: --model still means whisper: $got"; fi
got="$( (ENGINE=auto; WRITER=""; parse_args process X --native --writer apple; printf '%s|%s|%s' "$cmd" "$ENGINE" "$WRITER") 2>&1 )"
if [ "$got" = "process|native|apple" ]; then pass "parse_args: --native --writer apple"
else fail "parse_args: --native --writer apple: $got"; fi

# A stand-in mb-speech: check passes unless pk-unusable exists, and transcribe copies a fixture,
# or fails for a side named in pk-fail-<side> with the real helper's "mb-speech: " prefix, or
# finds no words for one named in pk-empty-<side>. It logs the WAV it was given and its TMPDIR.
# speakers also logs its output file and any further arguments, and fails for a side named in
# sp-fail-<side>, after leaving a partial file behind. pk-silent-<side> and sp-silent-<side> stop
# with 134, as a trap would, and say nothing.
mkdir -p "$HOME/speech"
SPEECH_BIN="$HOME/speech/mb-speech"; SPEECH_MODELS="$HOME/speech/models"
cat > "$SPEECH_BIN" <<EOF
#!/bin/bash
case "\$(basename "\${3:-}")" in call*) side=call ;; *) side=mic ;; esac
case "\$1" in
  speakers) echo "mb-speech speakers \$side wav=\$3 exists=\$([ -f "\$3" ] && echo yes) out=\$4 more=\${*:5} tmp=\$TMPDIR" >> "$HOME/calls.log" ;;
  *) echo "mb-speech \$1 wav=\$3 exists=\$([ -f "\$3" ] && echo yes) tmp=\$TMPDIR" >> "$HOME/calls.log" ;;
esac
case "\$1" in
  check) [ ! -e "$HOME/pk-unusable" ] ;;
  transcribe)
    [ -e "$HOME/pk-fail-\$side" ] && { echo "mb-speech: the model could not run" >&2; exit 1; }
    [ -e "$HOME/pk-silent-\$side" ] && exit 134
    [ -e "$HOME/pk-empty-\$side" ] && { printf '{"engine": "parakeet-ultra", "words": []}\n' > "\$4"; exit 0; }
    [ -e "$HOME/pk-labelled" ] && { cp "$FIX/labelled-\$side.json" "\$4"; exit 0; }
    cp "$FIX/pk-\$side.json" "\$4" ;;
  speakers)
    [ -e "$HOME/sp-silent-\$side" ] && exit 134
    if [ -e "$HOME/sp-fail-\$side" ]; then
      printf '{"model": "half' > "\$4"; printf '{"mod' > "\$(dirname "\$4")/.part-\$(basename "\$4")"
      echo "mb-speech: the diariser could not run" >&2; exit 1
    fi
    [ -e "$HOME/sp-garbled-\$side" ] && { printf '{"model": "FluidInference/speaker-diarization-coreml@x", "segm' > "\$4"; exit 0; }
    # a recording kept as one file (any other WAV) gets speakers-one.json, its first speaker with 30 s of talk
    case "\$(basename "\$3")" in mic*|call*) sps=\$side ;; *) sps=one ;; esac
    [ -e "$HOME/sp-fixture" ] && { cp "$FIX/speakers-\$sps.json" "\$4"; exit 0; }
    printf '{"model": "FluidInference/speaker-diarization-coreml@x", "segments": [], "speakers": []}\n' > "\$4" ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$SPEECH_BIN"
# Apple's transcriber as at the top of this file: the lock tests above replaced it.
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  for a in "$@"; do :; done
  case "$a" in
    *mic.m4a)  [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
    *call.m4a) [ "$SA_FAIL" = both ] || [ "$SA_FAIL" = call ] && return 1; cat "$FIX/sa-call.json" ;;
    *) return 1 ;;
  esac
}
# Every run in this section is checked for curl, though each case starts a fresh log.
PK_CURL=0; : > "$HOME/calls.log"
pk_reset() { grep -q '^curl' "$HOME/calls.log" && PK_CURL=1; : > "$HOME/calls.log"; rm -f "$HOME"/pk-*; ENGINE=auto; LOCALE=en-GB; SA_FAIL=""; }
pk_calls() { grep -c "^$1" "$HOME/calls.log" | tr -d ' '; }

# --- by default, Parakeet on both sides ---
pk_reset
d="$(meeting pk1 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && grep -q 'Them: Parakeet heard them' "$d/transcript.txt" \
   && [ "$(pk_calls speech-analyzer)" = 0 ] && printf '%s' "$out" | grep -q '(NVIDIA Parakeet)'; then
  pass "Parakeet transcribes both sides by default, and the log says so"
else fail "Parakeet transcribes both sides by default, and the log says so (rc $rc): $out"; fi
if [ "$(jq -r .engine "$d/mic.words.json")" = parakeet-ultra ] && [ "$(mode_of "$d/mic.words.json")" = 600 ] \
   && [ "$(mode_of "$d/call.words.json")" = 600 ]; then pass "Parakeet's words files are kept, 0600"
else fail "Parakeet's words files are kept, 0600"; fi
line="$(grep '^mb-speech transcribe' "$HOME/calls.log" | head -1)"
wav="$(printf '%s' "$line" | sed -n 's/.* wav=\([^ ]*\) .*/\1/p')"
case "$wav" in .stage.??????/.work.??????/mic.wav) wav_ok=1 ;; *) wav_ok=0 ;; esac
if [ "$wav_ok" = 1 ] && printf '%s' "$line" | grep -qF "exists=yes tmp=$(cd "$d" && pwd -P)/$(dirname "$wav")" \
   && ! ls -a "$d" | grep -q '^\.work\|^\.stage'; then
  pass "the helper gets a WAV in the work folder inside the run's stage, with TMPDIR there as a full path, and both are removed"
else fail "the helper gets a WAV in the work folder inside the run's stage, with TMPDIR there as a full path, and both are removed: $line"; fi
if [ "$(pk_calls curl)" = 0 ]; then pass "processing never calls curl"; else fail "processing never calls curl"; fi

# --- --native, or the app's preference for Apple, uses Apple's ---
pk_reset; ENGINE=native
d="$(meeting pk2 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls speech-analyzer)" = 2 ] && [ "$(pk_calls 'mb-speech transcribe')" = 0 ]; then
  pass "--native uses Apple's transcriber"; else fail "--native uses Apple's transcriber (rc $rc): $out"; fi
pk_reset
defaults() { echo "defaults $*" >> "$HOME/calls.log"; [ "$*" = "read com.jediconcepts.meetingbox transcriber" ] && echo apple; }
d="$(meeting pk3 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls speech-analyzer)" = 2 ] && [ "$(pk_calls 'mb-speech transcribe')" = 0 ]; then
  pass "the app's preference for Apple is followed"; else fail "the app's preference for Apple is followed (rc $rc): $out"; fi
defaults() { echo "defaults $*" >> "$HOME/calls.log"; return 1; }

# --- a meeting that is not in English uses Apple's, and says why ---
# MB_LOCALE, read by the engine's own settings line, as a run from the app or Terminal reads it
pk_reset; export MB_LOCALE=fr-FR
d="$(meeting pk4 audio.m4a mic.m4a call.m4a)"
out="$( (eval "$(grep '^LOCALE=' "$ROOT/meetingbox")"; process "$d/audio.m4a") 2>&1 )"; rc=$?
unset MB_LOCALE
if [ "$rc" -eq 0 ] && [ "$(pk_calls speech-analyzer)" = 2 ] && [ "$(pk_calls 'mb-speech transcribe')" = 0 ] \
   && printf '%s' "$out" | grep -q 'fr-FR.*Apple'; then
  pass "a meeting in fr-FR uses Apple's, and says why"; else fail "a meeting in fr-FR uses Apple's, and says why (rc $rc): $out"; fi

# --- Parakeet failing on one side: that side alone goes to Apple's ---
pk_reset; touch "$HOME/pk-fail-call"
d="$(meeting pk5 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && [ "$(pk_calls speech-analyzer)" = 1 ] \
   && grep -q '^speech-analyzer .*call.m4a' "$HOME/calls.log" && [ "$(jq -r '.engine // "apple"' "$d/call.words.json")" != parakeet-ultra ]; then
  pass "Parakeet failing on the call side retries that side with Apple's"
else fail "Parakeet failing on the call side retries that side with Apple's (rc $rc): $out"; fi

# --- Parakeet and Apple's failing on a side, whisper there: whisper for that side ---
pk_reset; touch "$HOME/pk-fail-call"; SA_FAIL=call
have() { case "$1" in speech-analyzer|fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
d="$(meeting pk6 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Me: Speaking' "$d/transcript.txt" && grep -q 'Them: Hello' "$d/transcript.txt" \
   && [ "$(pk_calls whisper-cli)" = 1 ] \
   && grep -q '^whisper-cli .* -f \.stage\.[^/ ]*/\.work\.[^/ ]*/call\.16k\.wav ' "$HOME/calls.log" && ! ls -a "$d" | grep -q '\.wav$\|^\.work\|^\.stage'; then
  pass "Parakeet and Apple's failing on the call side: whisper there, its WAV in the work folder"
else fail "Parakeet and Apple's failing on the call side: whisper there, its WAV in the work folder (rc $rc): $out"; fi
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }

# --- every transcriber failing on the call side only: Me only, and an empty words file ---
pk_reset; touch "$HOME/pk-fail-call"; SA_FAIL=call
d="$(meeting pk7 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && ! grep -qv '] Me: ' "$d/transcript.txt" \
   && [ "$(jq -c . "$d/call.words.json")" = '{"engine":"none","words":[]}' ] && [ "$(mode_of "$d/call.words.json")" = 600 ]; then
  pass "every transcriber failing on the call side gives a Me-only transcript and no words for it"
else fail "every transcriber failing on the call side gives a Me-only transcript and no words for it (rc $rc): $out"; fi

# --- every transcriber failing on both sides: refused as before ---
pk_reset; touch "$HOME/pk-fail-call" "$HOME/pk-fail-mic"; SA_FAIL=both
d="$(meeting pk8 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'failed on both sides' && [ ! -e "$d/transcript.txt" ]; then
  pass "every transcriber failing on both sides stops the run"
else fail "every transcriber failing on both sides stops the run (rc $rc): $out"; fi

# --- a helper that is not usable: Apple's, and the log says why ---
pk_reset; touch "$HOME/pk-unusable"
d="$(meeting pk9 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Parakeet is not set up' && [ "$(pk_calls speech-analyzer)" = 2 ] \
   && [ "$(pk_calls 'mb-speech transcribe')" = 0 ]; then
  pass "an unusable helper: Apple's transcriber, and the log says Parakeet is not set up"
else fail "an unusable helper: Apple's transcriber, and the log says Parakeet is not set up (rc $rc): $out"; fi

# --- a meeting with one file: Parakeet's words with their times, in labelled lines (Task 11A) ---
pk_reset
d="$(meeting pk10 audio.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Speaking from this desk." ] && [ "$(pk_calls speech-analyzer)" = 0 ] \
   && cmp -s "$d/words.json" "$FIX/pk-mic.json" && [ "$(mode_of "$d/words.json")" = 600 ] && ! ls -a "$d" | grep -q '^\.work\|^\.stage'; then
  pass "a single-file meeting gets Parakeet's words with their times (the finder found nobody: Unknown), and words.json, 0600"
else fail "a single-file meeting gets Parakeet's words with their times (the finder found nobody: Unknown), and words.json, 0600 (rc $rc): $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi

# --- a flag beats the app's preference ---
pk_reset; ENGINE=parakeet
defaults() { echo "defaults $*" >> "$HOME/calls.log"; [ "$*" = "read com.jediconcepts.meetingbox transcriber" ] && echo apple; }
d="$(meeting pk12 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls 'mb-speech transcribe')" = 2 ] && [ "$(pk_calls speech-analyzer)" = 0 ]; then
  pass "--parakeet beats the app's preference for Apple"; else fail "--parakeet beats the app's preference for Apple (rc $rc): $out"; fi
defaults() { echo "defaults $*" >> "$HOME/calls.log"; return 1; }

# --- a chosen transcriber that is not installed: said so, and the header names the one used ---
pk_reset; ENGINE=native
have() { case "$1" in fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
d="$(meeting pk13 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Apple's transcriber is not installed, so whisper is used" \
   && printf '%s' "$out" | grep -q 'each side on device (whisper.cpp)' && [ "$(pk_calls whisper-cli)" = 2 ]; then
  pass "--native without speech-analyzer says whisper is used instead"
else fail "--native without speech-analyzer says whisper is used instead (rc $rc): $out"; fi
pk_reset; ENGINE=whisper
have() { case "$1" in fm|speech-analyzer) return 0 ;; *) return 1 ;; esac; }
d="$(meeting pk14 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "whisper is not installed, so Apple's transcriber is used" \
   && printf '%s' "$out" | grep -q 'each side on device (Apple SpeechAnalyzer)' && [ "$(pk_calls speech-analyzer)" = 2 ]; then
  pass "--whisper without whisper-cli says Apple's is used instead"
else fail "--whisper without whisper-cli says Apple's is used instead (rc $rc): $out"; fi
pk_reset; touch "$HOME/pk-unusable"
have() { case "$1" in fm) return 0 ;; *) return 1 ;; esac; }
d="$(meeting pk15 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no transcriber installed. Run: meetingbox setup' \
   && ! printf '%s' "$out" | grep -q 'Speech Recognition'; then
  pass "with no transcriber installed, the run says so"
else fail "with no transcriber installed, the run says so (rc $rc): $out"; fi
pk_reset; touch "$HOME/pk-fail-mic"
have() { case "$1" in fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
d="$(meeting pk16 audio.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"
if printf '%s' "$out" | grep -q 'Parakeet could not transcribe audio.m4a, trying whisper' \
   && ! printf '%s' "$out" | grep -q "trying Apple's"; then
  pass "a single file: Parakeet failing with no Apple's transcriber says whisper is tried"
else fail "a single file: Parakeet failing with no Apple's transcriber says whisper is tried: $out"; fi
if [ "$(cat "$d/transcript.txt" 2>/dev/null)" = "[00:00:00] Unknown: Hello there thanks for coming" ] && cmp -s "$d/words.json" "$FIX/whisper.json"; then
  pass "a single file transcribed by whisper still gets its words' times, and its words.json"
else fail "a single file transcribed by whisper still gets its words' times, and its words.json: $(cat "$d/transcript.txt" 2>/dev/null) $out"; fi
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }

# --- the helper failing without a reason: the log still gives one ---
pk_reset; touch "$HOME/pk-silent-call"
d="$(meeting pk17 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'Parakeet: the speech helper stopped without giving a reason (exit 134)' \
   && ! printf '%s' "$out" | grep -q 'Parakeet: *$'; then
  pass "a helper failing without a reason logs a fixed one, with its exit status"
else fail "a helper failing without a reason logs a fixed one, with its exit status (rc $rc): $out"; fi

# --- the helper's reason is logged once, without its "mb-speech: " prefix ---
pk_reset; touch "$HOME/pk-fail-call"
d="$(meeting pk18 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Parakeet: the model could not run' && ! printf '%s' "$out" | grep -q 'mb-speech: '; then
  pass "Parakeet's log gives the helper's reason without its mb-speech: prefix"
else fail "Parakeet's log gives the helper's reason without its mb-speech: prefix (rc $rc): $out"; fi

# --- with no work folder, pk_run and whisper_words stop before writing anything ---
pk_reset
ffmpeg() { echo "ffmpeg $*" >> "$HOME/calls.log"; for a in "$@"; do :; done; printf 'wav' > "$a"; }
have() { case "$1" in speech-analyzer|fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
( WORK=""; pk_run "$HOME/pk1/mic.m4a" "$HOME/pk-none.json" ) >/dev/null 2>&1; rc1=$?
( WORK=""; whisper_words "$HOME/pk1/mic.m4a" "$HOME/pk-none.json" ) >/dev/null 2>&1; rc2=$?
if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ "$(pk_calls afconvert)" = 0 ] && [ "$(pk_calls ffmpeg)" = 0 ] \
   && [ "$(pk_calls 'mb-speech')" = 0 ] && [ "$(pk_calls whisper-cli)" = 0 ]; then
  pass "pk_run and whisper_words refuse an empty work folder"
else fail "pk_run and whisper_words refuse an empty work folder ($rc1 $rc2): $(cat "$HOME/calls.log")"; fi
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }
ffmpeg() { for a in "$@"; do :; done; printf 'wav' > "$a"; }   # the whisper test's stub again, without the log

# --- with SRC and OUT apart, SRC is left byte for byte as it was ---
pk_reset
src="$(meeting pk11 audio.m4a mic.m4a call.m4a)"; dst="$HOME/pk11-out"; mkdir -p "$dst"
before="$(cd "$src" && ls -laT . && shasum ./*)"
out="$( (umask 077; transcribe_channels "$src" "$dst") 2>&1 )"; rc=$?
after="$(cd "$src" && ls -laT . && shasum ./*)"
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ] && [ -s "$dst/transcript.txt" ] && [ -s "$dst/mic.words.json" ] \
   && [ -s "$dst/call.words.json" ] && ! ls -a "$dst" | grep -q '^\.work'; then
  pass "transcribe_channels reads SRC and writes only in OUT"
else fail "transcribe_channels reads SRC and writes only in OUT (rc $rc): $out"; fi
pk_reset
if [ "$PK_CURL" = 0 ]; then pass "no curl in any Parakeet run"; else fail "no curl in any Parakeet run"; fi
pk_reset

# === Speakers: mb-speech finds each side's speakers once both sides are transcribed (spec 6.2) ===

sp_reset() { pk_reset; rm -f "$HOME"/sp-fail-* "$HOME"/sp-silent-*; ROOM_COUNT=""; CALL_COUNT=""; }
sp_calls() { grep -c "^mb-speech speakers $1" "$HOME/calls.log" | tr -d ' '; }
sp_line()  { grep "^mb-speech speakers $1 " "$HOME/calls.log" | head -n 1; }
# The header lines in the log name the sides whose speakers are found: prints them, as "mic call".
sp_headers() {
  printf '%s\n' "$out" | sed -n 's/.*finding speakers on the \([a-z]*\) side.*/\1/p' | tr '\n' ' ' | sed 's/ $//'
  printf '%s\n' "$out" | grep -q 'finding speakers on each side' && printf ' each'
}

# --- by default: both sides, after both are transcribed, in the work folder, with no count ---
sp_reset
d="$(meeting sp1 audio.m4a mic.m4a call.m4a)"
out="$( (MB_PROGRESS_FILE="$HOME/progress-sp1"; export MB_PROGRESS_FILE; process "$d/audio.m4a") 2>&1 )"; rc=$?
last_t="$(grep -n '^mb-speech transcribe' "$HOME/calls.log" | tail -n 1 | cut -d: -f1)"
first_s="$(grep -n '^mb-speech speakers' "$HOME/calls.log" | head -n 1 | cut -d: -f1)"
if [ "$rc" -eq 0 ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 1 ] && [ -n "$last_t" ] && [ -n "$first_s" ] \
   && [ "$first_s" -gt "$last_t" ]; then
  pass "speakers are found on each side once both sides are transcribed"
else fail "speakers are found on each side once both sides are transcribed (rc $rc): $(cat "$HOME/calls.log") $out"; fi
if [ "$(sp_headers)" = "mic call" ]; then pass "the log names both sides as their speakers are found"
else fail "the log names both sides as their speakers are found: [$(sp_headers)] $out"; fi
paths_ok=1
for side in mic call; do
  line="$(sp_line "$side")"
  wav="$(printf '%s' "$line" | sed -n 's/.* wav=\([^ ]*\) .*/\1/p')"
  case "$wav" in .stage.??????/.work.??????/"$side".wav) ;; *) paths_ok=0 ;; esac
  printf '%s' "$line" | grep -qF " exists=yes out=$(dirname "$wav")/$side.speakers.json more= tmp=$(cd "$d" && pwd -P)/$(dirname "$wav")" || paths_ok=0
done
if [ "$paths_ok" = 1 ] && [ -z "$(find "$d" -name '*speakers*')" ] && ! ls -a "$d" | grep -q '^\.work\|^\.stage\|\.wav$'; then
  pass "each side's WAV and speakers file are in the run's work folder, with TMPDIR there, and none is left"
else fail "each side's WAV and speakers file are in the run's work folder, with TMPDIR there, and none is left: $(grep '^mb-speech speakers' "$HOME/calls.log") $(find "$d")"; fi
if [ "$(tr '\n' ' ' < "$HOME/progress-sp1" 2>/dev/null)" = "transcribing speakers minutes done " ]; then
  pass "with speakers found, progress is still transcribing, speakers, minutes, done"
else fail "with speakers found, progress is still transcribing, speakers, minutes, done: $(cat "$HOME/progress-sp1" 2>/dev/null)"; fi

# --- the people counts: 2 to 6 are passed as --count; 1 skips that side; anything else works it out ---
sp_reset; ROOM_COUNT=2; CALL_COUNT=6
d="$(meeting sp2 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && sp_line mic | grep -q ' more=--count 2 tmp=' && sp_line call | grep -q ' more=--count 6 tmp='; then
  pass "counts of 2 and 6 are passed to the helper as --count"
else fail "counts of 2 and 6 are passed to the helper as --count (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
sp_reset; ROOM_COUNT=1
d="$(meeting sp3 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sp_calls mic)" = 0 ] && [ "$(sp_calls call)" = 1 ] && sp_line call | grep -q ' more= tmp='; then
  pass "a room count of 1 skips the microphone side, and the call side is worked out"
else fail "a room count of 1 skips the microphone side, and the call side is worked out (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
if [ "$(sp_headers)" = "call" ]; then pass "with a room count of 1, the log names only the call side"
else fail "with a room count of 1, the log names only the call side: [$(sp_headers)] $out"; fi
sp_reset; CALL_COUNT=1
d="$(meeting sp4 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 0 ]; then pass "a call count of 1 skips the call side"
else fail "a call count of 1 skips the call side (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
sp_reset; ROOM_COUNT=7; CALL_COUNT=0
d="$(meeting sp4b audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && sp_line mic | grep -q ' more= tmp=' && sp_line call | grep -q ' more= tmp='; then
  pass "a count outside 1 to 6 passes no --count"
else fail "a count outside 1 to 6 passes no --count (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi

# --- a side transcribed with no words is skipped; a side every transcriber failed on is still run ---
sp_reset; touch "$HOME/pk-empty-call"
d="$(meeting sp5 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 0 ]; then pass "a side transcribed with no words is skipped"
else fail "a side transcribed with no words is skipped (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
if [ "$(sp_headers)" = "mic" ]; then pass "with no words on the call side, the log names only the microphone side"
else fail "with no words on the call side, the log names only the microphone side: [$(sp_headers)] $out"; fi
# whisper's shape: a call side holding only blanks and [BLANK_AUDIO] is no words to mb-transcript,
# so it is skipped too
sp_reset; touch "$HOME/pk-fail-call"; SA_FAIL=call
have() { case "$1" in speech-analyzer|fm|whisper-cli|ffmpeg) return 0 ;; *) return 1 ;; esac; }
whisper-cli() {
  echo "whisper-cli $*" >> "$HOME/calls.log"
  local prev="" a o=""
  for a in "$@"; do [ "$prev" = --output-file ] && o="$a"; prev="$a"; done
  printf '%s' '{"transcription":[{"offsets":{"from":0,"to":900},"text":" [BLANK_AUDIO]"},
    {"offsets":{"from":900,"to":1500},"text":" "}]}' > "$o.json"
}
d="$(meeting sp5b audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls whisper-cli)" = 1 ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 0 ]; then
  pass "a whisper side holding only blanks and [BLANK_AUDIO] is skipped"
else fail "a whisper side holding only blanks and [BLANK_AUDIO] is skipped (rc $rc): $(grep '^mb-speech speakers\|^whisper-cli' "$HOME/calls.log") $out"; fi
have() { case "$1" in speech-analyzer|fm) return 0 ;; *) return 1 ;; esac; }
whisper-cli() {
  echo "whisper-cli $*" >> "$HOME/calls.log"
  local prev="" a o=""
  for a in "$@"; do [ "$prev" = --output-file ] && o="$a"; prev="$a"; done
  cp "$FIX/whisper.json" "$o.json"
}
sp_reset; touch "$HOME/pk-fail-call"; SA_FAIL=call
d="$(meeting sp6 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq -r .engine "$d/call.words.json")" = none ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 1 ]; then
  pass "a side every transcriber failed on (engine none) still has its speakers found"
else fail "a side every transcriber failed on (engine none) still has its speakers found (rc $rc): $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
# every transcriber's shape of no words, and nothing else, counts as heard nothing
mkdir -p "$HOME/heard"
printf '{"words": []}' > "$HOME/heard/apple.json"
printf '{"engine": "parakeet-ultra", "words": []}' > "$HOME/heard/parakeet.json"
printf '{"transcription": []}' > "$HOME/heard/whisper.json"
printf '{"engine": "none", "words": []}' > "$HOME/heard/none.json"
printf '{"words":[{"start":1' > "$HOME/heard/garbled.json"
# what loadWords drops: blank or bracketed text, and entries without times
printf '{"transcription":[{"offsets":{"from":0,"to":900},"text":" [BLANK_AUDIO]"},{"offsets":{"from":900,"to":1500},"text":"  "}]}' \
  > "$HOME/heard/whisper-blank.json"
printf '{"words":[{"start":0,"end":1,"text":""},{"start":1,"end":2,"text":" [inaudible] "},{"text":"untimed"}]}' > "$HOME/heard/apple-blank.json"
printf ' \n' > "$HOME/heard/whitespace.json"
printf '{"words":[{"start":0,"end":1,"text":"["}]}' > "$HOME/heard/bracket.json"
heard_ok=1; heard_wrong=""
for f in apple parakeet whisper whisper-blank apple-blank whitespace; do
  heard_nothing "$HOME/heard/$f.json" || { heard_ok=0; heard_wrong="$heard_wrong $f"; }
done
for f in "$HOME/heard/none.json" "$HOME/heard/garbled.json" "$HOME/heard/bracket.json" "$FIX/sa-mic.json" "$FIX/pk-mic.json" \
         "$FIX/whisper.json"; do
  heard_nothing "$f" && { heard_ok=0; heard_wrong="$heard_wrong $(basename "$f")"; }
done
if [ "$heard_ok" = 1 ]; then
  pass "heard_nothing: no words, by loadWords' own filter, from Apple's, Parakeet or whisper, but not engine none, garbled or words"
else fail "heard_nothing: no words, by loadWords' own filter, from Apple's, Parakeet or whisper, but not engine none, garbled or words:$heard_wrong"; fi

# --- Apple's words: the speakers are still found when Parakeet is set up ---
sp_reset; ENGINE=native
d="$(meeting sp7 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls speech-analyzer)" = 2 ] && [ "$(sp_calls mic)" = 1 ] && [ "$(sp_calls call)" = 1 ]; then
  pass "with Apple's transcriber, the speakers are still found when Parakeet is set up"
else fail "with Apple's transcriber, the speakers are still found when Parakeet is set up (rc $rc): $(cat "$HOME/calls.log") $out"; fi

# --- a failure: a warning naming the side, the run carries on, and no partial file is left ---
sp_reset; touch "$HOME/sp-fail-call"
d="$(meeting sp8 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'warn.*could not find speakers on the call side, carrying on without labels there' \
   && ! printf '%s' "$out" | grep -q 'on the mic side, carrying on' && printf '%s' "$out" | grep -q 'the diariser could not run' \
   && grep -q 'Them: ' "$d/transcript.txt" && [ -s "$d/notes.md" ] && [ -z "$(find "$d" -name '*speakers*')" ]; then
  pass "speakers failing on one side warns, names it, and the run carries on"
else fail "speakers failing on one side warns, names it, and the run carries on (rc $rc): $out"; fi
if ! printf '%s' "$out" | grep -q 'mb-speech: '; then pass "the speakers reason is logged without its mb-speech: prefix"
else fail "the speakers reason is logged without its mb-speech: prefix: $out"; fi
sp_reset; touch "$HOME/sp-silent-call"
d="$(meeting sp8b audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'finding speakers: the speech helper stopped without giving a reason (exit 134)' \
   && printf '%s' "$out" | grep -q 'could not find speakers on the call side, carrying on without labels there'; then
  pass "speakers stopping without a reason log its exit status"
else fail "speakers stopping without a reason log its exit status (rc $rc): $out"; fi
# one conversion, one run and one reading of the reason, shared by Parakeet and speakers
if [ "$(grep -c 'afconvert -f WAVE' "$ROOT/meetingbox")" = 1 ] && declare -f pk_run | grep -q 'speech_run ' \
   && declare -f find_speakers | grep -q 'speech_run '; then
  pass "pk_run and find_speakers share one conversion and helper run"
else fail "pk_run and find_speakers share one conversion and helper run"; fi
src="$(meeting spsrc mic.m4a call.m4a)"
w="$(mktemp -d "$HOME/spwork.XXXXXX")"
( find_speakers "$src" "$w" call "" ) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(ls -A "$w")" ]; then pass "a failed find_speakers leaves no partial file, WAV or error file"
else fail "a failed find_speakers leaves no partial file, WAV or error file (rc $rc): $(ls -A "$w")"; fi
w="$(mktemp -d "$HOME/spwork.XXXXXX")"
( find_speakers "$src" "$w" mic "" ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(ls -A "$w")" = mic.speakers.json ]; then
  pass "find_speakers leaves only the side's speakers file in the work folder"
else fail "find_speakers leaves only the side's speakers file in the work folder (rc $rc): $(ls -A "$w")"; fi

# --- with no work folder, find_speakers stops before anything ---
sp_reset
( find_speakers "$src" "" mic "" ) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(pk_calls afconvert)" = 0 ] && [ "$(pk_calls 'mb-speech')" = 0 ]; then
  pass "find_speakers refuses an empty work folder"
else fail "find_speakers refuses an empty work folder (rc $rc): $(cat "$HOME/calls.log")"; fi

# --- a helper that is not usable: both sides skipped, said in one line ---
sp_reset; touch "$HOME/pk-unusable"
d="$(meeting sp9 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sp_calls '')" = 0 ] && [ "$(printf '%s\n' "$out" | grep -ci 'speaker')" = 1 ] && [ -s "$d/transcript.txt" ]; then
  pass "an unusable helper skips both sides, with one log line"
else fail "an unusable helper skips both sides, with one log line (rc $rc): $out"; fi
sp_reset
if [ "$PK_CURL" = 0 ]; then pass "no curl in any speakers run"; else fail "no curl in any speakers run"; fi

# === Tidy lines: on unless --no-tidy or the app's preference says no (spec 6.3) ===

# --- parse_args: the app's process arguments with --tidy and --no-tidy ---
got="$( (ENGINE=auto; TIDY=auto; WRITER=""; parse_args process X --parakeet --tidy --writer apple
         printf '%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$TIDY" "$WRITER") 2>&1 )"
if [ "$got" = "process|X|parakeet|1|apple" ]; then pass "parse_args: --parakeet --tidy --writer apple"
else fail "parse_args: --parakeet --tidy --writer apple: $got"; fi
got="$( (ENGINE=auto; TIDY=auto; WRITER=""; parse_args process X --native --no-tidy --writer apple
         printf '%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$TIDY" "$WRITER") 2>&1 )"
if [ "$got" = "process|X|native|0|apple" ]; then pass "parse_args: --native --no-tidy --writer apple"
else fail "parse_args: --native --no-tidy --writer apple: $got"; fi

# --- mb-transcript itself: tidy lines by default; with --plain, every word and a line per turn ---
mkdir -p "$HOME/tidy"
printf '%s' '{"engine": "parakeet-ultra", "words": [
  {"start": 0.0, "end": 0.3, "text": "So", "confidence": 0.9}, {"start": 0.4, "end": 0.6, "text": "um", "confidence": 0.9},
  {"start": 0.7, "end": 0.9, "text": "we", "confidence": 0.9}, {"start": 1.0, "end": 1.3, "text": "should", "confidence": 0.9},
  {"start": 1.5, "end": 1.8, "text": "go", "confidence": 0.9}, {"start": 1.9, "end": 2.0, "text": "to", "confidence": 0.9},
  {"start": 2.1, "end": 2.2, "text": "the", "confidence": 0.9}, {"start": 2.3, "end": 2.6, "text": "park.", "confidence": 0.9}]}' \
  > "$HOME/tidy/mic.words.json"
printf '%s' '{"engine": "parakeet-ultra", "words": [{"start": 1.35, "end": 1.45, "text": "yeah", "confidence": 0.9}]}' \
  > "$HOME/tidy/call.words.json"
tidied="$("$TRANSCRIPT_BIN" --mic "$HOME/tidy/mic.words.json" --call "$HOME/tidy/call.words.json" 2>&1)"
plain="$("$TRANSCRIPT_BIN" --mic "$HOME/tidy/mic.words.json" --call "$HOME/tidy/call.words.json" --plain 2>&1)"
if [ "$tidied" = "[00:00:00] Me: So we should (Them: yeah) go to the park." ]; then
  pass "mb-transcript tidies by default: 'um' dropped, the short reply inline"
else fail "mb-transcript tidies by default: 'um' dropped, the short reply inline: $tidied"; fi
if [ "$plain" = "$(printf '[00:00:00] Me: So um we should\n[00:00:01] Them: yeah\n[00:00:01] Me: go to the park.')" ]; then
  pass "mb-transcript --plain keeps 'um' and starts a line at every change of speaker"
else fail "mb-transcript --plain keeps 'um' and starts a line at every change of speaker: $plain"; fi
# a word stretched to 15 s: capped at 1.2 s either way, so the next word 10 s on is a new line
printf '%s' '{"engine": "parakeet-ultra", "words": [{"start": 0.0, "end": 15.0, "text": "Hello.", "confidence": 0.9},
  {"start": 10.0, "end": 10.5, "text": "Again.", "confidence": 0.9}]}' > "$HOME/tidy/long.words.json"
printf '%s' '{"engine": "none", "words": []}' > "$HOME/tidy/none.words.json"
n_plain="$("$TRANSCRIPT_BIN" --mic "$HOME/tidy/long.words.json" --call "$HOME/tidy/none.words.json" --plain 2>/dev/null | grep -c .)"
n_tidy="$("$TRANSCRIPT_BIN" --mic "$HOME/tidy/long.words.json" --call "$HOME/tidy/none.words.json" 2>/dev/null | grep -c .)"
if [ "$n_plain" = 2 ] && [ "$n_tidy" = 2 ]; then pass "mb-transcript caps word ends at 1.2 s with --plain and without"
else fail "mb-transcript caps word ends at 1.2 s with --plain and without (plain $n_plain lines, tidy $n_tidy)"; fi

# --- the engine passes --plain only when tidying is off: a flag, else the app's preference ---
# A stand-in mb-transcript that logs its arguments, then runs the real one.
REAL_TRANSCRIPT_BIN="$TRANSCRIPT_BIN"
cat > "$HOME/mb-transcript-logged" <<EOF
#!/bin/bash
echo "mb-transcript \$*" >> "$HOME/calls.log"
exec "$REAL_TRANSCRIPT_BIN" "\$@"
EOF
chmod 755 "$HOME/mb-transcript-logged"
TRANSCRIPT_BIN="$HOME/mb-transcript-logged"
# process on a new meeting, with the options after its name, as the command line gives them
tidy_process() {
  local name="$1"; shift
  pk_reset
  d="$(meeting "$name" audio.m4a mic.m4a call.m4a)"
  out="$( (parse_args process "$d/audio.m4a" "$@"; process "$argfile") 2>&1 )"; rc=$?
}
mbt_calls() { grep -c "^mb-transcript ${1:-}" "$HOME/calls.log" | tr -d ' '; }
asked_tidy() { grep -q '^defaults read com.jediconcepts.meetingbox tidyLines$' "$HOME/calls.log"; }

tidy_process td1 --no-tidy
if [ "$rc" -eq 0 ] && [ "$(mbt_calls)" = 1 ] && [ "$(mbt_calls '.* --plain$')" = 1 ]; then pass "--no-tidy passes --plain"
else fail "--no-tidy passes --plain (rc $rc): $(grep '^mb-transcript' "$HOME/calls.log") $out"; fi

# the app's preference answers TIDY_PREF; a Bool reads back as 0, a hand-set string as no or false
defaults() {
  echo "defaults $*" >> "$HOME/calls.log"
  [ "$*" = "read com.jediconcepts.meetingbox tidyLines" ] && { echo "$TIDY_PREF"; return 0; }
  return 1
}
for TIDY_PREF in 0 no false; do
  tidy_process "td2$TIDY_PREF"
  if [ "$rc" -eq 0 ] && asked_tidy && [ "$(mbt_calls)" = 1 ] && [ "$(mbt_calls '.* --plain$')" = 1 ]; then
    pass "the app's tidyLines preference of $TIDY_PREF passes --plain"
  else fail "the app's tidyLines preference of $TIDY_PREF passes --plain (rc $rc): $(grep '^mb-transcript\|^defaults' "$HOME/calls.log") $out"; fi
done
TIDY_PREF=0
tidy_process td3 --tidy
if [ "$rc" -eq 0 ] && ! asked_tidy && [ "$(mbt_calls)" = 1 ] && [ "$(mbt_calls '.*--plain')" = 0 ]; then
  pass "--tidy beats the app's preference"
else fail "--tidy beats the app's preference (rc $rc): $(grep '^mb-transcript\|^defaults' "$HOME/calls.log") $out"; fi
defaults() { echo "defaults $*" >> "$HOME/calls.log"; return 1; }

tidy_process td4
if [ "$rc" -eq 0 ] && asked_tidy && [ "$(mbt_calls)" = 1 ] && [ "$(mbt_calls '.*--plain')" = 0 ] && [ -s "$d/transcript.txt" ]; then
  pass "with no flag and no preference, lines are tidied"
else fail "with no flag and no preference, lines are tidied (rc $rc): $(grep '^mb-transcript\|^defaults' "$HOME/calls.log") $out"; fi
TRANSCRIPT_BIN="$REAL_TRANSCRIPT_BIN"
pk_reset

# --- the minutes writers are told what the labels mean, and the final pass how to name an owner ---
# Task 11A adds the Speaker sentence after the one about "Them".
ONE_SENTENCE='"Speaker 1", "Speaker 2" and so on are people in a recording kept as one file, numbered in the order they first spoke; they may be in the same room or on a call.'
LABELS='Speaker labels: "Me" is the person who recorded the meeting. "Room 1", "Room 2" and so on are people in the same room, numbered in the order they first spoke; if no line is labelled "Me", the person who recorded was not recognised and may be one of them. "Them", or "Them 1", "Them 2", are people on the other end of a call; a plain "Them" next to numbered ones is someone on the call who could not be told apart. "Speaker 1", "Speaker 2" and so on are people in a recording kept as one file, numbered in the order they first spoke; they may be in the same room or on a call. "Unknown" means the speaker could not be told. Text in brackets such as "(Them: yeah)" is a short reply made during or just after someone else'\''s turn; it may be that person'\''s answer to a question. Keep these labels exactly as written and never guess a real name for a label.'
mkdir -p "$HOME/labels"
printf '[00:00:01] Room 1: we start now (Them 2: yeah)\n[00:00:05] Them: fine\n' > "$HOME/labels/transcript.txt"
: > "$HOME/fm-instructions.txt"
(
  # over the window, so the transcript is sliced and the notes folded before the final pass
  fm() {
    case "$1" in
      count-tokens) cat >/dev/null; echo 5000 ;;
      respond) printf '%s\n' "$3" >> "$HOME/fm-instructions.txt"; cat >/dev/null; echo "the minutes" ;;
      *) return 1 ;;
    esac
  }
  summarise "$HOME/labels/transcript.txt" "$HOME/labels"
) >/dev/null 2>&1
map="$(grep '^You are taking minutes' "$HOME/fm-instructions.txt" | head -n 1)"
reduce="$(grep '^These are notes from consecutive slices' "$HOME/fm-instructions.txt" | head -n 1)"
final="$(grep 'Write the final minutes' "$HOME/fm-instructions.txt" | head -n 1)"
old='"Them" is everyone on the other end of the call'
labels_ok=1
for instr in "$map" "$reduce"; do
  case "$instr" in *"$LABELS"*) ;; *) labels_ok=0 ;; esac
  case "$instr" in *"$old"*) labels_ok=0 ;; esac
done
if [ -n "$map" ] && [ -n "$reduce" ] && [ "$labels_ok" = 1 ]; then
  pass "the slice and folding passes get the label sentence in place of the Me and Them one"
else fail "the slice and folding passes get the label sentence in place of the Me and Them one: [$map] [$reduce]"; fi
case "$final" in "$LABELS Write the final minutes"*) final_first=1 ;; *) final_first=0 ;; esac
if [ "$final_first" = 1 ] \
   && printf '%s' "$final" | grep -qF '(a name, or a speaker label exactly as written, such as Me, Room 1 or Them 2)' \
   && ! printf '%s' "$final" | grep -qF '(a name, Me or Them)'; then
  pass "the final pass gets the label sentence first, and the new owner wording"
else fail "the final pass gets the label sentence first, and the new owner wording: [$final]"; fi
if [ "$(grep -cF "$ONE_SENTENCE" "$HOME/fm-instructions.txt")" -ge 3 ] && [ "$(grep -cF "$ONE_SENTENCE" "$ROOT/meetingbox")" = 1 ]; then
  pass "Apple's minutes passes are told who Speaker 1, Speaker 2 are, from the one label explanation"
else fail "Apple's minutes passes are told who Speaker 1, Speaker 2 are, from the one label explanation"; fi
# and an outside writer: the system message it is sent opens with the same explanation, the sentence in it
rm -f "$HOME/node.stdin.complete" "$HOME/node.log"
mkdir -p "$HOME/labels-out"
printf '[00:00:01] Speaker 1: we start now\n[00:00:05] Speaker 2: fine\n' > "$HOME/labels-out/transcript.txt"
(
  security() { echo "security $*" >> "$HOME/calls.log"; return 44; }   # no key stored for this source
  fake_node
  WRITER=outside; OUTSIDE_KIND=standard; OUTSIDE_ADDRESS="http://127.0.0.1:11434/v1"; OUTSIDE_MODEL=llama3
  summarise "$HOME/labels-out/transcript.txt" "$HOME/labels-out"
) >"$HOME/labels-out.log" 2>&1
sent="$(jq -r .system "$HOME/node.stdin.complete" 2>/dev/null)"
case "$sent" in "$LABELS "*) sent_ok=1 ;; *) sent_ok=0 ;; esac
if [ "$sent_ok" = 1 ] && printf '%s' "$sent" | grep -qF "$ONE_SENTENCE"; then
  pass "an outside writer is sent the label explanation first, Speaker 1 and Speaker 2 explained in it"
else fail "an outside writer is sent the label explanation first, Speaker 1 and Speaker 2 explained in it: [$sent] $(cat "$HOME/labels-out.log")"; fi
rm -f "$HOME/node.stdin.complete" "$HOME/node.log" "$NODE_FILE"

# === Labels and the voice print: the speakers files, --voice and --learn reach mb-transcript (6.2) ===

# The stand-in helper gives the labelled fixtures: pk-labelled for the words, sp-fixture for the
# speakers, sp-garbled-<side> for a speakers file that is not JSON. mb-transcript is the real one,
# behind the wrapper that logs its arguments.
TRANSCRIPT_BIN="$HOME/mb-transcript-logged"
mkdir -p "$STATE_DIR"
lb_reset() { sp_reset; rm -f "$HOME/pk-labelled" "$HOME/sp-fixture" "$HOME"/sp-garbled-* "$VOICE_FILE" "$VOICE_FILE.tmp" "$INSTALLED"; }
lb_meeting() {   # $1: the folder's name, $2: meeting.json's id, if any
  d="$(meeting "$1" audio.m4a mic.m4a call.m4a)"
  [ -z "${2:-}" ] || printf '{"id": "%s", "state": "done"}\n' "$2" > "$d/meeting.json"
}
lb_args() { grep '^mb-transcript ' "$HOME/calls.log" | head -n 1; }

# --- the fixtures give Me, Room 1 and Them lines end to end ---
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"
lb_meeting lb1 MEETING-ONE
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
t="$d/transcript.txt"
if [ "$rc" -eq 0 ] && grep -q '^\[00:00:00\] Me: Right, so the plan for today is simple\.' "$t" \
   && grep -qx '\[00:00:10\] Room 1: what (Them: yeah) about the budget?' "$t" \
   && grep -q '^\[00:00:16\] Them: That works for me\.' "$t" && [ "$(grep -c . "$t")" = 3 ]; then
  pass "the speaker fixtures give Me, Room 1 and Them lines end to end"
else fail "the speaker fixtures give Me, Room 1 and Them lines end to end (rc $rc): $out $(cat "$t" 2>/dev/null)"; fi
args="$(lb_args)"
case "$args" in
  *" --mic-speakers .stage."??????"/.work."??????"/mic.speakers.json --call-speakers .stage."??????"/.work."??????"/call.speakers.json --voice $VOICE_FILE"*) args_ok=1 ;;
  *) args_ok=0 ;;
esac
if [ "$args_ok" = 1 ] && [ -z "$(find "$d" -name '*speakers*')" ]; then
  pass "mb-transcript gets both speakers files from the work folder and the voice print, and no speakers file is left"
else fail "mb-transcript gets both speakers files from the work folder and the voice print, and no speakers file is left: $args"; fi
if ! printf '%s' "$args" | grep -q -- '--learn' && [ ! -e "$VOICE_FILE" ] && ! printf '%s' "$out" | grep -q 'Learnt'; then
  pass "with no voice print on the install record, process passes no --learn and nothing is learnt"
else fail "with no voice print on the install record, process passes no --learn and nothing is learnt: $args $out"; fi

# --- process passes --learn with the meeting's id when the voice print is on the record ---
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; record_install "$VOICE_FILE"
lb_meeting lb2 MEETING-TWO
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
args="$(lb_args)"
if [ "$rc" -eq 0 ] && printf '%s' "$args" | grep -qF -- "--voice $VOICE_FILE --learn MEETING-TWO" \
   && [ "$(jq -r '.sources | join(",")' "$VOICE_FILE" 2>/dev/null)" = MEETING-TWO ] && [ "$(jq -r .meetings "$VOICE_FILE" 2>/dev/null)" = 1 ] \
   && [ "$(mode_of "$VOICE_FILE")" = 600 ] && [ ! -e "$VOICE_FILE.tmp" ] \
   && printf '%s' "$out" | grep -q 'Learnt 9 s of your voice from this call'; then
  pass "process passes --learn with meeting.json's id, and the call's voice is learnt (0600, through voice.json.tmp)"
else fail "process passes --learn with meeting.json's id, and the call's voice is learnt (rc $rc): $args $out $(cat "$VOICE_FILE" 2>/dev/null)"; fi
cp "$VOICE_FILE" "$HOME/voice.before"
: > "$HOME/calls.log"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$VOICE_FILE" "$HOME/voice.before" && printf '%s' "$out" | grep -q 'learnt from this meeting before'; then
  pass "processing the same meeting again learns nothing more"
else fail "processing the same meeting again learns nothing more (rc $rc): $out"; fi
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; record_install "$VOICE_FILE"
lb_meeting lb3
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && lb_args | grep -qF -- "--learn lb3" && [ "$(jq -r '.sources[0]' "$VOICE_FILE" 2>/dev/null)" = lb3 ]; then
  pass "without a meeting.json id, the folder's name is the meeting's id"
else fail "without a meeting.json id, the folder's name is the meeting's id (rc $rc): $(lb_args) $out"; fi

# --- a redo never learns: transcribe_channels given no meeting id passes no --learn ---
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; record_install "$VOICE_FILE"
lb_meeting lb4 MEETING-FOUR
out="$( (transcribe_channels "$d" "$d") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && lb_args | grep -qF -- "--voice $VOICE_FILE" && ! lb_args | grep -q -- '--learn' && [ ! -e "$VOICE_FILE" ]; then
  pass "transcribing without a meeting id, as a redo will, passes --voice but never --learn"
else fail "transcribing without a meeting id, as a redo will, passes --voice but never --learn (rc $rc): $(lb_args) $out"; fi

# --- a voice print that is there but not on the install record is never learnt into, and the log says why ---
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"
printf '%s\n' '{"model": "x", "seconds": 5, "meetings": 1, "sources": [], "vector": [1], "updated": "x"}' > "$VOICE_FILE"
cp "$VOICE_FILE" "$HOME/voice.before"
lb_meeting lb5 MEETING-FIVE
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && ! lb_args | grep -q -- '--learn' && cmp -s "$VOICE_FILE" "$HOME/voice.before" \
   && printf '%s' "$out" | grep -qF "$VOICE_FILE was not made by meetingbox"; then
  pass "a voice print not on the install record is not learnt into, and the log says why"
else fail "a voice print not on the install record is not learnt into, and the log says why (rc $rc): $(lb_args) $out"; fi

# --- an unreadable speakers file warns and leaves Me and Them ---
lb_reset; touch "$HOME/sp-garbled-mic" "$HOME/sp-garbled-call"
d="$(meeting lb6 audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
t="$d/transcript.txt"
if [ "$rc" -eq 0 ] && grep -q '] Me: Speaking from this desk' "$t" && grep -q '] Them: Parakeet heard them' "$t" \
   && printf '%s' "$out" | grep -q 'warn.*mic.speakers.json.*without speaker labels on the microphone side' \
   && printf '%s' "$out" | grep -q 'warn.*call.speakers.json.*without speaker labels on the call side'; then
  pass "an unreadable speakers file warns and leaves Me and Them"
else fail "an unreadable speakers file warns and leaves Me and Them (rc $rc): $out $(cat "$t" 2>/dev/null)"; fi

# --- an unreadable voice print is left byte for byte as it was under --learn, with a warning ---
LB_MODEL="FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232"
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; record_install "$VOICE_FILE"
printf '{"model": "%s", "seconds": "lots", "meetings": 1' "$LB_MODEL" > "$VOICE_FILE"
cp "$VOICE_FILE" "$HOME/voice.before"
lb_meeting lb7 MEETING-SEVEN
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && lb_args | grep -qF -- "--learn MEETING-SEVEN" && cmp -s "$VOICE_FILE" "$HOME/voice.before" \
   && [ ! -e "$VOICE_FILE.tmp" ] && printf '%s' "$out" | grep -q 'warn.*cannot read your voice print' \
   && grep -q '] Room 1: ' "$d/transcript.txt"; then
  pass "an unreadable voice print is left byte for byte as it was under --learn, and the transcript is still labelled"
else fail "an unreadable voice print is left byte for byte as it was under --learn, and the transcript is still labelled (rc $rc): $out"; fi

# --- the discard path end to end: a second refused call in a row discards a print that is not usable ---
lb_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; record_install "$VOICE_FILE"
printf '{"model": "%s", "seconds": 20, "meetings": 1, "sources": ["MEETING-ZERO"], "sample": false, "refusals": 1, "refused": ["MEETING-ONE-B"], "vector": [0, 0, 0, 1], "updated": "x"}\n' \
  "$LB_MODEL" > "$VOICE_FILE"
lb_meeting lb8 MEETING-EIGHT
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$VOICE_FILE" ] && [ ! -e "$VOICE_FILE.tmp" ] \
   && printf '%s' "$out" | grep -q "This call's microphone voice did not match the voice learnt so far, so it was not learnt" \
   && printf '%s' "$out" | grep -q 'That is two calls in a row, so the voice learnt so far is discarded'; then
  pass "a second refused call in a row discards the print, and the log says so"
else fail "a second refused call in a row discards the print, and the log says so (rc $rc): $out"; fi

# --- a count of 1 leaves that side unlabelled, and nothing is learnt from a microphone count of 1 ---
mkdir -p "$HOME/counts"
cp "$FIX/speakers-mic.json" "$HOME/counts/mic.speakers.json"
printf '%s\n' "{\"model\": \"$LB_MODEL\", \"segments\": [{\"speaker\": \"T1\", \"start\": 10.9, \"end\": 11.4},
  {\"speaker\": \"T1\", \"start\": 15.8, \"end\": 26.0}, {\"speaker\": \"T2\", \"start\": 26.0, \"end\": 36.6}],
  \"speakers\": [{\"id\": \"T1\", \"seconds\": 10.7, \"median\": 10.2, \"vector\": [0.0, 0.1, 0.9, 0.2]},
  {\"id\": \"T2\", \"seconds\": 10.6, \"median\": 10.6, \"vector\": [0.1, 0.0, 0.2, 0.9]}]}" > "$HOME/counts/call.speakers.json"
labels_of() {   # the labels mb-transcript gives the fixtures with these extra arguments, sorted and joined
  "$REAL_TRANSCRIPT_BIN" --mic "$FIX/labelled-mic.json" --call "$FIX/labelled-call.json" --mic-speakers "$HOME/counts/mic.speakers.json" \
    --call-speakers "$HOME/counts/call.speakers.json" "$@" 2>/dev/null | sed 's/^\[[0-9:]*\] \([^:]*\): .*/\1/' | sort -u | tr '\n' ',' | sed 's/,$//'
}
base="$(labels_of)"
mic1="$(labels_of --mic-count 1 --voice "$HOME/counts/voice.json" --learn COUNTED)"
call1="$(labels_of --call-count 1)"
if [ "$base" = "Me,Room 1,Them 1,Them 2" ] && [ "$mic1" = "Me,Them 1,Them 2" ] && [ ! -e "$HOME/counts/voice.json" ] \
   && printf '%s' "$call1" | grep -q 'Them' && ! printf '%s' "$call1" | grep -q 'Them [0-9]'; then
  pass "a count of 1 leaves that side unlabelled (all Me, or all Them), and a microphone count of 1 learns nothing"
else fail "a count of 1 leaves that side unlabelled (all Me, or all Them), and a microphone count of 1 learns nothing: [$base] [$mic1] [$call1]"; fi
lb_reset
TRANSCRIPT_BIN="$REAL_TRANSCRIPT_BIN"
if [ "$PK_CURL" = 0 ]; then pass "no curl in any labelling run"; else fail "no curl in any labelling run"; fi

# === A recording kept as one file: its words' times, its speakers found in the whole file (Task 11A) ===

# The labelled fixture as one recording: S1 (0 to 9.2 s, the voice print's) says the first two sentences,
# S2 (10.3 to 14.8 s) "Um, what about the budget?". voice-old.json is a usable print of S1's voice.
ONE_ME="[00:00:00] Me: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Speaker 1: what about the budget?"
ONE_NO_PRINT="[00:00:00] Speaker 1: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Speaker 2: what about the budget?"

# --- mb-transcript --one itself ---
one_cli() { "$REAL_TRANSCRIPT_BIN" --one "$FIX/labelled-mic.json" "$@" 2>/dev/null; }
got="$(one_cli --one-speakers "$FIX/speakers-one.json" --voice "$FIX/voice-old.json")"
if [ "$got" = "$ONE_ME" ]; then pass "mb-transcript --one with a speakers file and a matching print: Me and Speaker 1 lines with their times"
else fail "mb-transcript --one with a speakers file and a matching print: Me and Speaker 1 lines with their times: [$got]"; fi
# speakers-mic.json's first speaker matches the print as well, but has only 9.2 s of talk: by the microphone
# side's rules that is too short to be Me and too near the print to be anyone else, so Unknown
got="$(one_cli --one-speakers "$FIX/speakers-mic.json" --voice "$FIX/voice-old.json")"
if [ "$got" = "[00:00:00] Unknown: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Speaker 1: what about the budget?" ]; then pass "mb-transcript --one: a print match with under 10 s of talk is Unknown, never Me"
else fail "mb-transcript --one: a print match with under 10 s of talk is Unknown, never Me: [$got]"; fi
got="$(one_cli --one-speakers "$FIX/speakers-one.json")"
if [ "$got" = "$ONE_NO_PRINT" ]; then pass "mb-transcript --one with no print: Speaker 1 and Speaker 2, in the order they first spoke"
else fail "mb-transcript --one with no print: Speaker 1 and Speaker 2, in the order they first spoke: [$got]"; fi
got="$(one_cli --voice "$FIX/voice-old.json")"
if [ "$got" = "[00:00:00] Unknown: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round. what about the budget?" ]; then
  pass "mb-transcript --one with no speakers file: every line Unknown, with its time"
else fail "mb-transcript --one with no speakers file: every line Unknown, with its time: [$got]"; fi
got_me="$(one_cli --one-speakers "$FIX/speakers-one.json" --voice "$FIX/voice-old.json" --one-count 1 | sed 's/^\[[0-9:]*\] \([^:]*\): .*/\1/' | sort -u)"
got_s1="$(one_cli --one-speakers "$FIX/speakers-one.json" --one-count 1 | sed 's/^\[[0-9:]*\] \([^:]*\): .*/\1/' | sort -u)"
if [ "$got_me" = Me ] && [ "$got_s1" = "Speaker 1" ]; then pass "mb-transcript --one-count 1 gives one label: Me with a matching print, else Speaker 1"
else fail "mb-transcript --one-count 1 gives one label: Me with a matching print, else Speaker 1: [$got_me] [$got_s1]"; fi
got="$(one_cli --one-speakers "$FIX/speakers-one.json" --voice "$FIX/voice-old.json" --plain)"
if [ "$got" = "[00:00:00] Me: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Speaker 1: Um, what about the budget?" ]; then pass "mb-transcript --one --plain keeps 'Um' and starts a line at every change of label"
else fail "mb-transcript --one --plain keeps 'Um' and starts a line at every change of label: [$got]"; fi
refused_ok=1; refused_bad=""
for extra in "--mic $FIX/pk-mic.json" "--call $FIX/pk-call.json" "--learn ONE" "--mic-speakers $FIX/speakers-mic.json" \
             "--call-speakers $FIX/speakers-call.json" "--mic-count 2" "--call-count 2" "--voice-sample $FIX/speakers-mic.json" \
             "--one-count 0" "--one-count 7"; do
  # shellcheck disable=SC2086   # the option and its value, two words
  o="$("$REAL_TRANSCRIPT_BIN" --one "$FIX/labelled-mic.json" $extra 2>"$HOME/one-err")"; r=$?
  [ "$r" = 1 ] && [ -z "$o" ] && grep -q 'usage: mb-transcript' "$HOME/one-err" || { refused_ok=0; refused_bad="$refused_bad [$extra]"; }
done
for extra in "--one-speakers $FIX/speakers-mic.json" "--one-count 2"; do
  # shellcheck disable=SC2086
  o="$("$REAL_TRANSCRIPT_BIN" --mic "$FIX/pk-mic.json" --call "$FIX/pk-call.json" $extra 2>"$HOME/one-err")"; r=$?
  [ "$r" = 1 ] && [ -z "$o" ] && grep -q 'usage: mb-transcript' "$HOME/one-err" || { refused_ok=0; refused_bad="$refused_bad [sides $extra]"; }
done
if [ "$refused_ok" = 1 ]; then pass "mb-transcript refuses --one with any side, learning or sample option, and the --one options without --one: usage, exit 1"
else fail "mb-transcript refuses --one with any side, learning or sample option, and the --one options without --one: usage, exit 1:$refused_bad"; fi

# --- the engine: process, redo and the people count ---
TRANSCRIPT_BIN="$HOME/mb-transcript-logged"
# Apple's transcriber as at the top of this file, hearing the mix as it hears the microphone side; and fm
# keeping what it reads, as at the top (a test above replaced both).
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  local a
  for a in "$@"; do :; done
  case "$a" in
    *mic.m4a|*audio.m4a) [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
    *call.m4a) { [ "$SA_FAIL" = both ] || [ "$SA_FAIL" = call ]; } && return 1; cat "$FIX/sa-call.json" ;;
    *) return 1 ;;
  esac
}
fm() {
  case "$1" in
    count-tokens) cat >/dev/null; echo 100 ;;
    respond) case " $* " in *" --schema "*) cat >/dev/null; echo '{"summary": "the brief"}' ;; *) cat >> "$HOME/fm-input.txt"; echo "the minutes" ;; esac ;;
    schema) echo '{}' ;;
    *) return 1 ;;
  esac
}
: > "$HOME/fm-input.txt"
one_reset() { lb_reset; PEOPLE_COUNT=""; rm -f "$HOME"/sp-fail-* "$HOME"/sp-silent-*; }
one_meeting() {   # a meeting folder holding only its recording, with the labelled fixture's words and speakers
  d="$(meeting "$1" audio.m4a)"; touch "$HOME/pk-labelled" "$HOME/sp-fixture"
}
one_print() { cp "$FIX/voice-old.json" "$VOICE_FILE"; record_install "$VOICE_FILE"; cp "$VOICE_FILE" "$HOME/voice.before"; }
mbt_line() { grep '^mb-transcript ' "$HOME/calls.log" | head -n 1; }

# --- process of a folder with only audio.m4a: labelled, timed lines, words.json, and nothing learnt ---
one_reset; one_meeting one1; one_print
printf '{"id": "ONE-ONE", "state": "done"}\n' > "$d/meeting.json"
out="$( (MB_PROGRESS_FILE="$HOME/progress-one1"; export MB_PROGRESS_FILE; process "$d") 2>&1 )"; rc=$?
args="$(mbt_line)"
case "$args" in
  "mb-transcript --one .stage."??????"/words.json --one-speakers .stage."??????"/.work."??????"/one.speakers.json --voice $VOICE_FILE") args_ok=1 ;;
  *) args_ok=0 ;;
esac
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "$ONE_ME" ] && cmp -s "$d/words.json" "$FIX/labelled-mic.json" \
   && [ "$(mode_of "$d/words.json")" = 600 ] && [ ! -e "$d/mic.words.json" ] && [ ! -e "$d/call.words.json" ] && [ -s "$d/notes.md" ]; then
  pass "process of a folder with only audio.m4a writes Me and Speaker 1 lines with their times, and words.json (0600)"
else fail "process of a folder with only audio.m4a writes Me and Speaker 1 lines with their times, and words.json (0600) (rc $rc): $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi
if [ "$args_ok" = 1 ] && cmp -s "$VOICE_FILE" "$HOME/voice.before" && [ ! -e "$VOICE_FILE.tmp" ] && ! printf '%s' "$out" | grep -qi 'learnt'; then
  pass "a single recording gets --one, its speakers file and --voice, never --learn, though the print is on the record; the print is unchanged"
else fail "a single recording gets --one, its speakers file and --voice, never --learn, though the print is on the record; the print is unchanged: [$args] $out"; fi
line="$(sp_line mic)"
if [ "$(sp_calls '')" = 1 ] && printf '%s' "$line" | grep -q ' wav=\.stage\.[^/ ]*/\.work\.[^/ ]*/audio\.wav exists=yes out=\.stage\.[^/ ]*/\.work\.[^/ ]*/one\.speakers\.json more= tmp=' \
   && printf '%s' "$out" | grep -q 'finding speakers in the recording on device (FluidAudio)' \
   && [ -z "$(find "$d" -name '*speakers*')" ] && ! ls -a "$d" | grep -q '^\.work\|^\.stage\|\.wav$'; then
  pass "the speaker finder runs once on the whole recording, in the run's work folder, and leaves nothing behind"
else fail "the speaker finder runs once on the whole recording, in the run's work folder, and leaves nothing behind: $(grep '^mb-speech speakers' "$HOME/calls.log") $out"; fi
if [ "$(tr '\n' ' ' < "$HOME/progress-one1" 2>/dev/null)" = "transcribing speakers minutes done " ]; then
  pass "a single recording's progress is transcribing, speakers, minutes, done"
else fail "a single recording's progress is transcribing, speakers, minutes, done: $(cat "$HOME/progress-one1" 2>/dev/null)"; fi
if grep -q '^Me: Right, so the plan' "$HOME/fm-input.txt" && grep -q '^Speaker 1: what about the budget?' "$HOME/fm-input.txt"; then
  pass "Apple's minutes read the Me and Speaker 1 lines, without their times"
else fail "Apple's minutes read the Me and Speaker 1 lines, without their times: $(tail -n 3 "$HOME/fm-input.txt")"; fi

# --- process of any other recording: the same, beside it ---
one_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"
d="$HOME/loose"; mkdir -p "$d"; printf 'mp3' > "$d/talk.mp3"
printf '{"mine": "a words.json of my own"}\n' > "$d/words.json"; cp "$d/words.json" "$HOME/loose-own.json"
out="$( (process "$d/talk.mp3") 2>&1 )"; rc=$?
kept_own="$(find "$d/earlier" -name words.json 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$kept_own" | grep -c .)" = 1 ] && cmp -s "$kept_own" "$HOME/loose-own.json"; then
  pass "a words.json of the user's own beside a loose recording is moved into earlier/ byte for byte, never deleted"
else fail "a words.json of the user's own beside a loose recording is moved into earlier/ byte for byte, never deleted (rc $rc): [$kept_own] $out"; fi
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "$ONE_NO_PRINT" ] && cmp -s "$d/words.json" "$FIX/labelled-mic.json" \
   && mbt_line | grep -q '^mb-transcript --one ' && ! mbt_line | grep -q -- '--learn' && [ -s "$d/talk.mp3" ] \
   && grep -q '^mb-speech speakers .* wav=\.stage\.[^/ ]*/\.work\.[^/ ]*/talk\.wav ' "$HOME/calls.log"; then
  pass "process of another recording writes its labelled, timed transcript and words.json beside it"
else fail "process of another recording writes its labelled, timed transcript and words.json beside it (rc $rc): $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi

# --- a two-sided meeting is unchanged, word for word, and --people is ignored there with a line ---
TWO_LABELLED="[00:00:00] Me: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Room 1: what (Them: yeah) about the budget?
[00:00:16] Them: That works for me. I will send the numbers over by Friday so we can check them."
for people in "" 3; do
  one_reset; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; PEOPLE_COUNT="$people"
  d="$(meeting "two$people" audio.m4a mic.m4a call.m4a)"
  out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
  args="$(mbt_line)"
  if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "$TWO_LABELLED" ] && cmp -s "$d/mic.words.json" "$FIX/labelled-mic.json" \
     && cmp -s "$d/call.words.json" "$FIX/labelled-call.json" && [ ! -e "$d/words.json" ] \
     && case "$args" in "mb-transcript --mic ./mic.words.json --call ./call.words.json "*|"mb-transcript --mic .stage."*) true ;; *) false ;; esac \
     && ! printf '%s' "$args" | grep -q -- '--one' && sp_line mic | grep -q ' more= tmp=' && sp_line call | grep -q ' more= tmp=' \
     && [ "$(sp_calls '')" = 2 ]; then
    pass "a two-sided meeting${people:+ given --people $people} is labelled word for word as before, with no --one and no words.json"
  else fail "a two-sided meeting${people:+ given --people $people} is labelled word for word as before, with no --one and no words.json (rc $rc): [$args] $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi
done
if printf '%s' "$out" | grep -q -- '--people is for a recording kept as one file, so it is not used for this meeting'; then
  pass "--people on a two-sided meeting is ignored with an info line"
else fail "--people on a two-sided meeting is ignored with an info line: $out"; fi
one_reset
d="$(meeting two-pk audio.m4a mic.m4a call.m4a)"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Me: Speaking from this desk.
[00:00:04] Them: Parakeet heard them too." ] && ! printf '%s' "$out" | grep -q -- '--people'; then
  pass "a two-sided meeting whose finder found nobody is Me and Them, word for word as before"
else fail "a two-sided meeting whose finder found nobody is Me and Them, word for word as before (rc $rc): $out"; fi

# --- --people: 1 to 6, refused otherwise; on a single recording it reaches the finder and mb-transcript ---
got="$( (PEOPLE_COUNT=""; ENGINE=auto; TIDY=auto; WRITER=""; parse_args redo X --native --people 4 --no-tidy --writer apple
         printf '%s|%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$PEOPLE_COUNT" "$TIDY" "$WRITER") 2>&1 )"
if [ "$got" = "redo|X|native|4|0|apple" ]; then pass "parse_args: redo --native --people 4 --no-tidy --writer apple"
else fail "parse_args: redo --native --people 4 --no-tidy --writer apple: $got"; fi
people_ok=1
for bad in 0 7 two ""; do
  o="$( (parse_args process X --people $bad) 2>&1 )" && people_ok=0
  printf '%s' "$o" | grep -q -- '--people takes a number of people from 1 to 6' || people_ok=0
done
if [ "$people_ok" = 1 ]; then pass "--people 0, 7, two or nothing is refused: --people takes a number of people from 1 to 6"
else fail "--people 0, 7, two or nothing is refused: --people takes a number of people from 1 to 6"; fi
one_reset; one_meeting one3; PEOPLE_COUNT=3
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && sp_line mic | grep -q ' more=--count 3 tmp=' && mbt_line | grep -q -- ' --one-count 3$'; then
  pass "process --people 3 on a single recording: --count 3 to the finder, --one-count 3 to mb-transcript"
else fail "process --people 3 on a single recording: --count 3 to the finder, --one-count 3 to mb-transcript (rc $rc): $(sp_line mic) [$(mbt_line)] $out"; fi
one_reset; one_meeting one4; ROOM_COUNT=2; CALL_COUNT=3
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && sp_line mic | grep -q ' more= tmp=' && ! mbt_line | grep -q -- '-count' \
   && printf '%s' "$out" | grep -q -- '--room and --call are for a meeting with both sides, so they are not used for this recording'; then
  pass "--room and --call on a single recording are ignored with an info line"
else fail "--room and --call on a single recording are ignored with an info line (rc $rc): $(sp_line mic) [$(mbt_line)] $out"; fi
ROOM_COUNT=""; CALL_COUNT=""

# --- a speaker finder that fails: Unknown lines with their times, and the warning ---
one_reset; one_meeting one5; one_print; touch "$HOME/sp-fail-mic"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'warn.*could not find speakers in the recording, carrying on without labels$' \
   && printf '%s' "$out" | grep -q 'finding speakers: the diariser could not run' \
   && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round. what about the budget?" ] \
   && ! mbt_line | grep -q -- '--one-speakers\|--voice' && [ -z "$(find "$d" -name '*speakers*')" ] && [ -s "$d/notes.md" ]; then
  pass "a speaker finder that fails warns, leaves no partial file, and the lines say Unknown with their times"
else fail "a speaker finder that fails warns, leaves no partial file, and the lines say Unknown with their times (rc $rc): [$(mbt_line)] $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi

# --- Apple's words: times, and the speakers still found when the speech helper is set up ---
one_reset; one_meeting one6; ENGINE=native
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(pk_calls speech-analyzer)" = 1 ] && [ "$(pk_calls 'mb-speech transcribe')" = 0 ] && [ "$(sp_calls '')" = 1 ] \
   && cmp -s "$d/words.json" "$FIX/sa-mic.json" && grep -q '^\[00:00:00\] [A-Za-z][A-Za-z0-9 ]*: Hi everyone' "$d/transcript.txt"; then
  pass "with Apple's transcriber, a single recording still gets its words' times and its speakers"
else fail "with Apple's transcriber, a single recording still gets its words' times and its speakers (rc $rc): $out $(cat "$d/transcript.txt" 2>/dev/null)"; fi

# --- no speech helper: Apple's words, Unknown lines, said once ---
one_reset; one_meeting one7; touch "$HOME/pk-unusable"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sp_calls '')" = 0 ] && [ "$(printf '%s\n' "$out" | grep -ci 'speaker')" = 1 ] \
   && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Hi everyone can you hear me sounds good" ]; then
  pass "with no speech helper, a single recording is Apple's words in Unknown lines with their times, said in one line"
else fail "with no speech helper, a single recording is Apple's words in Unknown lines with their times, said in one line (rc $rc): $out"; fi

# --- every transcriber failing on a single recording stops the run, writing nothing ---
one_reset; one_meeting one8; touch "$HOME/pk-fail-mic"; SA_FAIL=both
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'transcription failed. Check Speech Recognition in Privacy settings' \
   && [ ! -e "$d/transcript.txt" ] && [ ! -e "$d/words.json" ] && [ -s "$d/audio.m4a" ] && ! ls -a "$d" | grep -q '^\.stage'; then
  pass "every transcriber failing on a single recording stops the run with the Speech Recognition hint, writing nothing"
else fail "every transcriber failing on a single recording stops the run with the Speech Recognition hint, writing nothing (rc $rc): $out"; fi
one_reset; one_meeting one9; touch "$HOME/pk-empty-mic"
out="$( (process "$d/audio.m4a") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'the transcript came out empty. Was there any sound?' && [ ! -e "$d/transcript.txt" ] \
   && [ "$(sp_calls '')" = 0 ]; then
  pass "a single recording with no words stops the run as before: the transcript came out empty"
else fail "a single recording with no words stops the run as before: the transcript came out empty (rc $rc): $out"; fi

one_reset
TRANSCRIPT_BIN="$REAL_TRANSCRIPT_BIN"
if [ "$PK_CURL" = 0 ]; then pass "no curl in any single recording run"; else fail "no curl in any single recording run"; fi

finish
