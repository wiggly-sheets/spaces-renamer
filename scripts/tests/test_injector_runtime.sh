#!/usr/bin/env bash
# Contracts for the bundled injection runtime: the private MIP root and its
# Mach service, the launcher subcommands that install and remove the runtime,
# the status keys the app reads, and the packaging that ships the runtime
# inside the app bundle.
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
  if rg --fixed-strings --quiet -e "$text" "$file"; then
  	pass=$((pass + 1))
  	echo "ok - $description"
  else
  	fail=$((fail + 1))
  	echo "FAIL - $description"
  fi
}

assert_absent() {
  local description="$1" text="$2" file="$3"
  if rg --fixed-strings --quiet -e "$text" "$file"; then
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

# --- the private runtime's identity -------------------------------------------

assert_fixed "the private runtime root is fixed" \
  'MIP_PRIVATE_ROOT="/Library/SpacesRenamer/mip"' "$INJECTOR"
assert_fixed "the private Mach service name is fixed" \
  'MIP_SERVICE_NAME="com.wiggly-sheets.spaces-renamer.injectd"' "$INJECTOR"
assert_fixed "the private injectd label is fixed" \
  'MIP_INJECTD_LABEL="com.wiggly-sheets.spaces-renamer.injectd"' "$INJECTOR"
assert_fixed "the private lsdinjector label is fixed" \
  'MIP_LSDINJECTOR_LABEL="com.wiggly-sheets.spaces-renamer.lsdinjector"' "$INJECTOR"
assert_fixed "the system MIP root keeps its own name" \
  'SYSTEM_MIP_ROOT="/Library/Apple/System/Library/Frameworks/mip"' "$INJECTOR"
assert_pass "the plain MIP_ROOT variable is gone" \
  bash -c "! rg --quiet -e '^MIP_ROOT=' '$INJECTOR'"

# --- mip on installs into the private root ------------------------------------

assert_fixed "the runtime payload is found next to the launcher" \
  '"$dir/mip"' "$INJECTOR"
assert_fixed "the runtime files are copied into the private root" \
  '"$payload/injectd" "$payload/loader.dylib" "$payload/lsdinjector.dylib"' "$INJECTOR"
assert_fixed "the runtime files land in the private root" \
  '"$payload/inject" "$MIP_PRIVATE_ROOT/"' "$INJECTOR"
assert_fixed "the private root gets its bundle and user_data directories" \
  '"$MIP_BUNDLES" "$MIP_PRIVATE_ROOT/user_data"' "$INJECTOR"
assert_fixed "the runtime files are owned by root" \
  'chown -R root:wheel "$MIP_PRIVATE_ROOT"' "$INJECTOR"
assert_fixed "the loader is not executable" \
  'chmod 0644 "$MIP_PRIVATE_ROOT/loader.dylib"' "$INJECTOR"
assert_fixed "the stale copy in the system root is removed" \
  'mip_remove_bundle "$SYSTEM_MIP_ROOT"' "$INJECTOR"
assert_fixed "the private daemon is bootstrapped" \
  'mip_bootstrap_daemon "$MIP_INJECTD_LABEL"' "$INJECTOR"
assert_fixed "the private daemon is enabled" \
  'launchctl enable "system/$MIP_INJECTD_LABEL"' "$INJECTOR"
assert_fixed "the library validation exception is written" \
  'DisableLibraryValidation -bool true' "$INJECTOR"
assert_fixed "the hook chain is repaired for the private job" \
  'launchctl kickstart -k "system/$label"' "$INJECTOR"
assert_fixed "the hook fallback uses the private injector" \
  'injector="$MIP_PRIVATE_ROOT/inject"' "$INJECTOR"

# --- the placeholders are substituted at install time --------------------------

assert_fixed "the runtime root placeholder is substituted" \
  's=@MIP_ROOT@=$MIP_PRIVATE_ROOT=g' "$INJECTOR"
assert_fixed "the service name placeholder is substituted" \
  's=@MIP_SERVICE_NAME@=$MIP_SERVICE_NAME=g' "$INJECTOR"
assert_fixed "the injectd plist template keeps the root placeholder" \
  '@MIP_ROOT@/injectd' "$PAYLOAD/spacesrenamer.injectd.plist"
assert_fixed "the injectd plist template keeps the service placeholder" \
  '@MIP_SERVICE_NAME@' "$PAYLOAD/spacesrenamer.injectd.plist"
assert_fixed "the lsdinjector plist template keeps the root placeholder" \
  '@MIP_ROOT@/inject' "$PAYLOAD/spacesrenamer.lsdinjector.plist"
assert_fixed "the lsdinjector plist template hooks launchservicesd" \
  '@MIP_ROOT@/lsdinjector.dylib' "$PAYLOAD/spacesrenamer.lsdinjector.plist"

# --- the system MIP install is never written to -------------------------------

assert_absent "the system injectd plist is never written" \
  '/Library/LaunchDaemons/local.injectd.plist' "$INJECTOR"
assert_absent "the system lsdinjector plist is never written" \
  '/Library/LaunchDaemons/local.lsdinjector.plist' "$INJECTOR"
assert_absent "the system injectd daemon is never booted out" \
  'launchctl bootout "system/local.injectd"' "$INJECTOR"
assert_absent "the system injectd daemon is never bootstrapped" \
  'bootstrap system "/Library/LaunchDaemons/local.injectd.plist"' "$INJECTOR"
assert_absent "the system root is never removed" \
  'rm -rf "$SYSTEM_MIP_ROOT"' "$INJECTOR"

# --- mip-runtime uninstall removes only our files -----------------------------

assert_fixed "our injectd daemon is booted out" \
  'launchctl bootout "system/$MIP_INJECTD_LABEL"' "$INJECTOR"
assert_fixed "our lsdinjector job is booted out" \
  'launchctl bootout "system/$MIP_LSDINJECTOR_LABEL"' "$INJECTOR"
assert_fixed "our injectd plist is removed" \
  '"/Library/LaunchDaemons/$MIP_INJECTD_LABEL.plist"' "$INJECTOR"
assert_fixed "our lsdinjector plist is removed" \
  '"/Library/LaunchDaemons/$MIP_LSDINJECTOR_LABEL.plist"' "$INJECTOR"
assert_fixed "the private root is removed" \
  'rm -rf "$MIP_PRIVATE_ROOT"' "$INJECTOR"

# --- the status keys the app reads ---------------------------------------------

assert_pass "the launcher has no syntax errors" sh -n "$INJECTOR"

status_out="$(sh "$INJECTOR" status 2>/dev/null)" || status_out=""
for key in host dyld_agent dyld_env dyld mip_installed mip_bundle mip_daemon \
  arm64e active runtime_root runtime_installed runtime_daemon runtime_hooked \
  runtime_bundle runtime_service; do
  assert_pass "status prints $key" grep -q "^$key=" <<<"$status_out"
done

runtime_out="$(sh "$INJECTOR" mip-runtime status 2>/dev/null)" || runtime_rc=$?
runtime_keys="$(sed -n 's/=.*//p' <<<"$runtime_out" | paste -sd' ' -)"
assert_eq "mip-runtime status prints the runtime keys in order" \
  "runtime_root runtime_installed runtime_daemon runtime_hooked runtime_bundle runtime_service" \
  "$runtime_keys"
assert_pass "mip-runtime status reports the private service name" \
  grep -q '^runtime_service=com.wiggly-sheets.spaces-renamer.injectd$' <<<"$runtime_out"
assert_eq "mip-runtime status runs without root" "0" "${runtime_rc:-0}"

# --- the runtime travels with the app -------------------------------------------

assert_fixed "the embed script copies the runtime" \
  '$APP/Contents/Resources/mip' "$EMBED"
assert_fixed "the embed script keeps the loader non-executable" \
  'install -m 0644' "$EMBED"
assert_fixed "the embed script warns when the runtime is missing" \
  'will not carry a private MIP runtime' "$EMBED"
for file in injectd loader.dylib lsdinjector.dylib inject \
  spacesrenamer.injectd.plist spacesrenamer.lsdinjector.plist; do
  assert_pass "the runtime payload ships $file" test -f "$PAYLOAD/$file"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy the embed script into a fake tree so its repo-relative sources resolve
# to fake files.
mkdir -p "$TMP/embed"
cp "$EMBED" "$TMP/embed/embed-injection.sh"
chmod 0755 "$TMP/embed/embed-injection.sh"
mkdir -p "$TMP/injection/lib" "$TMP/injection/mip" "$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS"
printf '#!/bin/sh\necho injected\n' >"$TMP/injection/injector.sh"
chmod 0755 "$TMP/injection/injector.sh"
printf 'dylib' >"$TMP/injection/lib/spaces-renamer.dylib"
printf 'plist' >"$TMP/build/SpacesRenamer.mip.bundle/Contents/Info.plist"
printf 'mip-executable' >"$TMP/build/SpacesRenamer.mip.bundle/Contents/MacOS/SpacesRenamer"
for file in injectd loader.dylib lsdinjector.dylib inject \
  spacesrenamer.injectd.plist spacesrenamer.lsdinjector.plist; do
  printf 'payload' >"$TMP/injection/mip/$file"
done
mkdir -p "$TMP/Fake.app/Contents/Resources"

"$TMP/embed/embed-injection.sh" "$TMP/Fake.app" >/dev/null

for file in injectd loader.dylib lsdinjector.dylib inject \
  spacesrenamer.injectd.plist spacesrenamer.lsdinjector.plist; do
  assert_pass "the app bundle carries mip/$file" \
  	test -f "$TMP/Fake.app/Contents/Resources/mip/$file"
done
assert_eq "the runtime executables are executable" "755" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/injectd")"
assert_eq "the lsdinjector is executable" "755" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/lsdinjector.dylib")"
assert_eq "the inject CLI is executable" "755" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/inject")"
assert_eq "the loader is not executable" "644" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/loader.dylib")"
assert_eq "the plists are not executable" "644" \
  "$(stat -f '%Lp' "$TMP/Fake.app/Contents/Resources/mip/spacesrenamer.injectd.plist")"

# An older tree without the runtime keeps working: the copy is skipped.
rm -rf "$TMP/injection/mip"
embed_out="$("$TMP/embed/embed-injection.sh" "$TMP/Fake.app" 2>&1)" && embed_rc=0 || embed_rc=$?
assert_eq "the embed script survives a missing runtime" "0" "$embed_rc"
assert_pass "the embed script warns about the missing runtime" \
  grep -q "will not carry a private MIP runtime" <<<"$embed_out"

# --- the Makefile ---------------------------------------------------------------

assert_fixed "the Makefile has a mip target" 'mip:' "$MAKEFILE"
assert_fixed "the mip target needs gobjcopy" 'gobjcopy' "$MAKEFILE"
assert_fixed "the mip target points at binutils" 'brew install binutils' "$MAKEFILE"
assert_fixed "the mip target prints the rebuild command" \
  'make -C third_party/mip/MIP MIP_ROOT=/Library/SpacesRenamer/mip MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd' \
  "$MAKEFILE"
assert_fixed "the app target embeds the injection stack" \
  './scripts/embed-injection.sh "$(APP)"' "$MAKEFILE"
assert_eq "no target depends on the mip target" "" \
  "$(rg -n '^[a-zA-Z0-9_-]+:.*[[:space:]]mip([[:space:]]|$)' "$MAKEFILE" || true)"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
