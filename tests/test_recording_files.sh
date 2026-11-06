#!/bin/bash
. "$(dirname "$0")/lib.sh"

# The recorder writes audio.m4a (the mix), mic.m4a and call.m4a by name.

# --- clear_permcheck removes exactly what the permission check writes ---
PERM_DIR="$HOME/permcheck"
mkdir -p "$PERM_DIR"
for f in audio.m4a mic.m4a call.m4a log mic.caf call.caf .recording-complete \
         .tmp-audio.m4a .tmp-mic.m4a .tmp-call.m4a .tmp-recording-complete; do echo x > "$PERM_DIR/$f"; done
clear_permcheck
if [ ! -e "$PERM_DIR" ]; then pass "clear_permcheck removes its files and the folder"
else fail "clear_permcheck removes its files and the folder"; fi

mkdir -p "$PERM_DIR"
for f in audio.m4a mic.m4a call.m4a log other.m4a 2026-01-01_permcheck.m4a; do echo x > "$PERM_DIR/$f"; done
clear_permcheck
left="$(cd "$PERM_DIR" 2>/dev/null && ls | tr '\n' ' ')"
if [ "$left" = "other.m4a " ]; then
  pass "clear_permcheck takes a v1.2.2 *_permcheck.m4a too, leaves anything else and the folder"
else fail "clear_permcheck takes a v1.2.2 *_permcheck.m4a too, leaves anything else and the folder (left: $left)"; fi
rm -f "$PERM_DIR/other.m4a"; rmdir "$PERM_DIR"

# --- test_recording passes on a non-empty audio.m4a ---
sleep() { :; }
stop_proc() { :; }
launch_recorder() { [ -n "${FAKE_WRITES:-}" ] && printf 'aac' > "$1/$FAKE_WRITES"; printf '123'; }

FAKE_WRITES=audio.m4a
if test_recording && [ ! -e "$PERM_DIR" ]; then pass "test_recording passes on audio.m4a and cleans up"
else fail "test_recording passes on audio.m4a and cleans up"; fi

FAKE_WRITES=1_permcheck.m4a
if ! test_recording; then pass "test_recording fails without audio.m4a"
else fail "test_recording fails without audio.m4a"; fi
rm -f "$PERM_DIR/1_permcheck.m4a"; clear_permcheck

# --- prime_permissions: a switch already on from v1.2.2 can still fail, so say what to do ---
for which in 'start system audio' 'start microphone'; do
  out="$(
    test_recording() { mkdir -p "$PERM_DIR"; echo "could not $which" > "$PERM_DIR/log"; return 1; }
    pause_for() { :; }; open_privacy() { :; }; open() { :; }
    prime_permissions 2>&1
  )"
  if printf '%s\n' "$out" | grep -q 'Already on? Turn it off and on again, or select it, remove it with the minus button and test again.'; then
    pass "prime_permissions: already-on hint ($which)"
  else fail "prime_permissions: already-on hint ($which)"; fi
done
rm -f "$PERM_DIR/log"; rmdir "$PERM_DIR" 2>/dev/null

# --- the folder the later checks use ---
# Stopping now belongs to the app (Session and --recover, tested in native/tests/app);
# what stays here is recovery and processing from the terminal.
dir="$HOME/meeting"
notify() { :; }
have() { return 1; }
DIR_FILE="$HOME/dir"
mkdir -p "$dir"

# --- crash-safe recordings: the recorder writes mic.caf and call.caf, then the .m4a ---
# A stand-in recorder: --recover turns the .caf into the three .m4a and the marker,
# or fails (FAKE_RECOVER_FAIL=1) and leaves everything in place.
APP_BIN="$HOME/fake-recorder"
cat > "$APP_BIN" <<'SH'
#!/bin/bash
echo "recorder $*" >> "$HOME/calls.log"
[ "$1" = "--recover" ] || exit 2
[ "${FAKE_RECOVER_FAIL:-0}" = 1 ] && { echo "could not read mic.caf" >&2; exit 1; }
for f in audio mic call; do printf 'aac' > "$2/$f.m4a"; done
: > "$2/.recording-complete"; rm -f "$2/mic.caf" "$2/call.caf"
SH
chmod +x "$APP_BIN"
export FAKE_RECOVER_FAIL=0

