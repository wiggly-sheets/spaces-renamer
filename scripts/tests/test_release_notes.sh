#!/usr/bin/env bash
# Tests for scripts/release-notes.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/release-notes.sh"
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

cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased

## 2.0.0 (2026-08-01)

## 1.0.0 (2026-07-31)

### Added

- First feature.

### Fixed

- A bug.

## 0.9.0 (2026-07-30)

### Added

- Older feature.

## 2025-06-10

### Added

- Legacy entry.
EOF

# 1. Extracts the section matching a plain version header.
out="$("$SCRIPT" 1.0.0 "$TMP/CHANGELOG.md")"
assert_eq "extracts matching version section" \
  $'### Added\n\n- First feature.\n\n### Fixed\n\n- A bug.' "$out"

# 2. A `v`-prefixed header also matches (tag is v<version>).
cat > "$TMP/CHANGELOG-v.md" <<'EOF'
# Changelog

## v3.0.0 (2026-08-02)

### Added

- V-prefixed feature.
EOF
out="$("$SCRIPT" 3.0.0 "$TMP/CHANGELOG-v.md")"
assert_eq "matches v-prefixed header" \
  $'### Added\n\n- V-prefixed feature.' "$out"

# 3. Missing section falls back to a generic note.
out="$("$SCRIPT" 9.9.9 "$TMP/CHANGELOG.md")"
assert_eq "missing section falls back to generic note" "Release 9.9.9" "$out"

# 4. Empty section falls back to a generic note.
out="$("$SCRIPT" 2.0.0 "$TMP/CHANGELOG.md")"
assert_eq "empty section falls back to generic note" "Release 2.0.0" "$out"

# 5. Version boundary: 1.0.0 must not match 10.0.0 or 1.0.0-rc.1.
cat > "$TMP/CHANGELOG-boundary.md" <<'EOF'
# Changelog

## 10.0.0 (2026-08-03)

### Added

- Ten.

## 1.0.0-rc.1 (2026-08-04)

### Added

- Release candidate.

## 1.0.0 (2026-08-05)

### Added

- The real one.
EOF
out="$("$SCRIPT" 1.0.0 "$TMP/CHANGELOG-boundary.md")"
assert_eq "version boundary ignores 10.0.0 and 1.0.0-rc.1" \
  $'### Added\n\n- The real one.' "$out"

# 6. Missing changelog file falls back to a generic note.
out="$("$SCRIPT" 1.0.0 "$TMP/nope.md")"
assert_eq "missing changelog falls back to generic note" "Release 1.0.0" "$out"

# 7. No arguments is a usage error.
if "$SCRIPT" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing args should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing args exit non-zero"
fi

# 8. Version dots are literal: 1.0 must not match 1.00 or 1X0.
cat > "$TMP/CHANGELOG-regex.md" <<'EOF'
# Changelog

## 1.00 (2026-08-06)

### Added

- Dotty.

## 1.0 (2026-08-07)

### Added

- The real one.
EOF
out="$("$SCRIPT" 1.0 "$TMP/CHANGELOG-regex.md")"
assert_eq "version dots treated literally" \
  $'### Added\n\n- The real one.' "$out"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
