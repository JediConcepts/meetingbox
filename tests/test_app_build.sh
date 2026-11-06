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

# The old app (meetingbox 1.3.1 and earlier, in $SRC_DIR) is named once, so that a recorder still
# running from it is found and the app removed once the new one is in place. It is never run.
if [ "$(grep -c 'SRC_DIR/meetingbox\.app' "$ROOT/meetingbox")" = 1 ] \
   && grep -q '^OLD_APP_DIR="\$SRC_DIR/meetingbox\.app"$' "$ROOT/meetingbox" \
   && [ "$(grep -c 'MacOS/audio-capture' "$ROOT/meetingbox")" = 1 ] \
   && grep -q '^OLD_REC_BIN="\$OLD_APP_DIR/Contents/MacOS/audio-capture"$' "$ROOT/meetingbox" \
   && ! grep -q '"\$OLD_APP_DIR" --args\|"\$OLD_REC_BIN" \|open .*OLD_APP_DIR' "$ROOT/meetingbox"; then
  pass "the old app is named once, to find its recorders and to remove it, and is never run"
else fail "the old app is named once, to find its recorders and to remove it, and is never run: $(grep -n 'SRC_DIR/meetingbox\.app\|MacOS/audio-capture\|OLD_APP_DIR\|OLD_REC_BIN' "$ROOT/meetingbox")"; fi

# --- the version (Task 10) ---
out="$(bash "$ROOT/meetingbox" --version 2>&1)"
if [ "$VERSION" = 2.0.0 ] && [ "$(printf '%s\n' "$out" | head -n 1)" = "meetingbox 2.0.0" ]; then
  pass "VERSION is 2.0.0"
else fail "VERSION is 2.0.0 ($VERSION: $out)"; fi

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

# --- every build says which it is (Task 10, items 9 and 12) ---
# The version; the build time as YYYYMMDDHHMM, numeric so it only grows; a hash of the Swift
# source it was built from; and the commit, when the source is a git checkout of its own.
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
if [ -e "$ROOT/.git" ] && [ -n "$commit" ]; then want_commit="$commit"; else want_commit=""; fi
built="$(pb CFBundleVersion)"
if printf '%s' "$built" | grep -qE '^20[0-9]{10}$' \
   && [ -n "$(source_hash)" ] && [ "$(pb MBSourceHash)" = "$(source_hash)" ] \
   && [ "$(pb MBCommit)" = "$want_commit" ]; then
  pass "build_app stamps the build time, the source hash and the commit into the Info.plist"
else fail "build_app stamps the build time, the source hash and the commit into the Info.plist ($built, $(pb MBSourceHash), $(pb MBCommit)): $(cat "$plist" 2>/dev/null)"; fi

# The source hash names files relative to the source folder and nothing else: a copy hashes the
# same, a changed, added or removed file does not. A copy with no .git has no commit.
plain="$HOME/plain"
mkdir -p "$plain"
cp -R "$ROOT/native" "$plain/native"
h_root="$(source_hash)"
SOURCE_DIR="$plain"; h_copy="$(source_hash)"
printf '\n// changed\n' >> "$plain/native/app/Main.swift"; h_changed="$(source_hash)"
: > "$plain/native/recorder/Extra.swift"; h_added="$(source_hash)"
rm -f "$plain/native/recorder/Extra.swift" "$plain/native/transcript/main.swift"; h_removed="$(source_hash)"
SOURCE_DIR="$HOME/no-source"; h_none="$(source_hash)"
SOURCE_DIR="$ROOT"
if [ -n "$h_root" ] && [ "$h_copy" = "$h_root" ] && [ "$h_changed" != "$h_copy" ] && [ "$h_added" != "$h_changed" ] \
   && [ "$h_removed" != "$h_changed" ] && [ -z "$h_none" ] && [ "$h_root" = "$(source_hash)" ]; then
  pass "source_hash: the same for a copy, different for a changed, added or removed file, empty with no source"
else fail "source_hash: the same for a copy, different for a changed, added or removed file, empty with no source ($h_root $h_copy $h_changed $h_added $h_removed '$h_none')"; fi

# The build recipe is part of it (fix round 1, U3): the compile lines and the Info.plists live in
# the script's build_app and install_recorder, so a change there is a different build too. A
# comment is not: declare -f leaves comments out.
saved_build="$(declare -f build_app)"
saved_install="$(declare -f install_recorder)"
eval "$(printf '%s\n' "$saved_build" | sed 's/LSMinimumSystemVersion<\/key><string>14\.0/LSMinimumSystemVersion<\/key><string>15.0/')"
h_plist="$(source_hash)"
eval "$saved_build"
eval "$(printf '%s\n' "$saved_install" | sed 's/swiftc -O -o/swiftc -Onone -o/')"
h_flags="$(source_hash)"
eval "$saved_install"
h_back="$(source_hash)"
eval "$(printf '%s\n' "$saved_build" | sed '2a\
  # only a comment
')"
h_comment="$(source_hash)"
eval "$saved_build"
if [ "$h_plist" != "$h_root" ] && [ "$h_flags" != "$h_root" ] && [ "$h_flags" != "$h_plist" ] \
   && [ "$h_back" = "$h_root" ] && [ "$h_comment" = "$h_root" ]; then
  pass "source_hash covers the build recipe (an Info.plist value, a compile flag), not a comment"
