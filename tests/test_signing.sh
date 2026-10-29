#!/bin/bash
. "$(dirname "$0")/lib.sh"

# The certificate is known by its SHA-1, never by its name: a name is matched as a
# substring, so it could reach a certificate the user made.

mkdir -p "$STATE_DIR"
OPENSSL=openssl   # the stub below, not /usr/bin/openssl
have() { return 1; }   # doctor must not run the real fm or brew
HASH=AABBCCDDEEFF00112233445566778899AABBCCDD
OTHER=1111111111111111111111111111111111111111
ENTRY="keychain:sha1:$HASH"
LEGACY="keychain:$SIGN_NAME"

# openssl stub: the certificate it makes has the fingerprint $FP.
FP="AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"
openssl() {
  echo "openssl $*" >> "$HOME/calls.log"
  case "$1" in x509) echo "SHA1 Fingerprint=$FP" ;; esac
  return 0
}

# security stub: the keychain is $HOME/kc, one identity hash per line, all named
# "meetingbox local signing". import adds $HASH; delete-identity -Z removes one.
: > "$HOME/kc"
security() {
  echo "security $*" >> "$HOME/calls.log"; echo "security $*" >> "$HOME/security-all.log"
  case "$1" in
    find-identity)
      echo "Policy: Code Signing"; echo "  Matching identities"
      n=0
      while IFS= read -r h; do
        n=$((n + 1)); echo "  $n) $h \"$SIGN_NAME\" (CSSMERR_TP_NOT_TRUSTED)"
      done < "$HOME/kc"
      echo "     $n identities found" ;;
    import) echo "$HASH" >> "$HOME/kc" ;;
    delete-identity)
      [ "$2" = -Z ] && grep -qxF "$3" "$HOME/kc" || return 1
      grep -vxF "$3" "$HOME/kc" > "$HOME/kc.tmp"; mv "$HOME/kc.tmp" "$HOME/kc" ;;
    *) return 0 ;;
  esac
}
security_named() { grep '^security ' "$HOME/calls.log" | grep -q -- "$1"; }

# --- fresh: no certificate yet, so one is made and recorded by its hash ---
TMPDIR="$(mktemp -d)"; export TMPDIR
: > "$HOME/calls.log"
ensure_signing_identity 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^openssl req' "$HOME/calls.log" \
   && grep -q '^openssl x509 .*-fingerprint -sha1' "$HOME/calls.log" \
   && grep -q '^security import .* -T /usr/bin/codesign' "$HOME/calls.log" \
   && installed_by_us "$ENTRY" && [ "$(signing_hash)" = "$HASH" ]; then
  pass "fresh: certificate created and recorded by its SHA-1"
else fail "fresh: certificate created and recorded by its SHA-1"; fi
if [ -z "$(ls -A "$TMPDIR")" ]; then pass "fresh: no temporary folder left behind"
else fail "fresh: no temporary folder left behind"; fi
rmdir "$TMPDIR"; unset TMPDIR

if have_signing_identity; then pass "have_signing_identity: recorded hash listed"
else fail "have_signing_identity: recorded hash listed"; fi

# --- ours already there: nothing made ---
: > "$HOME/calls.log"
ensure_signing_identity 2>/dev/null
if [ $? -eq 0 ] && ! grep -q '^openssl' "$HOME/calls.log" && ! security_named import; then
  pass "ours already there: used as it is"
else fail "ours already there: used as it is"; fi

# --- a fingerprint that is not 40 upper-case hex characters: nothing imported or recorded ---
forget_install "$ENTRY"; : > "$HOME/kc"; : > "$HOME/calls.log"
FP="not a fingerprint"
ensure_signing_identity 2>/dev/null
if [ $? -ne 0 ] && ! security_named import && [ -z "$(signing_hash)" ]; then
  pass "bad fingerprint: nothing imported or recorded"
else fail "bad fingerprint: nothing imported or recorded"; fi
FP="AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"

# --- someone else's certificate with the same name: ours is made, theirs never touched ---
echo "$OTHER" > "$HOME/kc"; : > "$HOME/calls.log"
if ! have_signing_identity; then pass "have_signing_identity: nothing recorded, a same-named one is not ours"
else fail "have_signing_identity: nothing recorded, a same-named one is not ours"; fi
ensure_signing_identity 2>/dev/null
if [ $? -eq 0 ] && grep -q '^openssl req' "$HOME/calls.log" && installed_by_us "$ENTRY" \
   && ! security_named "$OTHER"; then
  pass "same-named certificate not ours: a new one made and recorded, the other never named"
else fail "same-named certificate not ours: a new one made and recorded, the other never named"; fi

# --- recorded but gone: the line is forgotten and a new one made ---
echo "$OTHER" > "$HOME/kc"; : > "$HOME/calls.log"
if ! have_signing_identity; then pass "have_signing_identity: recorded hash not listed"
else fail "have_signing_identity: recorded hash not listed"; fi
ensure_signing_identity 2>/dev/null
if [ $? -eq 0 ] && grep -q '^openssl req' "$HOME/calls.log" && grep -qxF "$HASH" "$HOME/kc" \
   && [ "$(grep -c '^keychain:sha1:' "$INSTALLED")" = 1 ]; then
  pass "recorded but gone: made again, recorded once"
else fail "recorded but gone: made again, recorded once"; fi

# --- a line from a development build names the certificate: forgotten, never deleted by ---
record_install "$LEGACY"; : > "$HOME/calls.log"
ensure_signing_identity 2>/dev/null
if ! installed_by_us "$LEGACY" && ! grep -q 'delete-identity' "$HOME/calls.log"; then
  pass "a name-only record is forgotten by setup, nothing deleted"
