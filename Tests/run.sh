#!/usr/bin/env bash
# Runs the test suites against a stubbed WoW API. Needs a Lua 5.1 interpreter,
# which is the dialect the game uses.
set -uo pipefail
cd "$(dirname "$0")"

LUA="${LUA:-lua5.1}"
if ! command -v "$LUA" >/dev/null; then
  echo "no $LUA on PATH; set LUA=<interpreter>" >&2
  exit 1
fi

status=0
for suite in test_core.lua test_options.lua; do
  echo "=== $suite ==="
  "$LUA" "$suite" || status=1
done

echo
if [ "$status" -eq 0 ]; then
  echo "all suites passed"
else
  echo "FAILURES"
fi
exit "$status"
