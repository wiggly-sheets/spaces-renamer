#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v scdoc >/dev/null 2>&1; then
	echo "FAIL - scdoc is required (brew install scdoc)" >&2
	exit 1
fi

scdoc <"$ROOT/docs/sr.1.scd" >"$TMP/sr.1"

pass=0
fail=0
assert_contains() {
	local description="$1" pattern="$2"
	if grep -q -- "$pattern" "$TMP/sr.1"; then
		pass=$((pass + 1))
		echo "ok - $description"
	else
		fail=$((fail + 1))
		echo "FAIL - $description" >&2
	fi
}

assert_contains "renders sr(1) title" '^\.TH "SR" "1"'
assert_contains "documents sr status" \
	'\\fBsr\\fR \\fBstatus\\fR'
assert_contains "documents sr profile switch" \
	'\\fBsr\\fR \\fBprofile switch\\fR \\fIUUID\\fR'
assert_contains "documents sr naming modes" \
	'\\fBmanual\\fR, \\fBapplications\\fR, or'
assert_contains "documents the yabaiLabels naming mode" \
	'\\fByabaiLabels\\fR'
assert_contains "documents sr space name" \
	'\\fBsr\\fR \\fBspace\\fR \\fIUUID\\fR \\fBname\\fR \\fINAME\\fR'
assert_contains "documents the request-specific reply" \
	'request.*specific status reply'

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