else fail "source_hash covers the build recipe (an Info.plist value, a compile flag), not a comment ($h_root $h_plist $h_flags $h_back $h_comment)"; fi

rm -rf -- "$plain"; mkdir -p "$plain"; cp -R "$ROOT/native" "$plain/native"
SOURCE_DIR="$plain"
build_app >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && ! pb MBCommit >/dev/null && [ "$(pb MBSourceHash)" = "$h_root" ]; then
  pass "a build from a folder that is not a git checkout has no MBCommit"
else fail "a build from a folder that is not a git checkout has no MBCommit (rc $rc): $(cat "$plist" 2>/dev/null)"; fi
SOURCE_DIR="$ROOT"
rm -rf -- "$plain"
# built again from $ROOT, its calls alone in the log, for the checks that follow
: > "$HOME/calls.log"
build_app >/dev/null 2>&1

# setup rebuilds when the source changed, even at the same VERSION (a dev build once kept the old
# app). That is a build from MB_SOURCE_DIR; with no source on disk only the version is compared.
TRANSCRIPT_BIN="$HOME/t-mb-transcript"; printf '#!/bin/sh\n' > "$TRANSCRIPT_BIN"; chmod +x "$TRANSCRIPT_BIN"
nr() { if need_recorder; then echo yes; else echo no; fi; }
MB_SOURCE_DIR="$ROOT"; same="$(nr)"
mkdir -p "$plain"; cp -R "$ROOT/native" "$plain/native"; printf '\n// changed\n' >> "$plain/native/app/Session.swift"
MB_SOURCE_DIR="$plain"; SOURCE_DIR="$plain"; changed="$(nr)"
MB_SOURCE_DIR="$HOME/no-source"; SOURCE_DIR="$HOME/no-source"; none="$(nr)"
MB_SOURCE_DIR="$ROOT"; SOURCE_DIR="$ROOT"
cp "$plist" "$HOME/plist-aside"
/usr/libexec/PlistBuddy -c 'Delete :MBSourceHash' "$plist" >/dev/null 2>&1; unstamped="$(nr)"
cp "$HOME/plist-aside" "$plist"
if [ "$same" = no ] && [ "$changed" = yes ] && [ "$none" = no ] && [ "$unstamped" = yes ]; then
  pass "need_recorder: rebuild when the source hash differs or is missing, not when it matches or there is no source"
else fail "need_recorder: rebuild when the source hash differs or is missing, not when it matches or there is no source ($same $changed $none $unstamped)"; fi
# A release clone (no MB_SOURCE_DIR) is pinned by its tag, which VERSION names: one left at an
# older tag, before fetch_source has moved it on, is no reason to rebuild (fix round 1, U2).
unset MB_SOURCE_DIR
SOURCE_DIR="$plain"; stale="$(nr)"
SOURCE_DIR="$ROOT"
if [ "$stale" = no ]; then pass "need_recorder: a release clone at another source is no reason to rebuild"
else fail "need_recorder: a release clone at another source is no reason to rebuild ($stale)"; fi
rm -rf -- "$plain"
TRANSCRIPT_BIN="$SRC_DIR/mb-transcript"

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

# --- the recorder runs from a nested helper bundle (Gate 2) ---
# The recorder checks in with the window server, so LaunchServices registers its executable's
# bundle. From the app's own executable it was taken for the app itself, and a recorder
# orphaned by a crash left the app impossible to reopen. In a bundle of its own it is a
# different app, with a different identifier.
H="$APP_DIR/Contents/Helpers/meetingbox-recorder.app"
hplist="$H/Contents/Info.plist"
hp() { /usr/libexec/PlistBuddy -c "Print :$1" "$hplist" 2>/dev/null; }
if [ "$REC_BIN" = "$H/Contents/MacOS/meetingbox-recorder" ] && [ -x "$REC_BIN" ] && cmp -s "$APP_BIN" "$REC_BIN" \
   && [ "$(grep -c '^swiftc ' "$HOME/calls.log")" = 1 ]; then
  pass "the helper's executable is a copy of the one compiled binary, not a second compile"
else fail "the helper's executable is a copy of the one compiled binary, not a second compile ($REC_BIN)"; fi

if plutil -lint "$hplist" >/dev/null 2>&1 \
   && [ "$(hp CFBundleIdentifier)" = com.jediconcepts.meetingbox.recorder ] \
   && [ "$(hp CFBundleExecutable)" = meetingbox-recorder ] \
   && [ "$(hp CFBundlePackageType)" = APPL ] \
   && [ "$(hp LSUIElement)" = true ] \
   && [ "$(hp CFBundleShortVersionString)" = "$VERSION" ] \
   && [ -n "$(pb CFBundleVersion)" ] && [ "$(hp CFBundleVersion)" = "$(pb CFBundleVersion)" ] \
   && [ -n "$(pb MBSourceHash)" ] && [ "$(hp MBSourceHash)" = "$(pb MBSourceHash)" ] \
   && [ "$(hp MBCommit)" = "$(pb MBCommit)" ] \
   && [ -n "$(hp NSMicrophoneUsageDescription)" ] \
   && [ "$(hp NSMicrophoneUsageDescription)" = "$(pb NSMicrophoneUsageDescription)" ] \
   && [ -n "$(hp NSAudioCaptureUsageDescription)" ] \
   && [ "$(hp NSAudioCaptureUsageDescription)" = "$(pb NSAudioCaptureUsageDescription)" ]; then
  pass "the helper's Info.plist has its own identifier and executable, LSUIElement, the app's version, build, source hash and commit, and both usage strings"
