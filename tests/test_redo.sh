#!/bin/bash
. "$(dirname "$0")/lib.sh"

# notes, redo and every run of process (spec 6.4): each builds its files in a staging folder inside
# the meeting folder, keeps what it replaces in earlier/, and swaps the new files in under a .swap
# marker that the next run finishes if this one is killed. The transcribers, the speech helper and
# fm are stand-ins; mb-transcript is the real one, behind a wrapper that logs its arguments.

umask 022   # every file a run writes is checked for 0600 against a loose umask

# The real helper: tests/run.sh builds it into MB_TEST_BIN. Run alone, build it here.
if [ -n "${MB_TEST_BIN:-}" ] && [ -x "$MB_TEST_BIN/mb-transcript" ]; then
  REAL_MBT="$MB_TEST_BIN/mb-transcript"
else
  REAL_MBT="$HOME/mb-transcript"
  swiftc -suppress-warnings -o "$REAL_MBT" "$ROOT"/native/transcript/*.swift \
    || { fail "mb-transcript does not compile"; finish; }
fi
cat > "$HOME/mb-transcript-logged" <<EOF
#!/bin/bash
echo "mb-transcript \$*" >> "$HOME/calls.log"
[ ! -e "$HOME/mbt-fail" ] || { echo "mb-transcript: the labels could not be worked out" >&2; exit 1; }
exec "$REAL_MBT" "\$@"
EOF
chmod 755 "$HOME/mb-transcript-logged"
TRANSCRIPT_BIN="$HOME/mb-transcript-logged"

FIX="$ROOT/tests/fixtures"

# A stand-in speech helper: check passes; transcribe copies Parakeet's fixture for the side, or
# fails (pk-fail-<side>), or hears nothing (pk-empty-<side>), or gives the labelled fixture
# (pk-labelled); speakers gives no speakers, or the speaker fixtures with their voice vectors
# (sp-fixture). Each call is logged, speakers with its output file and any further arguments.
mkdir -p "$HOME/speech"
SPEECH_BIN="$HOME/speech/mb-speech"; SPEECH_MODELS="$HOME/speech/models"
cat > "$SPEECH_BIN" <<EOF
#!/bin/bash
case "\$(basename "\${3:-}")" in call*) side=call ;; *) side=mic ;; esac
case "\$1" in
  speakers) echo "mb-speech speakers \$side wav=\$3 out=\$4 more=\${*:5}" >> "$HOME/calls.log" ;;
  *) echo "mb-speech \$1 wav=\$3" >> "$HOME/calls.log" ;;
esac
case "\$1" in
  check) exit 0 ;;
  transcribe)
    [ -e "$HOME/pk-fail-\$side" ] && { echo "mb-speech: the model could not run" >&2; exit 1; }
    [ -e "$HOME/pk-empty-\$side" ] && { printf '{"engine": "parakeet-ultra", "words": []}\n' > "\$4"; exit 0; }
    [ -e "$HOME/pk-labelled" ] && { cp "$FIX/labelled-\$side.json" "\$4"; exit 0; }
    cp "$FIX/pk-\$side.json" "\$4" ;;
  speakers)
    [ -e "$HOME/sp-fixture" ] && { cp "$FIX/speakers-\$side.json" "\$4"; exit 0; }
    printf '{"model": "FluidInference/speaker-diarization-coreml@x", "segments": [], "speakers": []}\n' > "\$4" ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$SPEECH_BIN"

SA_FAIL=""      # "", call or both
HAVE_FM=1
have() { case "$1" in speech-analyzer) return 0 ;; fm) [ "$HAVE_FM" = 1 ] ;; *) return 1 ;; esac; }
notify() { :; }
chime() { :; }
speech-analyzer() {
  echo "speech-analyzer $*" >> "$HOME/calls.log"
  local a
  for a in "$@"; do :; done   # the audio is the last argument
  case "$a" in
    *mic.m4a)  [ "$SA_FAIL" = both ] && return 1; cat "$FIX/sa-mic.json" ;;
    *call.m4a) { [ "$SA_FAIL" = both ] || [ "$SA_FAIL" = call ]; } && return 1; cat "$FIX/sa-call.json" ;;
    *) [ "$SA_FAIL" = both ] && return 1; echo "a plain transcript of the whole mix" ;;
  esac
}
# fm: the new minutes are FM_TEXT and the new brief names itself. fm-empty makes every answer empty,
# brief-fail fails the structured pass, FM_MAP_FAIL=1 fails every slice of a long transcript, and
# FM_TOKENS is the count it gives. fm_hook is a test's own step, run inside the engine as fm answers.
FM_TOKENS=100; FM_MAP_FAIL=0
FM_TEXT="the new minutes"
# Apple's notes.md: its minutes, a blank line, and the line saying who wrote them (spec 6.5).
FM_NOTES="$FM_TEXT

Minutes written on this Mac by Apple's model."
fm_hook() { :; }
fm() {
  echo "fm $1" >> "$HOME/calls.log"
  case "$1" in
    count-tokens) cat >/dev/null; echo "$FM_TOKENS" ;;
    respond)
      cat >/dev/null
      fm_hook
      case "$3" in "You are taking minutes"*) [ "$FM_MAP_FAIL" != 1 ] || return 1 ;; esac
      [ ! -e "$HOME/fm-empty" ] || return 0
      case " $* " in
        *" --schema "*) [ ! -e "$HOME/brief-fail" ] || return 1; echo '{"summary": "the new brief"}' ;;
        *) echo "$FM_TEXT" ;;
      esac ;;
    schema) echo '{}' ;;
    *) return 1 ;;
  esac
}
# The time a run stamps its earlier/ folder and notes-edited copy with, fixed so names are known.
STAMP="2026-11-13 1452"
date() { if [ "$*" = '+%Y-%m-%d %H%M' ]; then printf '%s\n' "$STAMP"; else command date "$@"; fi; }

LISTED="transcript.txt mic.words.json call.words.json notes.md notes-raw.md brief.json .notes-written"
OTHERS="audio.m4a mic.m4a call.m4a meeting.json transcript-original.txt transcript-parakeet.txt"

# A two-channel meeting processed once before, every file dated 1 January 2026: each listed file
# (Apple's words, so Parakeet's new ones differ), .notes-written matching notes.md, and files that
# others wrote beside them. The listed files are also copied to <name>.old for comparison.
finished() {
  d="$HOME/$1"; mkdir -p "$d" "$HOME/$1.old"
  printf 'aac mix' > "$d/audio.m4a"; printf 'aac mic' > "$d/mic.m4a"; printf 'aac call' > "$d/call.m4a"
  printf '{"id": "%s", "state": "done"}\n' "$1" > "$d/meeting.json"
  printf '[00:00:01] Me: the old transcript\n' > "$d/transcript.txt"
  command cp "$FIX/sa-mic.json" "$d/mic.words.json"; command cp "$FIX/sa-call.json" "$d/call.words.json"
  printf 'the old minutes\n' > "$d/notes.md"; printf 'the old notes\n' > "$d/notes-raw.md"
  printf '{"summary": "the old brief"}\n' > "$d/brief.json"
  shasum -a 256 "$d/notes.md" | cut -d' ' -f1 > "$d/.notes-written"
  printf '[00:00:01] Speaker 1: written by MLX\n' > "$d/transcript-parakeet.txt"
  printf 'the original\n' > "$d/transcript-original.txt"
  touch -t 202601010000 "$d"/* "$d/.notes-written"
  command cp -p "$d"/* "$d/.notes-written" "$HOME/$1.old/"
}
# A meeting just recorded: its three audio files and nothing else.
recorded() { d="$HOME/$1"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"; printf 'aac mic' > "$d/mic.m4a"; printf 'aac call' > "$d/call.m4a"; }

# Every file in the folder outside earlier/, but the run's result: path, mode, time and contents.
snap() {
  (cd "$1" && find . -type f ! -path './earlier/*' ! -name .process-result | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s %s\n' "$f" "$(stat -f '%Lp %m' "$f")" "$(shasum -a 256 < "$f" | cut -c1-64)"
  done)
}
# The same for the named files only.
snap_of() { local dir="$1" f; shift; for f in "$@"; do printf '%s %s %s\n' "$f" "$(stat -f '%Lp %m' "$dir/$f" 2>/dev/null)" "$(shasum -a 256 < "$dir/$f" 2>/dev/null | cut -c1-64)"; done; }
entries() { ls -A "$1" | grep -vx '.process-result' | tr '\n' ' '; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }
status_of() { sed -n 's/.* status=\([0-9]*\) .*/\1/p' "$1/.process-result" 2>/dev/null; }
no_stage() { ! ls -A "$1" | grep -q '^\.stage\.\|^\.swap\|^\.work\.'; }
calls() { grep -c "^$1" "$HOME/calls.log" | tr -d ' '; }
mbt_args() { grep '^mb-transcript ' "$HOME/calls.log" | head -n 1; }
same() { cmp -s "$1" "$2"; }

CURLED=0
reset_run() {
  grep -q '^curl' "$HOME/calls.log" 2>/dev/null && CURLED=1
  : > "$HOME/calls.log"
  rm -f "$HOME"/pk-* "$HOME"/sp-* "$HOME/mbt-fail" "$HOME/fm-empty" "$HOME/brief-fail" "$HOME/progress"
  SA_FAIL=""; HAVE_FM=1; ENGINE=auto; TIDY=auto; ROOM_COUNT=""; CALL_COUNT=""; KEEP_AUDIO=1; FM_TOKENS=100; FM_MAP_FAIL=0
  fm_hook() { :; }
}
# An engine command as the script runs it, with set -euo pipefail, in a subshell: sets out and rc.
engine() { out="$( (set -euo pipefail; "$@") 2>&1 )"; rc=$?; }
# The command line as main gives it: the options parsed, then the command.
cli() {
  parse_args "$@"
  case "$cmd" in
    process) process "$argfile" ;;
    notes)   notes_cmd "$argfile" ;;
    redo)    redo_cmd "$argfile" ;;
  esac
}

# ======================================================================== keeping copies: notes

# --- notes keeps the minutes byte for byte in earlier/<stamp>/, writes new ones, and transcribes nothing ---
reset_run; finished n1
before_t="$(snap_of "$d" transcript.txt mic.words.json call.words.json)"
MB_PROGRESS_FILE="$HOME/progress" engine notes_cmd "$d"
e="$d/earlier/$STAMP"
kept=1; for f in notes.md notes-raw.md brief.json; do same "$e/$f" "$HOME/n1.old/$f" || kept=0; done
if [ "$rc" -eq 0 ] && [ "$kept" = 1 ] && [ ! -e "$e/.notes-written" ] && [ ! -e "$e/transcript.txt" ] \
   && [ "$(ls -A "$e" | tr '\n' ' ')" = "brief.json notes-raw.md notes.md " ]; then
  pass "notes keeps notes.md, notes-raw.md and brief.json byte for byte in earlier/<stamp>/, and never .notes-written"
else fail "notes keeps notes.md, notes-raw.md and brief.json byte for byte in earlier/<stamp>/, and never .notes-written (rc $rc): $(ls -A "$e" 2>&1) $out"; fi
if [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ "$(jq -r .summary "$d/brief.json")" = "the new brief" ] \
   && [ "$(cat "$d/.notes-written")" = "$(shasum -a 256 "$d/notes.md" | cut -d' ' -f1)" ] && [ "$(grep -c . "$d/.notes-written")" = 1 ]; then
  pass "notes writes new minutes and brief, and .notes-written holds the new notes.md's SHA-256 on one line"
