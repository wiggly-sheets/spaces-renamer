#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$TMP/ModuleCache" \
  "$ROOT/SpacesRenamer/YabaiClient.swift" \
  "$ROOT/scripts/tests/test_yabai_client.swift" \
  -o "$TMP/YabaiClientRegression"

"$TMP/YabaiClientRegression"
