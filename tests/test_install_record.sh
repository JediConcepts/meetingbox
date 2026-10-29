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
mkdir -p "$HOME/fake/native/recorder"
: > "$HOME/fake/native/recorder/main.swift"
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
    mkdir -p "$last/native/recorder" "$last/.git"
    : > "$last/native/recorder/main.swift"
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
APP_DIR="$HOME/t.app"; APP_BIN="$APP_DIR/Contents/MacOS/audio-capture"
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
if recorder_ready; then pass "recorder_ready true when the app matches VERSION"; else fail "recorder_ready true when the app matches VERSION"; fi

# install_recorder builds mb-transcript beside the app and records it
SRC_DIR="$HOME/src2"; SOURCE_DIR="$SRC_DIR/meetingbox"; BIN_DIR="$HOME/bin2"
TRANSCRIPT_BIN="$SRC_DIR/mb-transcript"
fetch_source() { return 0; }
build_app() { echo "build_app $1" >> "$HOME/calls.log"; }
swiftc() {
  echo "swiftc $*" >> "$HOME/calls.log"
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'bin' > "$2"; return 0; }; shift; done
}
: > "$HOME/calls.log"
install_recorder >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$TRANSCRIPT_BIN" ] && installed_by_us "$TRANSCRIPT_BIN" \
   && grep -q -- "swiftc -O -o .*/mb-transcript $SOURCE_DIR/native/transcript/\*.swift" "$HOME/calls.log"; then
  pass "install_recorder builds mb-transcript and records it"
else fail "install_recorder builds mb-transcript and records it: $(cat "$HOME/calls.log")"; fi

forget_install "$TRANSCRIPT_BIN"
install_recorder >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$TRANSCRIPT_BIN")" = bin ]; then
  pass "install_recorder will not replace an mb-transcript it did not make"
else fail "install_recorder will not replace an mb-transcript it did not make"; fi

finish
