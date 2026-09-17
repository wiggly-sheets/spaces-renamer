#!/usr/bin/env bash
# Tests for scripts/embed-injection.sh. Copies the script into a temp tree so
# its repo-relative sources (injection/ and build/) resolve to fake files,
# then verifies the DYLD/MIP layout lands in a fake app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EMBED="$ROOT/scripts/embed-injection.sh"
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

# Copy the embed script into the tmp tree so its ROOT resolution points at our
# fake sources instead of the repository.
mkdir -p "$TMP/embed"
SCRIPT="$TMP/embed/embed-injection.sh"
cp "$EMBED" "$SCRIPT"
chmod 0755 "$SCRIPT"

# Fake repo-relative sources: injection/injector.sh, injection/lib payload,
# and the build/ MIP bundle (normally assembled by `make bundle`).
mkdir -p "$TMP/injection/lib"
printf '#!/bin/sh\necho injected\n' > "$TMP/injection/injector.sh"
chmod 0755 "$TMP/injection/injector.sh"
printf 'dylib' > "$TMP/injection/lib/spaces-renamer.dylib"
mkdir -p "$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS"
printf 'plist' > "$TMP/build/SpacesRenamer.mip.bundle/Contents/Info.plist"
printf 'mip-executable' > "$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS/SpacesRenamer"

# Fake app bundle. It has no Contents/MacOS/SpacesRenamer binary, so the embed
# script skips re-signing. Seed the legacy layout first so we can verify the
# embed script removes it.
mkdir -p "$TMP/Fake.app/Contents/Resources/Injection/lib"
printf 'legacy' > "$TMP/Fake.app/Contents/Resources/Injection/run.sh"

# Run the script with the fake app path.
"$SCRIPT" "$TMP/Fake.app" >/dev/null

# Verify the new DYLD/MIP layout was copied.
assert_eq "injector.sh exists in Resources" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/injector.sh" && echo yes || echo no)"
assert_eq "injector.sh is executable" "yes" "$(test -x "$TMP/Fake.app/Contents/Resources/injector.sh" && echo yes || echo no)"
assert_eq "injector.sh content" "$(cat "$TMP/injection/injector.sh")" "$(cat "$TMP/Fake.app/Contents/Resources/injector.sh")"

assert_eq "PlugIns dylib exists" "yes" "$(test -f "$TMP/Fake.app/Contents/PlugIns/spaces-renamer.dylib" && echo yes || echo no)"
assert_eq "PlugIns dylib content" "$(cat "$TMP/injection/lib/spaces-renamer.dylib")" "$(cat "$TMP/Fake.app/Contents/PlugIns/spaces-renamer.dylib")"

assert_eq "MIP bundle exists in Resources" "yes" "$(test -d "$TMP/Fake.app/Contents/Resources/SpacesRenamer.mip.bundle" && echo yes || echo no)"
assert_eq "MIP bundle Info.plist present" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/SpacesRenamer.mip.bundle/Contents/Info.plist" && echo yes || echo no)"
assert_eq "MIP bundle executable present" "yes" "$(test -f "$TMP/Fake.app/Contents/Resources/SpacesRenamer.mip.bundle/Contents/MacOS/SpacesRenamer" && echo yes || echo no)"

# The legacy run.sh/dylinject layout must be gone.
assert_eq "legacy Resources/Injection removed" "yes" "$(test ! -e "$TMP/Fake.app/Contents/Resources/Injection" && echo yes || echo no)"

# Nothing named dylinject may be embedded.
assert_eq "no dylinject artifact embedded" "yes" "$(find "$TMP/Fake.app" -name dylinject | grep -q . && echo no || echo yes)"

# Test error handling: missing app.
if "$SCRIPT" "$TMP/missing.app" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing app should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing app exits non-zero"
fi

# Test error handling: missing injector script.
rm "$TMP/injection/injector.sh"
if "$SCRIPT" "$TMP/Fake.app" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing injector.sh should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing injector.sh exits non-zero"
fi

# Test error handling: missing MIP bundle.
touch "$TMP/injection/injector.sh"
chmod 0755 "$TMP/injection/injector.sh"
rm -rf "$TMP/build/SpacesRenamer.mip.bundle"
if "$SCRIPT" "$TMP/Fake.app" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing MIP bundle should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing MIP bundle exits non-zero"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]