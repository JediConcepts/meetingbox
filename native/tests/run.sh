#!/bin/bash
# Builds and runs every native/tests/*/main.swift. The first line of a test may
# name the sources it needs, relative to the test file:
#   // sources: ../../recorder/AudioMixer.swift
# Each test builds in its own temporary folder; any failure fails the run.
# The tests (and the mb-transcript build) run side by side, and each one's output is
# printed whole, in name order, once all are done. MB_TEST_SERIAL=1 runs them one at a time.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
logs="$(mktemp -d)" || exit 1

run_one() {   # run_one <main.swift>: prints the test's output; exit status is the result
  local t="$1" dir name first s out rc=0
  dir="$(dirname "$t")"
  name="$(basename "$dir")"
  echo "== native/$name"
  local srcs=("$t")
  first="$(head -n 1 "$t")"
  case "$first" in
    "// sources:"*)
      for s in ${first#"// sources:"}; do srcs+=("$dir/$s"); done ;;
  esac
  out="$(mktemp -d)"
  if ! swiftc -suppress-warnings -o "$out/test" "${srcs[@]}" -framework AVFoundation -framework CoreMedia; then
    echo "FAIL $name: does not compile"
    rc=1
  elif ! "$out/test"; then
    echo "FAIL $name"
    rc=1
  fi
  rm -rf "$out"
  return $rc
}

# The bash tests run the real mb-transcript when MB_TEST_BIN names a folder for it.
build_transcript() {
  echo "== build mb-transcript"
  if ! swiftc -suppress-warnings -o "$MB_TEST_BIN/mb-transcript" "$here"/../transcript/*.swift; then
    echo "FAIL mb-transcript: does not compile"
    return 1
  fi
}

# start <log name> <command...>: runs the command with its output in $logs/<name>.out and
# its exit status in $logs/<name>.rc; in the background unless MB_TEST_SERIAL=1.
start() {
  local name="$1"; shift
  if [ "${MB_TEST_SERIAL:-}" = 1 ]; then
    "$@" > "$logs/$name.out" 2>&1; echo $? > "$logs/$name.rc"
  else
    { "$@" > "$logs/$name.out" 2>&1; echo $? > "$logs/$name.rc"; } &
  fi
}

n=0
for t in "$here"/*/main.swift; do
  [ -e "$t" ] || continue
  n=$((n + 1))
  start "$(printf '%03d' "$n")" run_one "$t"
done
[ -n "${MB_TEST_BIN:-}" ] && start "999" build_transcript
wait

rc=0
for f in "$logs"/*.out; do
  [ -e "$f" ] || continue
  cat "$f"
  [ "$(cat "${f%.out}.rc" 2>/dev/null)" = 0 ] || rc=1
done
rm -rf "$logs"
exit $rc
