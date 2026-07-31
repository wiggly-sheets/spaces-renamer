#!/usr/bin/env bash
# Tests for scripts/embed-injection.sh. Uses a fake app bundle and a fake
# injection source directory to verify the script copies the stack correctly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/embed-injection.sh"
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

# Create a fake app bundle and a fake injection source directory.
mkdir -p "$TMP/Fake.app/Contents/Resources"
mkdir -p "$TMP/injection/lib"
printf '#!/bin/bash\necho injected\n' > "$TMP/injection/run.sh"
chmod 0755 "$TMP/injection/run.sh"
printf 'dylinject' > "$TMP/injection/lib/dylinject"
chmod 0755 "$TMP/injection/lib/dylinject"
printf 'dylib' > "$TMP/injection/lib/spaces-renamer.dylib"
chmod 0755 "$TMP/injection/lib/spaces-renamer.dylib"

# Run the script with the fake paths.
"$SCRIPT" "$TMP/Fake.app" "$TMP/injection" >/dev/null

# Verify the stack was copied to the correct location.
assert_eq "run.sh exists" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/Injection/run.sh" && echo yes || echo no)"
assert_eq "run.sh is executable" "yes" "$(test -x "$TMP/Fake.app/Contents/Resources/Injection/run.sh" && echo yes || echo no)"
assert_eq "dylinject exists" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/Injection/lib/dylinject" && echo yes || echo no)"
assert_eq "dylinject is executable" "yes" "$(test -x "$TMP/Fake.app/Contents/Resources/Injection/lib/dylinject" && echo yes || echo no)"
assert_eq "dylib exists" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/Injection/lib/spaces-renamer.dylib" && echo yes || echo no)"
assert_eq "dylib is executable" "yes" "$(test -x "$TMP/Fake.app/Contents/Resources/Injection/lib/spaces-renamer.dylib" && echo yes || echo no)"

# Verify the content of the copied files.
assert_eq "run.sh content" "$(cat "$TMP/injection/run.sh")" "$(cat "$TMP/Fake.app/Contents/Resources/Injection/run.sh")"
assert_eq "dylinject content" "$(cat "$TMP/injection/lib/dylinject")" "$(cat "$TMP/Fake.app/Contents/Resources/Injection/lib/dylinject")"
assert_eq "dylib content" "$(cat "$TMP/injection/lib/spaces-renamer.dylib")" "$(cat "$TMP/Fake.app/Contents/Resources/Injection/lib/spaces-renamer.dylib")"

# Test error handling: missing app.
if "$SCRIPT" "$TMP/missing.app" "$TMP/injection" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing app should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing app exits non-zero"
fi

# Test error handling: missing source directory.
if "$SCRIPT" "$TMP/Fake.app" "$TMP/missing" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing source directory should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing source directory exits non-zero"
fi

# Test error handling: missing run.sh.
mkdir -p "$TMP/injection-no-run/lib"
printf 'dylib' > "$TMP/injection-no-run/lib/spaces-renamer.dylib"
chmod 0755 "$TMP/injection-no-run/lib/spaces-renamer.dylib"
if "$SCRIPT" "$TMP/Fake.app" "$TMP/injection-no-run" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing run.sh should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing run.sh exits non-zero"
fi

# Test error handling: missing dylinject.
mkdir -p "$TMP/injection-no-dylinject/lib"
printf '#!/bin/bash\necho injected\n' > "$TMP/injection-no-dylinject/run.sh"
chmod 0755 "$TMP/injection-no-dylinject/run.sh"
printf 'dylib' > "$TMP/injection-no-dylinject/lib/spaces-renamer.dylib"
chmod 0755 "$TMP/injection-no-dylinject/lib/spaces-renamer.dylib"
if "$SCRIPT" "$TMP/Fake.app" "$TMP/injection-no-dylinject" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing dylinject should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing dylinject exits non-zero"
fi

# Test error handling: missing dylib.
mkdir -p "$TMP/injection-no-dylib/lib"
printf '#!/bin/bash\necho injected\n' > "$TMP/injection-no-dylib/run.sh"
chmod 0755 "$TMP/injection-no-dylib/run.sh"
printf 'dylinject' > "$TMP/injection-no-dylib/lib/dylinject"
chmod 0755 "$TMP/injection-no-dylib/lib/dylinject"
if "$SCRIPT" "$TMP/Fake.app" "$TMP/injection-no-dylib" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing dylib should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing dylib exits non-zero"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
