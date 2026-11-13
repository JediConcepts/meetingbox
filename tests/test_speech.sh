#!/bin/bash
# The Parakeet setup step: install_speech builds mb-speech in a temporary folder with every SwiftPM
# path inside it but the dependency cache, which is meetingbox's own, fetches the pinned models
# only when needed, and records what it makes. swift, fetch_source and the helper itself are
# stubs: nothing is built or downloaded.
. "$(dirname "$0")/lib.sh"

eval "$(sed -n '/^speech_ready() {/,/^}/p' "$HOME/meetingbox.functions")"   # the real one, not lib.sh's stub
SOURCE_DIR="$HOME/src"
mkdir -p "$SOURCE_DIR/native"
cp -R "$ROOT/native/speech" "$SOURCE_DIR/native/speech"
MANIFEST="$SOURCE_DIR/native/speech/models.json"
fetch_source() { echo "fetch_source" >> "$HOME/calls.log"; return 0; }
TEST_HOME="$HOME"
# meetingbox's own SwiftPM dependency cache, where the spec puts it, and the mark the stub swift
# leaves in it when it fetches FluidAudio there
DEPS="$SRC_DIR/swiftpm-cache"
MARK="$DEPS/repositories/FluidAudio/fetched"

# The stub swift "builds" a helper script that logs each call and answers like mb-speech.
# SWIFT_FAILS fails every call; SWIFT_FAILS_WITH_CACHE fails a call that uses meetingbox's cache.
swift() {
  # swift runs with its own HOME, so the log is the test's, named outright
  echo "swift $*" >> "$TEST_HOME/calls.log"
  echo "HOME=$HOME CFFIXED_USER_HOME=${CFFIXED_USER_HOME:-} TMPDIR=${TMPDIR:-}" >> "$TEST_HOME/swift-env.log"
  local a prev="" pkg="" scratch="" cache="" shared=1 show=0 stamp hash version
  for a in "$@"; do
    case "$prev" in --package-path) pkg="$a" ;; --scratch-path) scratch="$a" ;; --cache-path) cache="$a" ;; esac
    case "$a" in --show-bin-path) show=1 ;; --disable-dependency-cache) shared=0 ;; esac
    prev="$a"
  done
  [ -n "${SWIFT_FAILS:-}" ] && return 1
  [ -n "${SWIFT_FAILS_WITH_CACHE:-}" ] && [ "$cache" = "$DEPS" ] && [ "$shared" = 1 ] && return 1
  if [ "$show" = 1 ]; then printf '%s\n' "$scratch/release"; return 0; fi
  # As SwiftPM does: FluidAudio is fetched unless the dependency cache in use already holds it,
  # and a fetch with that cache in use leaves it there, read-only as git's objects are, marked
  # with the folder of the build that fetched it.
  if [ "$shared" = 0 ] || [ ! -e "$cache/repositories/FluidAudio/fetched" ]; then
    echo "FluidAudio fetched" >> "$TEST_HOME/calls.log"
    if [ "$shared" = 1 ] && [ -n "$cache" ]; then
      mkdir -p "$cache/repositories/FluidAudio" && printf '%s\n' "$pkg" > "$cache/repositories/FluidAudio/fetched" \
        && chmod 444 "$cache/repositories/FluidAudio/fetched"
    fi
  fi
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
  clear_logs
}
clear_logs() { : > "$HOME/calls.log"; : > "$HOME/swift-env.log"; }
calls() { grep -c "^$1" "$HOME/calls.log"; }
mode() { stat -f '%Lp' "$1"; }

