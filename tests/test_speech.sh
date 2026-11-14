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

# Checks in a subshell keep its stubs to themselves, and their counts too: this reads the PASS and
# FAIL lines it prints and counts them here, passing anything else through.
recount() {
  local l
  while IFS= read -r l; do
    case "$l" in "PASS "*) pass "${l#PASS }" ;; "FAIL "*) fail "${l#FAIL }" ;; *) printf '%s\n' "$l" ;; esac
  done
}

recount < <(
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
recount < <(
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

# A link there is never used, even one on the record: meetingbox makes a folder there, not a link.
fresh
mkdir -p "$SRC_DIR" "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$DEPS"; record_install "$DEPS"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$DEPS" ] && [ "$(readlink "$DEPS")" = "$HOME/elsewhere" ] && [ -z "$(ls -A "$HOME/elsewhere")" ] \
   && swift_calls temp temp && printf '%s' "$out" | grep -qF "$DEPS is not meetingbox's, so the build fetches FluidAudio as before"; then
  pass "a recorded link at the dependency cache's path is not used either: what it points at gets no files, and the build is as before"
else fail "a recorded link at the dependency cache's path is not used either: what it points at gets no files, and the build is as before ($rc): $out $(swift_log) $(ls -AR "$HOME/elsewhere")"; fi
rm -rf "$HOME/elsewhere"

# The folder cannot be made (here SRC_DIR is read-only, so the helper cannot be installed either):
# its record is forgotten, and the build is as before.
fresh
mkdir -p "$SRC_DIR"; chmod 555 "$SRC_DIR"
out="$(install_speech 2>&1)"; rc=$?
chmod 755 "$SRC_DIR"
if [ ! -e "$DEPS" ] && [ ! -L "$DEPS" ] && ! installed_by_us "$DEPS" && swift_calls temp temp \
   && printf '%s' "$out" | grep -qF "compiling. The first build fetches FluidAudio and takes a few minutes." \
   && ! printf '%s' "$out" | grep -qF "Later builds reuse it"; then
  pass "a dependency cache that cannot be made is not left on the record, and the build is as before"
else fail "a dependency cache that cannot be made is not left on the record, and the build is as before ($rc): $out $(swift_log) $(cat "$INSTALLED")"; fi

# A build that fails with the cache: the cache goes, through the record, and the build is tried
# once more as before. The next build makes it again.
fresh
out="$(SWIFT_FAILS_WITH_CACHE=1 install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && swift_calls deps temp temp && [ ! -e "$DEPS" ] && [ ! -L "$DEPS" ] && ! installed_by_us "$DEPS" \
   && installed_by_us "$SPEECH_BIN" && speech_ready \
   && [ "$(printf '%s\n' "$out" | grep -cF "the build with meetingbox's FluidAudio cache failed, so it is tried once more without the cache")" = 1 ]; then
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
voice_case '{"model": "m", "seconds": 75, "meetings": 1, "sources": [], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample (1 minute of speech)"
voice_case '{"model": "m", "seconds": 200, "meetings": 3, "sources": ["a", "b"], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample and 2 calls (3 minutes of speech)"
voice_case '{"model": "m", "seconds": 61, "meetings": 2, "sources": ["a"], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample and 1 call (1 minute of speech)"
voice_case '{"model": "m", "seconds": "lots"' "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
if [ "$voice_ok" = 1 ]; then pass "doctor's voice line: learnt from calls, from a sample, from both, or not learnt yet, with singulars"
else fail "doctor's voice line: learnt from calls, from a sample, from both, or not learnt yet, with singulars:$voice_wrong"; fi
# Whole minutes to the nearest, a half up, as Preferences shows them (Task 6 round 1): 95 s and 90 s are 2.
voice_ok=1; voice_wrong=""
voice_case '{"model": "m", "seconds": 95, "meetings": 1, "sources": [], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' \
  "Your voice: from a recorded sample (2 minutes of speech)"
voice_case '{"model": "m", "seconds": 90.9, "meetings": 2, "sources": ["a", "b"], "vector": [1], "updated": "x"}' \
  "Your voice: learnt from 2 calls (2 minutes of speech)"
voice_case '{"model": "m", "seconds": 89, "meetings": 2, "sources": ["a", "b"], "vector": [1], "updated": "x"}' \
  "Your voice: learnt from 2 calls (1 minute of speech)"
if [ "$voice_ok" = 1 ]; then pass "doctor's voice line: minutes to the nearest, a half up, as Preferences says them (95 s and 90 s are 2 minutes, 89 s is 1)"
else fail "doctor's voice line: minutes to the nearest, a half up, as Preferences says them (95 s and 90 s are 2 minutes, 89 s is 1):$voice_wrong"; fi
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

# A dangling link at the dependency cache's path is not meetingbox's either: setup does not record
# or use it, and says so, and reset --tools leaves it.
fresh
mkdir -p "$SRC_DIR"; ln -s "$HOME/nowhere" "$DEPS"
out="$(install_speech 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$DEPS" ] && [ "$(readlink "$DEPS")" = "$HOME/nowhere" ] && [ ! -e "$HOME/nowhere" ] \
   && ! installed_by_us "$DEPS" && swift_calls temp temp \
   && [ "$(printf '%s\n' "$out" | grep -cF "$DEPS is not meetingbox's, so the build fetches FluidAudio as before")" = 1 ]; then
  pass "a dangling link at the dependency cache's path is not recorded or used, and setup says it is not meetingbox's"
else fail "a dangling link at the dependency cache's path is not recorded or used, and setup says it is not meetingbox's ($rc): $out $(swift_log) $(cat "$INSTALLED")"; fi
out="$(reset_cmd tools 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$DEPS" ] && [ "$(readlink "$DEPS")" = "$HOME/nowhere" ]; then
  pass "reset_cmd tools leaves a dangling link at the dependency cache's path"
else fail "reset_cmd tools leaves a dangling link at the dependency cache's path ($rc): $out"; fi

# ======================================================== engines, voice add and voice forget (Task 6)

LOCK="$VOICE_FILE.lock"
# --- setup records the voice print's lock beside it, only if it is not there yet ---
fresh; rm -f "$LOCK"
install_speech >/dev/null 2>&1
if [ "$VOICE_LOCK" = "$LOCK" ] && installed_by_us "$LOCK" && [ ! -e "$LOCK" ]; then
  pass "setup records <voice.json>.lock, absent before"
else fail "setup records <voice.json>.lock, absent before: $(cat "$INSTALLED")"; fi
echo x > "$LOCK"; touch "$VOICE_FILE"
out="$(reset_cmd tools 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$LOCK" ] && ! grep -qxF "$LOCK" "$INSTALLED" 2>/dev/null; then
  pass "reset_cmd tools removes the recorded lock through the record"
