#!/usr/bin/env bash
cd "$CLAUDE_PROJECT_DIR" || exit 0
[[ -f go.mod ]] || exit 0
if ! out=$(make check 2>&1); then
  echo "make check failed:" >&2
  echo "$out" | tail -n 40 >&2
  exit 2
fi