# One logged swift call is right. Always: swift build -c release, with the scratch, config and
# security paths, and HOME, CFFIXED_USER_HOME and TMPDIR, inside its temporary folder (gone
# afterwards), the local manifest cache and the forced versions. Then, as $1 says, "deps":
# meetingbox's own dependency cache, in use; or "temp": a cache inside the temporary folder with
# --disable-dependency-cache, as every build was before.
swift_ok() {   # $1: deps | temp, $2: the call, $3: the environment it ran with
  local a prev="" t="" seen="" cache="" off=0 want
  case "$2" in "swift build -c release "*) ;; *) return 1 ;; esac
  for a in ${2#swift }; do
    case "$prev" in
      --package-path) t="${a%/speech}" ;;
      --scratch-path|--config-path|--security-path) case "$a" in "$t"/?*) seen="$seen $prev" ;; esac ;;
      --manifest-cache) [ "$a" = local ] && seen="$seen $prev" ;;
      --cache-path) cache="$a" ;;
    esac
    case "$a" in --force-resolved-versions) seen="$seen $a" ;; --disable-dependency-cache) off=1 ;; esac
    prev="$a"
  done
  for want in --scratch-path --config-path --security-path --manifest-cache --force-resolved-versions; do
    case " $seen " in *" $want "*) ;; *) return 1 ;; esac
  done
  [ -n "$t" ] && [ ! -e "$t" ] || return 1
  case "$3" in "HOME=$t/"?*" CFFIXED_USER_HOME=$t/"?*" TMPDIR=$t/"?*) ;; *) return 1 ;; esac
  case "$1" in
    deps) [ "$cache" = "$DEPS" ] && [ "$off" = 0 ] ;;
    temp) case "$cache" in "$t"/?*) [ "$off" = 1 ] ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}
# The swift calls since the logs were cleared are right: exactly these, in order. A build is one
# call, then one with --show-bin-path if that worked.
swift_calls() {
  local n=0 call env
  [ "$(calls swift)" = "$#" ] || return 1
  while IFS='|' read -r call env; do
    n=$((n + 1))
    swift_ok "${!n}" "$call" "$env" || return 1
  done < <(paste -d '|' <(grep '^swift ' "$HOME/calls.log") "$HOME/swift-env.log")
}
swift_log() { paste -d '|' <(grep '^swift ' "$HOME/calls.log") "$HOME/swift-env.log"; }
# Every path under a folder with its type, mode, size and time, and each file's contents.
snapshot() {
  (cd "$1" && find . | LC_ALL=C sort | while IFS= read -r f; do
     stat -f '%N %HT %Sp %z %m' "$f"; [ -f "$f" ] && shasum < "$f"; done)
}

# --- a first install ---
fresh
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -m1 -n '^fetch_source' "$HOME/calls.log" | cut -d: -f1)" = 1 ] && [ "$(calls swift)" = 2 ]; then
  pass "install_speech fetches the source first, then builds"
else fail "install_speech fetches the source first, then builds ($rc): $out $(cat "$HOME/calls.log")"; fi

# swift build writes beside HOME and TMPDIR whatever its flags say: those are in the temporary folder too.
if swift_calls deps deps; then
  pass "swift caches its dependencies in meetingbox's own folder, with no --disable-dependency-cache, and gets every other SwiftPM path, and its HOME and TMPDIR, inside the temporary folder, which is gone afterwards"
else fail "swift caches its dependencies in meetingbox's own folder, with no --disable-dependency-cache, and gets every other SwiftPM path, and its HOME and TMPDIR, inside the temporary folder, which is gone afterwards: $(swift_log)"; fi

if [ -d "$DEPS" ] && [ ! -L "$DEPS" ] && [ "$(mode "$DEPS")" = 700 ] && installed_by_us "$DEPS" \
   && [ "$(calls 'FluidAudio fetched')" = 1 ] && [ -e "$MARK" ]; then
  pass "the first build makes the dependency cache, 700 and recorded, and FluidAudio is fetched into it"
else fail "the first build makes the dependency cache, 700 and recorded, and FluidAudio is fetched into it: $(ls -ld "$DEPS" 2>&1) $(cat "$INSTALLED")"; fi

if [ "$(printf '%s\n' "$out" | grep -cF 'compiling. The first build fetches FluidAudio and takes a few minutes. Later builds reuse it.')" = 1 ]; then
  pass "the line before compiling says the first build fetches FluidAudio and later builds reuse it"
else fail "the line before compiling says the first build fetches FluidAudio and later builds reuse it: $out"; fi

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

