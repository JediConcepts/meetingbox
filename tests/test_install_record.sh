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

for bad in "" / "$HOME"; do
  remove_installed "$bad" 2>/dev/null
  if [ $? -ne 0 ] && [ -d "$HOME" ]; then pass "refused '$bad'"; else fail "refused '$bad'"; fi
done

finish
