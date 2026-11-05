#!/bin/bash
. "$(dirname "$0")/lib.sh"

# Pause and resume are requests to the app, which signals the recorder and keeps the
# paused marker. The command keeps one check of its own: a recording made by
# meetingbox 1.2 has no pause (SIGUSR1 would kill it), so it refuses before asking.
# nc and open are stubbed: nothing here reaches a real app.

mkdir -p "$APP_DIR" "$STATE_DIR"
nc() { echo "nc $*" >> "$HOME/calls.log"; IFS= read -r line; printf '%s\n' "$line" >> "$HOME/sent"; printf '%s\n' "$REPLY"; }
open() { echo "open $*" >> "$HOME/calls.log"; }
dir="$HOME/meeting"
mkdir -p "$dir"
printf '%s' "$dir" > "$DIR_FILE"

: > "$HOME/sent"; REPLY="ok paused $dir"
out="$(pause_recording 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$HOME/sent")" = "pause" ] && printf '%s' "$out" | grep -qF "paused -> $dir"; then
  pass "pause asks the app and says paused"
else fail "pause asks the app and says paused ($rc: $out)"; fi

: > "$HOME/sent"; REPLY="ok recording $dir"
out="$(resume_recording 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$HOME/sent")" = "resume" ] && printf '%s' "$out" | grep -qF "recording -> $dir"; then
  pass "resume asks the app and says recording"
else fail "resume asks the app and says recording ($rc: $out)"; fi

: > "$HOME/sent"; REPLY="error not recording"
out="$( (pause_recording) 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not recording"; then pass "pause with nothing recording says so"
else fail "pause with nothing recording says so ($rc: $out)"; fi

# --- a recording started by meetingbox 1.2 has a recorder that SIGUSR1 would kill ---
: > "$HOME/sent"; : > "$HOME/calls.log"; REPLY="ok paused $dir"
printf 'old' > "$dir/2026-10-29_0900_meeting.m4a"
out="$( (pause_recording) 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$HOME/sent" ] && ! grep -q '^nc ' "$HOME/calls.log" && printf '%s' "$out" | grep -q 'older meetingbox'; then
  pass "pause refuses a recording an older recorder is making, and asks the app nothing"
else fail "pause refuses a recording an older recorder is making ($rc): $out"; fi
rm -f "$dir/2026-10-29_0900_meeting.m4a"

# --- with no app answering, reset still clears a marker left behind ---
# (an app that answers keeps its own: see test_install_record.sh)
touch "$PAUSE_FILE"
nc() { echo "nc $*" >> "$HOME/calls.log"; return 1; }
confirm() { return 0; }
stop_recorders() { :; }
adopt_own_app() { :; }
reset_cmd state >/dev/null 2>&1
if [ ! -e "$PAUSE_FILE" ]; then pass "reset with no app answering removes the marker"
else fail "reset with no app answering removes the marker"; fi

finish
