#!/bin/bash
. "$(dirname "$0")/lib.sh"

cd "$HOME"

# A keychain entry is not a path: it must never reach rm -rf in the working directory.
record_install "keychain:meetingbox local signing"
mkdir "$HOME/keychain:meetingbox local signing"
remove_installed "keychain:meetingbox local signing" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ] && [ -d "$HOME/keychain:meetingbox local signing" ]; then
  pass "relative entry refused and folder kept"
else fail "relative entry refused and folder kept"; fi

# v1.2.1 guarantees
mkdir "$HOME/a" "$HOME/b"
record_install "$HOME/a"
remove_installed "$HOME/a"
if [ ! -e "$HOME/a" ] && ! installed_by_us "$HOME/a"; then
  pass "recorded path removed and dropped from record"
else fail "recorded path removed and dropped from record"; fi

remove_installed "$HOME/b" 2>/dev/null
if [ -d "$HOME/b" ]; then pass "unrecorded path kept"; else fail "unrecorded path kept"; fi

# Each is on the record first, so the case guard itself is what refuses. rm is a
# stub here, so a broken guard fails the check instead of deleting anything.
rm() { echo "rm $*" >> "$HOME/calls.log"; }
for bad in "" / "$HOME"; do
  record_install "$bad"; : > "$HOME/calls.log"
  remove_installed "$bad" 2>/dev/null
  if [ $? -ne 0 ] && [ -d "$HOME" ] && ! grep -q '^rm ' "$HOME/calls.log" && installed_by_us "$bad"; then
    pass "refused '$bad', though recorded"
  else fail "refused '$bad', though recorded"; fi
  forget_install "$bad"
done
unset -f rm

# --- the recorder is built from meetingbox's own source ---
mkdir -p "$HOME/fake/native/app"
: > "$HOME/fake/native/app/Main.swift"
MB_SOURCE_DIR="$HOME/fake"; SOURCE_DIR="$MB_SOURCE_DIR"
fetch_source
rc=$?
if [ "$rc" -eq 0 ] && ! installed_by_us "$MB_SOURCE_DIR" && [ ! -d "$MB_SOURCE_DIR/.git" ]; then
  pass "fetch_source uses MB_SOURCE_DIR as is, no clone, not recorded"
else fail "fetch_source uses MB_SOURCE_DIR as is, no clone, not recorded"; fi
unset MB_SOURCE_DIR

SRC_DIR="$HOME/src"; SOURCE_DIR="$SRC_DIR/meetingbox"
mkdir -p "$SRC_DIR"
git() {
  echo "git $*" >> "$HOME/calls.log"
  if [ "$1" = clone ]; then
    for last in "$@"; do :; done
    mkdir -p "$last/native/app" "$last/.git"
    : > "$last/native/app/Main.swift"
  fi
  return 0
}
fetch_source
rc=$?
if [ "$rc" -eq 0 ] && installed_by_us "$SRC_DIR/meetingbox" \
   && grep -q -- "git clone -q --depth 1 --branch v$VERSION " "$HOME/calls.log"; then
  pass "fetch_source clones tag v$VERSION and records the clone"
else fail "fetch_source clones tag v$VERSION and records the clone"; fi

: > "$HOME/calls.log"
fetch_source
if grep -q -- "fetch --depth 1 origin tag v$VERSION" "$HOME/calls.log" \
   && grep -q -- "checkout -q v$VERSION" "$HOME/calls.log" \
   && ! grep -q -- "clone" "$HOME/calls.log"; then
  pass "a recorded clone is fetched and checked out, not recloned"
else fail "a recorded clone is fetched and checked out, not recloned"; fi
unset -f git

# recorder_ready also checks the app is the current version
APP_DIR="$HOME/t.app"; APP_BIN="$APP_DIR/Contents/MacOS/meetingbox"
REC_BIN="$APP_DIR/Contents/Helpers/meetingbox-recorder.app/Contents/MacOS/meetingbox-recorder"
mkdir -p "$APP_DIR/Contents/MacOS"
printf '#!/bin/sh\n' > "$APP_BIN"; chmod +x "$APP_BIN"
writeplist() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' "$1" > "$APP_DIR/Contents/Info.plist"
}
writeplist 1.2.2
V_SAVE="$VERSION"; VERSION=9.9.9
if ! recorder_ready; then pass "recorder_ready false for an older app"; else fail "recorder_ready false for an older app"; fi
VERSION="$V_SAVE"
writeplist "$VERSION"
TRANSCRIPT_BIN="$HOME/t-mb-transcript"
if ! recorder_ready; then pass "recorder_ready false without mb-transcript"; else fail "recorder_ready false without mb-transcript"; fi
printf '#!/bin/sh\n' > "$TRANSCRIPT_BIN"; chmod +x "$TRANSCRIPT_BIN"
# an app built before the recorder had a helper bundle has the right version and no helper:
# it is not ready, so setup rebuilds it
if ! recorder_ready; then pass "recorder_ready false without the recorder helper, even at the right version"
else fail "recorder_ready false without the recorder helper, even at the right version"; fi
mkdir -p "$(dirname "$REC_BIN")"
printf '#!/bin/sh\n' > "$REC_BIN"
if ! recorder_ready; then pass "recorder_ready false when the helper is not executable"
else fail "recorder_ready false when the helper is not executable"; fi
chmod +x "$REC_BIN"
if recorder_ready; then pass "recorder_ready true when the app matches VERSION and the helper is there"; else fail "recorder_ready true when the app matches VERSION and the helper is there"; fi

