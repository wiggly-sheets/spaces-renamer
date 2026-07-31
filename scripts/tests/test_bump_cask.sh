#!/usr/bin/env bash
# Tests for scripts/bump-cask.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bump-cask.sh"
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
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

FIXTURE='cask "spacesrenamer" do
  version "0.9.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.dmg"
  name "Spaces Renamer"
  desc "Give macOS Spaces persistent names in Mission Control"
  homepage "https://github.com/wiggly-sheets/spaces-renamer"

  depends_on macos: ">= :ventura"

  app "SpacesRenamer.app"

  zap trash: [
    "~/Library/Application Support/SpacesRenamer",
    "~/Library/Containers/com.alexbeals.spacesrenamer",
    "~/.config/spacesrenamer",
  ]
end
'

# 1. Updates version and sha256, preserving the rest of the file.
cat > "$TMP/example.rb" <<EOF
$FIXTURE
EOF
SHA="a1b2c3d4e5f60718293a4b5c6d7e8f901a2b3c4d5e6f708192a3b4c5d6e7f809"
"$SCRIPT" 1.0.0 "$SHA" "$TMP/example.rb"
assert_eq "bumps version line" '  version "1.0.0"' \
  "$(grep -E '^  version ' "$TMP/example.rb")"
assert_eq "bumps sha256 line" "  sha256 \"$SHA\"" \
  "$(grep -E '^  sha256 ' "$TMP/example.rb")"
assert_eq "keeps url line intact" \
  '  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.dmg"' \
  "$(grep -E '^  url ' "$TMP/example.rb")"
assert_eq "keeps zap trash intact" \
  '    "~/Library/Application Support/SpacesRenamer",' \
  "$(grep -F '~/Library/Application Support/SpacesRenamer' "$TMP/example.rb")"

# 2. Rejects a short sha256 and leaves the file untouched.
cat > "$TMP/example.rb" <<EOF
$FIXTURE
EOF
cp "$TMP/example.rb" "$TMP/example.rb.bak"
if "$SCRIPT" 1.0.0 "abc" "$TMP/example.rb" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - short sha256 should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - short sha256 exits non-zero"
fi
assert_eq "short sha256 leaves file untouched" "$(cat "$TMP/example.rb.bak")" \
  "$(cat "$TMP/example.rb")"

# 3. Rejects a non-hex sha256.
if "$SCRIPT" 1.0.0 "$(printf 'z%.0s' {1..64})" "$TMP/example.rb" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - non-hex sha256 should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - non-hex sha256 exits non-zero"
fi

# 4. Missing cask file is an error.
if "$SCRIPT" 1.0.0 "$SHA" "$TMP/missing.rb" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing cask file should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing cask file exits non-zero"
fi

# 5. Missing arguments is a usage error.
if "$SCRIPT" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing args should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing args exit non-zero"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
