# Shared test setup. A test file is:
#   #!/bin/bash
#   . "$(dirname "$0")/lib.sh"
#   ...checks...
#   finish
# Never touches the real HOME: everything runs in a scratch folder with stubs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"
HOME="$(mktemp -d)"
export HOME
LSREGISTER=/usr/bin/true
: > "$HOME/calls.log"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; }
finish() {
  printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
  exit $?
}

# Everything from the main marker onwards is left out, so only functions load.
# shellcheck disable=SC1090
sed '/^# -* main$/,$d' "$ROOT/meetingbox" > "$HOME/meetingbox.functions"
. "$HOME/meetingbox.functions"
set +e   # the script sets -e; a failing check must not end the test file

tccutil()  { echo "tccutil $*" >> "$HOME/calls.log"; return 0; }
confirm()  { echo "confirm $*" >> "$HOME/calls.log"; return 0; }
codesign() { echo "codesign $*" >> "$HOME/calls.log"; return 0; }
security() { echo "security $*" >> "$HOME/calls.log"; return 0; }
openssl()  { echo "openssl $*" >> "$HOME/calls.log"; return 0; }
