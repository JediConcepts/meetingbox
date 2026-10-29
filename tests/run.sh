#!/bin/bash
# Runs the native tests (if present), then every tests/test_*.sh.
here="$(cd "$(dirname "$0")" && pwd)"
# Native test binaries (mb-transcript) go in MB_TEST_BIN; remove it only if we made it.
made_bin=0
if [ -z "${MB_TEST_BIN:-}" ]; then
  MB_TEST_BIN="$(mktemp -d)"
  made_bin=1
fi
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
[ "$made_bin" -eq 1 ] && rm -rf "$MB_TEST_BIN"
exit $rc
