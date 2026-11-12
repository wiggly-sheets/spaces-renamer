#!/usr/bin/env bash
# Tests for scripts/changelog.sh notes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/changelog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
    echo "ok - $desc"
  else
    fail=$((fail + 1))
    echo "FAIL - $desc"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
  fi
}

assert_fails() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "FAIL - $desc"
  else
    pass=$((pass + 1))
    echo "ok - $desc"
  fi
}

cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added

- Upcoming feature.

## [2.0.0] - 2026-08-01

## [1.0.0] - 2026-07-31

### Added

- First feature.

### Fixed

- A bug.
EOF

# 1. Extracts the section matching a version header.
out="$("$SCRIPT" notes 1.0.0 "$TMP/CHANGELOG.md")"
assert_eq "extracts matching version section" \
  $'### Added\n\n- First feature.\n\n### Fixed\n\n- A bug.' "$out"

# 2. A `v`-prefixed version also matches (the tag is v<version>).
out="$("$SCRIPT" notes v1.0.0 "$TMP/CHANGELOG.md")"
assert_eq "matches the v-prefixed spelling" \
  $'### Added\n\n- First feature.\n\n### Fixed\n\n- A bug.' "$out"

# 3. Missing and empty sections fail: a release must have notes.
assert_fails "missing section fails" "$SCRIPT" notes 9.9.9 "$TMP/CHANGELOG.md"
assert_fails "empty section fails" "$SCRIPT" notes 2.0.0 "$TMP/CHANGELOG.md"

# 4. Version boundary: 1.0.0 must not match 10.0.0 or 1.0.0-rc.1.
cat > "$TMP/CHANGELOG-boundary.md" <<'EOF'
# Changelog

## [10.0.0] - 2026-08-03

### Added

- Ten.

## [1.0.0-rc.1] - 2026-08-04

### Added

- Release candidate.

## [1.0.0] - 2026-08-05

### Added

- The real one.
EOF
out="$("$SCRIPT" notes 1.0.0 "$TMP/CHANGELOG-boundary.md")"
assert_eq "version boundary ignores 10.0.0 and 1.0.0-rc.1" \
  $'### Added\n\n- The real one.' "$out"

# 5. A missing changelog and missing arguments fail.
assert_fails "missing changelog fails" "$SCRIPT" notes 1.0.0 "$TMP/nope.md"
assert_fails "missing arguments fail" "$SCRIPT" notes

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
