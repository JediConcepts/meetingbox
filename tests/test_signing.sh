#!/bin/bash
. "$(dirname "$0")/lib.sh"

mkdir -p "$STATE_DIR"
ENTRY="keychain:$SIGN_NAME"
OPENSSL=openssl   # the lib.sh stub, not /usr/bin/openssl

# security stub: find-certificate fails until import has been called.
security() {
  echo "security $*" >> "$HOME/calls.log"
  case "$1" in
    find-certificate) [ -f "$HOME/imported" ] ;;
    import) : > "$HOME/imported" ;;
    *) return 0 ;;
  esac
}

# --- fresh: no certificate yet, so one is made and recorded ---
TMPDIR="$(mktemp -d)"; export TMPDIR
: > "$HOME/calls.log"; rm -f "$HOME/imported"
ensure_signing_identity
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^openssl req' "$HOME/calls.log" \
   && grep -q '^security import .* -T /usr/bin/codesign' "$HOME/calls.log" \
   && installed_by_us "$ENTRY"; then
  pass "fresh: certificate created and recorded"
else fail "fresh: certificate created and recorded"; fi
if [ -z "$(ls -A "$TMPDIR")" ]; then pass "fresh: no temporary folder left behind"
else fail "fresh: no temporary folder left behind"; fi
rmdir "$TMPDIR"

# --- existing but not ours: used, not imported, not recorded ---
forget_install "$ENTRY"
: > "$HOME/imported"; : > "$HOME/calls.log"
ensure_signing_identity
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^security import' "$HOME/calls.log" \
   && ! grep -q '^openssl' "$HOME/calls.log" && ! installed_by_us "$ENTRY"; then
  pass "existing certificate not ours: used, nothing recorded"
else fail "existing certificate not ours: used, nothing recorded"; fi

# --- reset tools removes a recorded certificate, never via rm ---
APP_DIR="$HOME/none.app"
record_install "$ENTRY"
mkdir "$HOME/gone"; record_install "$HOME/gone"
rm() { echo "rm $*" >> "$HOME/calls.log"; command rm "$@"; }
: > "$HOME/calls.log"
out="$(cd "$HOME" && reset_cmd tools 2>&1)"
if grep -qxF "security delete-identity -c $SIGN_NAME $SIGN_KEYCHAIN" "$HOME/calls.log" \
   && ! installed_by_us "$ENTRY" && [ ! -e "$HOME/gone" ]; then
  pass "reset tools deletes the certificate and drops it from the record"
else fail "reset tools deletes the certificate and drops it from the record"; fi
if ! grep -q '^rm .*keychain:' "$HOME/calls.log"; then pass "keychain entry never passed to rm"
else fail "keychain entry never passed to rm"; fi
if printf '%s\n' "$out" | grep -q 'the meetingbox signing certificate in your login keychain' \
   && ! printf '%s\n' "$out" | grep -q 'warn'; then
  pass "reset lists the certificate and warns about nothing"
else fail "reset lists the certificate and warns about nothing"; fi
unset -f rm

# not recorded: reset leaves someone else's certificate alone
: > "$HOME/calls.log"
remove_signing_identity
if ! grep -q 'delete-identity' "$HOME/calls.log"; then pass "unrecorded certificate kept"
else fail "unrecorded certificate kept"; fi

# delete-identity fails: a certificate already gone is forgotten, one still there is kept on the record
security() {
  echo "security $*" >> "$HOME/calls.log"
  case "$1" in
    find-certificate) [ -f "$HOME/imported" ] ;;
    delete-identity) return 1 ;;
    *) return 0 ;;
  esac
}
record_install "$ENTRY"; rm -f "$HOME/imported"
remove_signing_identity 2>/dev/null
if ! installed_by_us "$ENTRY"; then pass "certificate already gone is dropped from the record"
else fail "certificate already gone is dropped from the record"; fi
record_install "$ENTRY"; : > "$HOME/imported"
out="$(remove_signing_identity 2>&1)"
if installed_by_us "$ENTRY" && printf '%s\n' "$out" | grep -q 'Keychain Access'; then
  pass "certificate that will not delete stays recorded, with a warning"
else fail "certificate that will not delete stays recorded, with a warning"; fi
forget_install "$ENTRY"

# --- build_app signs with the certificate, or falls back to ad hoc ---
APP_DIR="$HOME/meetingbox.app"; APP_BIN="$APP_DIR/Contents/MacOS/audio-capture"
printf '#!/bin/sh\n' > "$HOME/rec"
: > "$HOME/imported"

: > "$HOME/calls.log"
build_app "$HOME/rec" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "^codesign --force --sign $SIGN_NAME --identifier $APP_ID " "$HOME/calls.log" \
   && ! grep -q -- '--sign - ' "$HOME/calls.log"; then
  pass "build_app signs with the meetingbox certificate"
else fail "build_app signs with the meetingbox certificate"; fi

codesign() {
  echo "codesign $*" >> "$HOME/calls.log"
  case "$*" in *"--sign $SIGN_NAME "*) return 1 ;; esac
  return 0
}
: > "$HOME/calls.log"
out="$(build_app "$HOME/rec" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "^codesign --force --sign - --identifier $APP_ID " "$HOME/calls.log" \
   && printf '%s\n' "$out" | grep -q 'could not use the meetingbox signing certificate'; then
  pass "build_app falls back to ad hoc and warns"
else fail "build_app falls back to ad hoc and warns"; fi

finish