# --- run again: nothing to build, nothing to fetch ---
: > "$HOME/calls.log"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls swift)" = 0 ] && [ "$(calls fetch_source)" = 1 ]; then
  pass "a recorded helper built from this source is not rebuilt"
else fail "a recorded helper built from this source is not rebuilt: $(cat "$HOME/calls.log")"; fi
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

# --- an update that fails keeps what works ---
FETCH_SRC="$SOURCE_DIR/native/speech/Sources/mb-speech/Fetch.swift"
printf '// changed\n' >> "$FETCH_SRC"   # so the helper is due a rebuild
cp "$SPEECH_BIN" "$HOME/helper.before"
cp "$SPEECH_MODELS/models.json" "$HOME/models.before"
kept() { [ -x "$SPEECH_BIN" ] && cmp -s "$SPEECH_BIN" "$HOME/helper.before" && cmp -s "$SPEECH_MODELS/models.json" "$HOME/models.before"; }
updated_line() { printf '%s' "$1" | grep -qF "Parakeet could not be updated: " \
  && printf '%s' "$1" | grep -qF ". The installed version is still used." && ! printf '%s' "$1" | grep -qF "Apple's transcriber"; }

out="$(doctor 2>&1)"
printf '%s' "$out" | grep -qF "Parakeet is out of date. Run: meetingbox setup" \
  && pass "doctor says a usable helper built from older source is out of date" \
  || fail "doctor says a usable helper built from older source is out of date: $out"

out="$(SWIFT_FAILS=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && updated_line "$out" && kept; then
  pass "a failing rebuild says Parakeet could not be updated, and keeps the usable helper and models"
else fail "a failing rebuild says Parakeet could not be updated, and keeps the usable helper and models ($rc): $out"; fi

out="$(install() { echo "install $*" >> "$HOME/calls.log"; return 1; }; install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && updated_line "$out" && kept; then
  pass "a failing install of the new helper leaves the old one in place"
else fail "a failing install of the new helper leaves the old one in place ($rc): $out"; fi

touch "$HOME/check-fails"   # the old helper is not usable now
out="$(SWIFT_FAILS=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "Parakeet could not be set up: " \
   && printf '%s' "$out" | grep -qF ". Carrying on with Apple's transcriber." && kept; then
  pass "a failing build with no usable helper says Parakeet could not be set up"
else fail "a failing build with no usable helper says Parakeet could not be set up ($rc): $out"; fi
rm -f "$HOME/check-fails"
cp "$ROOT/native/speech/Sources/mb-speech/Fetch.swift" "$FETCH_SRC"

out="$(install_speech 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && speech_ready && pass "after the failures, setup installs again" || fail "after the failures, setup installs again: $out"

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
  rm -f "$SPEECH_BIN"   # nothing usable, so the step builds, and fails
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

