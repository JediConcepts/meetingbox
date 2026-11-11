#!/bin/bash
# The Parakeet setup step: install_speech builds mb-speech in a temporary folder with every SwiftPM
# cache inside it, fetches the pinned models only when needed, and records what it makes. swift,
# fetch_source and the helper itself are stubs: nothing is built or downloaded.
. "$(dirname "$0")/lib.sh"

eval "$(sed -n '/^speech_ready() {/,/^}/p' "$HOME/meetingbox.functions")"   # the real one, not lib.sh's stub
SOURCE_DIR="$HOME/src"
mkdir -p "$SOURCE_DIR/native"
cp -R "$ROOT/native/speech" "$SOURCE_DIR/native/speech"
MANIFEST="$SOURCE_DIR/native/speech/models.json"
fetch_source() { echo "fetch_source" >> "$HOME/calls.log"; return 0; }
TEST_HOME="$HOME"

# The stub swift "builds" a helper script that logs each call and answers like mb-speech.
swift() {
  # swift runs with its own HOME, so the log is the test's, named outright
  echo "swift $*" >> "$TEST_HOME/calls.log"
  echo "HOME=$HOME CFFIXED_USER_HOME=${CFFIXED_USER_HOME:-} TMPDIR=${TMPDIR:-}" >> "$TEST_HOME/swift-env.log"
  local a prev="" pkg="" scratch="" show=0 stamp hash version
  for a in "$@"; do
    case "$prev" in --package-path) pkg="$a" ;; --scratch-path) scratch="$a" ;; esac
    [ "$a" = --show-bin-path ] && show=1
    prev="$a"
  done
  [ -n "${SWIFT_FAILS:-}" ] && return 1
  if [ "$show" = 1 ]; then printf '%s\n' "$scratch/release"; return 0; fi
  stamp="$pkg/Sources/mb-speech/BuildStamp.swift"
  cp "$stamp" "$TEST_HOME/stamp.seen"
  version="$(sed -n 's/^let buildVersion = "\(.*\)"$/\1/p' "$stamp")"
  hash="$(sed -n 's/^let speechHash = "\(.*\)"$/\1/p' "$stamp")"
  mkdir -p "$scratch/release"
  cat > "$scratch/release/mb-speech" <<EOF
#!/bin/bash
echo "mb-speech \$*" >> "\$HOME/calls.log"
case "\$1" in
  version) echo "mb-speech $version $hash" ;;
  cache-dir) if [ -f "\$HOME/cache-dir.out" ]; then cat "\$HOME/cache-dir.out"; else echo "\$HOME/Library/Caches/mb-speech"; fi ;;
  check) [ -f "\$2/models.json" ] && [ ! -e "\$HOME/check-fails" ] || { echo "mb-speech: \$2/models.json is missing" >&2; exit 1; } ;;
  fetch) cp "\$3" "\$2/models.json" && rm -f "\$HOME/check-fails" ;;
  warm) mkdir -p "\$HOME/Library/Caches/mb-speech" ;;
esac
EOF
  chmod 700 "$scratch/release/mb-speech"
}

CACHE="$HOME/Library/Caches/mb-speech"
fresh() {   # nothing installed, nothing recorded
  rm -rf "$SRC_DIR" "$CACHE" "$HOME/cache-dir.out" "$HOME/check-fails" "$HOME/stamp.seen" "$HOME/swift-env.log"
  rm -f "$INSTALLED" "$VOICE_FILE" "$VOICE_FILE.tmp"
  mkdir -p "$STATE_DIR"
  : > "$HOME/calls.log"
}
calls() { grep -c "^$1" "$HOME/calls.log"; }
mode() { stat -f '%Lp' "$1"; }

# --- a first install ---
fresh
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -m1 -n '^fetch_source' "$HOME/calls.log" | cut -d: -f1)" = 1 ] && [ "$(calls swift)" = 2 ]; then
  pass "install_speech fetches the source first, then builds"
else fail "install_speech fetches the source first, then builds ($rc): $out $(cat "$HOME/calls.log")"; fi