else fail "a name-only record is forgotten by setup, nothing deleted"; fi

# --- doctor: ok only when the recorded hash is listed ---
out="$(doctor 2>&1)"
if printf '%s\n' "$out" | grep -q '+.* signing certificate'; then pass "doctor: certificate ok when listed"
else fail "doctor: certificate ok when listed"; fi
echo "$OTHER" > "$HOME/kc"
out="$(doctor 2>&1)"
if printf '%s\n' "$out" | grep -q -- '-.* signing certificate'; then pass "doctor: certificate missing when not listed"
else fail "doctor: certificate missing when not listed"; fi

# --- reset tools deletes ours by hash, never via rm, never by name ---
printf '%s\n%s\n' "$OTHER" "$HASH" > "$HOME/kc"
APP_DIR="$HOME/none.app"
mkdir "$HOME/gone"; record_install "$HOME/gone"
rm() { echo "rm $*" >> "$HOME/calls.log"; command rm "$@"; }
: > "$HOME/calls.log"
out="$(cd "$HOME" && reset_cmd tools 2>&1)"
if grep -qxF "security delete-identity -Z $HASH $SIGN_KEYCHAIN" "$HOME/calls.log" \
   && ! installed_by_us "$ENTRY" && [ ! -e "$HOME/gone" ] && grep -qxF "$OTHER" "$HOME/kc"; then
  pass "reset tools deletes the certificate by hash and drops it from the record"
else fail "reset tools deletes the certificate by hash and drops it from the record"; fi
if ! grep -q '^rm .*keychain:' "$HOME/calls.log"; then pass "keychain entry never passed to rm"
else fail "keychain entry never passed to rm"; fi
if printf '%s\n' "$out" | grep -q 'the meetingbox signing certificate in your login keychain' \
   && ! printf '%s\n' "$out" | grep -q 'warn'; then
  pass "reset lists the certificate and warns about nothing"
else fail "reset lists the certificate and warns about nothing"; fi
unset -f rm

# --- ours recorded but gone, a same-named one present: forgotten, the other never named ---
record_install "$ENTRY"; echo "$OTHER" > "$HOME/kc"; : > "$HOME/calls.log"
remove_signing_identity 2>/dev/null
if ! installed_by_us "$ENTRY" && ! security_named "$OTHER" && grep -qxF "$OTHER" "$HOME/kc"; then
  pass "ours gone, same-named one present: ours forgotten, the other never named"
else fail "ours gone, same-named one present: ours forgotten, the other never named"; fi

# not recorded: reset leaves someone else's certificate alone
: > "$HOME/calls.log"
remove_signing_identity
if ! grep -q 'delete-identity' "$HOME/calls.log"; then pass "unrecorded certificate kept"
else fail "unrecorded certificate kept"; fi

# a name-only record is forgotten and nothing is deleted by it
record_install "$LEGACY"; : > "$HOME/calls.log"
remove_signing_identity
if ! installed_by_us "$LEGACY" && ! grep -q 'delete-identity' "$HOME/calls.log"; then
  pass "reset: a name-only record is forgotten, nothing deleted"
else fail "reset: a name-only record is forgotten, nothing deleted"; fi

# delete-identity fails and ours is still listed: kept on the record, with a warning
security() {
  echo "security $*" >> "$HOME/calls.log"; echo "security $*" >> "$HOME/security-all.log"
  case "$1" in
    find-identity) echo "  1) $HASH \"$SIGN_NAME\" (CSSMERR_TP_NOT_TRUSTED)" ;;
    delete-identity) return 1 ;;
    *) return 0 ;;
  esac
}
record_install "$ENTRY"
out="$(remove_signing_identity 2>&1)"
if installed_by_us "$ENTRY" && printf '%s\n' "$out" | grep -q 'Keychain Access'; then
  pass "certificate that will not delete stays recorded, with a warning"
else fail "certificate that will not delete stays recorded, with a warning"; fi

# --- build_app signs with the certificate's hash in the login keychain, or falls back to ad hoc ---
APP_DIR="$HOME/meetingbox.app"; APP_BIN="$APP_DIR/Contents/MacOS/audio-capture"
printf '#!/bin/sh\n' > "$HOME/rec"

: > "$HOME/calls.log"
build_app "$HOME/rec" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q -- "^codesign --force --sign $HASH --keychain $SIGN_KEYCHAIN --identifier $APP_ID " "$HOME/calls.log" \
   && ! grep -q -- '--sign - ' "$HOME/calls.log"; then
  pass "build_app signs with the certificate's hash"
else fail "build_app signs with the certificate's hash"; fi

codesign() {
  echo "codesign $*" >> "$HOME/calls.log"
  case "$*" in *"--sign $HASH "*) return 1 ;; esac
  return 0
}
: > "$HOME/calls.log"
out="$(build_app "$HOME/rec" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "^codesign --force --sign - --identifier $APP_ID " "$HOME/calls.log" \
   && printf '%s\n' "$out" | grep -q 'could not use the meetingbox signing certificate'; then
  pass "build_app falls back to ad hoc and warns"
else fail "build_app falls back to ad hoc and warns"; fi

# never by name, in any security call this file made
if grep -q 'delete-identity -Z' "$HOME/security-all.log" \
   && ! grep -q 'delete-identity -c' "$HOME/security-all.log"; then pass "no delete-identity -c call"
else fail "no delete-identity -c call"; fi

finish
