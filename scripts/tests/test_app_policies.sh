#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$TMP/ModuleCache" \
  "$ROOT/SpacesRenamer/URLQueryValues.swift" \
  "$ROOT/SpacesRenamer/CLIReplyPathPolicy.swift" \
  "$ROOT/SpacesRenamer/ManagedSymlinkInstaller.swift" \
  "$ROOT/scripts/tests/test_app_policies.swift" \
  -o "$TMP/AppPolicyRegression"

"$TMP/AppPolicyRegression"