else fail "notes writes new minutes and brief, and .notes-written holds the new notes.md's SHA-256 on one line: $(cat "$d/.notes-written" 2>&1)"; fi
if [ "$(tr '\n' ' ' < "$HOME/progress" 2>/dev/null)" = "minutes done " ]; then pass "notes reports progress as minutes, done"
else fail "notes reports progress as minutes, done: $(cat "$HOME/progress" 2>&1)"; fi
if [ "$(calls mb-speech)" = 0 ] && [ "$(calls speech-analyzer)" = 0 ] && [ "$(calls mb-transcript)" = 0 ] \
   && [ "$(snap_of "$d" transcript.txt mic.words.json call.words.json)" = "$before_t" ]; then
  pass "notes never transcribes, and the transcript and words keep their bytes and times"
else fail "notes never transcribes, and the transcript and words keep their bytes and times: $(cat "$HOME/calls.log")"; fi
if no_stage "$d" && [ ! -e "$d/.processing" ] && [ "$(status_of "$d")" = 0 ] && ! ls "$d" | grep -q '^notes-edited'; then
  pass "notes leaves no stage, marker or lock, writes the result, and an unedited notes.md gets no notes-edited copy"
else fail "notes leaves no stage, marker or lock, writes the result, and an unedited notes.md gets no notes-edited copy: $(ls -A "$d")"; fi

# --- hand edits: kept as notes-edited-<stamp>.md, with -2 on a clash; a second run makes none ---
reset_run; finished n2
rm -f "$d/.notes-written"   # from before .notes-written: its notes.md counts as hand-edited
engine notes_cmd "$d"; rc1=$rc
edited1="$(ls "$d" | grep -c '^notes-edited')"
same "$d/notes-edited-$STAMP.md" "$HOME/n2.old/notes.md"; copy1=$?
engine notes_cmd "$d"; rc2=$rc
edited2="$(ls "$d" | grep -c '^notes-edited')"
if [ "$rc1" -eq 0 ] && [ "$copy1" -eq 0 ] && [ "$edited1" = 1 ]; then
  pass "a notes.md with no .notes-written is kept as notes-edited-<stamp>.md"
else fail "a notes.md with no .notes-written is kept as notes-edited-<stamp>.md (rc $rc1, $edited1 copies): $(ls "$d")"; fi
if [ "$rc2" -eq 0 ] && [ "$edited2" = 1 ] && [ -d "$d/earlier/$STAMP-2" ]; then
  pass "running notes twice makes no notes-edited copy the second time"
else fail "running notes twice makes no notes-edited copy the second time (rc $rc2, $edited2 copies): $(ls "$d" "$d/earlier")"; fi
printf 'a line of my own\n' >> "$d/notes.md"; command cp "$d/notes.md" "$HOME/n2.edited"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && same "$d/notes-edited-$STAMP-2.md" "$HOME/n2.edited" && same "$d/notes-edited-$STAMP.md" "$HOME/n2.old/notes.md" \
   && same "$d/earlier/$STAMP-3/notes.md" "$HOME/n2.edited" && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "an edited notes.md is kept as notes-edited-<stamp>-2.md when the name is taken, and in earlier/"
else fail "an edited notes.md is kept as notes-edited-<stamp>-2.md when the name is taken, and in earlier/ (rc $rc): $(ls "$d" "$d/earlier") $out"; fi

# ======================================================================== process on a finished folder

# --- process keeps the old transcript, words and minutes in earlier/, and a hand-edited notes.md ---
reset_run; finished p1
printf 'a hand edit\n' >> "$d/notes.md"; command cp "$d/notes.md" "$HOME/p1.edited"
engine process "$d/audio.m4a"
e="$d/earlier/$STAMP"
kept=1; for f in transcript.txt mic.words.json call.words.json notes-raw.md brief.json; do same "$e/$f" "$HOME/p1.old/$f" || kept=0; done
if [ "$rc" -eq 0 ] && [ "$kept" = 1 ] && same "$e/notes.md" "$HOME/p1.edited" && [ ! -e "$e/.notes-written" ] \
   && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && same "$d/mic.words.json" "$FIX/pk-mic.json"; then
  pass "process on a finished folder keeps the old transcript, words and minutes in earlier/ and writes new ones"
else fail "process on a finished folder keeps the old transcript, words and minutes in earlier/ and writes new ones (rc $rc): $(ls -A "$e" 2>&1) $out"; fi
if same "$d/notes-edited-$STAMP.md" "$HOME/p1.edited" && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "process keeps a hand-edited notes.md as notes-edited-<stamp>.md"
else fail "process keeps a hand-edited notes.md as notes-edited-<stamp>.md: $(ls "$d")"; fi

# --- process <dir>/transcript.txt behaves as notes ---
reset_run; finished p2
before_t="$(snap_of "$d" transcript.txt mic.words.json call.words.json)"
MB_PROGRESS_FILE="$HOME/progress" engine process "$d/transcript.txt"
if [ "$rc" -eq 0 ] && [ "$(calls mb-speech)" = 0 ] && [ "$(calls speech-analyzer)" = 0 ] && [ "$(calls mb-transcript)" = 0 ] \
   && [ "$(snap_of "$d" transcript.txt mic.words.json call.words.json)" = "$before_t" ] \
   && [ "$(tr '\n' ' ' < "$HOME/progress" 2>/dev/null)" = "minutes done " ] \
   && [ "$(ls -A "$d/earlier/$STAMP" | tr '\n' ' ')" = "brief.json notes-raw.md notes.md " ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "process <dir>/transcript.txt behaves as notes"
else fail "process <dir>/transcript.txt behaves as notes (rc $rc): $(cat "$HOME/progress" 2>&1) $(ls -A "$d/earlier/$STAMP" 2>&1) $out"; fi

# ======================================================================== what redo touches

# --- redo replaces exactly its list; files others wrote, the audio and meeting.json keep bytes and times ---
reset_run; finished r1
before_o="$(snap_of "$d" $OTHERS)"; before_e="$(entries "$d")"
engine redo_cmd "$d"
e="$d/earlier/$STAMP"
kept=1; for f in transcript.txt mic.words.json call.words.json notes.md notes-raw.md brief.json; do same "$e/$f" "$HOME/r1.old/$f" || kept=0; done
changed=1; for f in transcript.txt mic.words.json call.words.json notes.md notes-raw.md brief.json .notes-written; do same "$d/$f" "$HOME/r1.old/$f" && changed=0; done
if [ "$rc" -eq 0 ] && [ "$kept" = 1 ] && [ "$changed" = 1 ] && [ ! -e "$e/.notes-written" ] \
   && [ "$(entries "$d" | sed 's/ earlier / /')" = "$before_e" ] && same "$d/call.words.json" "$FIX/pk-call.json"; then
  pass "redo replaces exactly its list, keeping each replaced file in earlier/<stamp>/"
else fail "redo replaces exactly its list, keeping each replaced file in earlier/<stamp>/ (rc $rc): before [$before_e] after [$(entries "$d")] $out"; fi
if [ "$(snap_of "$d" $OTHERS)" = "$before_o" ]; then
  pass "redo leaves transcript-original.txt, transcript-parakeet.txt, the audio and meeting.json with their bytes and times"
else fail "redo leaves transcript-original.txt, transcript-parakeet.txt, the audio and meeting.json with their bytes and times"; fi

# --- a brief that fails is displaced: no brief.json beside the new minutes ---
reset_run; finished r2; touch "$HOME/brief-fail"
engine redo_cmd "$d"
if [ "$rc" -eq 0 ] && [ ! -e "$d/brief.json" ] && same "$d/earlier/$STAMP/brief.json" "$HOME/r2.old/brief.json" \
   && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "a brief that fails is displaced into earlier/, so no brief.json sits beside the new minutes"
else fail "a brief that fails is displaced into earlier/, so no brief.json sits beside the new minutes (rc $rc): $(ls -A "$d" "$d/earlier/$STAMP" 2>&1)"; fi
reset_run; finished r3; touch "$HOME/brief-fail"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ ! -e "$d/brief.json" ] && same "$d/earlier/$STAMP/brief.json" "$HOME/r3.old/brief.json"; then
  pass "notes displaces a brief it could not write too"
else fail "notes displaces a brief it could not write too (rc $rc): $(ls -A "$d")"; fi
if [ "$(stat -f %m "$d/earlier/$STAMP/brief.json")" = "$(stat -f %m "$HOME/r3.old/brief.json")" ]; then
  pass "a displaced file is moved into earlier/, not copied: it keeps its time"
else fail "a displaced file is moved into earlier/, not copied: it keeps its time"; fi
# a run whose only replacement is a displacement still makes its earlier/ folder for it
reset_run; touch "$HOME/brief-fail"; d="$HOME/r4"; mkdir -p "$d"
printf '[00:00:01] Me: a transcript\n' > "$d/transcript.txt"; printf '{"summary": "a lone brief"}\n' > "$d/brief.json"
command cp "$d/brief.json" "$HOME/r4.brief"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ ! -e "$d/brief.json" ] && same "$d/earlier/$STAMP/brief.json" "$HOME/r4.brief" \
   && [ "$(ls -A "$d/earlier/$STAMP")" = brief.json ] && no_stage "$d"; then
  pass "a run that only displaces a file still keeps it in its own earlier/ folder"
else fail "a run that only displaces a file still keeps it in its own earlier/ folder (rc $rc): $(ls -A "$d" "$d/earlier/$STAMP" 2>&1) $out"; fi

# ======================================================================== counts

# --- parse_args: --room and --call, as the app's redo arguments give them ---
got="$( (ENGINE=auto; TIDY=auto; ROOM_COUNT=""; CALL_COUNT=""; WRITER=""
         parse_args redo X --native --room 2 --call 3 --no-tidy --writer apple
         printf '%s|%s|%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$ROOM_COUNT" "$CALL_COUNT" "$TIDY" "$WRITER") 2>&1 )"
if [ "$got" = "redo|X|native|2|3|0|apple" ]; then pass "parse_args: redo --native --room 2 --call 3 --no-tidy --writer apple"
else fail "parse_args: redo --native --room 2 --call 3 --no-tidy --writer apple: $got"; fi
got="$( (ENGINE=auto; TIDY=auto; ROOM_COUNT=""; CALL_COUNT=""; WRITER=""
         parse_args redo X --parakeet --room 1 --tidy --writer apple
         printf '%s|%s|%s|%s|%s|%s|%s' "$cmd" "$argfile" "$ENGINE" "$ROOM_COUNT" "$CALL_COUNT" "$TIDY" "$WRITER") 2>&1 )"
if [ "$got" = "redo|X|parakeet|1||1|apple" ]; then pass "parse_args: redo --parakeet --room 1 --tidy --writer apple"
else fail "parse_args: redo --parakeet --room 1 --tidy --writer apple: $got"; fi
got="$( (WRITER=""; parse_args notes X --writer apple; printf '%s|%s|%s' "$cmd" "$argfile" "$WRITER") 2>&1 )"
if [ "$got" = "notes|X|apple" ]; then pass "parse_args: notes --writer apple"; else fail "parse_args: notes --writer apple: $got"; fi
refused=1
for bad in "--room 0" "--room 7" "--call 9" "--call two" "--room"; do
  # shellcheck disable=SC2086
  ( parse_args redo X $bad ) >/dev/null 2>&1 && refused=0
