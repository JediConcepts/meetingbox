#!/bin/bash
. "$(dirname "$0")/lib.sh"

# The recorder writes audio.m4a (the mix), mic.m4a and call.m4a by name.

# --- clear_permcheck removes exactly what the permission check writes ---
PERM_DIR="$HOME/permcheck"
mkdir -p "$PERM_DIR"
for f in audio.m4a mic.m4a call.m4a log; do echo x > "$PERM_DIR/$f"; done
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

# --- stop_recording takes audio.m4a, whatever else is in the folder ---
dir="$HOME/meeting"
has_session() { return 0; }
session_dir() { printf '%s' "$dir"; }
is_recording() { return 1; }
notify() { :; }
have() { return 1; }
DIR_FILE="$HOME/dir"

mkdir -p "$dir"
printf 'mix' > "$dir/audio.m4a"; printf 'm' > "$dir/mic.m4a"
touch -t 202001010000 "$dir/audio.m4a"   # mic.m4a is the newest file
STOPPED_AUDIO=""
stop_recording 2>/dev/null
if [ "$STOPPED_AUDIO" = "$dir/audio.m4a" ] && [ -s "$dir/mic.m4a" ]; then
  pass "stop_recording uses audio.m4a and leaves mic.m4a"
else fail "stop_recording uses audio.m4a and leaves mic.m4a ($STOPPED_AUDIO)"; fi

rm -f "$dir/audio.m4a"
out="$( (stop_recording) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no recording was written' && [ -s "$dir/mic.m4a" ]; then
  pass "stop_recording without audio.m4a: no recording, mic.m4a not taken"
else fail "stop_recording without audio.m4a: no recording, mic.m4a not taken"; fi

# a recording started by v1.2.2 wrote <stamp>_meeting.m4a: that one is taken as audio.m4a
printf 'old' > "$dir/2026-10-27_1430_meeting.m4a"
got="$( (stop_recording 2>/dev/null; printf '%s' "$STOPPED_AUDIO") )"
if [ "$got" = "$dir/audio.m4a" ] && [ "$(cat "$dir/audio.m4a" 2>/dev/null)" = old ] \
   && [ ! -e "$dir/2026-10-27_1430_meeting.m4a" ] && [ -s "$dir/mic.m4a" ]; then
  pass "stop_recording adopts a v1.2.2 *_meeting.m4a"
else fail "stop_recording adopts a v1.2.2 *_meeting.m4a ($got)"; fi

finish