# install_recorder builds mb-transcript beside the app and records it
SRC_DIR="$HOME/src2"; SOURCE_DIR="$SRC_DIR/meetingbox"; BIN_DIR="$HOME/bin2"
TRANSCRIPT_BIN="$SRC_DIR/mb-transcript"
fetch_source() { return 0; }
build_app() { echo "build_app" >> "$HOME/calls.log"; }
swiftc() {
  echo "swiftc $*" >> "$HOME/calls.log"
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'bin' > "$2"; return 0; }; shift; done
}
: > "$HOME/calls.log"
install_recorder >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$TRANSCRIPT_BIN" ] && installed_by_us "$TRANSCRIPT_BIN" \
   && grep -q -- "swiftc -O -o .*/mb-transcript $SOURCE_DIR/native/transcript/\*.swift" "$HOME/calls.log" \
   && grep -qx build_app "$HOME/calls.log" && ! grep -q 'native/recorder' "$HOME/calls.log"; then
  pass "install_recorder builds mb-transcript and records it"
else fail "install_recorder builds mb-transcript and records it: $(cat "$HOME/calls.log")"; fi

forget_install "$TRANSCRIPT_BIN"
install_recorder >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$TRANSCRIPT_BIN")" = bin ]; then
  pass "install_recorder will not replace an mb-transcript it did not make"
else fail "install_recorder will not replace an mb-transcript it did not make"; fi

# --- a Shortcuts app in the way (Task 10, item 3) ---
# A shortcut added to the Dock becomes ~/Applications/<its name>.app, so a shortcut called
# meetingbox sits where the app goes. The refusal says what it is.
HINT="this is a Shortcuts app named meetingbox; rename the shortcut or remove it from the Dock"
bundle_with_id() {   # path id
  mkdir -p "$1/Contents"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$2" > "$1/Contents/Info.plist"
}
bundle_with_id "$HOME/Apps/meetingbox.app" com.apple.shortcuts.droplet
out="$(claim_path "$HOME/Apps/meetingbox.app" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$HINT" && printf '%s\n' "$out" | grep -q 'meetingbox did not create it' \
   && [ -f "$HOME/Apps/meetingbox.app/Contents/Info.plist" ] && ! installed_by_us "$HOME/Apps/meetingbox.app"; then
  pass "claim_path refuses a Shortcuts droplet and says what it is"
else fail "claim_path refuses a Shortcuts droplet and says what it is (rc $rc): $out"; fi
bundle_with_id "$HOME/Apps/other.app" com.example.other
out="$(claim_path "$HOME/Apps/other.app" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'Shortcuts' && [ -d "$HOME/Apps/other.app" ]; then
  pass "anything else in the way is refused without the Shortcuts hint"
else fail "anything else in the way is refused without the Shortcuts hint (rc $rc): $out"; fi

# --- uninstall and reset --tools (Task 10) ---
# They refuse while a recording is running, finalising or recovering, as setup does; otherwise,
# once asked, they quit the app, then remove the app setup recorded and the control socket.
# reset on its own leaves the app installed.
APP_DIR="$HOME/Applications/meetingbox.app"; APP_BIN="$APP_DIR/Contents/MacOS/meetingbox"
REC_APP="$APP_DIR/Contents/Helpers/meetingbox-recorder.app"; REC_BIN="$REC_APP/Contents/MacOS/meetingbox-recorder"
OLD_APP_DIR="$SRC_DIR/meetingbox.app"; OLD_REC_BIN="$OLD_APP_DIR/Contents/MacOS/audio-capture"
BASE_DIR="$HOME/Meetings"
mkdir -p "$BASE_DIR/2026-10-27_1430" "$BIN_DIR"
printf 'audio' > "$BASE_DIR/2026-10-27_1430/audio.m4a"
FAKE_PS=""
ps() { [ -n "$FAKE_PS" ] && printf '  777 %s\n' "$FAKE_PS"; return 0; }
sleep() { :; }
brew() { return 1; }
app_lock_held() { [ -e "$HOME/app-running" ]; }
osascript() {
  echo "osascript $*" >> "$HOME/calls.log"
  [ -d "$APP_DIR" ] && echo "the app was still there" >> "$HOME/calls.log"
  [ -e "$HOME/app-quits" ] && rm -f "$HOME/app-running"
  return 0
}
QUIT="osascript -e quit app id \"com.jediconcepts.meetingbox\""
MSG='a recording is still being saved. Wait for it, or run: meetingbox stop'
install_app() {
  mkdir -p "$STATE_DIR"   # an uninstall before removes it once it is empty
  bundle_with_id "$APP_DIR" "$APP_ID"
  mkdir -p "$APP_DIR/Contents/MacOS"; printf 'app' > "$APP_BIN"
  record_install "$APP_DIR"
  : > "$CONTROL_SOCK"
  printf 'x' > "$BIN_DIR/meetingbox"
  rm -f "$HOME/app-running" "$HOME/app-quits" "$DIR_FILE" "$PAUSE_FILE"
  : > "$HOME/calls.log"
}
kept() { [ -d "$APP_DIR" ] && installed_by_us "$APP_DIR" && [ -e "$CONTROL_SOCK" ] && [ -s "$BASE_DIR/2026-10-27_1430/audio.m4a" ]; }