else fail "reset_cmd tools removes the recorded lock through the record ($rc): $out"; fi
# A lock a writer made before this setup (voice.json recorded by an earlier one): recorded too, so
# reset and uninstall never leave it behind.
fresh; rm -f "$LOCK"; mkdir -p "$STATE_DIR"; record_install "$VOICE_FILE"; echo '{}' > "$VOICE_FILE"; : > "$LOCK"
install_speech >/dev/null 2>&1
recorded_there=0; installed_by_us "$LOCK" && recorded_there=1
out="$(reset_cmd tools 2>&1)"; rc=$?
if [ "$recorded_there" = 1 ] && [ "$rc" -eq 0 ] && [ ! -e "$LOCK" ] && ! grep -qxF "$LOCK" "$INSTALLED" 2>/dev/null; then
  pass "setup records a lock already there as a plain file when voice.json is recorded, and reset removes it"
else fail "setup records a lock already there as a plain file when voice.json is recorded, and reset removes it ($recorded_there, $rc): $out"; fi
# The same with a voice.json setup records now, absent before.
fresh; rm -f "$LOCK"; mkdir -p "$STATE_DIR"; : > "$LOCK"
install_speech >/dev/null 2>&1
if installed_by_us "$VOICE_FILE" && installed_by_us "$LOCK"; then pass "setup records a lock already there when it records voice.json now"
else fail "setup records a lock already there when it records voice.json now: $(cat "$INSTALLED")"; fi
# A voice.json of the user's own (there before setup, so never recorded): its lock is not claimed either.
fresh; rm -f "$LOCK"; mkdir -p "$STATE_DIR"; echo '{}' > "$VOICE_FILE"; echo mine > "$LOCK"
install_speech >/dev/null 2>&1
out="$(confirm() { return 1; }; reset_cmd tools 2>&1)"
if ! installed_by_us "$VOICE_FILE" && ! installed_by_us "$LOCK" && [ "$(cat "$LOCK")" = mine ] \
   && printf '%s\n' "$out" | sed -n '/leave alone/,$p' | grep -qF "$LOCK"; then
  pass "a lock beside a voice.json setup did not record is not recorded, and reset lists it as left alone"
