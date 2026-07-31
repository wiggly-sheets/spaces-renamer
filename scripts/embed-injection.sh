#!/usr/bin/env bash
# Embed the injection stack into the built SpacesRenamer.app bundle.
#
# Usage: embed-injection.sh [APP] [SOURCE_DIR]
#
#   APP         Built SpacesRenamer.app bundle.
#               Default: .build/DerivedData/Build/Products/Release/SpacesRenamer.app
#   SOURCE_DIR  Injection stack directory containing run.sh and lib/.
#               Default: <repo>/injection
#
# The stack is copied to the stable, code-signed-safe location
# Contents/Resources/Injection, preserving run.sh's contract: the script
# resolves its payload from a sibling lib/ directory. The injector executable
# and the payload are marked executable so the app can invoke run.sh with
# /bin/bash directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-$ROOT/.build/DerivedData/Build/Products/Release/SpacesRenamer.app}"
SOURCE_DIR="${2:-$ROOT/injection}"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found at $APP (run 'make app' first)" >&2
  exit 1
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "error: injection source directory not found at $SOURCE_DIR" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_DIR/run.sh" ]]; then
  echo "error: injection script not found at $SOURCE_DIR/run.sh" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_DIR/lib/dylinject" ]]; then
  echo "error: injector executable not found at $SOURCE_DIR/lib/dylinject" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_DIR/lib/spaces-renamer.dylib" ]]; then
  echo "error: payload not found at $SOURCE_DIR/lib/spaces-renamer.dylib" >&2
  exit 1
fi

DESTINATION="$APP/Contents/Resources/Injection"
mkdir -p "$DESTINATION/lib"

install -m 0755 "$SOURCE_DIR/run.sh" "$DESTINATION/run.sh"
install -m 0755 "$SOURCE_DIR/lib/dylinject" "$DESTINATION/lib/dylinject"
install -m 0755 "$SOURCE_DIR/lib/spaces-renamer.dylib" "$DESTINATION/lib/spaces-renamer.dylib"

echo "Embedded injection stack into $DESTINATION"
