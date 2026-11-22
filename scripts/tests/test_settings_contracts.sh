#!/usr/bin/env bash
# Focused source-level contracts for the MIP injection port. These
# assertions protect the exact seams the app, injector, and Dock hook rely on:
# the injector script's activation contract, the Swift backend, the hook's
# preference-domain reading, and the absence of the legacy dylinject pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DELEGATE="$ROOT/SpacesRenamer/AppDelegate.swift"
INJECTOR_SWIFT="$ROOT/SpacesRenamer/Injector.swift"
INJECTION_MANAGER="$ROOT/SpacesRenamer/InjectionManager.swift"
PREFERENCES="$ROOT/SpacesRenamer/PreferencesStore.swift"
SPACE_STORE="$ROOT/SpacesRenamer/SpaceStore.swift"
DOCK_HOOK="$ROOT/spaces-renamer/spacesRenamer.m"
INJECTOR_SCRIPT="$ROOT/injection/injector.sh"
EMBED_SCRIPT="$ROOT/scripts/embed-injection.sh"

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
  local description="$1" text="$2" path="$3"
  shift 3
  local status=0
  grep -F -q -e "$text" "$@" "$path" || status=$?
  case "$status" in
    0)
      fail=$((fail + 1))
      echo "FAIL - $description"
      ;;
    1)
      pass=$((pass + 1))
      echo "ok - $description"
      ;;
    *)
      fail=$((fail + 1))
      echo "FAIL - $description (grep could not read $path, status $status)"
      ;;
  esac
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

# --- injection/injector.sh --------------------------------------------------

assert_pass "injector script exists" test -f "$INJECTOR_SCRIPT"
assert_pass "injector script is executable" test -x "$INJECTOR_SCRIPT"
assert_pass "injector script has no syntax errors" sh -n "$INJECTOR_SCRIPT"

assert_absent \
  "injector has no persistent LaunchAgent" \
  'AGENT_LABEL' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector activates through DYLD_INSERT_LIBRARIES" \
  'DYLD_INSERT_LIBRARIES' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector requires the arm64e preview ABI boot argument" \
  '-arm64e_preview_abi' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector picks the Spaces bar host per macOS release" \
  'then echo WindowManager; else echo Dock' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector installs MIP under the user's Application Support" \
  'MIP_PRIVATE_ROOT="$HOME/Library/Application Support/SpacesRenamer/mip"' \
  "$INJECTOR_SCRIPT"
assert_absent \
  "injector does not grep the launchd list for mip" \
  'launchctl list' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector injects the MIP loader through DYLD_INSERT_LIBRARIES" \
  'launchctl setenv "$DYLD_VAR" "$loader"' \
  "$INJECTOR_SCRIPT"
assert_fixed \
  "injector restores the environment after the host restart" \
  'launchctl unsetenv "$DYLD_VAR"' \
  "$INJECTOR_SCRIPT"

# --- SpacesRenamer/Injector.swift ---------------------------------------------

assert_fixed "macOS 27+ host domain exists" 'com.apple.WindowManager' "$INJECTOR_SWIFT"
assert_fixed "macOS 26 host domain exists" 'com.apple.dock' "$INJECTOR_SWIFT"
assert_fixed "elevation uses the standard admin prompt" \
  'with administrator privileges' "$INJECTOR_SWIFT"
assert_fixed "the private loader lives in Application Support" \
  'Library/Application Support/SpacesRenamer/mip' "$INJECTOR_SWIFT"

# --- SpacesRenamer/InjectionManager.swift --------------------------------------

assert_fixed "arm64e preview ABI is required" '-arm64e_preview_abi' "$INJECTION_MANAGER"
assert_fixed "filesystem protection must be disabled" 'filesystem protections: disabled' "$INJECTION_MANAGER"
assert_fixed "debugging restrictions must be disabled" 'debugging restrictions: disabled' "$INJECTION_MANAGER"
assert_fixed "NVRAM protection must be disabled" 'nvram protections: disabled' "$INJECTION_MANAGER"
assert_fixed "Apple silicon is required" 'hw.optional.arm64' "$INJECTION_MANAGER"
assert_fixed "automatic injection has a cooldown" \
  'automaticInjectionCooldown' "$INJECTION_MANAGER"

# --- spaces-renamer/spacesRenamer.m --------------------------------------------

assert_fixed "hook reads the names mapping key" 'SpacesRenamerNames' "$DOCK_HOOK"
assert_fixed "hook reads the monitors snapshot key" 'SpacesRenamerMonitors' "$DOCK_HOOK"
assert_fixed "hook reads the compat preference domain" 'SPACES_RENAMER_DOMAIN' "$DOCK_HOOK"
assert_fixed "hook retries label application" 'scheduleApplyRetry' "$DOCK_HOOK"
assert_fixed "hook instruments the hot path" 'os_signpost' "$DOCK_HOOK"

assert_absent \
  "legacy handshake status publisher is gone" \
  'publishSpacesRenamerInjectionStatus' "$DOCK_HOOK"
assert_absent \
  "legacy injected notification is gone" \
  'SpacesRenamerInjectedNotification' "$DOCK_HOOK"
assert_absent \
  "legacy layer dump helper is gone" \
  'dumpLayerTree' "$DOCK_HOOK"

# --- SpacesRenamer/AppDelegate.swift ---------------------------------------------

assert_fixed "injection prerequisite alert exists" \
  'showInjectionSetupRequiredAlert' "$APP_DELEGATE"
first_consent="$(grep -n 'setInjectionConsent' "$APP_DELEGATE" | head -n1 | cut -d: -f1)"
first_inject="$(grep -n 'injectNow' "$APP_DELEGATE" | head -n1 | cut -d: -f1)"
if [[ -n "$first_consent" && -n "$first_inject" && "$first_consent" -lt "$first_inject" ]]; then
  pass=$((pass + 1))
  echo "ok - consent is recorded before injection starts"
else
  fail=$((fail + 1))
  echo "FAIL - consent is recorded before injection starts"
fi

# --- legacy dylinject pipeline removed -------------------------------------------

assert_absent "no dylinject references in SpacesRenamer/" 'dylinject' "$ROOT/SpacesRenamer" \
  -R --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm
assert_absent "embed script does not reference dylinject" 'dylinject' "$EMBED_SCRIPT"
assert_absent "embed script does not reference run.sh" 'run.sh' "$EMBED_SCRIPT"

# --- preference publication contracts ---------------------------------------------

assert_fixed "preferences publish the names mapping" 'SpacesRenamerNames' "$PREFERENCES"
assert_fixed "SpaceStore publishes the monitors snapshot" 'SpacesRenamerMonitors' "$SPACE_STORE"

assert_fixed \
  "preferences use the dock publishing policy" \
  'publishesToDockDomain: NativeAppManagement.publishesToDockNames' \
  "$PREFERENCES"
assert_fixed \
  "SpaceStore uses the dock publishing policy" \
  'publishesToDockDomain: NativeAppManagement.publishesToDockNames' \
  "$SPACE_STORE"
assert_absent \
  "preferences do not hardcode dock publishing" \
  'publishesToDockDomain: true' \
  "$PREFERENCES"
assert_absent \
  "SpaceStore does not hardcode dock publishing" \
  'publishesToDockDomain: true' \
  "$SPACE_STORE"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