else fail "a lock beside a voice.json setup did not record is not recorded, and reset lists it as left alone: $out"; fi
# A link, or a folder, at the lock's path is never claimed, whatever the record says of voice.json.
fresh; rm -f "$LOCK"; mkdir -p "$STATE_DIR"; record_install "$VOICE_FILE"; ln -s "$HOME/lock-elsewhere" "$LOCK"
install_speech >/dev/null 2>&1
link_recorded=0; installed_by_us "$LOCK" && link_recorded=1
reset_cmd tools >/dev/null 2>&1
link_kept=0; [ -L "$LOCK" ] && link_kept=1
rm -f "$LOCK"; mkdir -p "$STATE_DIR"; record_install "$VOICE_FILE"; mkdir "$LOCK"
install_speech >/dev/null 2>&1
folder_recorded=0; installed_by_us "$LOCK" && folder_recorded=1
if [ "$link_recorded" = 0 ] && [ "$link_kept" = 1 ] && [ "$folder_recorded" = 0 ] && [ -d "$LOCK" ] && [ ! -e "$HOME/lock-elsewhere" ]; then
  pass "a link or a folder at the lock's path is never recorded, so reset never follows or removes it"
else fail "a link or a folder at the lock's path is never recorded, so reset never follows or removes it ($link_recorded, $folder_recorded)"; fi
rmdir "$LOCK"

# --- the fakes: a usable speech helper, and mb-transcript ---
fresh; rm -f "$LOCK"
mkdir -p "$SRC_DIR" "$SPEECH_MODELS" "$STATE_DIR" "$HOME/tmp"
record_install "$VOICE_FILE"; record_install "$LOCK"   # as setup records them
cat > "$SPEECH_BIN" <<'EOF'
#!/bin/bash
printf '%s|TMPDIR=%s\n' "$*" "${TMPDIR:-}" >> "$HOME/speech-calls.log"
case "$1" in
  check) [ ! -e "$HOME/check-fails" ] || { echo "mb-speech: a model file is the wrong size" >&2; exit 1; } ;;
  speakers)
    [ ! -e "$HOME/speakers-fail" ] || { echo "mb-speech: the diariser failed" >&2; exit 1; }
    if [ -e "$HOME/speakers-slow" ]; then : > "$HOME/speaking"; sleep 30; fi
    if [ -f "$HOME/speakers.json" ]; then cp "$HOME/speakers.json" "$4"
    else printf '%s\n' '{"model": "m", "segments": [], "speakers": []}' > "$4"; fi ;;
esac
EOF
chmod 700 "$SPEECH_BIN"
FAKE_TRANSCRIPT="$HOME/fake-mb-transcript"
cat > "$FAKE_TRANSCRIPT" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/transcript-calls.log"
[ -f "$2" ] && cp "$2" "$HOME/speakers.seen"
case "$(cat "$HOME/transcript-says" 2>/dev/null)" in
  refused) echo "More than one voice was heard. Record again with only you speaking." >&2; exit 1 ;;
  broken)  echo "mb-transcript: cannot write voice.json.tmp: Permission denied" >&2; exit 1 ;;
  three)   echo "something else went wrong" >&2; exit 3 ;;
  *)       echo "sample 75" ;;
esac
EOF
chmod 700 "$FAKE_TRANSCRIPT"
TRANSCRIPT_BIN="$FAKE_TRANSCRIPT"
printf 'caf' > "$HOME/sample.caf"
voice_reset() { rm -f "$HOME/speech-calls.log" "$HOME/transcript-calls.log" "$HOME/transcript-says" "$HOME/check-fails" \
                      "$HOME/speakers-fail" "$HOME/speakers.seen" "$HOME/speakers.json"; clear_logs; }
# voice add in a subshell, as the command runs it: TMPDIR a scratch folder, so what it leaves there shows.
add_sample() { ( export TMPDIR="$HOME/tmp"; voice_add "${1:-$HOME/sample.caf}" ); }
seen_tmp() { sed -n 's/^speakers .*|TMPDIR=//p' "$HOME/speech-calls.log" | head -n 1; }

# --- parse_args: voice add <audio>, voice forget, engines ---
got="$( (parse_args voice add /x/sample.caf; printf '%s|%s|%s' "$cmd" "$subcmd" "$argfile") 2>&1 )"
got2="$( (parse_args voice forget; printf '%s|%s|%s' "$cmd" "$subcmd" "$argfile") 2>&1 )"
got3="$( (parse_args engines; printf '%s|%s|%s' "$cmd" "$subcmd" "$argfile") 2>&1 )"
got4="$( (parse_args process X --parakeet; printf '%s|%s|%s' "$cmd" "$subcmd" "$argfile") 2>&1 )"
if [ "$got" = "voice|add|/x/sample.caf" ] && [ "$got2" = "voice|forget|" ] && [ "$got3" = "engines||" ] && [ "$got4" = "process||X" ]; then
  pass "parse_args: voice add <audio>, voice forget and engines, and process as before"