done
if [ "$refused" = 1 ]; then pass "parse_args refuses a count outside 1 to 6, or none"
else fail "parse_args refuses a count outside 1 to 6, or none"; fi

# --- --room 1: an all-Me microphone side, with no --mic-speakers ---
reset_run; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; finished c1
engine cli redo "$d" --room 1
args="$(mbt_args)"
if [ "$rc" -eq 0 ] && printf '%s' "$args" | grep -q -- '--mic-count 1' && ! printf '%s' "$args" | grep -q -- '--mic-speakers' \
   && [ "$(grep -c '^mb-speech speakers mic' "$HOME/calls.log")" = 0 ] && grep -q '] Me: ' "$d/transcript.txt" \
   && ! grep -q '] Room ' "$d/transcript.txt"; then
  pass "redo --room 1 gives an all-Me microphone side, with no --mic-speakers"
else fail "redo --room 1 gives an all-Me microphone side, with no --mic-speakers (rc $rc): $args $(cat "$d/transcript.txt") $out"; fi

# --- --room 2 --call 3: --count to the helper, --mic-count and --call-count to mb-transcript ---
reset_run; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; finished c2
engine cli redo "$d" --room 2 --call 3
args="$(mbt_args)"
if [ "$rc" -eq 0 ] && grep '^mb-speech speakers mic ' "$HOME/calls.log" | grep -q ' more=--count 2$' \
   && grep '^mb-speech speakers call ' "$HOME/calls.log" | grep -q ' more=--count 3$' \
   && printf '%s' "$args" | grep -q -- '--mic-count 2' && printf '%s' "$args" | grep -q -- '--call-count 3'; then
  pass "redo --room 2 --call 3 passes --count 2 and --count 3 to the helper, and --mic-count 2 --call-count 3 to mb-transcript"
else fail "redo --room 2 --call 3 passes --count 2 and --count 3 to the helper, and --mic-count 2 --call-count 3 to mb-transcript (rc $rc): $(grep '^mb-' "$HOME/calls.log") $out"; fi

# ======================================================================== one side, and failed minutes

# --- process with the call side failing every transcriber: a Me-only transcript and minutes, exit 0 ---
reset_run; touch "$HOME/pk-fail-call"; SA_FAIL=call; recorded o1
engine process "$d/audio.m4a"
if [ "$rc" -eq 0 ] && grep -q '] Me: ' "$d/transcript.txt" && ! grep -qv '] Me: ' "$d/transcript.txt" \
   && [ "$(jq -c . "$d/call.words.json")" = '{"engine":"none","words":[]}' ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "process with the call side failing every transcriber writes a Me-only transcript and minutes, and exits 0"
else fail "process with the call side failing every transcriber writes a Me-only transcript and minutes, and exits 0 (rc $rc): $out"; fi

# --- process whose fm fails: the transcript and words are swapped in, kept; the minutes are untouched; exit 1 ---
for how in missing empty; do
  reset_run; finished "o2$how"
  if [ "$how" = missing ]; then HAVE_FM=0; else touch "$HOME/fm-empty"; fi
  before_m="$(snap_of "$d" notes.md notes-raw.md brief.json .notes-written)"
  engine process "$d/audio.m4a"
  e="$d/earlier/$STAMP"
  if [ "$rc" -eq 1 ] && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && same "$d/call.words.json" "$FIX/pk-call.json" \
     && same "$e/transcript.txt" "$HOME/o2$how.old/transcript.txt" && same "$e/mic.words.json" "$HOME/o2$how.old/mic.words.json" \
     && [ "$(ls -A "$e" | tr '\n' ' ')" = "call.words.json mic.words.json transcript.txt " ] \
     && [ "$(snap_of "$d" notes.md notes-raw.md brief.json .notes-written)" = "$before_m" ] && no_stage "$d" && [ "$(status_of "$d")" = 1 ]; then
    pass "process whose fm fails ($how) swaps in the transcript and words, keeping what they replace, leaves the minutes, exits 1"
  else fail "process whose fm fails ($how) swaps in the transcript and words, keeping what they replace, leaves the minutes, exits 1 (rc $rc): $(ls -A "$d" "$e" 2>&1) $out"; fi
done

# ======================================================================== speaker results never kept

# --- a run killed while writing the minutes leaves its stage, with no speakers file in it ---
reset_run; touch "$HOME/sp-fixture"; recorded s1
fm_hook() { kill -KILL "$(command cat "$HOME/engine.pid")"; }
( sh -c 'printf "%s" "$PPID"' > "$HOME/engine.pid"; set -euo pipefail; process "$d/audio.m4a" ) >"$HOME/s1.out" 2>&1 &
wait $!; rc=$?
fm_hook() { :; }
if [ "$rc" = 137 ] && [ -n "$(find "$d" -maxdepth 1 -name '.stage.??????' -type d)" ] && [ -z "$(find "$d" -name '*speakers*')" ] \
   && grep -q '^mb-speech speakers call' "$HOME/calls.log"; then
  pass "after a run killed while writing the minutes, its stage holds no speakers file"
else fail "after a run killed while writing the minutes, its stage holds no speakers file (rc $rc): $(find "$d") $(cat "$HOME/s1.out")"; fi
# the next run removes that stage
engine process "$d/audio.m4a"
if [ "$rc" -eq 0 ] && no_stage "$d" && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then pass "the next run removes a killed run's stage"
else fail "the next run removes a killed run's stage (rc $rc): $(ls -A "$d")"; fi

# ======================================================================== audio and recordings

# --- notes and redo never remove audio, with MB_KEEP_AUDIO=0 or --no-keep-audio ---
reset_run; finished a1
before_a="$(snap_of "$d" audio.m4a mic.m4a call.m4a)"
export MB_KEEP_AUDIO=0; eval "$(grep '^KEEP_AUDIO=' "$ROOT/meetingbox")"
engine redo_cmd "$d"; rc1=$rc
engine notes_cmd "$d"; rc2=$rc
unset MB_KEEP_AUDIO; KEEP_AUDIO=1
engine cli redo "$d" --no-keep-audio; rc3=$rc
engine cli notes "$d" --no-keep-audio; rc4=$rc
KEEP_AUDIO=1
if [ "$rc1$rc2$rc3$rc4" = 0000 ] && [ "$(snap_of "$d" audio.m4a mic.m4a call.m4a)" = "$before_a" ]; then
  pass "redo and notes leave the audio untouched with MB_KEEP_AUDIO=0 and with --no-keep-audio"
else fail "redo and notes leave the audio untouched with MB_KEEP_AUDIO=0 and with --no-keep-audio ($rc1 $rc2 $rc3 $rc4): $(ls "$d")"; fi
if declare -f notes_cmd >/dev/null && declare -f redo_cmd >/dev/null && ! declare -f notes_cmd redo_cmd | grep -q KEEP_AUDIO; then
  pass "notes_cmd and redo_cmd never read KEEP_AUDIO"
else fail "notes_cmd and redo_cmd never read KEEP_AUDIO"; fi

# --- redo on an unfinished recording stops with the recover message, changing nothing ---
reset_run; finished a3; printf 'caf' > "$d/mic.caf"
before="$(snap "$d")"
engine redo_cmd "$d"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'this recording was not finished. Run: meetingbox recover' \
   && [ "$(calls mb-speech)" = 0 ] && [ "$(calls speech-analyzer)" = 0 ] && [ "$(snap "$d")" = "$before" ]; then
  pass "redo on an unfinished recording stops with the recover message and changes nothing"
else fail "redo on an unfinished recording stops with the recover message and changes nothing (rc $rc): $out"; fi

# --- redo on a folder with only audio.m4a: a new timed, labelled transcript and its words.json, no side files ---
reset_run; d="$HOME/a4"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"
printf 'an old plain transcript\n' > "$d/transcript.txt"; printf 'old\n' > "$d/notes.md"; printf 'old\n' > "$d/notes-raw.md"
engine redo_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Speaking from this desk." ] && same "$d/words.json" "$FIX/pk-mic.json" \
   && [ ! -e "$d/mic.words.json" ] && [ ! -e "$d/call.words.json" ] && [ "$(cat "$d/earlier/$STAMP/transcript.txt")" = "an old plain transcript" ] \
   && [ ! -e "$d/earlier/$STAMP/words.json" ] && no_stage "$d"; then
  pass "redo on a folder with only audio.m4a writes a new timed transcript and words.json, and no side words files"
else fail "redo on a folder with only audio.m4a writes a new timed transcript and words.json, and no side words files (rc $rc): $(ls -A "$d") $out"; fi

# --- Transcribe again on a single recording: the people count, words.json kept in earlier/, nothing learnt (Task 11A) ---
# The stand-in helper gives the labelled fixture's words and its speakers; voice-old.json is a usable print of
# the first speaker, on the install record, so a run that learnt would change it.
ONE_ME="[00:00:00] Me: Right, so the plan for today is simple. We record the call and then we write the minutes after it ends, and we send them round.
[00:00:10] Speaker 1: what about the budget?"
mkdir -p "$STATE_DIR"
single() {   # a single recording processed once before: its audio, an old transcript, old words and old minutes
  d="$HOME/$1"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"
  printf '{"id": "%s", "state": "done"}\n' "$1" > "$d/meeting.json"
  printf '[00:00:01] Unknown: the old transcript\n' > "$d/transcript.txt"; command cp "$FIX/sa-mic.json" "$d/words.json"
  printf 'the old minutes\n' > "$d/notes.md"; printf 'the old notes\n' > "$d/notes-raw.md"
  command cp "$d/words.json" "$HOME/$1.words"
  touch "$HOME/pk-labelled" "$HOME/sp-fixture"
  command cp "$FIX/voice-old.json" "$VOICE_FILE"; record_install "$VOICE_FILE"; command cp "$VOICE_FILE" "$HOME/$1.voice"
}
for people in "" 1 3 6; do
  reset_run; single "solo1$people"
  if [ -n "$people" ]; then engine cli redo "$d" --people "$people"; else engine cli redo "$d"; fi
  args="$(mbt_args)"; sp="$(grep '^mb-speech speakers ' "$HOME/calls.log")"
  case "$people" in
    "") want_sp="more="; want_one="" ;;
    1)  want_sp="more="; want_one=" --one-count 1" ;;   # one person: the finder still runs, so the print can be matched
    *)  want_sp="more=--count $people"; want_one=" --one-count $people" ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$sp" | grep -c .)" = 1 ] && [ "${sp##* out=*one.speakers.json }" = "$want_sp" ] \
     && case "$args" in "mb-transcript --one .stage."??????"/words.json --one-speakers .stage."??????"/.work."??????"/one.speakers.json --voice $VOICE_FILE$want_one") true ;; *) false ;; esac; then
    pass "redo ${people:+--people $people }on a single recording: the finder gets [${want_sp#more=}], mb-transcript [${want_one# }]"
  else fail "redo ${people:+--people $people }on a single recording: the finder gets [${want_sp#more=}], mb-transcript [${want_one# }] (rc $rc): [$sp] [$args] $out"; fi
  # one person: every line takes the one label, the print's
  if [ "$people" = 1 ]; then
    if [ "$rc" -eq 0 ] && [ "$(sed 's/^\[[0-9:]*\] \([^:]*\): .*/\1/' "$d/transcript.txt" | sort -u)" = Me ]; then
      pass "redo --people 1 on a single recording: every line is Me when the print matches the one person"
    else fail "redo --people 1 on a single recording: every line is Me when the print matches the one person (rc $rc): $(cat "$d/transcript.txt") $out"; fi
  fi
