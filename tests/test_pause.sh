#!/bin/bash
. "$(dirname "$0")/lib.sh"

# Pause and resume signal the recorder and keep a marker; the recorder is faked
# with a sleeping process that just has to receive the signal.

dir="$HOME/meeting"
mkdir -p "$dir" "$STATE_DIR"
printf '%s' "$dir" > "$DIR_FILE"

SIGLOG="$HOME/signals"
trap_pid=""
bash -c 'trap "echo USR1 >> \"$0\"" USR1; trap "echo USR2 >> \"$0\"" USR2; while :; do sleep 0.05; done' "$SIGLOG" >/dev/null 2>&1 &
trap_pid=$!
recorder_pids() { printf '%s\n' "$trap_pid"; }
is_recording() { return 0; }
settle() { sleep 0.4; }
sleep 0.2

pause_recording 2>/dev/null; settle
if [ -e "$PAUSE_FILE" ] && [ "$(cat "$SIGLOG" 2>/dev/null)" = "USR1" ]; then
  pass "pause sends USR1 and creates the marker"
else fail "pause sends USR1 and creates the marker"; fi

out="$(pause_recording 2>&1)"; rc=$?; settle
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'already paused' && [ "$(cat "$SIGLOG")" = "USR1" ]; then
  pass "a second pause says already paused and signals nothing"
else fail "a second pause says already paused and signals nothing"; fi

out="$(status_cmd 2>&1)"
if printf '%s' "$out" | grep -q "paused -> $dir"; then pass "status says paused"
else fail "status says paused ($out)"; fi

resume_recording 2>/dev/null; settle
if [ ! -e "$PAUSE_FILE" ] && [ "$(tail -n 1 "$SIGLOG")" = "USR2" ]; then
  pass "resume sends USR2 and removes the marker"
else fail "resume sends USR2 and removes the marker"; fi

out="$(resume_recording 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not paused'; then pass "resume when not paused is harmless"
else fail "resume when not paused is harmless"; fi

out="$(status_cmd 2>&1)"
if printf '%s' "$out" | grep -q "recording -> $dir"; then pass "status says recording again"
else fail "status says recording again ($out)"; fi

is_recording() { return 1; }
if ! (pause_recording) >/dev/null 2>&1; then pass "pause needs a recording"
else fail "pause needs a recording"; fi
is_recording() { return 0; }

# --- a recording started by meetingbox 1.2 has a recorder that SIGUSR1 would kill ---
: > "$SIGLOG"
printf 'old' > "$dir/2026-10-29_0900_meeting.m4a"
out="$( (pause_recording) 2>&1)"; rc=$?; settle
if [ "$rc" -ne 0 ] && [ ! -s "$SIGLOG" ] && [ ! -e "$PAUSE_FILE" ] && printf '%s' "$out" | grep -q 'older meetingbox'; then
  pass "pause refuses a recording an older recorder is making, and signals nothing"
else fail "pause refuses a recording an older recorder is making ($rc): $out"; fi
rm -f "$dir/2026-10-29_0900_meeting.m4a"

# --- the marker never outlives the recording ---
kill "$trap_pid" 2>/dev/null; wait "$trap_pid" 2>/dev/null || true

touch "$PAUSE_FILE"
is_recording() { return 1; }
has_session() { return 0; }
notify() { :; }
have() { return 1; }
printf 'mix' > "$dir/audio.m4a"
stop_recording 2>/dev/null
if [ ! -e "$PAUSE_FILE" ]; then pass "stop_recording removes the marker"
else fail "stop_recording removes the marker"; fi

touch "$PAUSE_FILE"
rm -f "$DIR_FILE"
has_session() { [ -f "$DIR_FILE" ]; }
recorder_ready() { return 0; }
launch_recorder() { printf '%s' "$$"; }
sleep() { :; }
BASE_DIR="$HOME/Meetings"; mkdir -p "$BASE_DIR"
start_recording >/dev/null 2>&1
if [ ! -e "$PAUSE_FILE" ]; then pass "start_recording removes a stale marker"
else fail "start_recording removes a stale marker"; fi

touch "$PAUSE_FILE"
confirm() { return 0; }
stop_recorders() { :; }
adopt_own_app() { :; }
reset_cmd state >/dev/null 2>&1
if [ ! -e "$PAUSE_FILE" ]; then pass "reset removes the marker"
else fail "reset removes the marker"; fi

finish
