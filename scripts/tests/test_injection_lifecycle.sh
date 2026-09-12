#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$TMP/ModuleCache" \
  "$ROOT/SpacesRenamer/InjectionLifecycle.swift" \
  "$ROOT/scripts/tests/test_injection_lifecycle.swift" \
  -o "$TMP/InjectionLifecycleRegression"

"$TMP/InjectionLifecycleRegression"
