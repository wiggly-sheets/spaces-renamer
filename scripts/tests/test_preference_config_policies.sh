#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$TMP/ModuleCache" \
  "$ROOT/SpacesRenamer/ConfigPolicies.swift" \
  "$ROOT/SpacesRenamer/ProfileNamePolicy.swift" \
  "$ROOT/scripts/tests/test_preference_config_policies.swift" \
  -o "$TMP/PreferenceConfigPolicyRegression"

"$TMP/PreferenceConfigPolicyRegression"