done
reset_run; single solo2
engine redo_cmd "$d"
e="$d/earlier/$STAMP"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "$ONE_ME" ] && same "$e/words.json" "$HOME/solo2.words" && same "$d/words.json" "$FIX/labelled-mic.json"; then
  pass "Transcribe again on a single recording keeps the words.json it replaces in earlier/, byte for byte"
else fail "Transcribe again on a single recording keeps the words.json it replaces in earlier/, byte for byte (rc $rc): $(ls -A "$d" "$e" 2>&1) $out"; fi
if [ "$(mode_of "$d/words.json")" = 600 ] && [ "$(mode_of "$e/words.json")" = 600 ] \
   && [ "$(cat "$e/transcript.txt")" = "[00:00:01] Unknown: the old transcript" ] && ! mbt_args | grep -q -- '--learn' && same "$VOICE_FILE" "$HOME/solo2.voice" && [ ! -e "$VOICE_FILE.tmp" ]; then
  pass "Transcribe again on a single recording never learns the voice, though the print is on the record; words.json is 0600, and its copy"
else fail "Transcribe again on a single recording never learns the voice, though the print is on the record; words.json is 0600, and its copy: [$(mbt_args)] $out"; fi
# process too, on the same folder: a single recording never learns, and the earlier words.json is kept again
reset_run; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; command cp "$d/words.json" "$HOME/solo2.words2"; STAMP="2026-11-13 1500"
engine process "$d"
STAMP="2026-11-13 1452"
if [ "$rc" -eq 0 ] && same "$d/earlier/2026-11-13 1500/words.json" "$HOME/solo2.words2" && ! mbt_args | grep -q -- '--learn' \
   && same "$VOICE_FILE" "$HOME/solo2.voice"; then
  pass "process of a single recording keeps the words.json it replaces too, and never learns the voice"
else fail "process of a single recording keeps the words.json it replaces too, and never learns the voice (rc $rc): [$(mbt_args)] $out"; fi
rm -f "$VOICE_FILE" "$INSTALLED"

# ======================================================================== failures change nothing

# --- a failure before the swap: every file byte-identical, exit 1, the result written, no stage ---
for how in transcriber mb-transcript fm fm-empty side; do
  reset_run; finished "f$how"
  case "$how" in
    transcriber)   touch "$HOME/pk-fail-mic" "$HOME/pk-fail-call"; SA_FAIL=both ;;
    mb-transcript) touch "$HOME/mbt-fail" ;;
    fm)            HAVE_FM=0 ;;
    fm-empty)      touch "$HOME/fm-empty" ;;
    side)          touch "$HOME/pk-empty-call" ;;   # the call side has words today, none now
  esac
  before="$(snap "$d")"; before_e="$(entries "$d")"
  engine redo_cmd "$d"
  if [ "$rc" -eq 1 ] && [ "$(snap "$d")" = "$before" ] && [ "$(entries "$d")" = "$before_e" ] && [ "$(status_of "$d")" = 1 ] \
     && [ ! -e "$d/earlier" ] && no_stage "$d" && [ ! -e "$d/.processing" ]; then
    pass "redo failing at the $how leaves every file byte-identical, exits 1, writes the result and leaves no stage"
  else fail "redo failing at the $how leaves every file byte-identical, exits 1, writes the result and leaves no stage (rc $rc, status $(status_of "$d")): $(entries "$d") $out"; fi
done