else fail "parse_args: voice add <audio>, voice forget and engines, and process as before: $got / $got2 / $got3 / $got4"; fi

# --- voice add ---
voice_reset
out="$(add_sample)"; rc=$?
T="$(seen_tmp)"
speakers_call="$(grep '^speakers ' "$HOME/speech-calls.log")"
if [ "$rc" -eq 0 ] && [ "$out" = "sample 75" ] \
   && [ "$speakers_call" = "speakers $SPEECH_MODELS $T/sample.wav $T/sample.speakers.json|TMPDIR=$T" ] \
   && grep -qxF "afconvert -f WAVE -d LEI16@16000 -c 1 $HOME/sample.caf $T/sample.wav" "$HOME/calls.log" \
   && [ "$(cat "$HOME/transcript-calls.log")" = "--voice-sample $T/sample.speakers.json --voice $VOICE_FILE" ] \
   && case "$T" in "$HOME/tmp/"?*) true ;; *) false ;; esac; then
  pass "voice add: afconvert into a temporary folder, mb-speech speakers there with TMPDIR that folder, then mb-transcript --voice-sample; its line on stdout"
else fail "voice add: afconvert into a temporary folder, mb-speech speakers there with TMPDIR that folder, then mb-transcript --voice-sample; its line on stdout ($rc): $out | $speakers_call | $(cat "$HOME/transcript-calls.log" "$HOME/calls.log")"; fi
if ! grep -q -- '--count' "$HOME/speech-calls.log" && [ -s "$HOME/speakers.seen" ]; then
  pass "voice add: mb-speech is never given --count"
else fail "voice add: mb-speech is never given --count: $(cat "$HOME/speech-calls.log")"; fi
if [ -n "$T" ] && [ ! -e "$T" ] && [ -z "$(ls -A "$HOME/tmp")" ]; then pass "voice add: leaves no temporary folder"
else fail "voice add: leaves no temporary folder: $T $(ls -A "$HOME/tmp")"; fi

voice_reset; echo refused > "$HOME/transcript-says"
out="$(add_sample)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "More than one voice was heard. Record again with only you speaking." ] && [ -z "$(ls -A "$HOME/tmp")" ]; then
  pass "voice add: a refusal passes mb-transcript's one line and status through, and leaves no temporary folder"
else fail "voice add: a refusal passes mb-transcript's one line and status through, and leaves no temporary folder ($rc): $out"; fi
voice_reset; echo broken > "$HOME/transcript-says"
out="$(add_sample)"; rc=$?
voice_reset; echo three > "$HOME/transcript-says"
out3="$(add_sample)"; rc3=$?
if [ "$rc" -eq 1 ] && [ "$out" = "cannot write voice.json.tmp: Permission denied" ] && [ "$rc3" -eq 3 ] && [ "$out3" = "something else went wrong" ]; then
  pass "voice add: mb-transcript's own failures pass through, without its prefix, with its status"
else fail "voice add: mb-transcript's own failures pass through, without its prefix, with its status ($rc, $rc3): $out / $out3"; fi

voice_reset; touch "$HOME/speakers-fail"
out="$(add_sample)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "Your voice could not be found in the sample: the diariser failed" ] && [ ! -e "$HOME/transcript-calls.log" ] \
   && [ -z "$(ls -A "$HOME/tmp")" ]; then
  pass "voice add: when mb-speech fails, its reason in one line, nothing saved, no temporary folder"
else fail "voice add: when mb-speech fails, its reason in one line, nothing saved, no temporary folder ($rc): $out"; fi
voice_reset
out="$(afconvert() { echo "afconvert $*" >> "$HOME/calls.log"; return 1; }; add_sample)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "The recorded sample could not be read." ] && [ -z "$(ls -A "$HOME/tmp")" ]; then
  pass "voice add: a sample afconvert cannot read is refused in one line"
else fail "voice add: a sample afconvert cannot read is refused in one line ($rc): $out"; fi
voice_reset
out="$(add_sample "$HOME/no-such.caf")"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "There is no sample at $HOME/no-such.caf." ] && ! grep -q '^speakers ' "$HOME/speech-calls.log"; then
  pass "voice add: a sample that is not there is refused in one line"