for level in tools all; do
  busy_refuses() {   # $1: what is going on, $2: what it says
    out="$(reset_cmd "$level" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$2" && kept \
       && ! grep -q '^osascript\|^confirm\|^tccutil' "$HOME/calls.log"; then
      pass "reset_cmd $level refuses before asking, and changes nothing: $1"
    else fail "reset_cmd $level refuses before asking, and changes nothing: $1 (rc $rc): $out"; fi
  }
  install_app; FAKE_PS="$REC_BIN --record -o $BASE_DIR/x -n meeting"; busy_refuses "a recorder is running" "$MSG"
  install_app; FAKE_PS="$APP_BIN --recover $BASE_DIR/x"; busy_refuses "a recovery is running" "$MSG"
  install_app; FAKE_PS="$OLD_REC_BIN -o $BASE_DIR/y -n meeting"
  busy_refuses "a recorder from the old app is running" "an older meetingbox is still recording into $BASE_DIR/y"
  FAKE_PS=""
  install_app; printf '%s' "$BASE_DIR/x" > "$DIR_FILE"; busy_refuses "recording.dir is there" "$MSG"
  install_app; mkdir -p "$BASE_DIR/z"; printf '{"state":"finalising"}' > "$BASE_DIR/z/meeting.json"
  busy_refuses "a meeting.json says finalising" "$MSG"
  rm -rf -- "$BASE_DIR/z"

  # The app is running: it is quit after the question, before anything is removed.
  install_app; : > "$HOME/app-running"; : > "$HOME/app-quits"
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  cline="$(grep -n '^confirm' "$HOME/calls.log" | head -n 1 | cut -d: -f1)"
  qline="$(grep -nxF "$QUIT" "$HOME/calls.log" | cut -d: -f1)"
  if [ "$rc" -eq 0 ] && [ -n "$cline" ] && [ -n "$qline" ] && [ "$cline" -lt "$qline" ] \
     && grep -qx 'the app was still there' "$HOME/calls.log" && [ ! -e "$APP_DIR" ] && ! installed_by_us "$APP_DIR" \
     && [ ! -e "$CONTROL_SOCK" ] && [ -s "$BASE_DIR/2026-10-27_1430/audio.m4a" ]; then
    pass "reset_cmd $level quits the app once asked, then removes the recorded app and control.sock, keeping the meetings"
  else fail "reset_cmd $level quits the app once asked, then removes the recorded app and control.sock, keeping the meetings (rc $rc): $out $(cat "$HOME/calls.log")"; fi

  # An app that does not quit is not removed from under itself.
  install_app; : > "$HOME/app-running"
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && grep -qxF "$QUIT" "$HOME/calls.log" && kept && printf '%s\n' "$out" | grep -q 'did not quit'; then
    pass "reset_cmd $level leaves an app that will not quit, and says so"
  else fail "reset_cmd $level leaves an app that will not quit, and says so (rc $rc): $out"; fi

  # A recording started while the question was up: still nothing quit or removed (S3 a).
  install_app; : > "$HOME/app-running"; : > "$HOME/app-quits"
  confirm() { echo "confirm $*" >> "$HOME/calls.log"; printf '%s' "$BASE_DIR/late" > "$DIR_FILE"; return 0; }
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  confirm() { echo "confirm $*" >> "$HOME/calls.log"; return 0; }
  if [ "$rc" -ne 0 ] && grep -q '^confirm' "$HOME/calls.log" && ! grep -q '^osascript\|^tccutil' "$HOME/calls.log" \
     && kept && [ -e "$HOME/app-running" ] && printf '%s\n' "$out" | grep -qF "$MSG"; then
    pass "reset_cmd $level checks again once answered: a recording started meanwhile stops it before the quit"
  else fail "reset_cmd $level checks again once answered: a recording started meanwhile stops it before the quit (rc $rc): $out"; fi

  # Not running: nothing to ask.
  install_app
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q '^osascript' "$HOME/calls.log" && [ ! -e "$APP_DIR" ] && [ ! -e "$CONTROL_SOCK" ]; then
    pass "reset_cmd $level with the app not running asks nothing and removes it"
  else fail "reset_cmd $level with the app not running asks nothing and removes it (rc $rc): $out"; fi
