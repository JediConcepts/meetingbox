#!/bin/bash
. "$(dirname "$0")/lib.sh"

# Apple's transcriber is built with swiftc directly, like the recorder: SwiftPM
# cannot link on some macOS 27 Command Line Tools, so `swift build` is never used.

SRC_DIR="$HOME/src"; BIN_DIR="$HOME/.local/bin"
clone="$SRC_DIR/speech-analyzer-cli"
make_clone() {
  mkdir -p "$1/.git" "$1/Sources/SpeechAnalyzerCore" "$1/Sources/SpeechAnalyzerCLI" "$1/Resources" "$1/scripts"
  : > "$1/Sources/SpeechAnalyzerCore/Models.swift"
  : > "$1/Sources/SpeechAnalyzerCLI/Main.swift"
  printf '<plist/>\n' > "$1/Resources/Info.plist"
  printf '#!/bin/sh\necho upstream >> "%s/calls.log"\n' "$HOME" > "$1/scripts/install.sh"
}
git() {
  echo "git $*" >> "$HOME/calls.log"
  [ "$1" = clone ] && make_clone "${@: -1}"
  return 0
}
SWIFTC_FAILS=""
swiftc() {
  echo "swiftc $*" >> "$HOME/calls.log"
  [ -n "$SWIFTC_FAILS" ] && return 1
  local prev="" a
  for a in "$@"; do
    [ "$prev" = -o ] && printf 'bin' > "$a"
    prev="$a"
  done
  return 0
}
swift() { echo "swift $*" >> "$HOME/calls.log"; return 1; }
have() { case "$1" in speech-analyzer) [ -x "$SA_LINK" ] ;; swiftc|git) return 0 ;; *) return 1 ;; esac; }

# --- a fresh install builds with swiftc, never swift build or the upstream script ---
: > "$HOME/calls.log"
out="$(install_speech_analyzer 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$SA_APP/Contents/MacOS/speech-analyzer" ] && [ -f "$SA_APP/Contents/Info.plist" ] \
   && [ -L "$SA_LINK" ] && [ "$(readlink "$SA_LINK")" = "$SA_APP/Contents/MacOS/speech-analyzer" ] \
   && ! grep -q '^swift \|^upstream' "$HOME/calls.log"; then
  pass "speech-analyzer is built with swiftc and installed as an app with a link"
else fail "speech-analyzer is built with swiftc and installed as an app with a link (rc $rc): $out $(cat "$HOME/calls.log")"; fi
if grep -q -- '-module-name SpeechAnalyzerCore .*-emit-module' "$HOME/calls.log" \
   && grep -q -- "-I .*-lSpeechAnalyzerCore .*$clone/Sources/SpeechAnalyzerCLI/Main.swift" "$HOME/calls.log"; then
  pass "the core is built as its own module, then the command against it"
else fail "the core is built as its own module, then the command against it: $(cat "$HOME/calls.log")"; fi
if installed_by_us "$SA_APP" && installed_by_us "$SA_LINK" && installed_by_us "$clone"; then
  pass "the app, the link and the clone are on the install record"
else fail "the app, the link and the clone are on the install record"; fi
if grep -q "^codesign --force --sign - .*$SA_APP" "$HOME/calls.log"; then pass "the app is signed"
else fail "the app is signed: $(cat "$HOME/calls.log")"; fi
if [ -z "$(ls -A "$TMPDIR" 2>/dev/null | grep '^mb-sa\.')" ]; then pass "no build folder left behind"
else fail "no build folder left behind"; fi

# --- running again replaces what it made ---
: > "$HOME/calls.log"
if install_speech_analyzer >/dev/null 2>&1 && grep -q '^git -C .* pull' "$HOME/calls.log" && [ -L "$SA_LINK" ]; then
  pass "a second run updates the clone and rebuilds"
else fail "a second run updates the clone and rebuilds: $(cat "$HOME/calls.log")"; fi

# --- a compile failure installs nothing and leaves what was there ---
remove_installed "$SA_LINK"; remove_installed "$SA_APP"
SWIFTC_FAILS=1; : > "$HOME/calls.log"
out="$(install_speech_analyzer 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SA_APP" ] && [ ! -L "$SA_LINK" ] && printf '%s' "$out" | grep -q 'did not build'; then
  pass "a failed build installs nothing and says so"
else fail "a failed build installs nothing and says so (rc $rc): $out"; fi
SWIFTC_FAILS=""

# --- something at the link that meetingbox did not make is left alone ---
mkdir -p "$BIN_DIR"; printf 'theirs' > "$SA_LINK"
out="$(install_speech_analyzer 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$SA_LINK")" = theirs ]; then pass "a speech-analyzer meetingbox did not make is not replaced"
else fail "a speech-analyzer meetingbox did not make is not replaced"; fi
command rm -f "$SA_LINK"

# --- it runs as its own app, so macOS asks for Speech Recognition for it, not for
# whatever started meetingbox (a Shortcuts hotkey is refused without a prompt) ---
mkdir -p "$SA_APP/Contents/MacOS"
OPEN_MODE=ok
open() {
  echo "open $*" >> "$HOME/calls.log"
  local o="" e="" prev="" a last=""
  for a in "$@"; do
    [ "$prev" = -o ] && o="$a"; [ "$prev" = --stderr ] && e="$a"
    prev="$a"; last="$a"
  done
  case "$OPEN_MODE" in
    ok) printf 'words from %s' "$last" > "$o" ;;
    denied) printf 'Error: Speech recognition permission was denied. Enable it in System Settings.\n\nUsage: speech-analyzer [options] AUDIO_FILE\n' > "$e" ;;
  esac
  return 0
}
cd "$HOME"; printf 'aac' > "$HOME/talk.m4a"
: > "$HOME/calls.log"
sa_run "rel.json" "talk.m4a" -f json; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$HOME/rel.json")" = "words from $HOME/talk.m4a" ] \
   && grep -q -- "^open -W -n -g .*$SA_APP --args --locale $LOCALE -f json -o $HOME/rel.json $HOME/talk.m4a\$" "$HOME/calls.log"; then
  pass "sa_run opens the app and waits, with full paths"
