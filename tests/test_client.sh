#!/bin/bash
. "$(dirname "$0")/lib.sh"

# The command is a client of the app: one request line over ~/.meetingbox/control.sock,
# one reply line back. The whole script runs here with nc, open, sleep and ps stubbed on
# PATH, all inside the scratch HOME, so no real app, socket or recorder is ever reached.

STUB="$HOME/stub"
mkdir -p "$STUB" "$STATE_DIR" "$APP_DIR/Contents/MacOS" "$(dirname "$TRANSCRIPT_BIN")"
# Installed, as far as recorder_ready can tell.
printf '#!/bin/bash\nexit 0\n' > "$APP_BIN"; chmod +x "$APP_BIN"
printf '#!/bin/bash\nexit 0\n' > "$TRANSCRIPT_BIN"; chmod +x "$TRANSCRIPT_BIN"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>MBScriptPath</key><string>$BIN_DIR/meetingbox</string></dict></plist>
PLIST

# nc: refuses while $HOME/app-down exists; otherwise logs the request line and answers $HOME/reply.
cat > "$STUB/nc" <<'SH'
#!/bin/bash
echo "nc $*" >> "$HOME/calls.log"
[ -e "$HOME/app-down" ] && { echo "nc: connect: Connection refused" >&2; exit 1; }
IFS= read -r line || true
printf '%s\n' "$line" >> "$HOME/sent"
[ -e "$HOME/reply" ] && cat "$HOME/reply"
exit 0
SH
# open: logs; with $HOME/open-starts-app the app then answers.
cat > "$STUB/open" <<'SH'
#!/bin/bash
echo "open $*" >> "$HOME/calls.log"
[ -e "$HOME/open-starts-app" ] && rm -f "$HOME/app-down"
[ -e "$HOME/open-holds-lock" ] && : > "$HOME/lock-held"
exit 0
SH
# lockf: the probe for app.lock. Exits 75 (held) while $HOME/lock-held exists.
cat > "$STUB/lockf" <<'SH'
#!/bin/bash
echo "lockf $*" >> "$HOME/calls.log"
[ -e "$HOME/lock-held" ] && exit 75
exit 0
SH
cat > "$STUB/sleep" <<'SH'
#!/bin/bash
echo "sleep $*" >> "$HOME/calls.log"
SH
cat > "$STUB/ps" <<'SH'
#!/bin/bash
[ -e "$HOME/ps-out" ] && cat "$HOME/ps-out"
exit 0
SH
chmod +x "$STUB"/*

mb() { PATH="$STUB:$PATH" bash "$ROOT/meetingbox" "$@" 2>&1; }
reset_calls() {
  : > "$HOME/calls.log"; : > "$HOME/sent"
  rm -f "$HOME/app-down" "$HOME/open-starts-app" "$HOME/open-holds-lock" "$HOME/lock-held" "$HOME/ps-out" "$HOME/reply" "$DIR_FILE" "$PAUSE_FILE"
}
reply() { printf '%s\n' "$1" > "$HOME/reply"; }
sent() { cat "$HOME/sent"; }
slept() { awk '$1 == "sleep" { s += $2 } END { printf "%g", s + 0 }' "$HOME/calls.log"; }
SOCK="$STATE_DIR/control.sock"

# --- start ---
reset_calls; reply "ok recording /Meetings/2026-10-30_1000"
out="$(mb start --mic "USB")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "start mic=USB" ] && printf '%s' "$out" | grep -qF "/Meetings/2026-10-30_1000" \
   && grep -qxF "nc -U -w 30 $SOCK" "$HOME/calls.log"; then
  pass "start --mic USB sends 'start mic=USB' over the socket and prints the folder"
else fail "start --mic USB sends 'start mic=USB' over the socket and prints the folder ($rc: $(sent): $out)"; fi

reset_calls; reply "ok recording /x"
mb start >/dev/null
if [ "$(sent)" = "start" ]; then pass "start with no options leaves mic and folder to the app's preferences"
else fail "start with no options leaves mic and folder to the app's preferences ($(sent))"; fi

reset_calls; reply "ok recording /x"
mb start --mic "USB Mic=1%" --dir "/Users/me/My Meetings" >/dev/null
if [ "$(sent)" = "start mic=USB%20Mic%3D1%25 dir=/Users/me/My%20Meetings" ]; then
  pass "mic and dir are percent-encoded into the request"
else fail "mic and dir are percent-encoded into the request ($(sent))"; fi

reset_calls; reply "ok recording /x"
MB_DIR="/Volumes/Work/Calls" MB_MIC="Caf$(printf '\303\251')" mb start >/dev/null
if [ "$(sent)" = "start mic=Caf%C3%A9 dir=/Volumes/Work/Calls" ]; then
  pass "MB_MIC and MB_DIR travel in the request too, UTF-8 encoded byte by byte"
else fail "MB_MIC and MB_DIR travel in the request too, UTF-8 encoded byte by byte ($(sent))"; fi

reset_calls; reply "ok recording /x"
( cd "$HOME" && PATH="$STUB:$PATH" bash "$ROOT/meetingbox" start --dir "rel/folder" >/dev/null 2>&1 )
if [ "$(sent)" = "start dir=$(printf '%s' "$HOME" | sed 's/ /%20/g')/rel/folder" ]; then
  pass "a relative --dir is sent as a full path"
else fail "a relative --dir is sent as a full path ($(sent))"; fi

reset_calls; reply "error Failed to start system audio: denied"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "Failed to start system audio: denied"; then
  pass "an error reply exits non-zero with its text"
else fail "an error reply exits non-zero with its text ($rc: $out)"; fi

reset_calls; reply "error already recording in /Meetings/a b"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "already recording in /Meetings/a b"; then
  pass "a second start says already recording in <dir>"
else fail "a second start says already recording in <dir> ($rc: $out)"; fi

# --- stop ---
reset_calls; reply "ok finalising /Meetings/2026-10-30_1000"
out="$(mb stop)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "stop" ] && printf '%s' "$out" | grep -qF "/Meetings/2026-10-30_1000" \
   && printf '%s' "$out" | grep -q "the minutes will open in the meetingbox window when they are ready"; then
  pass "stop sends 'stop' and says the minutes will open in the meetingbox window"
else fail "stop sends 'stop' and says the minutes will open in the meetingbox window ($rc: $out)"; fi
if ! grep -q '^open ' "$HOME/calls.log"; then pass "stop processes nothing in the terminal"
else fail "stop processes nothing in the terminal"; fi

reset_calls; reply "error not recording"
out="$(mb stop)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not recording"; then pass "stop with nothing recording says so"
else fail "stop with nothing recording says so ($rc: $out)"; fi

# --- toggle ---
reset_calls; reply "ok recording /Meetings/t"
out="$(mb --mic "USB")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "toggle mic=USB" ] && printf '%s' "$out" | grep -qF "recording" && printf '%s' "$out" | grep -qF "/Meetings/t"; then
  pass "meetingbox on its own sends toggle, and a start reads as recording"
else fail "meetingbox on its own sends toggle, and a start reads as recording ($rc: $(sent): $out)"; fi
reset_calls; reply "ok finalising /Meetings/t"
out="$(mb)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "the minutes will open in the meetingbox window"; then
  pass "a toggle that stops says where the minutes will be"
else fail "a toggle that stops says where the minutes will be ($rc: $out)"; fi

# --- pause and resume ---
reset_calls; reply "ok paused /Meetings/p"
out="$(mb pause)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "pause" ] && printf '%s' "$out" | grep -qF "paused"; then pass "pause sends 'pause' and says paused"
else fail "pause sends 'pause' and says paused ($rc: $out)"; fi
reset_calls; reply "ok recording /Meetings/p"
out="$(mb resume)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "resume" ] && printf '%s' "$out" | grep -qF "recording"; then pass "resume sends 'resume'"
else fail "resume sends 'resume' ($rc: $out)"; fi

# The 1.3.0 guard still refuses first: a recorder from meetingbox 1.2 has no pause, SIGUSR1 kills it.
reset_calls; reply "ok paused /x"
old="$HOME/Meetings/2026-10-27_1430"; mkdir -p "$old"; printf 'old' > "$old/2026-10-27_1430_meeting.m4a"
printf '%s' "$old" > "$DIR_FILE"
out="$(mb pause)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'older meetingbox' && [ ! -s "$HOME/sent" ] && ! grep -q '^nc ' "$HOME/calls.log"; then
  pass "pause refuses a recording an older recorder is making, before asking the app"
else fail "pause refuses a recording an older recorder is making, before asking the app ($rc: $out)"; fi
rm -rf "$old"

# --- status ---
reset_calls; reply "ok paused /Meetings/s"
out="$(mb status)"
if [ "$(sent)" = "status" ] && printf '%s' "$out" | grep -qF "paused -> /Meetings/s"; then pass "status asks the app"
else fail "status asks the app ($out)"; fi
reset_calls; reply "ok idle -"
out="$(mb status)"
if printf '%s' "$out" | grep -qx ".*idle"; then pass "status: idle"
else fail "status: idle ($out)"; fi

# Review Focus 3: no app answering. status never opens the app: it reads the state files and
# finds the recorder by its command line, so it tells the truth after the app crashed.
reset_calls; : > "$HOME/app-down"
printf '%s' "/Meetings/c d" > "$DIR_FILE"
printf '  4242 %s --record -o /Meetings/c d -n meeting\n' "$APP_BIN" > "$HOME/ps-out"
out="$(mb status)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "recording -> /Meetings/c d" && printf '%s' "$out" | grep -q "meetingbox is not running" \
   && ! grep -q '^open ' "$HOME/calls.log"; then
  pass "status with no app running: the recorder still running reads as recording, and the app is not opened"
else fail "status with no app running: the recorder still running reads as recording ($rc: $out)"; fi
: > "$PAUSE_FILE"
out="$(mb status)"
if printf '%s' "$out" | grep -qF "paused -> /Meetings/c d"; then pass "status with no app running: paused"
else fail "status with no app running: paused ($out)"; fi
rm -f "$PAUSE_FILE" "$HOME/ps-out"
out="$(mb status)"
if printf '%s' "$out" | grep -q "idle" && printf '%s' "$out" | grep -qF "/Meetings/c d" && printf '%s' "$out" | grep -q "open meetingbox"; then
  pass "status with no app and no recorder: idle, and the unfinished recording is named"
else fail "status with no app and no recorder: idle, and the unfinished recording is named ($out)"; fi
rm -f "$DIR_FILE"
out="$(mb status)"
if printf '%s' "$out" | grep -q "idle" && ! grep -q '^open ' "$HOME/calls.log"; then pass "status with nothing at all: idle"
else fail "status with nothing at all: idle ($out)"; fi

# A command that finds no app opens it in the background and retries for 10 s.
reset_calls; : > "$HOME/app-down"; reply "ok recording /x"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "meetingbox did not start. Run: meetingbox setup" \
   && grep -qxF "open -g $APP_DIR" "$HOME/calls.log" && [ "$(slept)" = 10 ] && [ ! -s "$HOME/sent" ]; then
  pass "no app: opens \$APP_DIR, retries for 10 s, then says meetingbox did not start"
else fail "no app: opens \$APP_DIR, retries for 10 s, then says meetingbox did not start ($rc, slept $(slept): $out)"; fi
if [ "$(grep -c '^open ' "$HOME/calls.log")" = 1 ]; then pass "no app: opened once, not on every retry"
else fail "no app: opened once, not on every retry ($(grep -c '^open ' "$HOME/calls.log"))"; fi

reset_calls; : > "$HOME/app-down"; : > "$HOME/open-starts-app"; reply "ok recording /Meetings/late"
out="$(mb start)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sent)" = "start" ] && printf '%s' "$out" | grep -qF "/Meetings/late"; then
  pass "no app: once it is opened, the request goes through, once"
else fail "no app: once it is opened, the request goes through, once ($rc: $(sent): $out)"; fi

# Connected, but no answer: the request may have arrived, so it is never sent twice.
reset_calls; rm -f "$HOME/reply"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(sent)" = "start" ] && ! grep -q '^open ' "$HOME/calls.log" && printf '%s' "$out" | grep -q "did not answer"; then
  pass "a connection with no reply is an error, not a retry"
else fail "a connection with no reply is an error, not a retry ($rc: $(sent): $out)"; fi

# Not installed: nothing to open.
reset_calls; : > "$HOME/app-down"
mv "$APP_DIR" "$HOME/app-aside"
out="$(mb stop)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "meetingbox setup" && ! grep -q '^open ' "$HOME/calls.log"; then
  pass "no app installed: says to run setup and opens nothing"
else fail "no app installed: says to run setup and opens nothing ($rc: $out)"; fi
mv "$HOME/app-aside" "$APP_DIR"

# An app from meetingbox 1.3 is only a recorder: opened with no arguments it would start
# recording on its own with nothing to answer. Only an app built for this command is opened.
reset_calls; : > "$HOME/app-down"
cp "$APP_DIR/Contents/Info.plist" "$HOME/plist-aside"
/usr/libexec/PlistBuddy -c 'Delete :MBScriptPath' "$APP_DIR/Contents/Info.plist" >/dev/null
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "older than this command" && ! grep -q '^open ' "$HOME/calls.log"; then
  pass "an app from meetingbox 1.3 is never opened"
else fail "an app from meetingbox 1.3 is never opened ($rc: $out)"; fi
cp "$HOME/plist-aside" "$APP_DIR/Contents/Info.plist"

# --- fix round 1 ---
# M5: status waits 5 s, other commands 30 s; a connection with no reply is not "not running".
reset_calls; reply "ok idle -"
mb status >/dev/null; mb stop >/dev/null
if grep -qxF "nc -U -w 5 $SOCK" "$HOME/calls.log" && grep -qxF "nc -U -w 30 $SOCK" "$HOME/calls.log"; then
  pass "M5: status waits 5 s for the app, other commands 30 s"
else fail "M5: status waits 5 s for the app, other commands 30 s ($(grep '^nc' "$HOME/calls.log" | tr '\n' ';'))"; fi
reset_calls; rm -f "$HOME/reply"
printf '%s' "/Meetings/q" > "$DIR_FILE"
printf '  4242 %s --record -o /Meetings/q -n meeting\n' "$APP_BIN" > "$HOME/ps-out"
out="$(mb status)"
if printf '%s' "$out" | grep -qF "meetingbox did not answer; from the recording files:" && ! printf '%s' "$out" | grep -q "not running" \
   && printf '%s' "$out" | grep -qF "recording -> /Meetings/q"; then
  pass "M5: status with a connection but no reply says the app did not answer, then the files"
else fail "M5: status with a connection but no reply says the app did not answer, then the files ($out)"; fi

# M6: no answer while app.lock is held: the app is running but not answering; setup would not help.
reset_calls; : > "$HOME/app-down"; : > "$HOME/lock-held"; : > "$STATE_DIR/app.lock"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "meetingbox is running but not answering. Quit it and open it again." \
   && ! grep -q '^open ' "$HOME/calls.log" && [ "$(slept)" = 0 ] && grep -q '^lockf -n ' "$HOME/calls.log"; then
  pass "M6: app.lock held but no answer: says it is running but not answering, opens nothing, waits for nothing"
else fail "M6: app.lock held but no answer ($rc, slept $(slept): $out)"; fi
reset_calls; : > "$HOME/app-down"; : > "$HOME/open-holds-lock"; : > "$STATE_DIR/app.lock"
out="$(mb start)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "meetingbox is running but not answering. Quit it and open it again." \
   && [ "$(slept)" = 10 ]; then
  pass "M6: an app that opens but never answers in 10 s is reported as running but not answering"
else fail "M6: an app that opens but never answers in 10 s ($rc, slept $(slept): $out)"; fi
reset_calls; : > "$HOME/app-down"; rm -f "$STATE_DIR/app.lock"
out="$(mb start)"
if printf '%s' "$out" | grep -qF "meetingbox did not start. Run: meetingbox setup" && [ ! -e "$STATE_DIR/app.lock" ]; then
  pass "M6: the lock probe creates no app.lock, and with none the app simply did not start"
else fail "M6: the lock probe creates no app.lock ($out)"; fi

# I1: a start the app reports as failed exits non-zero with the reason, for toggle too.
reset_calls; reply 'error No input device matching "USB"'
out="$(mb --mic USB)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'No input device matching "USB"'; then
  pass "I1: a toggle that fails to start exits non-zero with the recorder's reason"
else fail "I1: a toggle that fails to start exits non-zero with the recorder's reason ($rc: $out)"; fi

# --- process still runs in the terminal, never through the app ---
reset_calls
out="$(mb process "$HOME/no-such-file.m4a")"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q '^nc \|^open ' "$HOME/calls.log" && [ ! -s "$HOME/sent" ]; then
  pass "process runs in the terminal as before, not through the app"
else fail "process runs in the terminal as before, not through the app ($rc: $out)"; fi

# --- pct_encode on its own ---
if [ "$(pct_encode 'a-b_c.d~e/f')" = "a-b_c.d~e/f" ] && [ "$(pct_encode 'a b=c%d')" = "a%20b%3Dc%25d" ] \
   && [ "$(pct_encode "$(printf 'x\ny')")" = "x%0Ay" ] && [ -z "$(pct_encode '')" ]; then
  pass "pct_encode keeps unreserved characters and encodes the rest, newlines included"
else fail "pct_encode keeps unreserved characters and encodes the rest, newlines included"; fi

finish