# --- meetingbox's dependency cache: FluidAudio is fetched once, then reused ---
fresh
install_speech >/dev/null 2>&1
mark="$(cat "$MARK" 2>/dev/null)"
printf '// changed\n' >> "$FETCH_SRC"   # so the helper is rebuilt, with the same pinned versions
clear_logs
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && swift_calls deps deps && [ -n "$mark" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$mark" ] \
   && [ "$(calls 'FluidAudio fetched')" = 0 ] && installed_by_us "$DEPS" && [ "$(mode "$DEPS")" = 700 ] && speech_ready; then
  pass "a rebuild uses the same dependency cache, still holding the first build's FluidAudio, and fetches nothing"
else fail "a rebuild uses the same dependency cache, still holding the first build's FluidAudio, and fetches nothing ($rc): $(swift_log) [$mark / $(cat "$MARK" 2>&1)]"; fi
cp "$ROOT/native/speech/Sources/mb-speech/Fetch.swift" "$FETCH_SRC"

# A folder there that meetingbox did not make, or a link, is never used, touched or recorded.
fresh
mkdir -p "$DEPS/repositories"; echo mine > "$DEPS/mine"; chmod 755 "$DEPS"
before="$(snapshot "$DEPS")"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(snapshot "$DEPS")" = "$before" ] && ! installed_by_us "$DEPS" && swift_calls temp temp \
   && [ "$(printf '%s\n' "$out" | grep -cF "$DEPS is not meetingbox's, so the build fetches FluidAudio as before")" = 1 ] \
   && speech_ready; then
  pass "a dependency cache folder meetingbox did not make is left byte for byte, unrecorded, and the build caches in the temporary folder as before"
else fail "a dependency cache folder meetingbox did not make is left byte for byte, unrecorded, and the build caches in the temporary folder as before ($rc): $out $(swift_log)"; fi

fresh
mkdir -p "$SRC_DIR" "$HOME/elsewhere"; echo mine > "$HOME/elsewhere/mine"; ln -s "$HOME/elsewhere" "$DEPS"
before="$(snapshot "$HOME/elsewhere")"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$DEPS" ] && [ "$(readlink "$DEPS")" = "$HOME/elsewhere" ] && [ "$(snapshot "$HOME/elsewhere")" = "$before" ] \
   && ! installed_by_us "$DEPS" && swift_calls temp temp && printf '%s' "$out" | grep -qF "$DEPS is not meetingbox's"; then
  pass "a link at the dependency cache's path is left as it is, with what it points at, unrecorded, and not used"
else fail "a link at the dependency cache's path is left as it is, with what it points at, unrecorded, and not used ($rc): $out $(swift_log)"; fi
rm -rf "$HOME/elsewhere"

# A build that fails with the cache: the cache goes, through the record, and the build is tried
# once more as before. The next build makes it again.
fresh
out="$(SWIFT_FAILS_WITH_CACHE=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && swift_calls deps temp temp && [ ! -e "$DEPS" ] && [ ! -L "$DEPS" ] && ! installed_by_us "$DEPS" \
   && installed_by_us "$SPEECH_BIN" && speech_ready; then
  pass "a build that fails with the dependency cache removes it, unrecorded, and one more build as before installs the helper"
else fail "a build that fails with the dependency cache removes it, unrecorded, and one more build as before installs the helper ($rc): $out $(swift_log)"; fi
printf '// changed\n' >> "$FETCH_SRC"
clear_logs
install_speech >/dev/null 2>&1
if swift_calls deps deps && [ "$(mode "$DEPS")" = 700 ] && installed_by_us "$DEPS" && [ -e "$MARK" ]; then
  pass "the next build makes the dependency cache again"
else fail "the next build makes the dependency cache again: $(swift_log)"; fi

# Both builds fail: the step fails as it did, the working helper is kept, and the cache is gone.
cp "$SPEECH_BIN" "$HOME/helper.before"
cp "$ROOT/native/speech/Sources/mb-speech/Fetch.swift" "$FETCH_SRC"   # due a rebuild again
clear_logs
out="$(SWIFT_FAILS=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "Parakeet could not be updated: the speech helper did not build." \
   && cmp -s "$SPEECH_BIN" "$HOME/helper.before" && swift_calls deps temp && [ ! -e "$DEPS" ] && ! installed_by_us "$DEPS"; then
  pass "when the build fails with the dependency cache and without it, the helper did not build, the old one is kept, and the cache is gone, unrecorded"
else fail "when the build fails with the dependency cache and without it, the helper did not build, the old one is kept, and the cache is gone, unrecorded ($rc): $out $(swift_log)"; fi

# --- doctor ---
fresh
install_speech >/dev/null 2>&1
need_fm_license() { return 1; }
out="$(doctor 2>&1)"
if printf '%s' "$out" | grep -q 'Parakeet' && printf '%s' "$out" | grep -qF "speech models" \
   && printf '%s' "$out" | grep -qF "model cache $CACHE" \
   && printf '%s' "$out" | grep -qF "Not learnt yet: meetingbox learns it from your video calls, or record a sample"; then
  pass "doctor reports Parakeet, the models, the cache folder and the voice print"
else fail "doctor reports Parakeet, the models, the cache folder and the voice print: $out"; fi

# --- doctor's voice line says what Preferences says, from voice.json ---
voice_said() {   # $1: voice.json's text, or "" for no file; prints doctor's line about the voice
  rm -f "$VOICE_FILE"
  [ -z "$1" ] || printf '%s\n' "$1" > "$VOICE_FILE"
  doctor 2>&1 | grep -i 'voice\|learnt' | sed 's/^ *//; s/^[a-z]* *//'
}
voice_ok=1; voice_wrong=""
voice_case() {   # $1: voice.json's text, $2: the line expected
  local got
  got="$(voice_said "$1")"
  case "$got" in *"$2"*) ;; *) voice_ok=0; voice_wrong="$voice_wrong [$2 / $got]" ;; esac
}
voice_case '' "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
voice_case '{"model": "m", "seconds": 75.4, "meetings": 2, "sources": ["a", "b"], "vector": [1], "updated": "x"}' \
  "Your voice: learnt from 2 calls (1 minute of speech)"