ok_flags=1
while IFS= read -r line; do
  set -- ${line#swift }
  tmp=""; prev=""; seen=""
  for a in "$@"; do
    case "$prev" in
      --package-path) tmp="${a%/speech}" ;;
      --scratch-path|--cache-path|--config-path|--security-path)
        case "$a" in "$tmp"/?*) seen="$seen $prev" ;; esac ;;
      --manifest-cache) [ "$a" = local ] && seen="$seen $prev" ;;
    esac
    case "$a" in --disable-dependency-cache|--force-resolved-versions) seen="$seen $a" ;; esac
    prev="$a"
  done
  for want in --scratch-path --cache-path --config-path --security-path --manifest-cache \
              --disable-dependency-cache --force-resolved-versions; do
    case " $seen " in *" $want "*) ;; *) ok_flags=0 ;; esac
  done
  [ -n "$tmp" ] && [ ! -e "$tmp" ] || ok_flags=0
  case "$line" in "swift build -c release "*) ;; *) ok_flags=0 ;; esac
done < <(grep '^swift ' "$HOME/calls.log")
# swift build writes beside HOME and TMPDIR whatever its flags say: those are in the temporary folder too.
while IFS= read -r line; do
  case "$line" in "HOME=$tmp/"?*" CFFIXED_USER_HOME=$tmp/"?*" TMPDIR=$tmp/"?*) ;; *) ok_flags=0 ;; esac
done < "$HOME/swift-env.log"
if [ "$ok_flags" = 1 ]; then
  pass "swift gets every SwiftPM path, and its HOME and TMPDIR, inside the temporary folder, which is gone afterwards"
else fail "swift gets every SwiftPM path, and its HOME and TMPDIR, inside the temporary folder, which is gone afterwards: $(grep '^swift ' "$HOME/calls.log")"; fi

if grep -qxF "let speechHash = \"$(speech_hash)\"" "$HOME/stamp.seen" && grep -qxF "let buildVersion = \"$VERSION\"" "$HOME/stamp.seen" \
   && grep -qxF 'let speechHash = "dev"' "$SOURCE_DIR/native/speech/Sources/mb-speech/BuildStamp.swift"; then
  pass "the build stamp is written in the temporary copy only"
else fail "the build stamp is written in the temporary copy only: $(cat "$HOME/stamp.seen" 2>/dev/null)"; fi

if [ "$(mode "$SPEECH_BIN")" = 755 ] && installed_by_us "$SPEECH_BIN" && installed_by_us "$SPEECH_MODELS" \
   && cmp -s "$SPEECH_MODELS/models.json" "$MANIFEST" && [ "$(calls 'mb-speech fetch')" = 1 ] && speech_ready; then
  pass "the helper is installed 755 and recorded, the models are fetched into a recorded folder, and it is ready"
else fail "the helper is installed 755 and recorded, the models are fetched into a recorded folder, and it is ready: $out"; fi

if installed_by_us "$CACHE" && installed_by_us "$VOICE_FILE" && [ ! -e "$VOICE_FILE" ]; then
  pass "the cache folder and the voice print, absent before, are recorded"
else fail "the cache folder and the voice print, absent before, are recorded: $(cat "$INSTALLED")"; fi

if printf '%s' "$out" | grep -qF 'Parakeet and speaker labels (on device)'; then pass "the step has its title"
else fail "the step has its title: $out"; fi

# --- run again: nothing to fetch ---
: > "$HOME/calls.log"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls 'mb-speech fetch')" = 0 ] && [ "$(calls 'mb-speech warm')" = 1 ]; then
  pass "models that pass check and match the source manifest are not fetched again"
else fail "models that pass check and match the source manifest are not fetched again: $(cat "$HOME/calls.log")"; fi

# --- the installed manifest differs, though check passes ---
printf ' ' >> "$SPEECH_MODELS/models.json"
speech_ready && fail "speech_ready is false when the installed manifest differs" || pass "speech_ready is false when the installed manifest differs"
: > "$HOME/calls.log"
install_speech >/dev/null 2>&1
if [ "$(calls 'mb-speech fetch')" = 1 ] && speech_ready; then pass "a manifest that differs from the source's is fetched again"
else fail "a manifest that differs from the source's is fetched again: $(cat "$HOME/calls.log")"; fi

# --- check fails ---
touch "$HOME/check-fails"
: > "$HOME/calls.log"
install_speech >/dev/null 2>&1
if [ "$(calls 'mb-speech fetch')" = 1 ] && speech_ready; then pass "models that fail check are fetched again"
else fail "models that fail check are fetched again: $(cat "$HOME/calls.log")"; fi

