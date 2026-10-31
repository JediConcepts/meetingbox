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
# Deterministic: the loser (the worker whose moved file is not the dead owner) holds the
# owner file aside until released, and the winner waits at its first clean-up until the loser
# is holding it. So the winner always looks for its owner file while it is missing. Run
# without set -e (as the other tests do) and under set -e (as the real script does).
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
hold_ok=1; hold_log=""
for mode in "set +e" "set -eo pipefail"; do
  d="$(meeting "hold${mode// /}" audio.m4a mic.m4a call.m4a)"
  mkdir "$d/.processing"
  printf '%s\n' "$dead_owner" > "$d/.processing/owner"
  command rm -f "$HOME/loser.held"
  : > "$HOME/calls.log"
  ( $mode; process "$d/audio.m4a" ) >"$HOME/a.out" 2>&1 & pa=$!
  sleep 0.05
  ( $mode; process "$d/audio.m4a" ) >"$HOME/b.out" 2>&1 & pb=$!
  wait "$pa"; ra=$?; wait "$pb"; rb=$?
  pair="$ra $rb"
  if { [ "$pair" = "0 75" ] || [ "$pair" = "75 0" ]; } && [ "$(sa_calls)" = 2 ] && ! grep -q OVERLAP "$HOME/calls.log" \
     && [ -e "$HOME/loser.held" ] && ! cat "$HOME/a.out" "$HOME/b.out" | grep -q 'No such file' \
     && [ ! -e "$d/.processing" ] && lock_clean "$d"; then :
  else hold_ok=0; hold_log="$hold_log [$mode: $pair, $(sa_calls) calls, $(ls -a "$d" | tr '\n' ' ') $(cat "$HOME/a.out" "$HOME/b.out" | grep error)]"; fi
done
unset -f cat rm
if [ "$hold_ok" = 1 ]; then pass "the winner keeps its own owner text while a loser holds the owner file: one runs, no lock left, with and without set -e"
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
    respond) cat >/dev/null; echo "the minutes" ;;
    schema) echo '{}' ;;
    *) return 1 ;;
  esac
}
d="$(meeting u1 audio.m4a mic.m4a call.m4a)"
(umask 022; process "$d/audio.m4a") >/dev/null 2>&1
bad=""
for f in mic.words.json call.words.json transcript.txt notes.md notes-raw.md brief.json .process-result; do
  [ -e "$d/$f" ] || { bad="$bad $f(missing)"; continue; }
  [ "$(mode_of "$d/$f")" = 600 ] || bad="$bad $f($(mode_of "$d/$f"))"
done
if [ -z "$bad" ]; then pass "words.json, transcript, minutes and result are all 0600"
else fail "words.json, transcript, minutes and result are all 0600:$bad"; fi
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

finish