voice_case '{"model": "m", "seconds": 130, "meetings": 1, "sources": ["a"], "sample": false, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: learnt from 1 call (2 minutes of speech)"
voice_case '{"model": "m", "seconds": 95, "meetings": 1, "sources": [], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample (1 minute of speech)"
voice_case '{"model": "m", "seconds": 200, "meetings": 3, "sources": ["a", "b"], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample and 2 calls (3 minutes of speech)"
voice_case '{"model": "m", "seconds": 61, "meetings": 2, "sources": ["a"], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample and 1 call (1 minute of speech)"
voice_case '{"model": "m", "seconds": "lots"' "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
if [ "$voice_ok" = 1 ]; then pass "doctor's voice line: learnt from calls, from a sample, from both, or not learnt yet, with singulars"
else fail "doctor's voice line: learnt from calls, from a sample, from both, or not learnt yet, with singulars:$voice_wrong"; fi
# a voice print setup did not record is never learnt into, and doctor says so
grep -vxF "$VOICE_FILE" "$INSTALLED" > "$HOME/installed.tmp"; mv "$HOME/installed.tmp" "$INSTALLED"
printf '%s\n' '{"model": "m", "seconds": 75, "meetings": 2, "sources": ["a", "b"], "vector": [1], "updated": "x"}' > "$VOICE_FILE"
out="$(doctor 2>&1)"
if printf '%s' "$out" | grep -qF "Your voice: learnt from 2 calls" && printf '%s' "$out" | grep -qF "$VOICE_FILE was not made by meetingbox"; then
  pass "doctor says when the voice print is not on the install record"
else fail "doctor says when the voice print is not on the install record: $out"; fi
rm -f "$VOICE_FILE"
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
  had_deps=0; [ -e "$MARK" ] && installed_by_us "$DEPS" && had_deps=1
  out="$(reset_cmd "$level" 2>&1)"; rc=$?
  if [ ! -e "$SPEECH_BIN" ] && [ ! -e "$SPEECH_MODELS" ] && [ ! -e "$CACHE" ] && [ ! -e "$VOICE_FILE" ] \
     && [ ! -e "$VOICE_FILE.tmp" ] && ! grep -q 'mb-speech\|models\|voice' "$INSTALLED" 2>/dev/null; then
    pass "reset_cmd $level removes the helper, models, cache and voice print through the record"
  else fail "reset_cmd $level removes the helper, models, cache and voice print through the record ($rc): $out"; fi
  if [ "$had_deps" = 1 ] && printf '%s' "$out" | grep -qF "    $DEPS" && [ ! -e "$DEPS" ] && [ ! -L "$DEPS" ] \
     && ! grep -qxF "$DEPS" "$INSTALLED" 2>/dev/null; then
    pass "reset_cmd $level lists the recorded dependency cache and removes it, read-only files and all, through the record"
  else fail "reset_cmd $level lists the recorded dependency cache and removes it, read-only files and all, through the record ($rc, had it: $had_deps): $out"; fi

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