else fail "the helper's Info.plist has its own identifier and executable, LSUIElement, the app's version, build, source hash and commit, and both usage strings: $(cat "$hplist" 2>/dev/null)"; fi

# Signed inside out: the helper first, then the app around it, never with --deep.
: > "$HOME/calls.log"
build_app >/dev/null 2>&1; rc=$?
hline="$(grep -n -- "^codesign --force --sign .* --identifier com.jediconcepts.meetingbox.recorder $H\$" "$HOME/calls.log" | cut -d: -f1)"
aline="$(grep -n -- "^codesign --force --sign .* --identifier $APP_ID $APP_DIR\$" "$HOME/calls.log" | cut -d: -f1)"
hwho="$(grep -- "--identifier com.jediconcepts.meetingbox.recorder $H\$" "$HOME/calls.log" | sed 's/ --identifier .*//')"
awho="$(grep -- "--identifier $APP_ID $APP_DIR\$" "$HOME/calls.log" | sed 's/ --identifier .*//')"
if [ "$rc" -eq 0 ] && [ -n "$hline" ] && [ -n "$aline" ] && [ "$hline" -lt "$aline" ] \
   && [ "$(printf '%s\n' "$hline" | wc -l)" -eq 1 ] && [ "$(printf '%s\n' "$aline" | wc -l)" -eq 1 ] \
   && [ -n "$hwho" ] && [ "$hwho" = "$awho" ] && printf '%s' "$hwho" | grep -q -- '--keychain ' \
   && ! grep -q -- '--deep' "$HOME/calls.log"; then
  pass "the helper is signed before the app, with its own identifier, the same certificate and keychain, no --deep"
else fail "the helper is signed before the app, with its own identifier, the same certificate and keychain, no --deep (rc $rc): $(grep '^codesign' "$HOME/calls.log")"; fi

# a certificate that cannot sign the helper: reported as for the app, then ad hoc, helper first
codesign() {
  echo "codesign $*" >> "$HOME/calls.log"
  case "$*" in *"--sign - "*) return 0 ;; *" $H") return 1 ;; esac
  return 0
}
: > "$HOME/calls.log"
out="$(build_app 2>&1)"; rc=$?
hline="$(grep -n -- "^codesign --force --sign - --identifier com.jediconcepts.meetingbox.recorder $H\$" "$HOME/calls.log" | cut -d: -f1)"
aline="$(grep -n -- "^codesign --force --sign - --identifier $APP_ID $APP_DIR\$" "$HOME/calls.log" | cut -d: -f1)"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'could not use the meetingbox signing certificate' \
   && ! grep -q -- "^codesign --force --sign [0-9A-Fa-f]\{40\} .* --identifier $APP_ID $APP_DIR\$" "$HOME/calls.log" \
   && [ -n "$hline" ] && [ -n "$aline" ] && [ "$hline" -lt "$aline" ]; then
  pass "a helper the certificate cannot sign is reported, the app is not signed around it, ad hoc signs both, helper first"
else fail "a helper the certificate cannot sign is reported, the app is not signed around it, ad hoc signs both, helper first (rc $rc): $out $(grep '^codesign' "$HOME/calls.log")"; fi

# a helper that cannot be signed at all: the build fails, as it does when the app cannot be signed
codesign() {
  echo "codesign $*" >> "$HOME/calls.log"
  case "$*" in *" $H") return 1 ;; esac
  return 0
}
: > "$HOME/calls.log"
out="$(build_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'could not sign the recorder app' \
   && ! grep -q -- "--identifier $APP_ID $APP_DIR\$" "$HOME/calls.log"; then
  pass "a helper that cannot be signed fails the build with the same message as the app, and the app is never signed"
else fail "a helper that cannot be signed fails the build with the same message as the app, and the app is never signed (rc $rc): $out"; fi
codesign() { echo "codesign $*" >> "$HOME/calls.log"; return 0; }

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

# --- a bundle is never moved into another (Task 10, item 8) ---
# mv onto a folder that exists puts the bundle inside it. Here the claim is made to leave the
# installed app where it is (as a removal that failed would), so only the move's own check stands.
mkdir -p "$HOME/mv"; mkdir -p "$HOME/mv/a.app/Contents" "$HOME/mv/b.app/Contents"
move_bundle "$HOME/mv/a.app" "$HOME/mv/b.app" 2>/dev/null; rc1=$?
move_bundle "$HOME/mv/a.app" "$HOME/mv/c.app" 2>/dev/null; rc2=$?
if [ "$rc1" -ne 0 ] && [ ! -e "$HOME/mv/b.app/a.app" ] && [ "$rc2" -eq 0 ] && [ -d "$HOME/mv/c.app/Contents" ] && [ ! -e "$HOME/mv/a.app" ]; then
  pass "move_bundle refuses a destination that exists and moves to one that does not"