# --- a cp that fails on the second file kept: nothing changed, no earlier/ ---
reset_run; finished fcp
before="$(snap "$d")"; echo 0 > "$HOME/cp.count"
cp() {
  case "$*" in
    */kept/*) local n; n=$(( $(command cat "$HOME/cp.count") + 1 )); echo "$n" > "$HOME/cp.count"; [ "$n" -ne 2 ] || return 1 ;;
  esac
  command cp "$@"
}
engine notes_cmd "$d"
unset -f cp
if [ "$rc" -eq 1 ] && [ "$(command cat "$HOME/cp.count")" = 2 ] && [ "$(snap "$d")" = "$before" ] && [ ! -e "$d/earlier" ] && no_stage "$d"; then
  pass "a cp failing on the second file kept changes nothing and makes no earlier/"
else fail "a cp failing on the second file kept changes nothing and makes no earlier/ (rc $rc, $(command cat "$HOME/cp.count") copies): $(ls -A "$d") $out"; fi

# --- a held lock gives 75 for notes and redo ---
reset_run; finished flock
mkdir "$d/.processing"; printf '%s %s\n' "$$" "$(pid_lstart $$)" > "$d/.processing/owner"
before="$(snap "$d")"
engine notes_cmd "$d"; rc1=$rc
engine redo_cmd "$d"; rc2=$rc
if [ "$rc1" = 75 ] && [ "$rc2" = 75 ] && [ "$(snap "$d")" = "$before" ] && [ "$(calls fm)" = 0 ] && [ "$(calls mb-speech)" = 0 ]; then
  pass "a held lock gives 75 for notes and redo, and nothing runs"
else fail "a held lock gives 75 for notes and redo, and nothing runs ($rc1 $rc2): $out"; fi
rm -rf "$d/.processing"

# --- a folder moved after the lock was taken: stopped, nothing changed ---
reset_run; finished fmoved
before="$(snap "$d")"
fm_hook() { if [ -d "$HOME/fmoved" ]; then command mv "$HOME/fmoved" "$HOME/fmoved-away"; fi; }
engine notes_cmd "$d"
fm_hook() { :; }
m="$HOME/fmoved-away"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'the meeting folder was moved, nothing was changed' && [ "$(snap "$m")" = "$before" ] \
   && [ ! -e "$m/earlier" ] && no_stage "$m" && [ ! -e "$m/.processing" ] && [ "$(status_of "$m")" = 1 ]; then
  pass "a folder moved after the lock was taken stops with nothing changed"
else fail "a folder moved after the lock was taken stops with nothing changed (rc $rc): $(ls -A "$m" 2>&1) $out"; fi
# a run given a link to the meeting folder works in the folder itself, and is not taken as moved
reset_run; finished flink; ln -s "$d" "$HOME/flink-link"
engine notes_cmd "$HOME/flink-link"
if [ "$rc" -eq 0 ] && [ -L "$HOME/flink-link" ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ -d "$d/earlier/$STAMP" ] && no_stage "$d"; then
  pass "a run given a link to the meeting folder works in the folder, and is not taken as moved"
else fail "a run given a link to the meeting folder works in the folder, and is not taken as moved (rc $rc): $out"; fi

# ======================================================================== permissions

reset_run; finished perm
rm -f "$d/.notes-written"; chmod 644 "$d"/*
engine redo_cmd "$d"
bad=""
for f in $LISTED .process-result "notes-edited-$STAMP.md"; do
  [ -e "$d/$f" ] || { bad="$bad $f(missing)"; continue; }
  [ "$(mode_of "$d/$f")" = 600 ] || bad="$bad $f($(mode_of "$d/$f"))"
done
for f in "$d/earlier/$STAMP"/*; do [ "$(mode_of "$f")" = 600 ] || bad="$bad earlier/$(basename "$f")($(mode_of "$f"))"; done
for f in "$d/earlier" "$d/earlier/$STAMP"; do [ "$(mode_of "$f")" = 700 ] || bad="$bad ${f#"$d"/}($(mode_of "$f"))"; done
if [ "$rc" -eq 0 ] && [ -z "$bad" ] && [ -n "$(ls "$d/earlier/$STAMP")" ]; then
  pass "under umask 022, every file the run wrote, the earlier/ copies, .notes-written and notes-edited are 0600, the folders 0700"
else fail "under umask 022, every file the run wrote, the earlier/ copies, .notes-written and notes-edited are 0600, the folders 0700 (rc $rc):$bad"; fi

# ======================================================================== killed during the swap

# A stand-in mv that kills the engine's shell (SIGKILL, so no trap runs) as it reaches the second
# rename of a staged file over its target. KILL_AT names the rename it stops at.
KILL_AT=2
mv() {
  local a last=""
  for a in "$@"; do last="$a"; done
  case "$*" in
    *.stage.*)
      case " $LISTED " in
        *" $last "*)
          local n; n=$(( $(command cat "$HOME/mv.count") + 1 )); echo "$n" > "$HOME/mv.count"
          [ "$n" -ne "$KILL_AT" ] || kill -KILL "$(command cat "$HOME/engine.pid")" ;;
      esac ;;
  esac
  command mv "$@"
}
# Runs the engine command in the background with the killing mv; rc is how it ended.
killed_run() {
  echo 0 > "$HOME/mv.count"
  ( sh -c 'printf "%s" "$PPID"' > "$HOME/engine.pid"; set -euo pipefail; "$@" ) >"$HOME/killed.out" 2>&1 &
  wait $!; rc=$?
}
# Every file that was in the folder before is in it still, or in earlier/<stamp>/.
none_missing() {
  local f
  for f in $(command cat "$HOME/$1.names"); do [ -e "$d/$f" ] || [ -e "$d/earlier/$STAMP/$f" ] || return 1; done
}
names_of() { (cd "$d" && ls -A | grep -vx '.process-result') > "$HOME/$1.names"; }
# The files the marker moves in, from the stage or already in place, dated 2020, so a finishing run must touch them.
backdate() {
  local s f
  s="$(find "$d" -maxdepth 1 -name '.stage.??????' -type d | head -n 1)"
  for f in $(sed -n 's/^move //p' "$d/.swap"); do
    if [ -e "$s/$f" ]; then touch -t 202001010000 "$s/$f"; command cp -p "$s/$f" "$HOME/staged.$f"
    else touch -t 202001010000 "$d/$f"; command cp -p "$d/$f" "$HOME/staged.$f"; fi
  done
}

# --- notes killed between two renames: every file there, or in earlier/; .swap left ---
reset_run; finished k1; names_of k1
rm -f "$HOME"/staged.*
killed_run notes_cmd "$d"
if [ "$rc" = 137 ] && [ -f "$d/.swap" ] && none_missing k1 && [ -n "$(find "$d" -maxdepth 1 -name '.stage.??????' -type d)" ] \
   && [ "$(sed -n 's/^kind //p' "$d/.swap")" = minutes ] && [ "$(tail -n 1 "$d/.swap")" = end ]; then
  pass "notes killed between renames: every file is in the folder or in earlier/<stamp>/, and .swap is there"
else fail "notes killed between renames: every file is in the folder or in earlier/<stamp>/, and .swap is there (rc $rc): $(ls -A "$d") $(cat "$d/.swap" 2>&1)"; fi
if [ "$(sed -n '2s/^stage //p' "$d/.swap")" = "$(basename "$(find "$d" -maxdepth 1 -name '.stage.??????' -type d)")" ] \
   && [ "$(sed -n '3p' "$d/.swap")" = "earlier $STAMP" ] && [ "$(sed -n 's/^move //p' "$d/.swap" | tail -n 1)" = .notes-written ] \
   && [ "$(sed -n 's/^move //p' "$d/.swap" | tr '\n' ' ')" = "notes-raw.md brief.json notes.md .notes-written " ] \
   && [ "$(mode_of "$d/.swap")" = 600 ]; then
  pass "the marker names the kind, the stage, the earlier folder and each file to move in, .notes-written last, and is 0600"
else fail "the marker names the kind, the stage, the earlier folder and each file to move in, .notes-written last, and is 0600: $(cat "$d/.swap" 2>&1)"; fi
backdate
: > "$HOME/calls.log"; start="$(date +%s)"
engine notes_cmd "$d"
fresh=1; full=1
for f in notes.md notes-raw.md brief.json .notes-written; do
  [ "$(stat -f %m "$d/$f")" -ge "$start" ] || fresh=0
  same "$d/$f" "$HOME/staged.$f" || full=0
done
if [ "$rc" -eq 0 ] && [ "$full" = 1 ] && [ "$(ls "$d/earlier" | wc -l | tr -d ' ')" = 1 ] && no_stage "$d" && [ "$(calls fm)" = 0 ] \
   && same "$d/earlier/$STAMP/notes.md" "$HOME/k1.old/notes.md"; then
  pass "the next notes finishes the swap, exits 0, makes no second earlier/ folder and leaves the full new set"
else fail "the next notes finishes the swap, exits 0, makes no second earlier/ folder and leaves the full new set (rc $rc, full $full): $(ls -A "$d" "$d/earlier") $out"; fi
if [ "$fresh" = 1 ]; then pass "every file the finishing run moved in has a modification time at or after its start"
else fail "every file the finishing run moved in has a modification time at or after its start: $(stat -f '%N %m' "$d"/notes.md "$d"/.notes-written) start $start"; fi

# --- notes killed between renames, then redo: the swap is finished, then the meeting is transcribed again ---
reset_run; finished k2; names_of k2
killed_run notes_cmd "$d"; rc1=$rc
engine redo_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc" -eq 0 ] && same "$d/earlier/$STAMP/notes.md" "$HOME/k2.old/notes.md" \
   && [ "$(cat "$d/earlier/$STAMP-2/notes.md")" = "$FM_NOTES" ] && same "$d/earlier/$STAMP-2/transcript.txt" "$HOME/k2.old/transcript.txt" \
   && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && no_stage "$d" && [ "$(calls 'mb-speech transcribe')" = 2 ]; then
  pass "after a notes killed between renames, redo finishes that swap and then transcribes again"
else fail "after a notes killed between renames, redo finishes that swap and then transcribes again ($rc1, $rc): $(ls -A "$d" "$d/earlier") $out"; fi

# --- process killed between renames, then process: the swap is finished and nothing runs again ---
reset_run; finished k3; names_of k3
killed_run process "$d/audio.m4a"; rc1=$rc
missing_ok=0; none_missing k3 && missing_ok=1
: > "$HOME/calls.log"
engine process "$d/audio.m4a"
if [ "$rc1" = 137 ] && [ "$missing_ok" = 1 ] && [ "$rc" -eq 0 ] && [ "$(calls mb-speech)" = 0 ] && [ "$(calls fm)" = 0 ] \
   && [ "$(ls "$d/earlier" | wc -l | tr -d ' ')" = 1 ] && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" \
   && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && no_stage "$d"; then
  pass "a process killed between renames is finished by the next process, which runs nothing again"
else fail "a process killed between renames is finished by the next process, which runs nothing again ($rc1, $rc): $(ls -A "$d") $out"; fi
unset -f mv

# --- a .swap with no end line is discarded: nothing moves in from it, and the run completes normally ---
# The marker is whole but for its end line (kind, stage, an earlier folder that holds the kept copy,
# a move line), so only the end-line rule can refuse it.
no_end_marker() {
  mkdir -m 700 "$d/.stage.ABCDEF"; printf 'notes a stage left\n' > "$d/.stage.ABCDEF/notes.md"
  mkdir -p "$d/earlier/2026-01-01 0000"; command cp "$d/notes.md" "$d/earlier/2026-01-01 0000/notes.md"
  printf 'kind minutes\nstage .stage.ABCDEF\nearlier 2026-01-01 0000\nmove notes.md\n' > "$d/.swap"
}
reset_run; finished k4
no_end_marker
before_l="$(snap_of "$d" $LISTED)"
HAVE_FM=0
engine notes_cmd "$d"
HAVE_FM=1
if [ "$rc" -eq 1 ] && [ "$(snap_of "$d" $LISTED)" = "$before_l" ] && no_stage "$d" && printf '%s' "$out" | grep -q 'has no end line'; then
  pass "a .swap whole but for its end line is discarded, with a log line saying so, and moves nothing in"
else fail "a .swap whole but for its end line is discarded, with a log line saying so, and moves nothing in (rc $rc): $(ls -A "$d") $out"; fi
rm -rf "$d/earlier/2026-01-01 0000"
no_end_marker
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && same "$d/earlier/$STAMP/notes.md" "$HOME/k4.old/notes.md" && no_stage "$d"; then
  pass "after discarding such a .swap, the run completes normally"
else fail "after discarding such a .swap, the run completes normally (rc $rc): $(ls -A "$d") $out"; fi
# a complete marker naming a stage that is not there is discarded too
reset_run; finished k5
printf 'kind minutes\nstage .stage.GONE00\nearlier -\nmove notes.md\nend\n' > "$d/.swap"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && same "$d/earlier/$STAMP/notes.md" "$HOME/k5.old/notes.md" && no_stage "$d"; then
  pass "a .swap naming a stage that does not exist is discarded, and the run completes"
else fail "a .swap naming a stage that does not exist is discarded, and the run completes (rc $rc): $out"; fi

# --- a rename that fails during the swap: logged, the rest still move, .swap stays, exit 3; the next run finishes ---
reset_run; finished k6
mv() {
  local a last=""
  for a in "$@"; do last="$a"; done
  case "$*" in *.stage.*) [ "$last" != notes.md ] || return 1 ;; esac
  command mv "$@"
}
engine notes_cmd "$d"
unset -f mv
if [ "$rc" = 3 ] && [ -f "$d/.swap" ] && same "$d/notes.md" "$HOME/k6.old/notes.md" && [ "$(cat "$d/notes-raw.md")" != "the old notes" ] \
   && [ "$(jq -r .summary "$d/brief.json")" = "the new brief" ] && printf '%s' "$out" | grep -q 'notes.md' && [ "$(status_of "$d")" = 3 ]; then
  pass "a rename that fails mid-swap is logged, the rest still move, .swap stays, and the run exits 3"
else fail "a rename that fails mid-swap is logged, the rest still move, .swap stays, and the run exits 3 (rc $rc): $(ls -A "$d") $out"; fi
: > "$HOME/calls.log"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && no_stage "$d" && [ "$(calls fm)" = 0 ] \
   && [ "$(cat "$d/.notes-written")" = "$(shasum -a 256 "$d/notes.md" | cut -d' ' -f1)" ]; then
  pass "the next run finishes a swap left by a failed rename"
else fail "the next run finishes a swap left by a failed rename (rc $rc): $(ls -A "$d") $out"; fi

# ======================================================================== findings carried from earlier tasks

# --- Task 2, finding 3: a removal that fails never stops the exit trap or skips the result ---
reset_run; recorded cf1
# removing a stage or work folder fails, as it would on a folder the user cannot write in
rm() {
  case "$1 $*" in -rf\ *.stage.*|-rf\ *.work.*) echo "rm refused $*" >> "$HOME/calls.log"; return 1 ;; esac
  command rm "$@"
}
engine process "$d/audio.m4a"
rc_ok=$rc; status_ok="$(status_of "$d")"; lock_left=0; [ -e "$d/.processing" ] && lock_left=1
reset_run; touch "$HOME/pk-fail-mic" "$HOME/pk-fail-call"; SA_FAIL=both; recorded cf1b
engine process "$d/audio.m4a"
rc_bad=$rc; status_bad="$(status_of "$d")"; [ -e "$d/.processing" ] && lock_left=1
unset -f rm
if [ "$rc_ok" -eq 0 ] && [ "$status_ok" = 0 ] && [ "$rc_bad" -eq 1 ] && [ "$status_bad" = 1 ] && [ "$lock_left" = 0 ] \
   && grep -q '^rm refused' "$HOME/calls.log" && [ -s "$HOME/cf1/notes.md" ]; then
  pass "a stage or work folder that cannot be removed never stops the exit trap: the result is written and the lock released"
else fail "a stage or work folder that cannot be removed never stops the exit trap: the result is written and the lock released ($rc_ok/$status_ok, $rc_bad/$status_bad, lock $lock_left)"; fi
reset_run
engine notes_cmd "$HOME/cf1"
if [ "$rc" -eq 0 ] && no_stage "$HOME/cf1"; then pass "the next run removes the stage that could not be removed"
else fail "the next run removes the stage that could not be removed (rc $rc): $(ls -A "$HOME/cf1")"; fi

# --- Task 2, finding 5 and Task 4: the work folder is in the stage; leftovers of both kinds go; doctor names them ---
reset_run; touch "$HOME/sp-fixture"; recorded root/cf2
mkdir -m 700 "$d/.work.LEGACY" "$d/.stage.OLD123"
printf 'wav' > "$d/.work.LEGACY/mic.wav"; command cp "$FIX/speakers-mic.json" "$d/.work.LEGACY/mic.speakers.json"
printf 'copy' > "$d/.stage.OLD123/notes.md"; printf 'kind minutes\n' > "$d/.swap.tmp"
mkdir -p "$HOME/root/clean"
BASE_DIR="$HOME/root"
doc="$(doctor 2>&1)"
line="$(printf '%s\n' "$doc" | grep -i 'staging')"
if printf '%s' "$line" | grep -q 'cf2' && [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] && ! printf '%s' "$line" | grep -q 'clean'; then
  pass "doctor's leftover-staging line names a meeting holding .stage and .work folders left by stopped runs"
else fail "doctor's leftover-staging line names a meeting holding .stage and .work folders left by stopped runs: [$line]"; fi
engine process "$d/audio.m4a"
wav="$(grep '^mb-speech speakers mic ' "$HOME/calls.log" | sed -n 's/.* wav=\([^ ]*\) .*/\1/p')"
case "$wav" in .stage.??????/.work.??????/mic.wav) in_stage=1 ;; *) in_stage=0 ;; esac
if [ "$rc" -eq 0 ] && [ "$in_stage" = 1 ] && [ ! -e "$d/.work.LEGACY" ] && [ ! -e "$d/.stage.OLD123" ] && [ ! -e "$d/.swap.tmp" ] \
   && no_stage "$d" && [ -z "$(find "$d" -name '*speakers*' -o -name '*.wav')" ]; then
  pass "the run's work folder lives in its stage, and leftover .stage, .work and .swap.tmp are removed under the lock"
