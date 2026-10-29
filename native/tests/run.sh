#!/bin/bash
# Builds and runs every native/tests/*/main.swift. The first line of a test may
# name the sources it needs, relative to the test file:
#   // sources: ../../recorder/AudioMixer.swift
# Each test builds in its own temporary folder; any failure fails the run.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$here"/*/main.swift; do
  [ -e "$t" ] || continue
  dir="$(dirname "$t")"
  name="$(basename "$dir")"
  echo "== native/$name"
  srcs=("$t")
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
done
exit $rc