else fail "move_bundle refuses a destination that exists and moves to one that does not ($rc1 $rc2)"; fi
rm -rf -- "$HOME/mv"

saved_remove="$(declare -f remove_installed)"
remove_installed() { return 0; }
printf 'still here' > "$APP_DIR/marker"
before="$(snapshot)"
: > "$HOME/calls.log"
out="$(build_app 2>&1)"; rc=$?
eval "$saved_remove"
if [ "$rc" -ne 0 ] && [ ! -e "$APP_DIR/meetingbox.app" ] && [ "$(snapshot)" = "$before" ] && ! grep -q '^codesign --force' "$HOME/calls.log"; then
  pass "build_app refuses to move the new app into one still in its place, and signs nothing"
else fail "build_app refuses to move the new app into one still in its place, and signs nothing (rc $rc): $out $(ls "$APP_DIR")"; fi
rm -f "$APP_DIR/marker"

# --- a running app is quit before it is replaced, never left running old (Task 10, item 10) ---
# Asked as its own Quit would be, once the new bundle is complete; one that will not quit is not
# replaced. app.lock held is how a running app is told.
app_lock_held() { [ -e "$HOME/app-running" ]; }
osascript() {
  echo "osascript $*" >> "$HOME/calls.log"
  [ -e "$HOME/app-quits" ] && rm -f "$HOME/app-running"
  return 0
}
sleep() { echo "sleep $*" >> "$HOME/calls.log"; }
QUIT="osascript -e quit app id \"com.jediconcepts.meetingbox\""
: > "$HOME/app-running"; : > "$HOME/app-quits"; : > "$HOME/calls.log"
build_app >/dev/null 2>&1; rc=$?
qline="$(grep -nxF "$QUIT" "$HOME/calls.log" | cut -d: -f1)"
sline="$(grep -n '^swiftc ' "$HOME/calls.log" | cut -d: -f1)"
cline="$(grep -n '^codesign --force' "$HOME/calls.log" | head -n 1 | cut -d: -f1)"
if [ "$rc" -eq 0 ] && [ -n "$qline" ] && [ -n "$sline" ] && [ -n "$cline" ] && [ "$sline" -lt "$qline" ] && [ "$qline" -lt "$cline" ] \
   && [ ! -e "$HOME/app-running" ] && [ -x "$APP_BIN" ]; then
  pass "build_app quits a running app after the compile and before the swap"
else fail "build_app quits a running app after the compile and before the swap (rc $rc): $(cat "$HOME/calls.log")"; fi

rm -f "$HOME/app-quits"; : > "$HOME/app-running"
printf 'still here' > "$APP_DIR/marker"
before="$(snapshot)"
: > "$HOME/calls.log"
out="$(build_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qxF "$QUIT" "$HOME/calls.log" && printf '%s\n' "$out" | grep -q 'did not quit' \
   && [ "$(snapshot)" = "$before" ] && ! grep -q '^codesign --force' "$HOME/calls.log"; then
  pass "an app that does not quit is not replaced, and the build says so"
else fail "an app that does not quit is not replaced, and the build says so (rc $rc): $out"; fi
rm -f "$APP_DIR/marker" "$HOME/app-running"

: > "$HOME/calls.log"
build_app >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^osascript' "$HOME/calls.log"; then
  pass "an app that is not running is not asked to quit"
else fail "an app that is not running is not asked to quit (rc $rc)"; fi

# re-signing changes the bundle too, so a running app is quit first there as well
: > "$HOME/app-running"; : > "$HOME/app-quits"; : > "$HOME/calls.log"
resign_app >/dev/null 2>&1
qline="$(grep -nxF "$QUIT" "$HOME/calls.log" | cut -d: -f1)"
cline="$(grep -n '^codesign --force' "$HOME/calls.log" | head -n 1 | cut -d: -f1)"
if [ -n "$qline" ] && [ -n "$cline" ] && [ "$qline" -lt "$cline" ]; then
  pass "resign_app quits a running app before signing it"
else fail "resign_app quits a running app before signing it: $(cat "$HOME/calls.log")"; fi

