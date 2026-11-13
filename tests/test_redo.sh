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
# brief-fail fails the structured pass. fm_hook is a test's own step, run inside the engine as fm
# answers.
FM_TEXT="the new minutes"
fm_hook() { :; }
fm() {
  echo "fm $1" >> "$HOME/calls.log"
  case "$1" in
    count-tokens) cat >/dev/null; echo 100 ;;
    respond)
      cat >/dev/null
      fm_hook
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
  SA_FAIL=""; HAVE_FM=1; ENGINE=auto; TIDY=auto; ROOM_COUNT=""; CALL_COUNT=""; KEEP_AUDIO=1
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
if [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && [ "$(jq -r .summary "$d/brief.json")" = "the new brief" ] \
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
   && same "$d/earlier/$STAMP-3/notes.md" "$HOME/n2.edited" && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then
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
if same "$d/notes-edited-$STAMP.md" "$HOME/p1.edited" && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then
  pass "process keeps a hand-edited notes.md as notes-edited-<stamp>.md"
else fail "process keeps a hand-edited notes.md as notes-edited-<stamp>.md: $(ls "$d")"; fi

# --- process <dir>/transcript.txt behaves as notes ---
reset_run; finished p2
before_t="$(snap_of "$d" transcript.txt mic.words.json call.words.json)"
MB_PROGRESS_FILE="$HOME/progress" engine process "$d/transcript.txt"
if [ "$rc" -eq 0 ] && [ "$(calls mb-speech)" = 0 ] && [ "$(calls speech-analyzer)" = 0 ] && [ "$(calls mb-transcript)" = 0 ] \
   && [ "$(snap_of "$d" transcript.txt mic.words.json call.words.json)" = "$before_t" ] \
   && [ "$(tr '\n' ' ' < "$HOME/progress" 2>/dev/null)" = "minutes done " ] \
   && [ "$(ls -A "$d/earlier/$STAMP" | tr '\n' ' ')" = "brief.json notes-raw.md notes.md " ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then
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
   && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then
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
   && [ "$(jq -c . "$d/call.words.json")" = '{"engine":"none","words":[]}' ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then
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
if [ "$rc" -eq 0 ] && no_stage "$d" && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ]; then pass "the next run removes a killed run's stage"
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

# --- redo on a folder with only audio.m4a: a new plain transcript and no words files ---
reset_run; d="$HOME/a4"; mkdir -p "$d"; printf 'aac mix' > "$d/audio.m4a"
printf 'an old plain transcript\n' > "$d/transcript.txt"; printf 'old\n' > "$d/notes.md"; printf 'old\n' > "$d/notes-raw.md"
engine redo_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/transcript.txt")" = "Speaking from this desk." ] && [ ! -e "$d/mic.words.json" ] \
   && [ ! -e "$d/call.words.json" ] && [ "$(cat "$d/earlier/$STAMP/transcript.txt")" = "an old plain transcript" ] && no_stage "$d"; then
  pass "redo on a folder with only audio.m4a writes a new plain transcript and no words files"
else fail "redo on a folder with only audio.m4a writes a new plain transcript and no words files (rc $rc): $(ls -A "$d") $out"; fi

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
if [ "$rc" -eq 0 ] && [ -L "$HOME/flink-link" ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && [ -d "$d/earlier/$STAMP" ] && no_stage "$d"; then
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
   && [ "$(cat "$d/earlier/$STAMP-2/notes.md")" = "$FM_TEXT" ] && same "$d/earlier/$STAMP-2/transcript.txt" "$HOME/k2.old/transcript.txt" \
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
   && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && no_stage "$d"; then
  pass "a process killed between renames is finished by the next process, which runs nothing again"
else fail "a process killed between renames is finished by the next process, which runs nothing again ($rc1, $rc): $(ls -A "$d") $out"; fi
unset -f mv

# --- a .swap with no end line is discarded: nothing moves in from it, and the run completes normally ---
reset_run; finished k4
mkdir -m 700 "$d/.stage.ABCDEF"; printf 'notes a stage left\n' > "$d/.stage.ABCDEF/notes.md"
printf 'kind minutes\nstage .stage.ABCDEF\nmove notes.md\n' > "$d/.swap"
before_l="$(snap_of "$d" $LISTED)"
HAVE_FM=0
engine notes_cmd "$d"
HAVE_FM=1
if [ "$rc" -eq 1 ] && [ "$(snap_of "$d" $LISTED)" = "$before_l" ] && no_stage "$d" && printf '%s' "$out" | grep -qi 'swap'; then
  pass "a .swap with only kind, stage and move lines is discarded, with a log line, and moves nothing in"
else fail "a .swap with only kind, stage and move lines is discarded, with a log line, and moves nothing in (rc $rc): $(ls -A "$d") $out"; fi
printf 'kind minutes\nstage .stage.ABCDEF\nmove notes.md\n' > "$d/.swap"
mkdir -m 700 "$d/.stage.ABCDEF"; printf 'notes a stage left\n' > "$d/.stage.ABCDEF/notes.md"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && same "$d/earlier/$STAMP/notes.md" "$HOME/k4.old/notes.md" && no_stage "$d"; then
  pass "after discarding such a .swap, the run completes normally"
else fail "after discarding such a .swap, the run completes normally (rc $rc): $(ls -A "$d") $out"; fi
# a complete marker naming a stage that is not there is discarded too
reset_run; finished k5
printf 'kind minutes\nstage .stage.GONE00\nearlier -\nmove notes.md\nend\n' > "$d/.swap"
engine notes_cmd "$d"
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && same "$d/earlier/$STAMP/notes.md" "$HOME/k5.old/notes.md" && no_stage "$d"; then
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
if [ "$rc" -eq 0 ] && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && no_stage "$d" && [ "$(calls fm)" = 0 ] \
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
   && [ "$(cat "$d/notes.md")" = "$FM_TEXT" ] && [ ! -e "$d/.swap" ] && ! ls -A "$d" | grep -q '^\.stage\.'; then
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

# ======================================================================== the command line

out="$(bash "$ROOT/meetingbox" notes 2>&1)"; rc1=$?
out2="$(bash "$ROOT/meetingbox" redo 2>&1)"; rc2=$?
help="$(bash "$ROOT/meetingbox" help 2>&1)"
if [ "$rc1" -eq 1 ] && printf '%s' "$out" | grep -q 'usage: meetingbox notes <folder>' && [ "$rc2" -eq 1 ] \
   && printf '%s' "$out2" | grep -q 'usage: meetingbox redo <folder>' \
   && printf '%s' "$help" | grep -q 'meetingbox notes <folder>' && printf '%s' "$help" | grep -q 'meetingbox redo <folder>' \
   && printf '%s' "$help" | grep -q -- '--room' && printf '%s' "$help" | grep -q 'earlier/'; then
  pass "meetingbox notes and redo need a folder, and help lists them, --room and --call, and earlier/"
else fail "meetingbox notes and redo need a folder, and help lists them, --room and --call, and earlier/ ($rc1 $rc2): $out $out2"; fi

reset_run
if [ "$CURLED" = 0 ]; then pass "no run reached curl"; else fail "no run reached curl"; fi

finish