# --- the helper's source changed ---
printf '// changed\n' >> "$SOURCE_DIR/native/speech/Sources/mb-speech/Fetch.swift"
speech_ready && fail "speech_ready is false when the helper's hash differs from the source" \
  || pass "speech_ready is false when the helper's hash differs from the source"
cp "$ROOT/native/speech/Sources/mb-speech/Fetch.swift" "$SOURCE_DIR/native/speech/Sources/mb-speech/Fetch.swift"
speech_ready && pass "speech_ready is true again with the source it was built from" \
  || fail "speech_ready is true again with the source it was built from"

# --- a failing build keeps what works, and setup carries on ---
cp "$SPEECH_BIN" "$HOME/helper.before"
cp "$SPEECH_MODELS/models.json" "$HOME/models.before"
out="$(SWIFT_FAILS=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "Parakeet could not be set up: " \
   && printf '%s' "$out" | grep -qF ". Carrying on with Apple's transcriber." \
   && cmp -s "$SPEECH_BIN" "$HOME/helper.before" && cmp -s "$SPEECH_MODELS/models.json" "$HOME/models.before"; then
  pass "a failing build says Parakeet could not be set up and keeps the old helper and models"
else fail "a failing build says Parakeet could not be set up and keeps the old helper and models ($rc): $out"; fi

(
  macos_major() { echo 27; }
  refuse_while_busy() { return 0; }
  need_xcode_clt() { return 1; }
  need_recorder() { return 1; }
  speech_ready() { return 1; }
  transcriber_present() { return 0; }
  have_signing_identity() { return 0; }
  app_signed_by_us() { return 0; }
  need_fm_license() { return 1; }
  on_path() { return 0; }
  remove_old_app() { :; }
  prime_permissions() { echo "prime_permissions" >> "$HOME/calls.log"; return 0; }
  prime_speech() { :; }
  make_shortcut_hint() { :; }
  open_app() { :; }
  mkdir -p "$BIN_DIR"
  : > "$HOME/calls.log"
  out="$(SWIFT_FAILS=1 setup 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'Parakeet (more accurate transcripts and speaker labels, about 630 MB)' \
     && printf '%s' "$out" | grep -qF "Parakeet could not be set up" && grep -qx prime_permissions "$HOME/calls.log"; then
    pass "setup offers Parakeet, and carries on after it fails"
  else fail "setup offers Parakeet, and carries on after it fails ($rc): $out"; fi
)

# --- the survey: on a release update, Parakeet is due whenever the recorder is ---
(
  speech_ready() { return 0; }
  recorder_ready() { return 1; }
  need_speech && pass "Parakeet is due when the recorder step is" || fail "Parakeet is due when the recorder step is"
  recorder_ready() { return 0; }
  built_from_source() { return 0; }
  need_speech && fail "Parakeet is not due when it is ready and the recorder is" || pass "Parakeet is not due when it is ready and the recorder is"
)

# --- the models folder ---
fresh
mkdir -p "$SPEECH_MODELS"; touch "$SPEECH_MODELS/mine"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$SPEECH_MODELS already exists and meetingbox did not create it" \
   && [ -e "$SPEECH_MODELS/mine" ] && ! installed_by_us "$SPEECH_MODELS" && [ "$(calls 'mb-speech fetch')" = 0 ]; then
  pass "a models folder meetingbox did not make stops the step with the claim_path message, untouched"
else fail "a models folder meetingbox did not make stops the step with the claim_path message, untouched ($rc): $out"; fi

fresh
install_speech >/dev/null 2>&1
touch "$SPEECH_MODELS/kept"
install_speech >/dev/null 2>&1
[ -e "$SPEECH_MODELS/kept" ] && pass "a recorded models folder is kept, not claimed again" \
  || fail "a recorded models folder is kept, not claimed again"

# --- the cache folder and the voice print ---
fresh
mkdir -p "$CACHE"; mkdir -p "$(dirname "$VOICE_FILE")"; echo '{}' > "$VOICE_FILE"
install_speech >/dev/null 2>&1
if ! installed_by_us "$CACHE" && ! installed_by_us "$VOICE_FILE" && installed_by_us "$SPEECH_BIN"; then
  pass "a cache folder or voice print that was already there is not recorded"