else fail "the run's work folder lives in its stage, and leftover .stage, .work and .swap.tmp are removed under the lock (rc $rc): [$wav] $(ls -A "$d")"; fi
doc="$(doctor 2>&1)"
if printf '%s\n' "$doc" | grep -i 'staging' | grep -q '+'; then pass "doctor's leftover-staging line is ok once they are gone"
else fail "doctor's leftover-staging line is ok once they are gone: $(printf '%s\n' "$doc" | grep -i staging)"; fi
BASE_DIR="$HOME/Meetings"
# a .work. folder in a folder the recorder did not make might be someone else's: left alone
reset_run; d="$HOME/plain"; mkdir -p "$d/.work.OTHERS"; printf 'theirs' > "$d/.work.OTHERS/file"
printf '[00:00:01] Me: a typed transcript\n' > "$d/typed.txt"
engine process "$d/typed.txt"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/.work.OTHERS/file")" = theirs ] && same "$d/transcript.txt" "$d/typed.txt" \
   && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ ! -e "$d/.swap" ] && ! ls -A "$d" | grep -q '^\.stage\.'; then
  pass "a .work. folder where the recorder made nothing is left alone, and a transcript file is processed beside it"
else fail "a .work. folder where the recorder made nothing is left alone, and a transcript file is processed beside it (rc $rc): $(ls -A "$d") $out"; fi

# --- Task 5: redo never passes --learn, whatever the voice print's record; notes never transcribes ---
reset_run; touch "$HOME/pk-labelled" "$HOME/sp-fixture"
mkdir -p "$STATE_DIR"; rm -f "$VOICE_FILE" "$VOICE_FILE.tmp"; record_install "$VOICE_FILE"
recorded cf3a; printf '{"id": "CF3A"}\n' > "$d/meeting.json"
engine process "$d/audio.m4a"
learnt_by_process=0; mbt_args | grep -q -- '--learn CF3A' && learnt_by_process=1
rm -f "$VOICE_FILE" "$VOICE_FILE.tmp"
reset_run; touch "$HOME/pk-labelled" "$HOME/sp-fixture"; finished cf3
engine redo_cmd "$d"
if [ "$learnt_by_process" = 1 ] && [ "$rc" -eq 0 ] && [ "$(calls mb-transcript)" = 1 ] && mbt_args | grep -q -- "--voice $VOICE_FILE" \
   && ! grep '^mb-transcript ' "$HOME/calls.log" | grep -q -- '--learn' && [ ! -e "$VOICE_FILE" ]; then
  pass "redo calls mb-transcript with --voice but never --learn, though process would learn"
else fail "redo calls mb-transcript with --voice but never --learn, though process would learn ($learnt_by_process, rc $rc): $(grep '^mb-transcript' "$HOME/calls.log")"; fi
: > "$HOME/calls.log"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(calls mb-transcript)" = 0 ] && [ "$(calls mb-speech)" = 0 ] && [ "$(calls speech-analyzer)" = 0 ]; then
  pass "notes never transcribes, so never learns"
else fail "notes never transcribes, so never learns (rc $rc): $(cat "$HOME/calls.log")"; fi
forget_install "$VOICE_FILE"

# ======================================================================== review round 1

# The killing mv again, as a definition to switch on: KILL_SIG (KILL unless set) at the KILL_AT'th
# rename of a staged file over its target. unset -f mv switches it off.
kill_mv() {
  mv() {
    local a last=""
    for a in "$@"; do last="$a"; done
    case "$*" in
      *.stage.*)
        case " $LISTED " in
          *" $last "*)
            local n; n=$(( $(command cat "$HOME/mv.count") + 1 )); echo "$n" > "$HOME/mv.count"
            [ "$n" -ne "$KILL_AT" ] || kill "-${KILL_SIG:-KILL}" "$(command cat "$HOME/engine.pid")" ;;
        esac ;;
    esac
    command mv "$@"
  }
}
moved_line="the meeting folder was moved, nothing was changed"

# --- 1: a first process whose folder is renamed during the minutes: stopped, nothing new in it ---
reset_run; recorded mv1
fm_hook() { if [ -d "$HOME/mv1" ]; then command mv "$HOME/mv1" "$HOME/mv1-renamed"; fi; }
engine process "$HOME/mv1/audio.m4a"
fm_hook() { :; }
m="$HOME/mv1-renamed"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "$moved_line" && [ "$(entries "$m")" = "audio.m4a call.m4a mic.m4a " ] \
   && [ "$(status_of "$m")" = 1 ]; then
  pass "a first process whose folder is renamed during the minutes stops, and nothing new is in the folder"
else fail "a first process whose folder is renamed during the minutes stops, and nothing new is in the folder (rc $rc): [$(entries "$m")] $out"; fi
# --- and notes on a folder holding only its recording and transcript ---
reset_run; d="$HOME/mv2"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"; printf '[00:00:01] Me: a transcript\n' > "$d/transcript.txt"
before="$(snap "$d")"
fm_hook() { if [ -d "$HOME/mv2" ]; then command mv "$HOME/mv2" "$HOME/mv2-renamed"; fi; }
engine notes_cmd "$d"
fm_hook() { :; }
m="$HOME/mv2-renamed"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "$moved_line" && [ "$(snap "$m")" = "$before" ] \
   && [ "$(entries "$m")" = "audio.m4a transcript.txt " ]; then
  pass "notes on a transcript-only folder renamed mid-run stops, and nothing new is in the folder"
else fail "notes on a transcript-only folder renamed mid-run stops, and nothing new is in the folder (rc $rc): [$(entries "$m")] $out"; fi

# --- 2: a file changed since it was kept is never overwritten without a copy ---
# (a) a locked notes.md stops the swap (exit 3); unlocked and edited, the next run keeps the edit
reset_run; finished e1
chflags uchg "$d/notes.md"
engine notes_cmd "$d"; rc1=$rc
chflags nouchg "$d/notes.md"
printf 'MY EDIT while the swap waited\n' >> "$d/notes.md"
engine notes_cmd "$d"
if [ "$rc1" = 3 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ -n "$(grep -rl 'MY EDIT while the swap waited' "$d/earlier")" ] \
   && no_stage "$d"; then
  pass "a notes.md edited while a swap waited is kept in earlier/ before the new one lands"
else fail "a notes.md edited while a swap waited is kept in earlier/ before the new one lands ($rc1, $rc): $(ls -A "$d" "$d/earlier") $out"; fi
# (b) notes killed just before notes.md moves in; notes.md edited; the next run keeps the edit
reset_run; finished e2
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
printf 'MY EDIT after the kill\n' >> "$d/notes.md"
engine notes_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ -n "$(grep -rl 'MY EDIT after the kill' "$d/earlier")" ] \
   && no_stage "$d"; then
  pass "a notes.md edited after a kill is kept in earlier/ before the finishing run moves the new one in"
else fail "a notes.md edited after a kill is kept in earlier/ before the finishing run moves the new one in ($rc1, $rc): $(ls -A "$d" "$d/earlier" 2>&1) $out"; fi
# (c) a first process killed after transcript.txt moved in (earlier -); the user writes a notes.md
reset_run; recorded e3
KILL_AT=2; kill_mv; killed_run process "$d/audio.m4a"; rc1=$rc; unset -f mv
marker_none=0; grep -qx 'earlier -' "$d/.swap" 2>/dev/null && marker_none=1
printf 'MY OWN NOTES\n' > "$d/notes.md"
engine process "$d/audio.m4a"
if [ "$rc1" = 137 ] && [ "$marker_none" = 1 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] \
   && [ -n "$(grep -rl 'MY OWN NOTES' "$d/earlier" 2>/dev/null)" ] && no_stage "$d"; then
  pass "a notes.md written where the marker kept nothing (earlier -) is kept in earlier/ before the new one lands"
else fail "a notes.md written where the marker kept nothing (earlier -) is kept in earlier/ before the new one lands ($rc1, $marker_none, $rc): $(ls -A "$d") $out"; fi

