#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
# Throwaway preference domain: the integration test publishes its
# names/monitors snapshot here and the runner removes the plist on exit.
DOMAIN="com.wiggly-sheets.spaces-renamer.dockhook-safety-test"
PREFS="$HOME/Library/Preferences/${DOMAIN}.plist"
trap 'rm -rf "$TMP"; rm -f "$PREFS"' EXIT

COMMON=(
	-fmodules
	-fmodules-cache-path="$TMP/ModuleCache"
	-fno-objc-arc
	-Wall
	-Wextra
	-Wno-unused-function
	-Wno-unused-parameter
	-Wno-sign-compare
	-framework Cocoa
	-framework QuartzCore
	-framework CoreText
)

# Static regression tests: swizzles are replaced with no-ops so the harness
# only exercises the helper functions directly.
xcrun clang "${COMMON[@]}" \
	"$ROOT/spaces-renamer/tests/DockHookSafetyRegression.m" \
	-o "$TMP/DockHookSafetyRegression"
"$TMP/DockHookSafetyRegression"

# Integration test: real ZKSwizzle hooks (ZKSwizzle.m is imported by the
# test file itself), a fake SpacesBar layer tree, and a published
# names/monitors snapshot. The CALayer setBounds:/layoutSublayers hot path
# is driven directly: the bar layer is named "SpacesBar" so
# applySpacesBarNames fires, and the sre_applySpaceNamesForFrame prefilter
# in -setFrame: requires a frame width matching an active display, which the
# zero-sized fake tree never satisfies.
xcrun clang "${COMMON[@]}" \
	-DSPACES_RENAMER_TESTING=1 \
	"$ROOT/spaces-renamer/tests/DockHookSafetyIntegration.m" \
	-o "$TMP/DockHookSafetyIntegration"
SPACES_RENAMER_DOMAIN="$DOMAIN" "$TMP/DockHookSafetyIntegration"