else fail "voice add: a sample that is not there is refused in one line ($rc): $out"; fi

voice_reset; touch "$HOME/check-fails"
out="$(add_sample)"; rc=$?
mv "$SPEECH_BIN" "$SPEECH_BIN.away"
out2="$(add_sample)"; rc2=$?
mv "$SPEECH_BIN.away" "$SPEECH_BIN"
if [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$out" = "Parakeet is not set up, so a voice sample cannot be used. Run meetingbox setup." ] \
   && [ "$out2" = "$out" ] && ! grep -q '^speakers ' "$HOME/speech-calls.log" && [ ! -e "$HOME/transcript-calls.log" ]; then
  pass "voice add: an unusable or missing speech helper is refused with the Parakeet line, and nothing runs"
else fail "voice add: an unusable or missing speech helper is refused with the Parakeet line, and nothing runs ($rc, $rc2): $out / $out2"; fi
voice_reset; forget_install "$VOICE_FILE"
out="$(add_sample)"; rc=$?
record_install "$VOICE_FILE"
if [ "$rc" -eq 1 ] && [ "$out" = "$VOICE_FILE was not made by meetingbox, so a voice sample is not saved there." ] \
   && ! grep -q '^speakers ' "$HOME/speech-calls.log" 2>/dev/null && [ ! -e "$HOME/transcript-calls.log" ]; then
  pass "voice add: a voice print setup did not record is refused, and nothing runs"
else fail "voice add: a voice print setup did not record is refused, and nothing runs ($rc): $out"; fi

# --- voice forget ---
hold_lock() {   # $1: seconds to hold <voice.json>.lock with flock, in the background; waits until it is held
  rm -f "$HOME/held"
  perl -e 'use Fcntl qw(:flock O_RDWR O_CREAT); sysopen(my $fh, $ARGV[0], O_RDWR|O_CREAT, 0600) or die; flock($fh, LOCK_EX) or die;
           open(my $r, ">", $ARGV[1]) or die; close $r; select(undef, undef, undef, $ARGV[2]);' "$LOCK" "$HOME/held" "$1" &
  HOLDER=$!
  for _ in $(seq 1 200); do [ -e "$HOME/held" ] && break; sleep 0.02; done
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
voice_reset; rm -f "$LOCK"
echo '{"seconds": 75}' > "$VOICE_FILE"; echo stale > "$VOICE_FILE.tmp"
out="$( (voice_forget) )"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$VOICE_FILE" ] && [ ! -e "$VOICE_FILE.tmp" ] && installed_by_us "$VOICE_FILE" \
   && [ -f "$LOCK" ] && [ "$(mode "$LOCK")" = 600 ] && installed_by_us "$LOCK"; then
  pass "voice forget: removes the recorded print and its voice.json.tmp, keeps the record line, and the lock file (0600) stays"
else fail "voice forget: removes the recorded print and its voice.json.tmp, keeps the record line, and the lock file (0600) stays ($rc): $out"; fi
out="$( (voice_forget) )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "voice forget: with no print to forget it succeeds"; else fail "voice forget: with no print to forget it succeeds ($rc): $out"; fi
echo '{"seconds": 75}' > "$VOICE_FILE"
forget_install "$VOICE_FILE"
out="$( (voice_forget) )"; rc=$?
record_install "$VOICE_FILE"
if [ "$rc" -eq 1 ] && [ -e "$VOICE_FILE" ] && [ "$out" = "$VOICE_FILE was not made by meetingbox, so it is left alone." ]; then
  pass "voice forget: refuses a voice print setup did not record, in one line"
else fail "voice forget: refuses a voice print setup did not record, in one line ($rc): $out"; fi

hold_lock 1.5
start="$(now)"
out="$( (VOICE_LOCK_WAIT=10; voice_forget) )"; rc=$?
waited="$(perl -e "print $(now) - $start >= 1.0 ? 1 : 0")"
wait "$HOLDER" 2>/dev/null
if [ "$rc" -eq 0 ] && [ "$waited" = 1 ] && [ ! -e "$VOICE_FILE" ]; then
  pass "voice forget: waits while another writer holds the lock, then forgets"
else fail "voice forget: waits while another writer holds the lock, then forgets ($rc, waited $waited): $out"; fi
echo '{"seconds": 75}' > "$VOICE_FILE"
hold_lock 5
out="$( (VOICE_LOCK_WAIT=1; voice_forget) )"; rc=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
if [ "$rc" -eq 1 ] && [ -e "$VOICE_FILE" ] && [ "$out" = "Your voice print is being saved right now, so it was not forgotten. Try again." ]; then
  pass "voice forget: when the lock is not free in time it refuses in one line and forgets nothing"
else fail "voice forget: when the lock is not free in time it refuses in one line and forgets nothing ($rc): $out"; fi
rm -f "$LOCK"; ln -s "$HOME/elsewhere" "$LOCK"
out="$( (voice_forget) )"; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$VOICE_FILE" ] && [ ! -e "$HOME/elsewhere" ] && [ "$out" = "$LOCK is not a plain file, so your voice was not forgotten." ]; then
  pass "voice forget: a link at the lock's path is never followed, and nothing is forgotten"
else fail "voice forget: a link at the lock's path is never followed, and nothing is forgotten ($rc): $out"; fi
rm -f "$LOCK"

# --- engines ---
engines_out() { ( have() { [ "$1" = speech-analyzer ] && [ -z "${NO_SA:-}" ]; }; engines_cmd ) 2>/dev/null; }
voice_reset; rm -f "$VOICE_FILE"
out="$(engines_out)"
printf '%s\n' '{"model": "m", "seconds": 75.4, "meetings": 1, "sources": [], "sample": true, "refusals": 0, "vector": [1], "updated": "x"}' > "$VOICE_FILE"
out2="$(engines_out)"
if [ "$out" = "$(printf 'parakeet ready\napple ready\nvoice none\noutside-runtime unavailable outside models are not set up')" ] && [ "$out2" = "$(printf 'parakeet ready\napple ready\nvoice 75 1 sample\noutside-runtime unavailable outside models are not set up')" ] \
   && ! grep -q '^curl' "$HOME/calls.log"; then
  pass "engines: the parakeet, apple, voice and outside-runtime lines, with no network call"
else fail "engines: the parakeet, apple, voice and outside-runtime lines, with no network call: $out / $out2 / $(cat "$HOME/calls.log")"; fi
touch "$HOME/check-fails"
out="$(NO_SA=1 engines_out)"
rm -f "$HOME/check-fails"; mv "$SPEECH_BIN" "$SPEECH_BIN.away"
out2="$(engines_out)"
mv "$SPEECH_BIN.away" "$SPEECH_BIN"
if [ "$out" = "$(printf 'parakeet unavailable a model file is the wrong size\napple unavailable speech-analyzer is not installed\nvoice 75 1 sample\noutside-runtime unavailable outside models are not set up')" ] \
   && [ "$(printf '%s\n' "$out2" | head -n 1)" = "parakeet unavailable the speech helper is not installed" ]; then
  pass "engines: unavailable, each with its reason in one line"
else fail "engines: unavailable, each with its reason in one line: $out / $out2"; fi

# --- the commands as the app runs them: the whole script, under set -e ---
mkdir -p "$HOME/fakebin"
printf '#!/bin/bash\n: > "${!#}"\n' > "$HOME/fakebin/afconvert"; chmod 700 "$HOME/fakebin/afconvert"
cp "$FAKE_TRANSCRIPT" "$SRC_DIR/mb-transcript"
script() { env -i HOME="$HOME" PATH="$HOME/fakebin:/usr/bin:/bin" TMPDIR="$HOME/tmp" /bin/bash "$ROOT/meetingbox" "$@" 2>/dev/null; }
voice_reset
out="$(script voice add "$HOME/sample.caf")"; rc=$?
echo refused > "$HOME/transcript-says"
out2="$(script voice add "$HOME/sample.caf")"; rc2=$?
if [ "$rc" -eq 0 ] && [ "$out" = "sample 75" ] && [ "$rc2" -eq 1 ] && [ "$out2" = "More than one voice was heard. Record again with only you speaking." ] \
   && [ -z "$(ls -A "$HOME/tmp")" ]; then
  pass "meetingbox voice add: one line on stdout and mb-transcript's status, as the app reads them"
else fail "meetingbox voice add: one line on stdout and mb-transcript's status, as the app reads them ($rc, $rc2): $out / $out2"; fi
echo '{"seconds": 75}' > "$VOICE_FILE"
out="$(script voice forget)"; rc=$?
out2="$(script voice)"; rc2=$?
if [ "$rc" -eq 0 ] && [ ! -e "$VOICE_FILE" ] && [ "$rc2" -ne 0 ]; then
  pass "meetingbox voice forget: forgets; meetingbox voice alone is a usage error"
else fail "meetingbox voice forget: forgets; meetingbox voice alone is a usage error ($rc, $rc2): $out / $out2"; fi
out="$(script engines)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | head -n 1)" = "parakeet ready" ] && [ "$(printf '%s\n' "$out" | sed -n 3p)" = "voice none" ]; then
  pass "meetingbox engines: runs to the end under set -e"
else fail "meetingbox engines: runs to the end under set -e ($rc): $out"; fi

# --- the app's limit: SIGTERM to voice add's whole process group, as ScriptEngineCommands sends it ---
voice_reset; rm -f "$HOME/speaking"; touch "$HOME/speakers-slow"
perl -e 'setpgrp(0, 0); exec @ARGV or die' env -i HOME="$HOME" PATH="$HOME/fakebin:/usr/bin:/bin" TMPDIR="$HOME/tmp" \
  /bin/bash "$ROOT/meetingbox" voice add "$HOME/sample.caf" > "$HOME/term.out" 2>/dev/null &
group=$!
for _ in $(seq 1 250); do [ -e "$HOME/speaking" ] && break; sleep 0.02; done
during="$(ls -A "$HOME/tmp")"
kill -TERM -- "-$group" 2>/dev/null
wait "$group"; rc=$?
rm -f "$HOME/speakers-slow"
if [ -e "$HOME/speaking" ] && [ -n "$during" ] && [ "$rc" -eq 143 ] && [ -z "$(ls -A "$HOME/tmp")" ] && [ ! -e "$HOME/transcript-calls.log" ]; then
  pass "voice add: SIGTERM to its process group while mb-speech runs exits 143 and removes its temporary folder"
else fail "voice add: SIGTERM to its process group while mb-speech runs exits 143 and removes its temporary folder ($rc, during: $during, after: $(ls -A "$HOME/tmp"))"; fi

# --- the real mb-transcript --voice-sample, when tests/run.sh built it ---
if [ -n "${MB_TEST_BIN:-}" ] && [ -x "$MB_TEST_BIN/mb-transcript" ]; then
  REAL="$MB_TEST_BIN/mb-transcript"
  one='{"model": "m@1", "segments": [{"speaker": "S1", "start": 0, "end": 75.4}], "speakers": [{"id": "S1", "seconds": 75.4, "median": 6, "vector": [3, 4, 0, 0]}]}'
  two='{"model": "m@1", "segments": [], "speakers": [{"id": "S1", "seconds": 80, "median": 5, "vector": [1, 0, 0, 0]}, {"id": "S2", "seconds": 20, "median": 4, "vector": [0, 0, 1, 0]}]}'
  printf '%s\n' "$one" > "$HOME/one.json"; printf '%s\n' "$two" > "$HOME/two.json"
  printf '%s\n' '{"model": "m@1", "seconds": 391, "meetings": 3, "sources": ["a", "b", "c"], "sample": false, "refusals": 0, "refused": [], "vector": [0, 0, 1, 0], "updated": "x"}' > "$VOICE_FILE"
  rm -f "$LOCK"
  out="$("$REAL" --voice-sample "$HOME/one.json" --voice "$VOICE_FILE" 2>"$HOME/real.err")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "sample 75" ] && [ ! -s "$HOME/real.err" ] && [ ! -e "$VOICE_FILE.tmp" ] && [ "$(mode "$VOICE_FILE")" = 600 ] \
     && [ "$(jq -c '[.sample, .meetings, .sources, .seconds, .model]' "$VOICE_FILE")" = '[true,1,[],75.4,"m@1"]' ] \
     && [ -f "$LOCK" ] && [ "$(mode "$LOCK")" = 600 ]; then
    pass "mb-transcript --voice-sample: replaces a learnt print through voice.json.tmp, prints sample 75, under the lock"
  else fail "mb-transcript --voice-sample: replaces a learnt print through voice.json.tmp, prints sample 75, under the lock ($rc): $out $(cat "$HOME/real.err" "$VOICE_FILE")"; fi
  cp "$VOICE_FILE" "$HOME/voice.before"
  out="$("$REAL" --voice-sample "$HOME/two.json" --voice "$VOICE_FILE" 2>"$HOME/real.err")"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ] && [ "$(cat "$HOME/real.err")" = "More than one voice was heard. Record again with only you speaking." ] \
     && cmp -s "$VOICE_FILE" "$HOME/voice.before"; then
    pass "mb-transcript --voice-sample: a refusal is one stderr line, exit 1, and voice.json byte-identical"
  else fail "mb-transcript --voice-sample: a refusal is one stderr line, exit 1, and voice.json byte-identical ($rc): $out / $(cat "$HOME/real.err")"; fi
  "$REAL" --voice-sample "$HOME/one.json" --voice "$VOICE_FILE" --mic "$HOME/one.json" >/dev/null 2>&1; rc=$?
  "$REAL" --voice-sample "$HOME/one.json" >/dev/null 2>&1; rc2=$?
  if [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && cmp -s "$VOICE_FILE" "$HOME/voice.before"; then
    pass "mb-transcript --voice-sample: with transcript arguments, or without --voice, it is a usage error and writes nothing"
  else fail "mb-transcript --voice-sample: with transcript arguments, or without --voice, it is a usage error and writes nothing ($rc, $rc2)"; fi
  voice_reset; printf '%s\n' "$one" > "$HOME/speakers.json"; rm -f "$VOICE_FILE"
  out="$(TRANSCRIPT_BIN="$REAL"; add_sample)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "sample 75" ] && [ "$(jq -r .sample "$VOICE_FILE")" = true ] && [ -z "$(ls -A "$HOME/tmp")" ]; then
    pass "voice add with the real mb-transcript: the sample becomes the print"
  else fail "voice add with the real mb-transcript: the sample becomes the print ($rc): $out"; fi
else
  echo "note: the real mb-transcript was not built (run tests/run.sh), so its --voice-sample checks were skipped"
fi

# --- the app's side: no test makes the real sampler or engine, and only AppDelegate passes them ---
first="$(head -n 1 "$ROOT/native/tests/app/main.swift")"
if ! grep -qE 'MicSampleRecorder *\(|ScriptEngineCommands *\(' "$ROOT/native/tests/app/main.swift" \
   && printf '%s' "$first" | grep -qF '../../app/VoiceSample.swift' && ! printf '%s' "$first" | grep -qF 'MicSample.swift' \
   && grep -qF 'engine: ScriptEngineCommands.fromBundle() ?? NoEngineCommands()' "$ROOT/native/app/AppDelegate.swift" \
   && grep -qF 'sampler: MicSampleRecorder()' "$ROOT/native/app/AppDelegate.swift" \
   && [ "$(grep -rlE 'MicSampleRecorder\(\)|ScriptEngineCommands\.fromBundle\(' "$ROOT/native/app" | xargs -n 1 basename | sort | tr '\n' ' ')" = "AppDelegate.swift " ]; then
  pass "only AppDelegate makes MicSampleRecorder and ScriptEngineCommands; no app test does, and MicSample.swift is not in the tests' sources"
else fail "only AppDelegate makes MicSampleRecorder and ScriptEngineCommands; no app test does, and MicSample.swift is not in the tests' sources"; fi
if grep -qx 'import Foundation' "$ROOT/native/app/VoiceSample.swift" && ! grep -qE '^import (AVFoundation|AppKit|SwiftUI|CoreMedia)' "$ROOT/native/app/VoiceSample.swift" \
   && grep -qx 'import AVFoundation' "$ROOT/native/app/MicSample.swift"; then
  pass "VoiceSample.swift is Foundation only; MicSample.swift is the AVFoundation part"
else fail "VoiceSample.swift is Foundation only; MicSample.swift is the AVFoundation part"; fi

# --- the top bar: its rules and words are Foundation only, and only AppDelegate gives a player the real audio ---
if [ "$(grep -c '^import ' "$ROOT/native/app/TopBarPresentation.swift")" = 1 ] && grep -qx 'import Foundation' "$ROOT/native/app/TopBarPresentation.swift" \
   && grep -q '^enum PlayerState' "$ROOT/native/app/TopBarPresentation.swift" && grep -qx 'import AVFoundation' "$ROOT/native/app/Player.swift"; then
  pass "TopBarPresentation.swift (with PlayerState) is Foundation only; Player.swift is the AVFoundation part"
else fail "TopBarPresentation.swift (with PlayerState) is Foundation only; Player.swift is the AVFoundation part"; fi
if [ "$(grep -rlE 'SystemAudio *\(' "$ROOT/native/app" | xargs -n 1 basename | sort | tr '\n' ' ')" = "AppDelegate.swift " ] \
   && grep -qF 'player: Player(audio: SystemAudio(), tickQueue: .main))' "$ROOT/native/app/AppDelegate.swift" \
   && [ "$(grep -cE 'SystemAudio *\(' "$ROOT/native/tests/app/main.swift")" = 1 ] \
   && ! grep -qE 'Player\(audio: *SystemAudio' "$ROOT/native/tests/app/main.swift"; then
  pass "only AppDelegate gives a Player the real SystemAudio; the app test makes one only to see it refuse files"
else fail "only AppDelegate gives a Player the real SystemAudio; the app test makes one only to see it refuse files"; fi

finish