# --- busy again by the time the app is to be quit (fix round 1, S1/D1/U1) ---
# setup checks at its start, then asks, fetches and compiles for minutes. A recording started
# meanwhile (the hotkey, the menu bar) must stop it before any Apple event reaches the app.
BUSY_MSG='a recording is still being saved. Wait for it, or run: meetingbox stop'
eval "$(declare -f swiftc | sed '1s/^swiftc /plain_swiftc /')"
swiftc() { plain_swiftc "$@"; local rc=$?; [ -n "${BUSY_AFTER_COMPILE:-}" ] && printf '%s' "$HOME/Meetings/late" > "$DIR_FILE"; return "$rc"; }
: > "$HOME/app-running"; : > "$HOME/app-quits"; rm -f "$DIR_FILE"
printf 'still here' > "$APP_DIR/marker"
before="$(snapshot)"
: > "$HOME/calls.log"
mktemp() { local d; d="$(command mktemp "$@")" || return 1; echo "mktemp $d" >> "$HOME/calls.log"; printf '%s\n' "$d"; }
out="$(BUSY_AFTER_COMPILE=1 build_app 2>&1)"; rc=$?
unset -f mktemp
made="$(sed -n 's/^mktemp //p' "$HOME/calls.log")"
leftover=""
for d in $made; do [ -e "$d" ] && leftover="$leftover $d"; done
if [ "$rc" -ne 0 ] && grep -q '^swiftc ' "$HOME/calls.log" && ! grep -q '^osascript' "$HOME/calls.log" \
   && printf '%s\n' "$out" | grep -qF "$BUSY_MSG" && [ "$(snapshot)" = "$before" ] && [ -e "$HOME/app-running" ] \
   && ! grep -q '^codesign --force' "$HOME/calls.log" && [ -n "$made" ] && [ -z "$leftover" ]; then
  pass "build_app: a recording started during the compile stops it before the quit, nothing changed or left"
else fail "build_app: a recording started during the compile stops it before the quit, nothing changed or left (rc $rc): $out $(cat "$HOME/calls.log") $leftover"; fi
rm -f "$DIR_FILE"

# A recorder from the helper, running by the time resign_app is reached: nothing is signed.
ps() { printf '  888 %s --record -o %s -n meeting\n' "$REC_BIN" "$HOME/Meetings/y"; }
: > "$HOME/calls.log"
out="$(resign_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q '^osascript\|^codesign\|^tccutil\|^security' "$HOME/calls.log" \
   && printf '%s\n' "$out" | grep -qF "$BUSY_MSG" && [ "$(snapshot)" = "$before" ] && [ -e "$HOME/app-running" ]; then
  pass "resign_app: a recording running by then stops it before the quit, nothing signed"
else fail "resign_app: a recording running by then stops it before the quit, nothing signed (rc $rc): $out $(cat "$HOME/calls.log")"; fi

# Keep recording and quit: the app goes, its recorder carries on. Nothing is replaced under it.
ps() { [ -e "$HOME/app-running" ] || printf '  889 %s --record -o %s -n meeting\n' "$REC_BIN" "$HOME/Meetings/z"; }
: > "$HOME/app-running"; : > "$HOME/app-quits"; : > "$HOME/calls.log"
out="$(build_app 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qxF "$QUIT" "$HOME/calls.log" && [ ! -e "$HOME/app-running" ] \
   && printf '%s\n' "$out" | grep -qF 'the app has quit but a recording is still running, so nothing was replaced or removed' \
   && [ "$(snapshot)" = "$before" ] \
   && ! grep -q '^codesign --force' "$HOME/calls.log"; then
  pass "build_app: a recorder that outlives the app is not replaced under"
else fail "build_app: a recorder that outlives the app is not replaced under (rc $rc): $out $(cat "$HOME/calls.log")"; fi
unset -f ps
eval "$(declare -f plain_swiftc | sed '1s/^plain_swiftc /swiftc /')"
unset -f plain_swiftc
rm -f "$APP_DIR/marker" "$HOME/app-running" "$HOME/app-quits"
rm -f "$HOME/app-running" "$HOME/app-quits"
unset -f app_lock_held osascript sleep

# --- the old app stays, and stays on the record, while install_recorder builds the new one;
# setup removes it once the new one is in place (below) ---
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

# A recorder is found under the helper's prefix (what the app starts now) and under the old
# one (a recorder the previous build started, still running after an upgrade).
ps() {
  printf '  201 %s --record -o /m/a -n meeting\n' "$REC_BIN"
  printf '  202 %s -o /m/a -n meeting\n' "$REC_BIN"
  printf '  203 %s --record -o /m/b -n meeting -d USB\n' "$REC_BIN"
  printf '  204 %s --recover /m/c\n' "$REC_BIN"
  printf '  205 %s\n' "$REC_BIN"
  printf '  206 %s --record -o /m/d -n meeting\n' "$APP_BIN"
  printf '  207 %s --record -o /m/a2 -n meeting\n' "$REC_BIN"
}
if [ "$(recorder_pids /m/a | tr '\n' ' ')" = "201 " ] && [ "$(recorder_pids /m/b | tr '\n' ' ')" = "203 " ] \
   && [ "$(recorder_pids /m/d | tr '\n' ' ')" = "206 " ] \
   && [ "$(recorder_pids "" | tr '\n' ' ' | tr ' ' '\n' | sort | tr '\n' ' ')" = "201 203 206 207 " ] \
   && [ -z "$(recorder_pids /m/c)" ] && [ -z "$(recorder_pids /m)" ]; then
  pass "recorder_pids finds a recorder under the helper's prefix and under the old one, and nothing else"
else fail "recorder_pids finds a recorder under the helper's prefix and under the old one, and nothing else: $(recorder_pids /m/a | tr '\n' ' ') / $(recorder_pids /m/d | tr '\n' ' ') / $(recorder_pids "" | tr '\n' ' ')"; fi
unset -f ps