done

# reset on its own: the app stays installed and is not quit.
install_app; : > "$HOME/app-running"
out="$(reset_cmd state 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && kept && ! grep -q '^osascript' "$HOME/calls.log" && grep -q '^tccutil reset ScreenCapture' "$HOME/calls.log"; then
  pass "reset leaves the app installed and running, and resets the permissions"
else fail "reset leaves the app installed and running, and resets the permissions (rc $rc): $out"; fi

# --- reset through the app (Task 10, item 5) ---
# A running app owns recording.dir and paused: reset asks it to stop rather than clearing them
# behind it, and falls back to clearing them only when no app answers.
APP_ANSWER=""
app_send() { echo "app_send $*" >> "$HOME/calls.log"; [ -n "$APP_ANSWER" ] || return 1; printf '%s' "$APP_ANSWER"; }
saved_stop="$(declare -f stop_recorders)"
stop_recorders() { echo "stop_recorders $*" >> "$HOME/calls.log"; }
for answer in "ok finalising $BASE_DIR/2026-10-27_1430" "error not recording"; do
  install_app; printf '%s' "$BASE_DIR/2026-10-27_1430" > "$DIR_FILE"; : > "$PAUSE_FILE"
  APP_ANSWER="$answer"
  out="$(reset_cmd state 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(grep '^app_send' "$HOME/calls.log")" = "app_send stop" ] && [ -e "$DIR_FILE" ] && [ -e "$PAUSE_FILE" ] \
     && ! grep -q '^stop_recorders' "$HOME/calls.log" && grep -q '^tccutil reset ScreenCapture' "$HOME/calls.log"; then
    pass "reset with the app answering '$answer' asks it to stop and leaves its state files to it"
  else fail "reset with the app answering '$answer' asks it to stop and leaves its state files to it (rc $rc): $out $(cat "$HOME/calls.log")"; fi
done
install_app; printf '%s' "$BASE_DIR/2026-10-27_1430" > "$DIR_FILE"; : > "$PAUSE_FILE"
APP_ANSWER=""
out="$(reset_cmd state 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^app_send stop' "$HOME/calls.log" && [ ! -e "$DIR_FILE" ] && [ ! -e "$PAUSE_FILE" ] \
   && grep -q '^stop_recorders' "$HOME/calls.log" && printf '%s\n' "$out" | grep -qF "$BASE_DIR/2026-10-27_1430"; then
  pass "reset with no app answering stops the recorders and clears the state files itself, naming the folder kept"
else fail "reset with no app answering stops the recorders and clears the state files itself, naming the folder kept (rc $rc): $out"; fi
eval "$saved_stop"
unset -f app_send

# --- setup's permission test with the screen asleep or locked (fix round 1, U4) ---
# The recorder says no display; that is not a missing permission, so setup neither sends anyone
# to Privacy & Security nor suggests resetting the permissions.
SCREEN="The screen is asleep or locked, so the call side cannot be recorded. Wake the screen and try again."
: > "$HOME/calls.log"
out="$(
  test_recording() {
    mkdir -p "$PERM_DIR"
    printf 'Failed to start system audio: No display found for audio capture\n%s\n' "$SCREEN" > "$PERM_DIR/log"
    return 1
  }
  pause_for() { echo "pause_for $*" >> "$HOME/calls.log"; }
  open_privacy() { echo "open_privacy $*" >> "$HOME/calls.log"; }
  open() { echo "open $*" >> "$HOME/calls.log"; }
  prime_permissions 2>&1
)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$SCREEN" && ! printf '%s\n' "$out" | grep -q 'Screen Recording is not on' \
   && ! printf '%s\n' "$out" | grep -q 'meetingbox reset' && grep -q '^pause_for' "$HOME/calls.log" \
   && ! grep -q '^open_privacy\|^open ' "$HOME/calls.log"; then
  pass "prime_permissions: no display says to wake the screen, opens no settings, does not suggest a reset"
else fail "prime_permissions: no display says to wake the screen, opens no settings, does not suggest a reset (rc $rc): $out $(cat "$HOME/calls.log")"; fi
rm -f "$PERM_DIR/log"; rmdir "$PERM_DIR" 2>/dev/null

finish
