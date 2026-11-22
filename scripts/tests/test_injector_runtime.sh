#!/usr/bin/env bash
# Contracts for the bundled MIP loader: the user-owned root, the short-lived
# DYLD window, the status keys the app reads, and the packaging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INJECTOR="$ROOT/injection/injector.sh"
EMBED="$ROOT/scripts/embed-injection.sh"
MAKEFILE="$ROOT/Makefile"
PAYLOAD="$ROOT/injection/mip"

pass=0
fail=0

assert_fixed() {
  local description="$1" text="$2" file="$3"
  if grep -F -q -e "$text" "$file"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

assert_absent() {
  local description="$1" text="$2" file="$3"
  if grep -F -q -e "$text" "$file"; then
    fail=$((fail + 1))
    echo "FAIL - $description"
  else
    pass=$((pass + 1))
    echo "ok - $description"
  fi
}

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_pass() {
  local description="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

# --- the loader root and activation window ------------------------------------

assert_fixed "the loader root is user-owned" \
  'MIP_PRIVATE_ROOT="$HOME/Library/Application Support/SpacesRenamer/mip"' "$INJECTOR"
assert_fixed "the loader is installed without root" \
  'mip_install_runtime "$payload"' "$INJECTOR"
assert_fixed "activation checks Library Validation" \
  'library_validation_disabled' "$INJECTOR"
assert_fixed "activation sets the loader for one restart" \
  'launchctl setenv "$DYLD_VAR" "$loader"' "$INJECTOR"
assert_fixed "activation clears the variable" \
  'launchctl unsetenv "$DYLD_VAR"' "$INJECTOR"
assert_fixed "activation waits for a new host pid" \
  '[ "$new" != "$old" ]' "$INJECTOR"
assert_fixed "the marker's host pid decides loaded state" \
  'marker_pid' "$INJECTOR"

# --- no daemon path is shipped -------------------------------------------------

assert_absent "the private root is not system-owned" \
  'MIP_PRIVATE_ROOT="/Library/SpacesRenamer/mip"' "$INJECTOR"
assert_absent "no Mach service remains" 'MIP_SERVICE_NAME' "$INJECTOR"
assert_absent "no injectd label remains" 'MIP_INJECTD_LABEL' "$INJECTOR"
assert_absent "no lsdinjector label remains" 'MIP_LSDINJECTOR_LABEL' "$INJECTOR"
assert_absent "the system MIP root is not referenced" 'SYSTEM_MIP_ROOT' "$INJECTOR"
assert_absent "the daemon is not bootstrapped" 'launchctl bootstrap system' "$INJECTOR"

# --- status keys ---------------------------------------------------------------

assert_pass "the launcher has no syntax errors" sh -n "$INJECTOR"

status_out="$(sh "$INJECTOR" status 2>/dev/null)" || status_out=""
missing_keys=""
for key in host mip_installed mip_bundle arm64e active \
  runtime_root runtime_installed runtime_bundle runtime_loaded; do
  grep -q "^$key=" <<<"$status_out" || missing_keys="$missing_keys $key"
done
assert_eq "status prints every documented key" "" "$missing_keys"

runtime_out="$(sh "$INJECTOR" mip-runtime status 2>/dev/null)" || runtime_rc=$?
assert_eq "mip-runtime status runs without root" "0" "${runtime_rc:-0}"
assert_pass "runtime status names the user root" \
  grep -q '^runtime_root=.*/Library/Application Support/SpacesRenamer/mip$' <<<"$runtime_out"

# --- the loader travels with the app -------------------------------------------

assert_fixed "the embed script copies the loader" \
  'install -m 0644 "$MIP_RUNTIME/loader.dylib"' "$EMBED"
assert_fixed "the embed script warns when the loader is missing" \
  'will not carry a MIP loader' "$EMBED"
assert_fixed "make verify checks the embedded loader" \
  'test -f "$(APP)/Contents/Resources/mip/loader.dylib"' "$MAKEFILE"
assert_pass "the committed loader is present" test -f "$PAYLOAD/loader.dylib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/embed"
cp "$EMBED" "$TMP/embed/embed-injection.sh"
chmod 0755 "$TMP/embed/embed-injection.sh"
mkdir -p "$TMP/injection/lib" "$TMP/injection/mip" "$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS"
printf '#!/bin/sh\necho injected\n' >"$TMP/injection/injector.sh"
chmod 0755 "$TMP/injection/injector.sh"
printf 'dylib' >"$TMP/injection/lib/spaces-renamer.dylib"
printf 'plist' >"$TMP/build/SpacesRenamer.mip.bundle/Contents/Info.plist"
printf 'mip-executable' >"$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS/SpacesRenamer"
printf 'payload' >"$TMP/injection/mip/loader.dylib"
mkdir -p "$TMP/Fake.app/Contents/Resources"

"$TMP/embed/embed-injection.sh" "$TMP/Fake.app" >/dev/null

assert_eq "the app bundle carries the loader" "644" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/loader.dylib")"
assert_eq "the app bundle carries no daemon" "loader.dylib" \
  "$(ls "$TMP/Fake.app/Contents/Resources/mip")"

if [[ $fail -ne 0 ]]; then
  echo "$fail failed, $pass passed" >&2
  exit 1
fi
echo "$pass passed"