# (d) keeping the changed file again fails: exit 3, nothing moves over it, .swap stays; then it finishes
reset_run; finished e4
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
printf 'MY EDIT kept through a failed copy\n' >> "$d/notes.md"; command cp "$d/notes.md" "$HOME/e4.edited"
cp() { case "$*" in */kept.??????/*) return 1 ;; esac; command cp "$@"; }
engine notes_cmd "$d"; rc2=$rc
unset -f cp
held=0; same "$d/notes.md" "$HOME/e4.edited" && [ -f "$d/.swap" ] && held=1
engine notes_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc2" = 3 ] && [ "$held" = 1 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] \
   && [ -n "$(grep -rl 'MY EDIT kept through a failed copy' "$d/earlier")" ] && no_stage "$d"; then
  pass "when the changed file cannot be kept again, the swap stops with exit 3 and moves nothing over it"
else fail "when the changed file cannot be kept again, the swap stops with exit 3 and moves nothing over it ($rc1, $rc2, held $held, $rc): $out"; fi

# --- 1 again: a move seen only at the marker undoes the copies already kept, so nothing is new ---
reset_run; finished mv3; printf 'a hand edit\n' >> "$d/notes.md"
before="$(snap "$d")"; before_e="$(entries "$d")"
eval "$(declare -f still_here | sed '1s/still_here/real_still_here/')"
echo 0 > "$HOME/here.count"
still_here() { local n; n=$(( $(command cat "$HOME/here.count") + 1 )); echo "$n" > "$HOME/here.count"; [ "$n" -ne 3 ] && real_still_here; }
engine notes_cmd "$d"
eval "$(declare -f real_still_here | sed '1s/real_still_here/still_here/')"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "$moved_line" && [ "$(command cat "$HOME/here.count")" = 3 ] \
   && [ "$(snap "$d")" = "$before" ] && [ "$(entries "$d")" = "$before_e" ] && no_stage "$d"; then
  pass "a move seen just before the marker undoes the earlier/ copy and the notes-edited copy, so nothing is new"
else fail "a move seen just before the marker undoes the earlier/ copy and the notes-edited copy, so nothing is new (rc $rc): [$(entries "$d")] $out"; fi

# --- 3: a write that fails inside the minutes is the minutes failing, never a cut-short file ---
CP_PARTIAL=""
cp() {
  if [ -n "$CP_PARTIAL" ]; then
    # shellcheck disable=SC2254
    case "$*" in $CP_PARTIAL) head -c 5 "$1" > "$2"; echo "cp: $2: No space left on device" >&2; return 1 ;; esac
  fi
  command cp "$@"
}
for CP_PARTIAL in '*/merged.txt *notes-raw.md' '*/transcript.txt */merged.txt'; do
  reset_run; finished w1
  before="$(snap "$d")"
  engine notes_cmd "$d"; rc1=$rc; same1=0; [ "$(snap "$d")" = "$before" ] && [ ! -e "$d/earlier" ] && no_stage "$d" && same1=1
  rm -rf "$HOME/w1" "$HOME/w1.old"; reset_run; finished w1
  before_m="$(snap_of "$d" notes.md notes-raw.md brief.json .notes-written)"
  engine process "$d/audio.m4a"
  if [ "$rc1" -eq 1 ] && [ "$same1" = 1 ] && [ "$rc" -eq 1 ] && [ "$(snap_of "$d" notes.md notes-raw.md brief.json .notes-written)" = "$before_m" ] \
     && grep -q 'Me: Speaking from this desk' "$d/transcript.txt"; then
    pass "a cp cut short in the minutes ($CP_PARTIAL) fails notes with nothing changed, and process with only the transcript in"
  else fail "a cp cut short in the minutes ($CP_PARTIAL) fails notes with nothing changed, and process with only the transcript in ($rc1/$same1, $rc): $out"; fi
  rm -rf "$HOME/w1" "$HOME/w1.old"
done
CP_PARTIAL=""
unset -f cp

# --- 5: process takes only a recording or a transcript; --no-keep-audio never removes anything else ---
reset_run; finished a5; before="$(snap "$d")"; KEEP_AUDIO=0
engine process "$d/meeting.json"; rc1=$rc; out1="$out"
engine process "$d/brief.json"; rc2=$rc
KEEP_AUDIO=1
if [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && printf '%s' "$out1" | grep -q 'meeting.json' && [ "$(snap "$d")" = "$before" ] \
   && [ "$(calls mb-speech)" = 0 ] && [ "$(calls fm)" = 0 ]; then
  pass "process <dir>/meeting.json with KEEP_AUDIO=0 is refused and deletes nothing (and so is a .json brief)"
else fail "process <dir>/meeting.json with KEEP_AUDIO=0 is refused and deletes nothing (and so is a .json brief) ($rc1 $rc2): $(ls "$d") $out1"; fi

# --- round 2: other recordings are still taken, in any case: .mp3 and .M4A reach the transcriber ---
for rec in talk.mp3 TALK.M4A; do
  reset_run; d="$HOME/r2-$rec"; mkdir -p "$d"; printf 'audio' > "$d/$rec"
  engine process "$d/$rec"
  if [ "$rc" -eq 0 ] && [ "$(calls 'mb-speech transcribe')" = 1 ] && grep -qF "afconvert -f WAVE -d LEI16@16000 -c 1 ./$rec " "$HOME/calls.log" \
     && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Speaking from this desk." ]; then
    pass "process takes $rec as a recording, and it reaches the transcriber"
  else fail "process takes $rec as a recording, and it reaches the transcriber (rc $rc): $out"; fi
done

# --- 6: a copy that cp says it made but that differs stops the keep, with nothing changed ---
cp() {
  case "$*" in
    $CP_SHORT)
      local n a src="" dst=""; n=$(( $(command cat "$HOME/cp.count") + 1 )); echo "$n" > "$HOME/cp.count"
      if [ "$n" -eq "$CP_SHORT_AT" ]; then for a in "$@"; do src="$dst"; dst="$a"; done; head -c 3 "$src" > "$dst"; return 0; fi ;;
  esac
  command cp "$@"
}
for CP_SHORT in '*/kept/*' '*/notes-edited'; do
  reset_run; finished fb; echo 0 > "$HOME/cp.count"
  if [ "$CP_SHORT" = '*/notes-edited' ]; then CP_SHORT_AT=1; printf 'a hand edit\n' >> "$d/notes.md"; else CP_SHORT_AT=2; fi
  before="$(snap "$d")"
  engine notes_cmd "$d"
  if [ "$rc" -eq 1 ] && [ "$(snap "$d")" = "$before" ] && [ ! -e "$d/earlier" ] && no_stage "$d" && ! ls "$d" | grep -q '^notes-edited'; then
    pass "a copy cut short without an error ($CP_SHORT) is caught by the comparison: nothing changed"
  else fail "a copy cut short without an error ($CP_SHORT) is caught by the comparison: nothing changed (rc $rc): $(ls -A "$d") $out"; fi
  rm -rf "$HOME/fb" "$HOME/fb.old"
done
unset -f cp

# --- 7 and 13b: notes, and process on a transcript file, refuse an unfinished recording ---
for how in transcript-original.txt notes; do
  reset_run; finished u7; printf 'pcm' > "$d/mic.caf"
  before="$(snap "$d")"
  if [ "$how" = notes ]; then engine notes_cmd "$d"; else engine process "$d/$how"; fi
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'this recording was not finished. Run: meetingbox recover' \
     && [ "$(snap "$d")" = "$before" ] && [ "$(calls fm)" = 0 ]; then
    pass "an unfinished recording is refused with the recover message by $how, changing nothing"
  else fail "an unfinished recording is refused with the recover message by $how, changing nothing (rc $rc): $out"; fi
  rm -rf "$HOME/u7" "$HOME/u7.old"
done

# --- 8: a whole .swap whose earlier folder has gone is finished, not thrown away ---
reset_run; finished e8; touch "$HOME/brief-fail"
KILL_AT=2; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
command mv "$d/earlier/$STAMP" "$HOME/e8-kept-away"
rm -f "$HOME/brief-fail"; HAVE_FM=0
engine notes_cmd "$d"
HAVE_FM=1
if [ "$rc1" = 137 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ ! -e "$d/brief.json" ] \
   && same "$d/earlier/$STAMP/brief.json" "$HOME/e8.old/brief.json" && same "$d/earlier/$STAMP-2/notes.md" "$HOME/e8.old/notes.md" \
   && no_stage "$d" && ! printf '%s' "$out" | grep -q 'none of its files' && printf '%s' "$out" | grep -q "earlier/$STAMP"; then
  pass "a .swap whose earlier folder has gone is finished: displaced files go into it made again, and the old notes.md is kept anew"
else fail "a .swap whose earlier folder has gone is finished: displaced files go into it made again, and the old notes.md is kept anew ($rc1, $rc): $(ls -A "$d" "$d/earlier" 2>&1) $out"; fi

# --- 9: a loose recording whose name starts with a dash reaches Parakeet ---
reset_run; d="$HOME/dash"; mkdir -p "$d"; printf 'aac' > "$d/-rec one.m4a"
engine process "$d/-rec one.m4a"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Speaking from this desk." ] && [ "$(calls 'mb-speech transcribe')" = 1 ] \
   && grep -q '^afconvert .* \./-rec one\.m4a ' "$HOME/calls.log" && grep -q '^mb-speech speakers .* wav=\.stage\.[^/ ]*/\.work\.[^/ ]*/-rec one\.wav ' "$HOME/calls.log" \
   && ! printf '%s' "$out" | grep -q 'illegal option'; then
  pass "a loose recording whose name starts with a dash reaches Parakeet"
else fail "a loose recording whose name starts with a dash reaches Parakeet (rc $rc): $(grep '^afconvert' "$HOME/calls.log") $out"; fi

# --- 10: a run that finished another kind's swap and then failed says so, not that nothing changed ---
reset_run; finished f10
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
touch "$HOME/pk-fail-mic" "$HOME/pk-fail-call"; SA_FAIL=both
engine redo_cmd "$d"
last="$(printf '%s\n' "$out" | grep . | tail -n 1)"
if [ "$rc1" = 137 ] && [ "$rc" -eq 1 ] && printf '%s' "$last" | grep -q 'put in place' && ! printf '%s' "$out" | grep -q 'nothing was changed' \
   && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && no_stage "$d"; then
  pass "a run that finished another kind's swap and then failed says the interrupted run's files were put in place"
else fail "a run that finished another kind's swap and then failed says the interrupted run's files were put in place ($rc1, $rc): [$last] $out"; fi

# --- 11: a version kept in earlier/ is never treated as a meeting folder ---
reset_run; finished f11; engine redo_cmd "$d"
k="$d/earlier/$STAMP"; before="$(snap "$k")"; before_e="$(ls -A "$k")"
engine process "$k/transcript.txt"; rc1=$rc
engine notes_cmd "$k"; rc2=$rc
if [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$(snap "$k")" = "$before" ] && [ "$(ls -A "$k")" = "$before_e" ]; then
  pass "notes and process refuse a folder inside earlier/, and leave it as it was"
else fail "notes and process refuse a folder inside earlier/, and leave it as it was ($rc1 $rc2): $(ls -A "$k") $out"; fi

# --- 12: a displaced file is made 0600 in earlier/ ---
reset_run; finished f12; chmod 644 "$d"/*; touch "$HOME/brief-fail"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(mode_of "$d/earlier/$STAMP/brief.json")" = 600 ]; then pass "a displaced file is made 0600 in earlier/"
else fail "a displaced file is made 0600 in earlier/ (rc $rc): $(mode_of "$d/earlier/$STAMP/brief.json")"; fi

# --- 13a: a process whose minutes failed, killed in its transcript-only swap: the next process exits 1 ---
reset_run; finished f13; touch "$HOME/fm-empty"
KILL_AT=2; kill_mv; killed_run process "$d/audio.m4a"; rc1=$rc; unset -f mv
status_line=0; [ "$(tail -n 2 "$d/.swap" 2>/dev/null | tr '\n' '|')" = "status 1|end|" ] && status_line=1
rm -f "$HOME/fm-empty"; : > "$HOME/calls.log"
engine process "$d/audio.m4a"
if [ "$rc1" = 137 ] && [ "$status_line" = 1 ] && [ "$rc" -eq 1 ] && [ "$(calls fm)" = 0 ] && [ "$(calls mb-speech)" = 0 ] \
   && grep -q 'Me: Speaking from this desk' "$d/transcript.txt" && same "$d/notes.md" "$HOME/f13.old/notes.md" \
   && [ "$(status_of "$d")" = 1 ] && no_stage "$d"; then
  pass "a process whose minutes failed writes status 1 in .swap, and the process that finishes it exits 1"
else fail "a process whose minutes failed writes status 1 in .swap, and the process that finishes it exits 1 ($rc1, $status_line, $rc): $out"; fi

# --- 14: a TERM during the swap is ignored, and the run completes ---
reset_run; finished f14
KILL_AT=2; KILL_SIG=TERM; kill_mv; killed_run notes_cmd "$d"; unset -f mv; KILL_SIG=""
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && no_stage "$d"; then pass "a TERM during the swap is ignored, and the run completes"
else fail "a TERM during the swap is ignored, and the run completes (rc $rc): $(ls -A "$d") $(cat "$HOME/killed.out")"; fi

# ======================================================================== review round 3

# --- N1: a write error while slicing a long transcript is the minutes failing, never exit 0 ---
reset_run; finished n1x
for i in $(seq 1 400); do printf 'word%03d ' "$i"; done > "$d/transcript.txt"; printf '\n' >> "$d/transcript.txt"
touch -t 202601010000 "$d/transcript.txt"
before="$(snap "$d")"
FM_TOKENS=5000; FM_MAP_FAIL=1
# awk for split_chunks only, with a 1 KB file size limit: its chunk files cannot be written whole
awk() {
  if [ "${FUNCNAME[1]:-}" = split_chunks ]; then ( trap '' XFSZ; ulimit -f 1; command awk "$@" ); else command awk "$@"; fi
}
engine notes_cmd "$d"
unset -f awk
FM_TOKENS=100; FM_MAP_FAIL=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && [ "$(snap "$d")" = "$before" ] && [ ! -e "$d/earlier" ] && no_stage "$d"; then
  pass "a write error while slicing a long transcript fails the minutes, with nothing changed"
else fail "a write error while slicing a long transcript fails the minutes, with nothing changed (rc $rc): $(ls -A "$d") $out"; fi

# --- N2: keep_again compares its copy: a copy cut short without an error stops the swap ---
reset_run; finished n2x
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
printf 'MY EDIT under a short copy\n' >> "$d/notes.md"; command cp "$d/notes.md" "$HOME/n2x.edited"
cp() {
  case "$*" in
    */kept.??????/*) local a src="" dst=""; for a in "$@"; do src="$dst"; dst="$a"; done; head -c 3 "$src" > "$dst"; return 0 ;;
  esac
  command cp "$@"
}
engine notes_cmd "$d"
unset -f cp
if [ "$rc1" = 137 ] && [ "$rc" = 3 ] && same "$d/notes.md" "$HOME/n2x.edited" && [ -f "$d/.swap" ]; then
  pass "a copy kept again that is cut short without an error stops the swap with exit 3, the edit intact"
else fail "a copy kept again that is cut short without an error stops the swap with exit 3, the edit intact ($rc1, $rc): $out"; fi

# --- N3: a link inside earlier/ is never taken for the kept copy, and nothing is moved through one ---
# A1c: the kept notes.md replaced by a link to the live one, then an edit
reset_run; finished n3c
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
rm -f "$d/earlier/$STAMP/notes.md"; ln -s ../../notes.md "$d/earlier/$STAMP/notes.md"
printf 'MY EDIT beside a linked copy\n' >> "$d/notes.md"
engine notes_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] \
   && [ -n "$(grep -rl 'MY EDIT beside a linked copy' "$d/earlier")" ]; then
  pass "a kept notes.md replaced by a link to the live one is not trusted: the edit is kept before the new one lands"
else fail "a kept notes.md replaced by a link to the live one is not trusted: the edit is kept before the new one lands ($rc1, $rc): $out"; fi
# A1d: the earlier folder itself replaced by a link to the meeting folder, then an edit
reset_run; finished n3d
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
command mv "$d/earlier/$STAMP" "$HOME/n3d-kept-away"; ln -s .. "$d/earlier/$STAMP"
printf 'MY EDIT beside a linked folder\n' >> "$d/notes.md"
engine notes_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ] && [ -L "$d/earlier/$STAMP" ] \
   && [ -n "$(grep -l 'MY EDIT beside a linked folder' "$d"/earlier/"$STAMP"-*/notes.md 2>/dev/null)" ]; then
  pass "an earlier folder replaced by a link to the meeting folder is not trusted: the edit is kept before the new one lands"
else fail "an earlier folder replaced by a link to the meeting folder is not trusted: the edit is kept before the new one lands ($rc1, $rc): $out"; fi
# a displacement through a linked earlier folder is refused: exit 3, nothing leaves the folder
reset_run; finished n3e; touch "$HOME/brief-fail"
KILL_AT=2; kill_mv; killed_run notes_cmd "$d"; rc1=$rc; unset -f mv
rm -f "$HOME/brief-fail"
mkdir -p "$HOME/n3e-outside"; command mv "$d/earlier/$STAMP" "$HOME/n3e-kept-away"; ln -s "$HOME/n3e-outside" "$d/earlier/$STAMP"
engine notes_cmd "$d"
if [ "$rc1" = 137 ] && [ "$rc" = 3 ] && same "$d/brief.json" "$HOME/n3e.old/brief.json" && [ -z "$(ls -A "$HOME/n3e-outside")" ] \
   && [ -f "$d/.swap" ] && same "$d/notes.md" "$HOME/n3e.old/notes.md"; then
  pass "a displacement through a linked earlier folder is refused with exit 3, and nothing leaves the meeting folder"
else fail "a displacement through a linked earlier folder is refused with exit 3, and nothing leaves the meeting folder ($rc1, $rc): $(ls -A "$HOME/n3e-outside") $out"; fi

# --- N4: what keep_again says is true ---
reset_run; finished n4a
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; unset -f mv
printf 'an edit\n' >> "$d/notes.md"
engine notes_cmd "$d"; out_a="$out"; rc_a=$rc
reset_run; recorded n4b
KILL_AT=2; kill_mv; killed_run process "$d/audio.m4a"; unset -f mv
printf 'my own notes\n' > "$d/notes.md"
engine process "$d/audio.m4a"; out_b="$out"; rc_b=$rc
reset_run; finished n4c
KILL_AT=3; kill_mv; killed_run notes_cmd "$d"; unset -f mv
command mv "$d/notes.md" "$HOME/n4c-notes"; mkdir "$d/notes.md"
engine notes_cmd "$d"; out_c="$out"; rc_c=$rc
if [ "$rc_a" -eq 0 ] && printf '%s' "$out_a" | grep -qF "notes.md is not the copy kept in earlier/$STAMP, so it is kept in earlier/$STAMP-2 before the new one goes in" \
   && [ "$rc_b" -eq 0 ] && printf '%s' "$out_b" | grep -qF "no copy of notes.md was kept, so it is kept in earlier/$STAMP before the new one goes in" \
   && [ "$rc_c" = 3 ] && printf '%s' "$out_c" | grep -q 'notes.md is a folder' && [ -d "$d/notes.md" ] && [ -z "$(ls -A "$d/notes.md")" ]; then
  pass "keep_again says which copy a file is not, or that none was kept, and why it could not keep a folder"
else fail "keep_again says which copy a file is not, or that none was kept, and why it could not keep a folder ($rc_a $rc_b $rc_c): [$out_a] [$out_b] [$out_c]"; fi

# --- N5: earlier/ itself is refused; a folder named earlier that is not in a meeting folder is not ---
reset_run; finished n5; engine redo_cmd "$d"
before="$(snap "$d")"; before_e="$(ls -A "$d/earlier")"
engine notes_cmd "$d/earlier"; rc1=$rc
engine process "$d/earlier/"; rc2=$rc
if [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$(snap "$d")" = "$before" ] && [ "$(ls -A "$d/earlier")" = "$before_e" ]; then
  pass "notes <dir>/earlier and process <dir>/earlier/ are refused, leaving it as it was"
else fail "notes <dir>/earlier and process <dir>/earlier/ are refused, leaving it as it was ($rc1 $rc2): $(ls -A "$d/earlier")"; fi
reset_run; d="$HOME/own/earlier/standup"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"
printf '[00:00:01] Me: our standup\n' > "$d/transcript.txt"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_NOTES" ]; then
  pass "a user's own folder inside a folder named earlier, outside a meeting, is not refused"
else fail "a user's own folder inside a folder named earlier, outside a meeting, is not refused (rc $rc): $out"; fi

# --- N6: a named recording in a meeting folder is transcribed as itself; the folder or audio.m4a uses both sides ---
reset_run; finished n6; printf 'mp3 audio' > "$d/talk.mp3"; KEEP_AUDIO=0
before_a="$(snap_of "$d" audio.m4a mic.m4a call.m4a)"
engine process "$d/talk.mp3"
KEEP_AUDIO=1
if [ "$rc" -eq 0 ] && [ "$(calls 'mb-speech transcribe')" = 1 ] && grep -qF 'afconvert -f WAVE -d LEI16@16000 -c 1 ./talk.mp3 ' "$HOME/calls.log" \
   && [ "$(calls 'mb-speech speakers')" = 1 ] && grep -q '^mb-speech speakers .* wav=\.stage\.[^/ ]*/\.work\.[^/ ]*/talk\.wav ' "$HOME/calls.log" \
   && [ "$(cat "$d/transcript.txt")" = "[00:00:00] Unknown: Speaking from this desk." ] && same "$d/words.json" "$FIX/pk-mic.json" \
   && [ ! -e "$d/talk.mp3" ] && [ "$(snap_of "$d" audio.m4a mic.m4a call.m4a)" = "$before_a" ]; then
  pass "process <meeting>/talk.mp3 transcribes talk.mp3 itself, finds its speakers in it alone, and --no-keep-audio removes only it"
else fail "process <meeting>/talk.mp3 transcribes talk.mp3 itself, and --no-keep-audio removes only it (rc $rc): $(ls "$d") $(grep '^afconvert\|^mb-speech' "$HOME/calls.log")"; fi
reset_run; finished n6b; printf 'mp3 audio' > "$d/talk.mp3"; KEEP_AUDIO=0
engine process "$d"
KEEP_AUDIO=1
if [ "$rc" -eq 0 ] && [ "$(calls 'mb-speech transcribe')" = 2 ] && [ ! -e "$d/audio.m4a" ] && [ ! -e "$d/mic.m4a" ] && [ ! -e "$d/call.m4a" ] \
   && [ -e "$d/talk.mp3" ] && grep -q 'Them: ' "$d/transcript.txt"; then
  pass "process <meeting> uses both sides, and --no-keep-audio removes the meeting's three files and nothing else"
else fail "process <meeting> uses both sides, and --no-keep-audio removes the meeting's three files and nothing else (rc $rc): $(ls "$d")"; fi

# --- Task 11A: a single recording's redo killed in its swap: .swap names words.json, and the next redo finishes it ---
reset_run; single solo3
LISTED_TWO="$LISTED"; LISTED="$LISTED words.json"   # kill_mv counts the single recording's words.json too
KILL_AT=2; kill_mv; killed_run redo_cmd "$d"; rc1=$rc; unset -f mv
LISTED="$LISTED_TWO"
swap_words=0; grep -qx 'move words.json' "$d/.swap" 2>/dev/null && swap_words=1
old_words=0; same "$d/words.json" "$HOME/solo3.words" && old_words=1   # killed at its rename: the old one is still there
: > "$HOME/calls.log"
engine redo_cmd "$d"
if [ "$rc1" = 137 ] && [ "$swap_words" = 1 ] && [ "$old_words" = 1 ] && [ "$rc" -eq 0 ] && same "$d/words.json" "$FIX/labelled-mic.json" \
   && same "$d/earlier/$STAMP/words.json" "$HOME/solo3.words" && [ "$(cat "$d/transcript.txt")" = "$ONE_ME" ] && no_stage "$d" \
   && printf '%s' "$out" | grep -q 'finishing the swap an interrupted run began' && ! printf '%s' "$out" | grep -q 'it is removed' \
   && [ ! -e "$d/earlier/$STAMP-2" ] && [ "$(calls 'mb-speech')" = 0 ]; then
  pass "a single recording's redo killed in its swap: .swap names words.json, and the next redo finishes it, the old words kept"
else fail "a single recording's redo killed in its swap: .swap names words.json, and the next redo finishes it, the old words kept ($rc1, $swap_words, $old_words, $rc): $(cat "$d/.swap" 2>/dev/null) $out"; fi
rm -f "$VOICE_FILE" "$INSTALLED"

# ======================================================================== the command line

out="$(bash "$ROOT/meetingbox" notes 2>&1)"; rc1=$?
out2="$(bash "$ROOT/meetingbox" redo 2>&1)"; rc2=$?
help="$(bash "$ROOT/meetingbox" help 2>&1)"
if [ "$rc1" -eq 1 ] && printf '%s' "$out" | grep -q 'usage: meetingbox notes <folder>' && [ "$rc2" -eq 1 ] \
   && printf '%s' "$out2" | grep -q 'usage: meetingbox redo <folder>' \
   && printf '%s' "$help" | grep -q 'meetingbox notes <folder>' && printf '%s' "$help" | grep -q 'meetingbox redo <folder>' \
   && printf '%s' "$help" | grep -q -- '--room' && printf '%s' "$help" | grep -q 'earlier/' \
   && printf '%s' "$help" | grep -q -- '--people N  *people in a recording kept as one file' && printf '%s' "$help" | grep -q 'words.json'; then
  pass "meetingbox notes and redo need a folder, and help lists them, --room and --call, --people, words.json and earlier/"
else fail "meetingbox notes and redo need a folder, and help lists them, --room and --call, and earlier/ ($rc1 $rc2): $out $out2"; fi

reset_run
if [ "$CURLED" = 0 ]; then pass "no run reached curl"; else fail "no run reached curl"; fi

finish