else fail "sa_run opens the app and waits, with full paths (rc $rc): $(cat "$HOME/calls.log")"; fi

OPEN_MODE=denied
out="$(sa_run "$HOME/d.json" "$HOME/talk.m4a" -f json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'permission was denied' && ! printf '%s' "$out" | grep -q 'Usage:'; then
  pass "sa_run fails on the transcriber's error, showing the error without its usage text"
else fail "sa_run fails on the transcriber's error, showing the error without its usage text (rc $rc): $out"; fi

OPEN_MODE=nothing
if ! sa_run "$HOME/n.json" "$HOME/talk.m4a" -f json 2>/dev/null; then pass "sa_run fails when nothing was written"
else fail "sa_run fails when nothing was written"; fi

command rm -rf "$SA_APP"
speech-analyzer() { echo "speech-analyzer $*" >> "$HOME/calls.log"; echo direct; }
: > "$HOME/calls.log"
if sa_run "$HOME/x.json" "$HOME/talk.m4a" -f json && [ "$(cat "$HOME/x.json")" = direct ] && ! grep -q '^open' "$HOME/calls.log"; then
  pass "a speech-analyzer meetingbox did not build is run directly"
else fail "a speech-analyzer meetingbox did not build is run directly"; fi
unset -f speech-analyzer

# --- setup asks for Speech Recognition with a short spoken clip, like the other permissions ---
SAY_BIN="$HOME/fake-say"
printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && printf aiff > "$2"; shift; done\n' > "$SAY_BIN"; chmod +x "$SAY_BIN"
have() { case "$1" in speech-analyzer) return 0 ;; *) return 1 ;; esac; }
SA_RESULTS="denied ok"
sa_run() {
  echo "sa_run $*" >> "$HOME/calls.log"
  local r="${SA_RESULTS%% *}"; SA_RESULTS="${SA_RESULTS#* }"
  [ "$r" = ok ] && { printf 'meetingbox' > "$1"; return 0; }
  echo "Error: Speech recognition permission was denied." >&2; return 1
}
open_privacy() { echo "open_privacy $1" >> "$HOME/calls.log"; }
pause_for() { echo "pause_for" >> "$HOME/calls.log"; }
: > "$HOME/calls.log"
out="$(prime_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^open_privacy SpeechRecognition' "$HOME/calls.log" \
   && [ "$(grep -c '^sa_run' "$HOME/calls.log")" = 2 ] && printf '%s' "$out" | grep -q 'Speech Recognition works'; then
  pass "prime_speech walks through Speech Recognition and tests again"
else fail "prime_speech walks through Speech Recognition and tests again (rc $rc): $out $(cat "$HOME/calls.log")"; fi

SA_RESULTS="denied denied denied denied denied"; : > "$HOME/calls.log"
out="$(prime_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'whisper' && [ "$(grep -c '^sa_run' "$HOME/calls.log")" = 4 ]; then
  pass "prime_speech gives up after three goes without failing setup"
else fail "prime_speech gives up after three goes without failing setup (rc $rc): $out"; fi

have() { return 1; }; : > "$HOME/calls.log"
if prime_speech >/dev/null 2>&1 && [ ! -s "$HOME/calls.log" ]; then pass "prime_speech does nothing without Apple's transcriber"
else fail "prime_speech does nothing without Apple's transcriber"; fi
unset -f sa_run open_privacy pause_for

# --- setup offers it on macOS 26 and later even when whisper is there, and carries on without it ---
macos_major() { echo 27; }
need_xcode_clt() { return 1; }
need_recorder() { return 1; }
have_signing_identity() { return 0; }
app_signed_by_us() { return 0; }
need_fm_license() { return 1; }
on_path() { return 0; }
transcriber_present() { return 0; }
prime_permissions() { return 0; }
prime_speech() { echo "prime_speech" >> "$HOME/calls.log"; }
make_shortcut_hint() { :; }
install_speech_analyzer() { echo "install_speech_analyzer" >> "$HOME/calls.log"; return 1; }
have() { case "$1" in whisper-cli|fm) return 0 ;; *) return 1 ;; esac; }
: > "$HOME/calls.log"
out="$(setup 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Apple's transcriber" && grep -q '^install_speech_analyzer' "$HOME/calls.log" \
   && printf '%s' "$out" | grep -q 'carrying on with whisper' && grep -q '^prime_speech' "$HOME/calls.log"; then
  pass "setup offers Apple's transcriber beside whisper, and a failure does not stop setup"
else fail "setup offers Apple's transcriber beside whisper (rc $rc): $out"; fi

macos_major() { echo 25; }
: > "$HOME/calls.log"
out="$(setup 2>&1)"
if ! grep -q '^install_speech_analyzer' "$HOME/calls.log" && ! printf '%s' "$out" | grep -q "Apple's transcriber"; then
  pass "not offered before macOS 26"
else fail "not offered before macOS 26: $out"; fi

finish