# Only the recorder is started from the helper, by the app. The script's own calls keep the
# main executable: the permission check goes through the app bundle so the first prompts are
# meetingbox.app's, and --record -l and --recover do not touch the window server.
if ! grep -q '"\$REC_BIN" --' "$ROOT/meetingbox" \
   && grep -q '"\$APP_BIN" --recover "\$1"' "$ROOT/meetingbox" \
   && grep -q -- 'open -n -g --stdout /dev/null --stderr "\$log" "\$APP_DIR" --args --record' "$ROOT/meetingbox"; then
  pass "the script still runs --record -l and --recover from APP_BIN and the permission check through the app"
else fail "the script still runs --record -l and --recover from APP_BIN and the permission check through the app"; fi

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
# Nothing real is opened or quit: setup now ends by opening the app.
open() { echo "open $*" >> "$HOME/calls.log"; return 0; }
osascript() { echo "osascript $*" >> "$HOME/calls.log"; return 0; }
app_lock_held() { return 1; }
FAKE_PREF=""
defaults() { echo "defaults $*" >> "$HOME/calls.log"; [ -n "$FAKE_PREF" ] && printf '%s\n' "$FAKE_PREF"; }

refuses() {   # $1: what is going on
  : > "$HOME/calls.log"
  out="$(setup 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$MSG" \
     && ! grep -q '^install_recorder\|^resign_app\|^prime_permissions' "$HOME/calls.log"; then
    pass "setup refuses and builds nothing: $1"
  else fail "setup refuses and builds nothing: $1 (rc $rc): $out"; fi
}
# The refusal ends with how to carry on, once and last, after any hint (parked 14).
rerun_last() {   # $1: what is going on
  if [ "$(printf '%s\n' "$out" | tail -n 1 | sed 's/^ *//')" = "then run: meetingbox setup" ] \
     && [ "$(printf '%s\n' "$out" | grep -c 'then run: meetingbox setup')" = 1 ]; then
    pass "setup's refusal ends with 'then run: meetingbox setup', once: $1"
  else fail "setup's refusal ends with 'then run: meetingbox setup', once: $1: $out"; fi
}

FAKE_PS="$APP_BIN --record -o $BASE_DIR/x -n meeting"; refuses "a recorder is running"
rerun_last "a recorder is running"
FAKE_PS="$APP_BIN --recover $BASE_DIR/x"; refuses "a recovery is running"
FAKE_PS="$REC_BIN --record -o $BASE_DIR/x -n meeting"; refuses "a recorder from the helper is running"
FAKE_PS="$REC_BIN --recover $BASE_DIR/x"; refuses "a recovery from the helper is running"
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

# --- Task 10: what else counts as busy ---
# A session left open (recording.dir): a v1.3.1 recording, or the app's own. With nothing
# recording and no app running: with no 2.0 app installed it is a 1.3.x leftover, and the way to
# clear it is named; with the 2.0 app installed it is a recording that app did not finish (it
# stopped with its recorder), and opening meetingbox recovers it, as status says (fix round 1, D2).
printf '%s' "$BASE_DIR/2026-10-27_1430" > "$DIR_FILE"
cp "$APP_DIR/Contents/Info.plist" "$HOME/plist-aside"
/usr/libexec/PlistBuddy -c 'Delete :MBScriptPath' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1
refuses "recording.dir is there, no 2.0 app (a v1.3.1 session)"
if printf '%s\n' "$out" | grep -qF "nothing is recording into $BASE_DIR/2026-10-27_1430 now" \
   && printf '%s\n' "$out" | grep -qF "meetingbox reset" && ! printf '%s\n' "$out" | grep -q 'open meetingbox'; then
  pass "a 1.3.x session with nothing recording names its folder and how to clear it"
else fail "a 1.3.x session with nothing recording names its folder and how to clear it: $out"; fi
# An app running (app.lock held) has the session in hand: no way to clear it is offered (S3 c).
app_lock_held() { return 0; }
refuses "recording.dir is there and an app is running"
if ! printf '%s\n' "$out" | grep -q 'meetingbox reset\|open meetingbox'; then pass "a session an app is running for is not called clearable"
else fail "a session an app is running for is not called clearable: $out"; fi
app_lock_held() { return 1; }
cp "$HOME/plist-aside" "$APP_DIR/Contents/Info.plist"
refuses "recording.dir is there, the 2.0 app installed and not running"
rerun_last "after the hint to open meetingbox"
if printf '%s\n' "$out" | grep -qF "the recording in $BASE_DIR/2026-10-27_1430 did not finish; open meetingbox to recover it" \
   && ! printf '%s\n' "$out" | grep -q 'meetingbox reset'; then
  pass "a 2.0 session with nothing recording says to open meetingbox to recover it, not to reset"
else fail "a 2.0 session with nothing recording says to open meetingbox to recover it, not to reset: $out"; fi
FAKE_PS="$REC_BIN --record -o $BASE_DIR/2026-10-27_1430 -n meeting"
refuses "recording.dir is there and its recorder is running"
if ! printf '%s\n' "$out" | grep -q "meetingbox reset"; then pass "a session still recording is not called clearable"
else fail "a session still recording is not called clearable: $out"; fi
FAKE_PS=""; rm -f "$DIR_FILE"