else fail "a cache folder or voice print that was already there is not recorded: $(cat "$INSTALLED")"; fi

# A rebuild claims the helper again, which moves its line to the end once; after that the
# record is stable, so it is taken after one rebuild.
install_speech >/dev/null 2>&1
cp "$INSTALLED" "$HOME/installed.before"
bad_cache() {   # $1: what it is, $2: what cache-dir prints
  rm -rf "$CACHE"
  printf '%s\n' "$2" > "$HOME/cache-dir.out"
  install_speech >/dev/null 2>&1
  if cmp -s "$INSTALLED" "$HOME/installed.before"; then pass "cache-dir printing $1 leaves the install record byte-identical"
  else fail "cache-dir printing $1 leaves the install record byte-identical: $(cat "$INSTALLED")"; fi
}
bad_cache "\$HOME/Library/Caches" "$HOME/Library/Caches"
bad_cache "two lines" "$CACHE
$CACHE"
bad_cache "a path with .." "$HOME/x/../Library/Caches/mb-speech"
bad_cache "a relative path" "Library/Caches/mb-speech"
rm -f "$HOME/cache-dir.out"

# --- doctor ---
fresh
install_speech >/dev/null 2>&1
need_fm_license() { return 1; }
out="$(doctor 2>&1)"
if printf '%s' "$out" | grep -q 'Parakeet' && printf '%s' "$out" | grep -qF "speech models" \
   && printf '%s' "$out" | grep -qF "model cache $CACHE" && printf '%s' "$out" | grep -qF "voice print"; then
  pass "doctor reports Parakeet, the models, the cache folder and the voice print"
else fail "doctor reports Parakeet, the models, the cache folder and the voice print: $out"; fi
printf '%s\n' "$HOME/Library/Caches" > "$HOME/cache-dir.out"
out="$(doctor 2>&1)"
printf '%s' "$out" | grep -qF "model cache: " && pass "doctor says when the cache folder cannot be recorded" \
  || fail "doctor says when the cache folder cannot be recorded: $out"
rm -f "$HOME/cache-dir.out"

# --- reset --tools and uninstall ---
refuse_while_busy() { return 0; }
adopt_own_app() { :; }
quit_app() { return 0; }
reset_through_app() { return 1; }
stop_recorders() { :; }
remove_signing_identity() { :; }
brew() { return 1; }
for level in tools all; do
  fresh
  install_speech >/dev/null 2>&1
  echo '{}' > "$VOICE_FILE"; echo '{}' > "$VOICE_FILE.tmp"
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  if [ ! -e "$SPEECH_BIN" ] && [ ! -e "$SPEECH_MODELS" ] && [ ! -e "$CACHE" ] && [ ! -e "$VOICE_FILE" ] \
     && [ ! -e "$VOICE_FILE.tmp" ] && ! grep -q 'mb-speech\|models\|voice' "$INSTALLED" 2>/dev/null; then
    pass "reset_cmd $level removes the helper, models, cache and voice print through the record"
  else fail "reset_cmd $level removes the helper, models, cache and voice print through the record ($rc): $out"; fi

  fresh
  mkdir -p "$SPEECH_MODELS" "$CACHE"; touch "$SPEECH_BIN" "$VOICE_FILE"
  out="$(confirm() { return 1; }; reset_cmd "$level" 2>&1)"
  left="$(printf '%s\n' "$out" | sed -n '/leave alone/,$p')"
  if printf '%s' "$left" | grep -qF "$SPEECH_BIN" && printf '%s' "$left" | grep -qF "$SPEECH_MODELS" \
     && printf '%s' "$left" | grep -qF "$CACHE" && printf '%s' "$left" | grep -qF "$VOICE_FILE" \
     && [ -e "$SPEECH_BIN" ] && [ -d "$SPEECH_MODELS" ] && [ -d "$CACHE" ] && [ -e "$VOICE_FILE" ]; then
    pass "reset_cmd $level lists an unrecorded helper, models, cache and voice print as left alone"
  else fail "reset_cmd $level lists an unrecorded helper, models, cache and voice print as left alone: $out"; fi
done

finish
