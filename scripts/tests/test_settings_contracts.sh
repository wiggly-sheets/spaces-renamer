#!/usr/bin/env bash
# Focused source-level UI contracts for behavior that currently has no XCTest
# target. These assertions protect the exact SwiftUI and AppKit seams that
# previously rendered Manual naming as read-only and silently stopped consent
# when injection prerequisites were missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$ROOT/SpacesRenamer/SettingsView.swift"
APP_DELEGATE="$ROOT/SpacesRenamer/AppDelegate.swift"
INJECTION_MANAGER="$ROOT/SpacesRenamer/InjectionManager.swift"
PREFERENCES="$ROOT/SpacesRenamer/PreferencesStore.swift"
DOCK_HOOK="$ROOT/spaces-renamer/spacesRenamer.m"
INJECTION_SCRIPT="$ROOT/injection/run.sh"

pass=0
fail=0

assert_match() {
  local description="$1" pattern="$2" file="$3"
  if rg --multiline --quiet "$pattern" "$file"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

assert_fixed() {
  local description="$1" text="$2" file="$3"
  if rg --fixed-strings --quiet "$text" "$file"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

assert_match \
  "Manual Naming rows expose editable fields" \
  'preferences\.namingMode == \.manual[[:space:]]*\{[[:space:][:print:]]*TextField\(' \
  "$SETTINGS"

assert_match \
  "blocked first-launch injection surfaces setup guidance" \
  'if let warning = injection\.prerequisitesWarning[[:space:]]*\{[[:space:][:print:]]*showInjectionSetupRequiredAlert\(warning\)' \
  "$APP_DELEGATE"

assert_match \
  "startup completes the move decision before injection onboarding" \
  'guard !NativeAppManagement\.promptToMoveIfNeeded\(\) else \{ return \}[[:space:][:print:]]*injectionConsentGranted' \
  "$APP_DELEGATE"

assert_fixed \
  "first-run injection offers recommended Launch at Login" \
  'checkboxWithTitle: "Launch Spaces Renamer at login (Recommended)"' \
  "$APP_DELEGATE"

assert_fixed \
  "Injection Settings describe restart coverage honestly" \
  'Toggle("Keep Dock renaming active"' \
  "$SETTINGS"

assert_fixed \
  "Injection Settings colocate Launch at Login" \
  'Toggle("Launch Spaces Renamer at login"' \
  "$SETTINGS"

assert_fixed \
  "yabai signals send only indexes from the fixed event allowlist" \
  'let action = "/usr/bin/printf \(index) | /usr/bin/nc -U \(socketPath)"' \
  "$APP_DELEGATE"

assert_match \
  "automatic naming refreshes immediately when Mission Control enters" \
  'if event == "mission_control_enter"[[:space:]]*\{[[:space:][:print:]]*refreshSpaces\(\)' \
  "$APP_DELEGATE"

assert_match \
  "automatic naming uses a fixed first pass plus trailing convergence" \
  'automaticRefreshGeneration != generation[[:space:]]*\{[[:space:][:print:]]*scheduleAutomaticRefreshPass' \
  "$APP_DELEGATE"

assert_match \
  "Mission Control naming uses the stable CALayer hook with a geometric prefilter" \
  'arg1\.origin\.x == 0 && self\.superlayer\.class == \[CALayer class\]\)[[:space:]]*\{[[:space:]]*\[self sre_applySpaceNamesForFrame:arg1\]' \
  "$DOCK_HOOK"

assert_match \
  "Dock handshake reports Mission Control verification separately from loading" \
  'publishSpacesRenamerInjectionStatus\(@"active"\)' \
  "$DOCK_HOOK"

assert_match \
  "Injection UI distinguishes a loaded payload from an active hook" \
  'case loaded\(pid: Int32, payloadVersion: String\)' \
  "$INJECTION_MANAGER"

assert_match \
  "handshake health rejects a stale payload version" \
  'handshake\.payloadVersion != bundledVersion[[:space:]]*else[[:space:]]*\{[[:space:][:print:]]*updateState\(from: handshake\)' \
  "$INJECTION_MANAGER"

assert_fixed \
  "cancelled administrator authorization has a dedicated state" \
  'case authorizationCancelled(pid: Int32?)' \
  "$INJECTION_MANAGER"

assert_fixed \
  "AppleScript user cancellation is recognized" \
  '?.intValue == -128' \
  "$INJECTION_MANAGER"

assert_fixed \
  "automatic cancellation is remembered for one Dock PID" \
  'cancelledAutomaticInjectionDockPID' \
  "$INJECTION_MANAGER"

assert_fixed \
  "overlapping injection attempts are rejected" \
  'guard !operationInProgress else { return }' \
  "$INJECTION_MANAGER"

assert_fixed \
  "SIP readiness is checked directly" \
  'sipProcess.arguments = ["status"]' \
  "$INJECTION_MANAGER"

assert_fixed \
  "partial SIP requires filesystem protection disabled" \
  'filesystem protections: disabled' \
  "$INJECTION_MANAGER"

assert_fixed \
  "partial SIP requires debugging restrictions disabled" \
  'debugging restrictions: disabled' \
  "$INJECTION_MANAGER"

assert_fixed \
  "partial SIP requires NVRAM protection disabled" \
  'nvram protections: disabled' \
  "$INJECTION_MANAGER"

assert_fixed \
  "moving to Applications tells startup whether to stop onboarding" \
  'static func promptToMoveIfNeeded() -> Bool' \
  "$PREFERENCES"

assert_match \
  "only the arm64e preview ABI boot argument is required" \
  'requiredArguments = \["-arm64e_preview_abi"\]' \
  "$INJECTION_MANAGER"

if rg --quiet 'amfi_get_out_of_my_way' "$INJECTION_SCRIPT"; then
  fail=$((fail + 1))
  echo "FAIL - injection script does not require the optional AMFI workaround"
else
  pass=$((pass + 1))
  echo "ok - injection script does not require the optional AMFI workaround"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
