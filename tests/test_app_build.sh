#!/bin/bash
. "$(dirname "$0")/lib.sh"

# One executable, three modes: `meetingbox --record` (the recorder), `--recover`
# (finishing an interrupted recording) and, with neither, the app. It lives in
# one bundle at ~/Applications/meetingbox.app.

# --- where it lives ---
if [ "$APP_DIR" = "$HOME/Applications/meetingbox.app" ] \
   && [ "$APP_BIN" = "$HOME/Applications/meetingbox.app/Contents/MacOS/meetingbox" ]; then
  pass "the app is ~/Applications/meetingbox.app, its executable is meetingbox"
else fail "the app is ~/Applications/meetingbox.app, its executable is meetingbox ($APP_DIR, $APP_BIN)"; fi

if ! grep -q 'SRC_DIR/meetingbox\.app' "$ROOT/meetingbox" && ! grep -q 'MacOS/audio-capture' "$ROOT/meetingbox"; then
  pass "nothing in the script refers to the old app any more"
else fail "nothing in the script refers to the old app any more: $(grep -n 'SRC_DIR/meetingbox\.app\|MacOS/audio-capture' "$ROOT/meetingbox")"; fi

# The executable starts the app when given no mode, so every call that only
# wants the recorder must say --record.
if [ "$(grep -c '"\$APP_BIN" --record -l' "$ROOT/meetingbox")" = 2 ] \
   && ! grep -q '"\$APP_BIN" -l' "$ROOT/meetingbox"; then
  pass "mics and doctor list microphones with --record -l"
else fail "mics and doctor list microphones with --record -l"; fi

