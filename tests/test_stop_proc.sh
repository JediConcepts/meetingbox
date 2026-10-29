#!/bin/bash
. "$(dirname "$0")/lib.sh"

# stop_proc: the recorder is launched with `open`, so it is not this shell's child
# and `wait` cannot wait for it. After kill -9 it must be polled until it is gone,
# or recovery races a recorder still holding its folder.
# kill and sleep are stubbed: the "process" ignores INT and TERM, and stays alive
# for DIE_AFTER more checks once it has been sent -9 (never, if DIE_AFTER is "").
sleep() { :; }
kill() {
  case "$1" in
    -9)   KILLED=1; echo "kill -9" >> "$HOME/calls.log" ;;
    -0)   if [ "$KILLED" = 1 ]; then
            POLLS=$((POLLS + 1))
            [ -n "$DIE_AFTER" ] && [ "$POLLS" -gt "$DIE_AFTER" ] && return 1
          fi
          return 0 ;;
  esac
  return 0
}

KILLED=0; POLLS=0; DIE_AFTER=3; : > "$HOME/calls.log"
stop_proc 4242 2
if [ "$POLLS" -eq 4 ] && grep -qx 'kill -9' "$HOME/calls.log"; then
  pass "stop_proc waits for a process that outlives kill -9 briefly"
else fail "stop_proc waits for a process that outlives kill -9 briefly (checks after -9: $POLLS)"; fi

KILLED=0; POLLS=0; DIE_AFTER=""
stop_proc 4242 2
if [ "$POLLS" -ge 50 ] && [ "$POLLS" -le 52 ]; then
  pass "stop_proc gives up waiting after kill -9 at about 5 s"
else fail "stop_proc gives up waiting after kill -9 at about 5 s (checks after -9: $POLLS)"; fi

KILLED=0; POLLS=0; DIE_AFTER=0
stop_proc 4242 2
if [ "$POLLS" -eq 1 ]; then pass "stop_proc does not linger once the process is gone"
else fail "stop_proc does not linger once the process is gone (checks after -9: $POLLS)"; fi

finish