# A recorder from the old app (meetingbox 1.3.1 and earlier, the *_meeting.m4a kind among them),
# still running after an upgrade: neither this command nor the new app can stop it, so its
# folder is named, and how to stop it keeping its audio.
OLD_APP_DIR="$HOME/src/meetingbox.app"; OLD_REC_BIN="$OLD_APP_DIR/Contents/MacOS/audio-capture"
FAKE_PS="$OLD_REC_BIN -o $BASE_DIR/2026-10-27 0900 -n meeting"
: > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "an older meetingbox is still recording into $BASE_DIR/2026-10-27 0900" \
   && printf '%s\n' "$out" | grep -qF "kill -INT 777" \
   && ! grep -q '^install_recorder\|^resign_app\|^prime_permissions\|^open\|^osascript' "$HOME/calls.log"; then
  pass "setup refuses while a recorder from the old app runs, naming its folder and how to stop it"
else fail "setup refuses while a recorder from the old app runs, naming its folder and how to stop it (rc $rc): $out"; fi
if recording_busy; then pass "recording_busy counts a recorder from the old app"
else fail "recording_busy counts a recorder from the old app"; fi
FAKE_PS=""

# The app's meetings folder, when its preference holds a full path, is looked at as well.
mkdir -p "$HOME/Moved/2026-11-01_1000"
printf '{"id":"3","state":"recording"}' > "$HOME/Moved/2026-11-01_1000/meeting.json"
FAKE_PREF="$HOME/Moved"
refuses "a meeting.json in the app's meetings folder says recording"
if grep -qxF "defaults read com.jediconcepts.meetingbox meetingsFolder" "$HOME/calls.log"; then
  pass "the meetings folder is read from the app's preference"
else fail "the meetings folder is read from the app's preference: $(cat "$HOME/calls.log")"; fi
# Run from $HOME, where Moved/*/meeting.json says recording: a relative value would find it.
FAKE_PREF="Moved"
if ! (cd "$HOME" && recording_busy); then pass "a meetings folder preference that is not a full path is ignored"
else fail "a meetings folder preference that is not a full path is ignored"; fi
odd="$HOME/$(printf 'odd\nname')"
mkdir -p "$odd/2026-11-01_1100"
printf '{"id":"4","state":"recording"}' > "$odd/2026-11-01_1100/meeting.json"
FAKE_PREF="$odd"
if ! recording_busy; then pass "a meetings folder preference of more than one line is ignored"
else fail "a meetings folder preference of more than one line is ignored"; fi
rm -rf -- "$odd"
FAKE_PREF=""
if ! recording_busy; then pass "with no preference, only the default folder is looked at"
else fail "with no preference, only the default folder is looked at"; fi
rm -rf -- "$HOME/Moved"

# --- setup ends by opening the app, and removes the old one once the new one is in place ---
printf '#!/bin/sh\necho "lsregister $*" >> "%s/calls.log"\n' "$HOME" > "$HOME/lsregister"; chmod +x "$HOME/lsregister"
LSREGISTER="$HOME/lsregister"
recorder_ready() { [ -e "$HOME/built" ]; }
install_recorder() { echo "install_recorder" >> "$HOME/calls.log"; [ -n "${BUILD_FAILS:-}" ] && return 1; : > "$HOME/built"; }
mkdir -p "$OLD_APP_DIR/Contents/MacOS"; printf 'old' > "$OLD_APP_DIR/Contents/MacOS/audio-capture"

record_install "$OLD_APP_DIR"; rm -f "$HOME/built"; : > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
last="$(grep -v '^defaults ' "$HOME/calls.log" | tail -n 1)"
if [ "$rc" -eq 0 ] && [ ! -e "$OLD_APP_DIR" ] && ! installed_by_us "$OLD_APP_DIR" \
   && grep -qxF "lsregister -u $OLD_APP_DIR" "$HOME/calls.log" && [ "$last" = "open $APP_DIR" ] \
   && [ "$(grep -n '^install_recorder' "$HOME/calls.log" | cut -d: -f1)" -lt "$(grep -n '^prime_permissions' "$HOME/calls.log" | cut -d: -f1)" ]; then
  pass "setup removes the recorded old app once the new one is built, and ends by opening the app"
else fail "setup removes the recorded old app once the new one is built, and ends by opening the app (rc $rc): $(cat "$HOME/calls.log") $out"; fi

mkdir -p "$OLD_APP_DIR/Contents/MacOS"; printf 'old' > "$OLD_APP_DIR/Contents/MacOS/audio-capture"
forget_install "$OLD_APP_DIR"; rm -f "$HOME/built"; : > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$OLD_APP_DIR/Contents/MacOS/audio-capture")" = old ] && ! grep -q "lsregister -u" "$HOME/calls.log"; then
  pass "an old app setup did not record is left alone"
else fail "an old app setup did not record is left alone (rc $rc): $out"; fi