# --- the real thing compiles, and dispatches --recover without starting the app ---
# Only --recover on an empty scratch folder is run: no capture, no permissions, no UI.
if command -v swiftc >/dev/null 2>&1; then
  out_dir="$(mktemp -d)"
  if command swiftc -suppress-warnings -parse-as-library -o "$out_dir/meetingbox" \
       "$ROOT"/native/recorder/*.swift "$ROOT"/native/app/*.swift \
       -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
       -framework AppKit -framework SwiftUI >"$out_dir/build.log" 2>&1; then
    pass "recorder and app compile as one executable"
    mkdir "$out_dir/empty"
    out="$("$out_dir/meetingbox" --recover "$out_dir/empty" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q "Could not recover $out_dir/empty" \
       && [ -z "$(ls -A "$out_dir/empty")" ]; then
      pass "--recover on a folder with nothing to finish exits 1, says why, changes nothing"
    else fail "--recover on a folder with nothing to finish exits 1, says why, changes nothing (rc $rc): $out"; fi
    out="$("$out_dir/meetingbox" --recover 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q -- '--recover requires a folder'; then
      pass "--recover without a folder exits 1"
    else fail "--recover without a folder exits 1 (rc $rc): $out"; fi
    # Another process holds the folder lock (a recorder or a CLI finalise): busy is 75, not 1.
    mkdir "$out_dir/held"
    perl -e 'use Fcntl qw(:flock O_RDONLY); sysopen(my $fh, $ARGV[0], O_RDONLY) or die; flock($fh, LOCK_EX) or die;
             open(my $r, ">", $ARGV[1]) or die; close $r; sleep 20;' "$out_dir/held" "$out_dir/held.ready" &
    holder=$!
    for _ in $(seq 1 100); do [ -e "$out_dir/held.ready" ] && break; sleep 0.05; done
    out="$("$out_dir/meetingbox" --recover "$out_dir/held" 2>&1)"; rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    if [ "$rc" -eq 75 ] && printf '%s\n' "$out" | grep -q "is still being recorded or saved" \
       && [ -z "$(ls -A "$out_dir/held")" ]; then
      pass "--recover exits 75 while another process holds the folder lock, and changes nothing"
    else fail "--recover exits 75 while another process holds the folder lock, and changes nothing (rc $rc): $out"; fi
  else
    fail "recorder and app compile as one executable: $(tail -n 20 "$out_dir/build.log")"
  fi
  rm -rf -- "$out_dir"
fi

# --- build_app: one swiftc call, the Info.plist contract, the icon ---
SOURCE_DIR="$ROOT"
BIN_DIR="$HOME/bin"
swiftc() {
  echo "swiftc $*" >> "$HOME/calls.log"
  [ -n "${SWIFTC_FAILS:-}" ] && return 1
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'bin' > "$2"; chmod +x "$2"; return 0; }; shift; done
}
# sips -z H W in --out out
sips() {
  echo "sips $*" >> "$HOME/calls.log"
  while [ $# -gt 0 ]; do [ "$1" = --out ] && { printf 'png' > "$2"; return 0; }; shift; done
}
# iconutil -c icns DIR -o OUT
iconutil() {
  echo "iconutil $*" >> "$HOME/calls.log"
  [ -n "${ICONUTIL_FAILS:-}" ] && return 1
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'icns' > "$2"; return 0; }; shift; done
}

: > "$HOME/calls.log"
build_app >/dev/null 2>&1; rc=$?
calls="$(grep -c '^swiftc ' "$HOME/calls.log")"
line="$(grep '^swiftc ' "$HOME/calls.log")"
all=1
for f in "$ROOT"/native/recorder/*.swift "$ROOT"/native/app/*.swift; do
  case " $line " in *" $f "*) ;; *) all=0 ;; esac
done
[ -e "$ROOT/native/app/Main.swift" ] || all=0
# compiled inside a bundle in a temporary folder, moved into place once it is whole
case "$line" in
  *" -o $APP_BIN "*) all=0 ;;
  *" -o "*"/meetingbox.app/Contents/MacOS/meetingbox "*) ;;
  *) all=0 ;;
esac
for flag in -parse-as-library "-framework ScreenCaptureKit" "-framework AVFoundation" \
            "-framework CoreMedia" "-framework AppKit" "-framework SwiftUI"; do
  case "$line " in *" $flag "*) ;; *) all=0 ;; esac
done
if [ "$rc" -eq 0 ] && [ "$calls" = 1 ] && [ "$all" = 1 ] && [ -x "$APP_BIN" ]; then
  pass "build_app compiles the recorder and the app in one swiftc call, then \$APP_BIN is in place"
else fail "build_app compiles the recorder and the app in one swiftc call, then \$APP_BIN is in place (rc $rc): $(cat "$HOME/calls.log")"; fi

plist="$APP_DIR/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }
if plutil -lint "$plist" >/dev/null 2>&1 \
   && [ "$(pb CFBundleIdentifier)" = com.jediconcepts.meetingbox ] \
   && [ "$(pb CFBundleExecutable)" = meetingbox ] \
   && [ "$(pb CFBundleIconFile)" = meetingbox ] \
   && [ "$(pb LSUIElement)" = true ] \
   && [ "$(pb NSHighResolutionCapable)" = true ] \
   && [ "$(pb MBScriptPath)" = "$BIN_DIR/meetingbox" ] \
   && [ "$(pb CFBundleShortVersionString)" = "$VERSION" ] \
   && ! pb CFBundleURLTypes >/dev/null; then
  pass "Info.plist has the shared contract's keys and no URL scheme"
else fail "Info.plist has the shared contract's keys and no URL scheme: $(cat "$plist" 2>/dev/null)"; fi

sizes=1
for s in 16 32 64 128 256 512 1024; do
  grep -q "^sips -z $s $s $ROOT/native/app/icon.png --out " "$HOME/calls.log" || sizes=0
done
if [ -s "$APP_DIR/Contents/Resources/meetingbox.icns" ] && [ "$sizes" = 1 ] \
   && grep -q '^iconutil -c icns ' "$HOME/calls.log" && [ -f "$ROOT/native/app/icon.png" ]; then
  pass "the icon is made from icon.png with sips and iconutil into Resources/meetingbox.icns"
else fail "the icon is made from icon.png with sips and iconutil into Resources/meetingbox.icns: $(cat "$HOME/calls.log")"; fi

if installed_by_us "$APP_DIR" && grep -q -- "^codesign --force .* --identifier $APP_ID $APP_DIR\$" "$HOME/calls.log"; then
  pass "the new app is on the install record and signed"
else fail "the new app is on the install record and signed"; fi

# A failed build must leave the installed app exactly as it was, so the user can
# still record until the toolchain is fixed.
snapshot() { (cd "$APP_DIR" && find . -type f -exec cksum {} \; | sort); }
printf 'still here' > "$APP_DIR/marker"
before="$(snapshot)"
: > "$HOME/calls.log"
out="$(SWIFTC_FAILS=1 build_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q '^codesign --force' "$HOME/calls.log" && printf '%s\n' "$out" | grep -q 'compile failed' \
   && [ "$(snapshot)" = "$before" ] && [ "$(cat "$APP_DIR/marker")" = 'still here' ] && installed_by_us "$APP_DIR"; then
  pass "a failed compile leaves the installed app untouched and signs nothing"
else fail "a failed compile leaves the installed app untouched and signs nothing (rc $rc): $out"; fi

: > "$HOME/calls.log"
out="$(ICONUTIL_FAILS=1 build_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q '^codesign --force' "$HOME/calls.log" && printf '%s\n' "$out" | grep -q 'could not make the app icon' \
   && [ "$(snapshot)" = "$before" ] && [ "$(cat "$APP_DIR/marker")" = 'still here' ] && installed_by_us "$APP_DIR"; then
  pass "a failed icon leaves the installed app untouched and signs nothing"
else fail "a failed icon leaves the installed app untouched and signs nothing (rc $rc): $out"; fi

# and a good build replaces it whole
build_app >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$APP_DIR/marker" ] && [ -x "$APP_BIN" ] && installed_by_us "$APP_DIR" \
   && [ -s "$APP_DIR/Contents/Resources/meetingbox.icns" ] && plutil -lint "$plist" >/dev/null 2>&1; then
  pass "a good build replaces the installed app whole"
else fail "a good build replaces the installed app whole (rc $rc)"; fi

# --- the old app stays, and stays on the record, until the acceptance step ---
SRC_DIR="$HOME/src"; TRANSCRIPT_BIN="$SRC_DIR/mb-transcript"
fetch_source() { return 0; }
for recorded in 1 0; do
  old="$SRC_DIR/meetingbox.app"
  mkdir -p "$old/Contents/MacOS"; printf 'old' > "$old/Contents/MacOS/audio-capture"
  if [ "$recorded" = 1 ]; then record_install "$old"; else forget_install "$old"; fi
  forget_install "$TRANSCRIPT_BIN"; rm -f "$TRANSCRIPT_BIN"
  : > "$HOME/calls.log"
  install_recorder >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$old/Contents/MacOS/audio-capture")" = old ] \
     && { [ "$recorded" = 0 ] || installed_by_us "$old"; } && [ -x "$APP_BIN" ]; then
    pass "install_recorder leaves the old app (recorded=$recorded) in place, builds the new one"
  else fail "install_recorder leaves the old app (recorded=$recorded) in place, builds the new one (rc $rc)"; fi
done
unset -f swiftc sips iconutil

# --- the recorder is found by --record and its folder ---
ps() {
  printf '  101 %s --record -o /m/a -n meeting\n' "$APP_BIN"
  printf '  102 %s -o /m/a -n meeting\n' "$APP_BIN"
  printf '  103 %s --record -o /m/b -n meeting -d USB\n' "$APP_BIN"
  printf '  104 %s --recover /m/c\n' "$APP_BIN"
  printf '  105 %s\n' "$APP_BIN"
}
if [ "$(recorder_pids /m/a | tr '\n' ' ')" = "101 " ] && [ "$(recorder_pids "" | tr '\n' ' ')" = "101 103 " ]; then
  pass "recorder_pids matches \"\$APP_BIN --record -o DIR -n\" only"
else fail "recorder_pids matches \"\$APP_BIN --record -o DIR -n\" only: $(recorder_pids /m/a | tr '\n' ' ') / $(recorder_pids "" | tr '\n' ' ')"; fi
unset -f ps

# --- the permission check launches the recorder mode through open ---
PERM_DIR="$HOME/permcheck"
open() { echo "open $*" >> "$HOME/calls.log"; return 0; }
ps() { printf '  4242 %s --record -o %s -n permcheck\n' "$APP_BIN" "$PERM_DIR"; }
sleep() { :; }
stop_proc() { :; }
: > "$HOME/calls.log"
test_recording >/dev/null 2>&1
if grep -qxF -- "open -n -g --stdout /dev/null --stderr $PERM_DIR/log $APP_DIR --args --record -o $PERM_DIR -n permcheck" "$HOME/calls.log"; then
  pass "test_recording launches the app with --record -o PERM_DIR -n permcheck"
else fail "test_recording launches the app with --record -o PERM_DIR -n permcheck: $(cat "$HOME/calls.log")"; fi
clear_permcheck
unset -f open ps sleep stop_proc

# --- doctor asks the recorder mode for microphones, never starting the app ---
mkdir -p "$APP_DIR/Contents/MacOS"
printf '#!/bin/sh\necho "args $*" >> "%s/calls.log"\n' "$HOME" > "$APP_BIN"; chmod +x "$APP_BIN"
recorder_ready() { return 0; }
: > "$HOME/calls.log"
doctor >/dev/null 2>&1
if grep -qxF 'args --record -l' "$HOME/calls.log"; then pass "doctor lists microphones with --record -l"
else fail "doctor lists microphones with --record -l: $(cat "$HOME/calls.log")"; fi
unset -f recorder_ready

# --- setup refuses to rebuild while a recording is running, finalising or recovering ---
MSG='a recording is still being saved. Wait for it, or run: meetingbox stop'
macos_major() { echo 27; }
need_xcode_clt() { return 1; }
recorder_ready() { return 1; }          # so setup would rebuild
transcriber_present() { return 0; }
have() { case "$1" in swiftc|speech-analyzer) return 0 ;; *) return 1 ;; esac; }
have_signing_identity() { return 0; }
app_signed_by_us() { return 0; }
on_path() { return 0; }
install_recorder() { echo "install_recorder" >> "$HOME/calls.log"; return 0; }
resign_app() { echo "resign_app" >> "$HOME/calls.log"; }
prime_permissions() { echo "prime_permissions" >> "$HOME/calls.log"; return 0; }
prime_speech() { :; }
make_shortcut_hint() { :; }
mkdir -p "$BIN_DIR"
BASE_DIR="$HOME/Meetings"
FAKE_PS=""
ps() { [ -n "$FAKE_PS" ] && printf '  777 %s\n' "$FAKE_PS"; return 0; }

refuses() {   # $1: what is going on
  : > "$HOME/calls.log"
  out="$(setup 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$MSG" \
     && ! grep -q '^install_recorder\|^resign_app\|^prime_permissions' "$HOME/calls.log"; then
    pass "setup refuses and builds nothing: $1"
  else fail "setup refuses and builds nothing: $1 (rc $rc): $out"; fi
}

FAKE_PS="$APP_BIN --record -o $BASE_DIR/x -n meeting"; refuses "a recorder is running"
FAKE_PS="$APP_BIN --recover $BASE_DIR/x"; refuses "a recovery is running"
FAKE_PS=""
mkdir -p "$BASE_DIR/2026-10-29_0900" "$BASE_DIR/2026-10-29 1000 Standup"
printf '{\n  "id" : "1",\n  "state" : "recording"\n}\n' > "$BASE_DIR/2026-10-29_0900/meeting.json"
refuses "a meeting.json says recording"
printf '{"id":"1","state":"finalising"}' > "$BASE_DIR/2026-10-29 1000 Standup/meeting.json"
printf '{"id":"1","state":"done"}' > "$BASE_DIR/2026-10-29_0900/meeting.json"
refuses "a meeting.json says finalising, in a folder with a space"

printf '{"id":"1","state":"done"}' > "$BASE_DIR/2026-10-29 1000 Standup/meeting.json"
printf '{"id":"2","state":"queued","stage":"recording"}' > "$BASE_DIR/2026-10-29_0900/meeting.json"
: > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -qF "$MSG" && grep -q '^install_recorder' "$HOME/calls.log"; then
  pass "setup rebuilds when nothing is being recorded or saved"
else fail "setup rebuilds when nothing is being recorded or saved (rc $rc): $out"; fi

finish
