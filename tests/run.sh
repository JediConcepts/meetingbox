#!/bin/bash
# Runs the native tests (if present), then every tests/test_*.sh.
here="$(cd "$(dirname "$0")" && pwd)"
MB_TEST_BIN="$(mktemp -d)"
export MB_TEST_BIN
rc=0
if [ -f "$here/../native/tests/run.sh" ]; then
  bash "$here/../native/tests/run.sh" || rc=1
fi
for t in "$here"/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t")"
  bash "$t" || rc=1
done
exit $rc
