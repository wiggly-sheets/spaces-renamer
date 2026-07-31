#!/usr/bin/env bash
# Build the distributable Spaces Renamer disk image.
#
# Usage: make-dmg.sh [VERSION] [APP] [OUTPUT_DIR]
#
#   VERSION    Release version, used in the artifact name
#              SpacesRenamer-v<VERSION>.dmg. Defaults to MARKETING_VERSION
#              from the Xcode project.
#   APP        Path to the built SpacesRenamer.app.
#              Default: .build/DerivedData/Build/Products/Release/SpacesRenamer.app
#   OUTPUT_DIR Directory for the .dmg and .sha256 sidecar.
#              Default: .build/DerivedData
#
# The volume is prettified with packaging/background.png (placeholder artwork
# with baked-in "Drag to Applications" instructions) and an Applications
# drop-link, so users see exactly the app and the install target — no stray
# volume files. The window size and icon positions below must stay aligned
# with the artwork: packaging/render-background.swift is the layout source of
# truth (it draws in the same 800x450 bottom-left coordinate space).
# Requires create-dmg: brew install create-dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:-}"
APP="${2:-$ROOT/.build/DerivedData/Build/Products/Release/SpacesRenamer.app}"
OUTPUT_DIR="${3:-$ROOT/.build/DerivedData}"
BACKGROUND="$ROOT/packaging/background.png"

if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -m1 'MARKETING_VERSION' "$ROOT/spaces-renamer.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' \
    | tr -d '[:space:]')"
fi
if [[ -z "$VERSION" ]]; then
  echo "error: unable to determine version (pass it as the first argument)" >&2
  exit 1
fi
# The version becomes part of a filesystem path, so keep it to safe
# characters. Without this, a slash in VERSION would escape OUTPUT_DIR.
if ! [[ "$VERSION" =~ ^[0-9A-Za-z._+-]+$ ]]; then
  echo "error: invalid version '$VERSION'" >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "error: app not found at $APP (run 'make app' first)" >&2
  exit 1
fi
if [[ ! -f "$BACKGROUND" ]]; then
  echo "error: background image not found at $BACKGROUND" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not found (brew install create-dmg)" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/SpacesRenamer.app"

DMG="$OUTPUT_DIR/SpacesRenamer-v${VERSION}.dmg"
mkdir -p "$OUTPUT_DIR"
rm -f "$DMG" "$DMG.sha256"

VOLICON_ARGS=()
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  VOLICON_ARGS=(--volicon "$APP/Contents/Resources/AppIcon.icns")
fi

create-dmg \
  --volname "Spaces Renamer" \
  "${VOLICON_ARGS[@]}" \
  --background "$BACKGROUND" \
  --window-pos 200 120 \
  --window-size 800 450 \
  --icon-size 110 \
  --icon "SpacesRenamer.app" 200 190 \
  --hide-extension "SpacesRenamer.app" \
  --app-drop-link 600 190 \
  --no-internet-enable \
  --overwrite \
  "$DMG" \
  "$STAGING"

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Created $DMG"
echo "SHA256: $(cut -d' ' -f1 "$DMG.sha256")"
