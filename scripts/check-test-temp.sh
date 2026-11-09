#!/bin/bash
# Guard: the test suites must leave nothing behind in $TMPDIR.
# Runs `swift test` (all suites, or the --filter regexes given as arguments) and fails if any
# entry created after the start is still in $TMPDIR (SwiftPM's own TemporaryDirectory.* excepted).
set -u
cd "$(dirname "$0")/.."
T="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
mark="$(mktemp "$T/.xside-tmpcheck.XXXXXX")"
trap 'rm -f "$mark"' EXIT
sleep 1
args=()
for f in "$@"; do args+=(--filter "$f"); done
swift test ${args[@]+"${args[@]}"} >/dev/null 2>&1 || { echo "FAIL: swift test failed"; exit 1; }
left="$(find "$T" -maxdepth 1 -mindepth 1 -newer "$mark" ! -name 'TemporaryDirectory.*' ! -name TemporaryItems ! -name "$(basename "$mark")" 2>/dev/null)"
n=$(printf '%s' "$left" | grep -c . || true)
echo "new entries left in $T: $n"
if [ "$n" -gt 0 ]; then printf '%s\n' "$left" | head -20; echo "FAIL"; exit 1; fi
echo "OK"