record_install "$OLD_APP_DIR"; rm -f "$HOME/built"; : > "$HOME/calls.log"
out="$(BUILD_FAILS=1 setup 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$OLD_APP_DIR/Contents/MacOS/audio-capture")" = old ] && installed_by_us "$OLD_APP_DIR" \
   && ! grep -q '^open \|^osascript' "$HOME/calls.log"; then
  pass "when the new app is not built, the old one stays, on the record, and nothing is opened"
else fail "when the new app is not built, the old one stays, on the record, and nothing is opened (rc $rc): $out"; fi

# Nothing to install: the old app still goes once the new one is in place, and the app is opened.
need_recorder() { return 1; }
: > "$HOME/built"; : > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
last="$(grep -v '^defaults ' "$HOME/calls.log" | tail -n 1)"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'everything is already in place' && [ ! -e "$OLD_APP_DIR" ] \
   && ! installed_by_us "$OLD_APP_DIR" && [ "$last" = "open $APP_DIR" ] && ! grep -q '^install_recorder' "$HOME/calls.log"; then
  pass "with everything in place, setup still removes the recorded old app and ends by opening the app"
else fail "with everything in place, setup still removes the recorded old app and ends by opening the app (rc $rc): $(cat "$HOME/calls.log") $out"; fi

# An app that is not built for this command (no MBScriptPath: meetingbox 1.3 or earlier) is never
# opened at the end: opened with no arguments it would start recording on its own (S3 b).
cp "$APP_DIR/Contents/Info.plist" "$HOME/plist-aside"
/usr/libexec/PlistBuddy -c 'Delete :MBScriptPath' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1
: > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^prime_permissions' "$HOME/calls.log" && ! grep -q '^open ' "$HOME/calls.log"; then
  pass "setup does not open an app that is not built for this command"
else fail "setup does not open an app that is not built for this command (rc $rc): $(cat "$HOME/calls.log")"; fi
cp "$HOME/plist-aside" "$APP_DIR/Contents/Info.plist"
unset -f need_recorder
LSREGISTER=/usr/bin/true

# --- meetingbox version (Task 10, item 12) ---
# The command's version, then the app's line as the app shows it, read from its Info.plist.
# The whole script runs here, in the scratch HOME, so its own functions answer, not the stubs.
writeinfo() {   # version build hash [commit]
  cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$APP_ID</string>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>CFBundleVersion</key><string>$2</string>
<key>MBSourceHash</key><string>$3</string>
${4:+<key>MBCommit</key><string>$4</string>}
</dict></plist>
PLIST
}
HASH=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809
writeinfo 2.0.0 202611051430 "$HASH" 9602459
out="$(bash "$ROOT/meetingbox" version 2>&1)"; rc=$?
want="$(printf 'meetingbox 2.0.0\napp: meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4, 9602459)')"
if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then pass "meetingbox version: the command's version and the app's build line, with its commit"
else fail "meetingbox version: the command's version and the app's build line, with its commit (rc $rc): $out"; fi
out2="$(bash "$ROOT/meetingbox" --version 2>&1)"
if [ "$out2" = "$want" ]; then pass "meetingbox --version says the same"
else fail "meetingbox --version says the same: $out2"; fi

writeinfo 2.0.0 202611051430 "$HASH"
out="$(bash "$ROOT/meetingbox" version 2>&1)"
if [ "$out" = "$(printf 'meetingbox 2.0.0\napp: meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4)')" ]; then
  pass "meetingbox version: no commit, no commit in the line"
else fail "meetingbox version: no commit, no commit in the line: $out"; fi

writeinfo 1.3.1 202611051430 "$HASH"
out="$(bash "$ROOT/meetingbox" version 2>&1)"
if [ "$out" = "$(printf 'meetingbox 2.0.0\napp: meetingbox 1.3.1 (build 2026-11-05 14:30, 1a2b3c4)\nThe app and the command differ. Run: meetingbox setup')" ]; then
  pass "meetingbox version: an app of another version is pointed out"
else fail "meetingbox version: an app of another version is pointed out: $out"; fi

# An app from before builds were stamped has a version only.
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$APP_ID</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string><key>CFBundleVersion</key><string>2.0.0</string></dict></plist>
PLIST
out="$(bash "$ROOT/meetingbox" version 2>&1)"
if [ "$out" = "$(printf 'meetingbox 2.0.0\napp: meetingbox 2.0.0')" ]; then
  pass "meetingbox version: an app with no build stamp gives its version alone"
else fail "meetingbox version: an app with no build stamp gives its version alone: $out"; fi

mv "$APP_DIR" "$HOME/app-aside"
out="$(bash "$ROOT/meetingbox" version 2>&1)"
if [ "$out" = "meetingbox 2.0.0" ]; then pass "meetingbox version with no app installed: the command's version alone"
else fail "meetingbox version with no app installed: the command's version alone: $out"; fi
mv "$HOME/app-aside" "$APP_DIR"

writeinfo 2.0.0 202611051430 "$HASH" 9602459
out="$(bash "$ROOT/meetingbox" status 2>&1)"
if ! printf '%s\n' "$out" | grep -q 'build\|differ'; then pass "status does not change: no build line"
else fail "status does not change: no build line: $out"; fi

finish
