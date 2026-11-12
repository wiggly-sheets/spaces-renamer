#!/usr/bin/env bash
# The SDK version recorded in LC_BUILD_VERSION decides whether macOS 26/27
# draws the Liquid Glass design. SwiftPM under Xcode 27 stamps the deployment
# target (14.0) there by default, which silently selects the legacy design,
# so the manifest must stamp the 26.0 floor and the app must not opt out.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE="$ROOT/SpacesRenamer/Package.swift"
INFO_PLIST="$ROOT/SpacesRenamer/Info.plist"

pass=0
fail=0

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      pass=$((pass + 1))
      echo "ok - $description"
      ;;
    *)
      fail=$((fail + 1))
      echo "FAIL - $description"
      ;;
  esac
}

manifest="$(tr -s '[:space:]' ' ' < "$PACKAGE")"

assert_contains \
  "the app stamps the linker platform version" \
  "$manifest" \
  '"-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"'

if grep -F -q 'UIDesignRequiresCompatibility' "$INFO_PLIST"; then
  fail=$((fail + 1))
  echo "FAIL - the app does not opt out of the new design"
else
  pass=$((pass + 1))
  echo "ok - the app does not opt out of the new design"
fi

assert_contains \
  "the app keeps its macOS 14 deployment target" \
  "$(tr -s '[:space:]' ' ' < "$PACKAGE")" \
  'platforms: [.macOS("14.0")]'

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
