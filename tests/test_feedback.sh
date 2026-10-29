#!/bin/bash
. "$(dirname "$0")/lib.sh"

# A hotkey press has nothing on screen, so start, stop and minutes ready each
# play a short system sound. MB_SOUNDS=0 turns them off.

afplay() { echo "afplay $*" >> "$HOME/calls.log"; }
have() { case "$1" in afplay) return 0 ;; *) return 1 ;; esac; }

: > "$HOME/calls.log"
chime start; chime stop; chime done; wait
if grep -q '^afplay /System/Library/Sounds/Tink.aiff$' "$HOME/calls.log" \
   && grep -q '^afplay /System/Library/Sounds/Pop.aiff$' "$HOME/calls.log" \
   && grep -q '^afplay /System/Library/Sounds/Glass.aiff$' "$HOME/calls.log"; then
  pass "start, stop and done each have their own sound"
else fail "start, stop and done each have their own sound: $(cat "$HOME/calls.log")"; fi

SOUNDS=0; : > "$HOME/calls.log"
chime start; wait
if [ ! -s "$HOME/calls.log" ]; then pass "MB_SOUNDS=0 keeps it quiet"; else fail "MB_SOUNDS=0 keeps it quiet"; fi
SOUNDS=1

# --- start and stop play them ---
chime() { echo "chime $1" >> "$HOME/calls.log"; }
notify() { :; }
recorder_ready() { return 0; }
is_recording() { return 1; }
has_session() { [ -f "$DIR_FILE" ]; }
launch_recorder() { printf '%s' "$$"; }
sleep() { :; }
BASE_DIR="$HOME/Meetings"; mkdir -p "$BASE_DIR" "$STATE_DIR"
: > "$HOME/calls.log"
start_recording >/dev/null 2>&1
if grep -q '^chime start$' "$HOME/calls.log"; then pass "a recording that starts plays the start sound"
else fail "a recording that starts plays the start sound"; fi

printf 'mix' > "$(cat "$DIR_FILE")/audio.m4a"
: > "$HOME/calls.log"
stop_recording >/dev/null 2>&1
if grep -q '^chime stop$' "$HOME/calls.log"; then pass "stopping plays the stop sound"
else fail "stopping plays the stop sound"; fi

launch_recorder() { return 1; }
: > "$HOME/calls.log"
(start_recording) >/dev/null 2>&1
if ! grep -q '^chime start$' "$HOME/calls.log"; then pass "a recording that fails to start plays no start sound"
else fail "a recording that fails to start plays no start sound"; fi

# --- the minutes record only what was said, and owners only when named ---
if printf '%s' "$FINAL_INSTRUCTIONS" | grep -q 'None' \
   && ! printf '%s' "$FINAL_INSTRUCTIONS" | grep -q 'using Me or Them where no name' \
   && printf '%s' "$FINAL_INSTRUCTIONS" | grep -q 'only when the notes name one'; then
  pass "final minutes: say None for an empty heading, owner only when named"
else fail "final minutes: say None for an empty heading, owner only when named"; fi
if printf '%s' "$MAP_INSTRUCTIONS" | grep -q 'only something someone said they would do'; then
  pass "slice notes: an action is only something someone said they would do"
else fail "slice notes: an action is only something someone said they would do"; fi

finish
