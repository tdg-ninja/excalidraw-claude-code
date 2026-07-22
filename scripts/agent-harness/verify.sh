#!/usr/bin/env bash
#
# Shared verification gate for the issue-to-pr agent harness.
#
# Runs the project's checks (typecheck, lint, tests) and reports a combined
# pass/fail. Used both by the autonomous coding agent (to self-check before
# it considers a fix done) and by the harness itself (as the independent
# gate that decides whether a PR gets opened) -- same script, same
# definition of "green", so the agent can't diverge from what actually
# gates the PR.
#
# Usage: scripts/agent-harness/verify.sh [--fast]
#   --fast   skip the full test suite and only run typecheck + lint
#            (useful for quick iteration; the harness's final gate always
#            runs the full, non-fast check).

set -uo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

status=0

echo "== typecheck (tsc) =="
yarn test:typecheck
if [ $? -ne 0 ]; then status=1; fi

echo
echo "== lint (eslint) =="
yarn test:code
if [ $? -ne 0 ]; then status=1; fi

if [ "$FAST" -eq 0 ]; then
  echo
  echo "== tests (vitest run) =="
  yarn test:app run --silent
  if [ $? -ne 0 ]; then status=1; fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "verify.sh: PASS"
else
  echo "verify.sh: FAIL"
fi

exit "$status"
