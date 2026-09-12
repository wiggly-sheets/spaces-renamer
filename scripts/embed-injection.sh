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
# Contents/Resources/Injection. run.sh retains its sibling lib/ contract for
# standalone recovery, while the app verifies and stages the two lib artifacts
# into a root-owned temporary directory before elevation executes them.
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

# The app validates its running code signature before elevating. Xcode's
# linker signature does not seal resources, so replace it after every resource
# has been embedded. A future Developer ID build must embed first and apply its
# distribution signature afterward instead of using this ad-hoc build path.
if [[ -x "$APP/Contents/MacOS/SpacesRenamer" ]]; then
  /usr/bin/codesign \
    --force \
    --sign - \
    --entitlements "$ROOT/SpacesRenamer/SpacesRenamer.entitlements" \
    "$APP"
fi

echo "Embedded injection stack into $DESTINATION"