new_session() {
  rm -rf "$dir"; mkdir -p "$dir"; printf '%s' "$dir" > "$DIR_FILE"; : > "$HOME/calls.log"
}
# --- process refuses a recording that was never finished ---
transcribe_channels() { echo "transcribe_channels $*" >> "$HOME/calls.log"; printf 'Me: hi\n' > "$2"; }
transcribe() { echo "transcribe $*" >> "$HOME/calls.log"; printf 'hi\n' > "$2"; }
summarise() { echo "summarise $*" >> "$HOME/calls.log"; printf '# notes\n' > "$2/notes.md"; }
chime() { :; }

new_session; rm -f "$DIR_FILE"; printf 'pcm' > "$dir/mic.caf"; printf 'pcm' > "$dir/call.caf"
for arg in "$dir" "$dir/audio.m4a"; do
  out="$( (process "$arg") 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "this recording was not finished. Run: meetingbox recover $dir" \
     && ! grep -q 'transcribe\|summarise' "$HOME/calls.log"; then
    pass "process refuses a folder holding only .caf ($(basename "$arg"))"
  else fail "process refuses a folder holding only .caf ($(basename "$arg"): $out)"; fi
done

# --- meetingbox recover <dir> calls the same recovery mode ---
out="$( (recover_cmd "$dir") 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "recorder --recover $dir" "$HOME/calls.log" && printf '%s' "$out" | grep -q 'recovered' \
   && [ -e "$dir/.recording-complete" ]; then
  pass "recover_cmd runs the recorder's --recover on the folder"
else fail "recover_cmd runs the recorder's --recover on the folder ($rc: $out)"; fi
# The minutes come from the app's Process, which keeps the meeting's record; process alone does not.
if printf '%s\n' "$out" | grep -qF "recovered $dir" \
   && printf '%s\n' "$out" | grep -qF "to get its minutes, open meetingbox and choose Process on it (or run: meetingbox process $dir)"; then
  pass "recover_cmd: once recovered, says to choose Process in meetingbox (or run process)"
else fail "recover_cmd: once recovered, says to choose Process in meetingbox (or run process) ($out)"; fi

new_session; rm -f "$DIR_FILE"; printf 'pcm' > "$dir/mic.caf"; printf 'pcm' > "$dir/call.caf"
out="$(FAKE_RECOVER_FAIL=1; (recover_cmd "$dir") 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'could not read mic.caf' && [ -e "$dir/mic.caf" ]; then
  pass "recover_cmd: a failed recovery says why and keeps the .caf"
else fail "recover_cmd: a failed recovery says why and keeps the .caf ($rc: $out)"; fi
if printf '%s\n' "$out" | grep -qF "could not recover $dir. Its recording files are kept"; then
  pass "recover_cmd: a failed recovery says its recording files are kept"
else fail "recover_cmd: a failed recovery says its recording files are kept ($out)"; fi

recorder_pids() { [ "$1" = "$dir" ] && printf '4242\n'; }
: > "$HOME/calls.log"
out="$( (recover_cmd "$dir") 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- '--recover' "$HOME/calls.log" && [ -e "$dir/mic.caf" ]; then
  pass "recover_cmd will not touch a folder that is still recording"
else fail "recover_cmd will not touch a folder that is still recording ($rc: $out)"; fi
recorder_pids() { :; }

# --- process writes private files (umask 077) ---
new_session; rm -f "$DIR_FILE"; for f in audio mic call; do printf 'aac' > "$dir/$f.m4a"; done
: > "$dir/.recording-complete"
( umask 022; process "$dir/audio.m4a" >/dev/null 2>&1 )
m1="$(stat -f %Lp "$dir/transcript.txt" 2>/dev/null)"; m2="$(stat -f %Lp "$dir/notes.md" 2>/dev/null)"
if [ "$m1" = 600 ] && [ "$m2" = 600 ]; then pass "process writes transcript and minutes 0600"
else fail "process writes transcript and minutes 0600 ($m1 $m2)"; fi

finish
