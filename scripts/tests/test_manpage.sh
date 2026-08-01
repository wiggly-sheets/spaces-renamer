#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v scdoc >/dev/null 2>&1; then
  echo "FAIL - scdoc is required (brew install scdoc)" >&2
  exit 1
fi

scdoc < "$ROOT/docs/sr.1.scd" > "$TMP/sr.1"

pass=0
assert_contains() {
  local description="$1" pattern="$2"
  if grep -q -- "$pattern" "$TMP/sr.1"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    echo "FAIL - $description" >&2
    exit 1
  fi
}

assert_contains "renders sr(1) title" '^\.TH "SR" "1"'
assert_contains "documents status" 'status'
assert_contains "documents profile switching" 'profile switch'
assert_contains "documents naming modes" 'yabaiLabels'
assert_contains "documents Space naming" 'space'

echo
echo "$pass passed, 0 failed"
