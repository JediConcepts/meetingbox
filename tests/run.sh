#!/bin/bash
# Runs the native tests (if present), every tests/test_*.sh and the node --test suite for
# minutes/writer.mjs. Each test file has its own scratch HOME (tests/lib.sh), and each native test
# builds in its own folder, so they all run side by side; each one's output is printed whole, in
# order, once all are done. MB_TEST_SERIAL=1 runs everything one at a time, as before.
here="$(cd "$(dirname "$0")" && pwd)"
# Native test binaries (mb-transcript) go in MB_TEST_BIN; remove it only if we made it.
made_bin=0
if [ -z "${MB_TEST_BIN:-}" ]; then
  MB_TEST_BIN="$(mktemp -d)"
  made_bin=1
fi
export MB_TEST_BIN
rc=0
logs="$(mktemp -d)" || exit 1
native="$here/../native/tests/run.sh"

# start <log name> <command...>: output in $logs/<name>.out, exit status in $logs/<name>.rc;
# in the background unless MB_TEST_SERIAL=1.
start() {
  local name="$1"; shift
  if [ "${MB_TEST_SERIAL:-}" = 1 ]; then
    "$@" > "$logs/$name.out" 2>&1; echo $? > "$logs/$name.rc"
  else
    { "$@" < /dev/null > "$logs/$name.out" 2>&1; echo $? > "$logs/$name.rc"; } &
  fi
}

if [ -f "$native" ]; then
  # The bash tests use the real mb-transcript, so it is built before they start.
  echo "== build mb-transcript"
  if ! swiftc -suppress-warnings -o "$MB_TEST_BIN/mb-transcript" "$here"/../native/transcript/*.swift; then
    echo "FAIL mb-transcript: does not compile"
    rc=1
  fi
  # MB_TEST_BIN is left out so the native step does not build mb-transcript a second time.
  start 0-native env -u MB_TEST_BIN bash "$native"
fi
for t in "$here"/test_*.sh; do
  [ -e "$t" ] || continue
  start "1-$(basename "$t")" bash "$t"
done

# writer.mjs's own suite, against the real router: the script, its package files, its tests and the
# shared address table are copied into a temporary folder, npm installs the locked router there, and
# node --test runs there. npm runs as the Node found running npm's own script (its launcher would
# start whichever node is first on the PATH), with its cache and a home of its own in the temporary
# folder, which goes afterwards. Without a Node 20 or later, or when the install fails (offline, say),
# the suite is skipped and says why.
node_tests() {
  local minutes="$here/../minutes" node="" d v npm_cli tmp status=0
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] && [ -f "$d/node" ] && [ -x "$d/node" ] || continue
    v="$("$d/node" --version 2>/dev/null)" || continue
    case "$v" in v[0-9]*.*) ;; *) continue ;; esac
    v="${v#v}"
    [ "${v%%.*}" -ge 20 ] 2>/dev/null || continue
    node="$d/node"
    break
  done
  IFS=$' \t\n'
  [ -n "$node" ] || { echo "node tests skipped: no Node 20 or later on the PATH"; return 0; }
  npm_cli="$(realpath "$(dirname "$node")/npm" 2>/dev/null)" && [ -f "$npm_cli" ] \
    || { echo "node tests skipped: there is no npm beside $node"; return 0; }
  tmp="$(mktemp -d)" || { echo "node tests skipped: no temporary folder"; return 0; }
  mkdir "$tmp/home" "$tmp/work"
  cp "$minutes/writer.mjs" "$minutes/package.json" "$minutes/package-lock.json" "$tmp/work/" \
    && cp -R "$minutes/test" "$tmp/work/test" && cp "$here/fixtures/addresses.txt" "$tmp/work/addresses.txt" \
    || { rm -rf "$tmp"; echo "node tests: FAIL, the script or its tests could not be copied"; return 1; }
  if ! (cd "$tmp/work" && HOME="$tmp/home" "$node" "$npm_cli" ci --ignore-scripts --omit=dev --cache "$tmp/cache" \
          --no-audit --no-fund --no-update-notifier > "$tmp/npm.log" 2>&1); then
    echo "node tests skipped: npm could not install the router ($(grep -m 1 'npm error' "$tmp/npm.log" || tail -n 1 "$tmp/npm.log"))"
    rm -rf "$tmp"
    return 0
  fi
  echo "== node --test minutes/test ($node $("$node" --version))"
  (cd "$tmp/work" && HOME="$tmp/home" "$node" --test test/*.test.mjs) || status=1
  rm -rf "$tmp"
  return "$status"
}
start 2-node node_tests

wait
for f in "$logs"/*.out; do
  [ -e "$f" ] || continue
  name="$(basename "${f%.out}")"
  case "$name" in 1-*) echo "== ${name#1-}" ;; esac
  cat "$f"
  [ "$(cat "${f%.out}.rc" 2>/dev/null)" = 0 ] || rc=1
done
rm -rf "$logs"
[ "$made_bin" -eq 1 ] && rm -rf "$MB_TEST_BIN"
exit $rc
