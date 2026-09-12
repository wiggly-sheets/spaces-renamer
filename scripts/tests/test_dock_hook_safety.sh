#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun clang \
  -fmodules \
  -fmodules-cache-path="$TMP/ModuleCache" \
  -fno-objc-arc \
  -Wall \
  -Wextra \
  -Wno-unused-function \
  -Wno-unused-parameter \
  -Wno-sign-compare \
  -framework Cocoa \
  -framework QuartzCore \
  -framework CoreText \
  "$ROOT/spaces-renamer/tests/DockHookSafetyRegression.m" \
  -o "$TMP/DockHookSafetyRegression"

"$TMP/DockHookSafetyRegression"
