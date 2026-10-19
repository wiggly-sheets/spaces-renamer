#!/usr/bin/env bash
# Embed the injection stack into the built SpacesRenamer.app bundle.
#
# Usage: embed-injection.sh [APP]
#
#   APP   Built SpacesRenamer.app bundle.
#         Default: .build/DerivedData/Build/Products/Release/SpacesRenamer.app
#
# The DYLD injector script is copied to Contents/Resources, the arm64e payload
# to Contents/PlugIns, the MIP bundle (assembled by `make bundle` in
# build/) and the private MIP runtime to Contents/Resources. The app is then
# re-signed so the embedded resources are covered by its ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-$ROOT/.build/DerivedData/Build/Products/Release/SpacesRenamer.app}"
MIP_RUNTIME="$ROOT/injection/mip"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found at $APP (run 'make app' first)" >&2
  exit 1
fi
if [[ ! -f "$ROOT/injection/injector.sh" ]]; then
  echo "error: injection script not found at $ROOT/injection/injector.sh" >&2
  exit 1
fi
if [[ ! -f "$ROOT/injection/lib/spaces-renamer.dylib" ]]; then
  echo "error: payload not found at $ROOT/injection/lib/spaces-renamer.dylib" >&2
  exit 1
fi
if [[ ! -d "$ROOT/build/SpacesRenamer.mip.bundle" ]]; then
  echo "error: MIP bundle not found at $ROOT/build/SpacesRenamer.mip.bundle (run 'make bundle' first)" >&2
  exit 1
fi

# Remove the legacy Injection directory if a previous build left it behind.
rm -rf "$APP/Contents/Resources/Injection"

# DYLD injector script lives in Resources; the LaunchAgent copies it to
# ~/Library/Application Support/SpacesRenamer so activation survives app moves.
install -m 0755 "$ROOT/injection/injector.sh" "$APP/Contents/Resources/injector.sh"

# arm64e payload for the DYLD_INSERT_LIBRARIES path.
mkdir -p "$APP/Contents/PlugIns"
install -m 0755 "$ROOT/injection/lib/spaces-renamer.dylib" "$APP/Contents/PlugIns/spaces-renamer.dylib"

# MIP bundle (Info.plist + Contents/MacOS/SpacesRenamer) for the root/MIP path.
rm -rf "$APP/Contents/Resources/SpacesRenamer.mip.bundle"
cp -R "$ROOT/build/SpacesRenamer.mip.bundle" "$APP/Contents/Resources/SpacesRenamer.mip.bundle"

# The private MIP runtime, so a fresh Mac needs nothing but the app: no
# compiler, no GNU binutils and no separate MIP install. The launcher script
# finds it next to itself and installs it into its own root. An older tree
# without the runtime keeps working: the launcher then falls back to the
# user's own MIP install.
if [[ -d "$MIP_RUNTIME" ]]; then
  rm -rf "$APP/Contents/Resources/mip"
  mkdir -p "$APP/Contents/Resources/mip"
  install -m 0755 \
    "$MIP_RUNTIME/injectd" \
    "$MIP_RUNTIME/lsdinjector.dylib" \
    "$MIP_RUNTIME/inject" \
    "$APP/Contents/Resources/mip/"
  install -m 0644 \
    "$MIP_RUNTIME/loader.dylib" \
    "$MIP_RUNTIME/spacesrenamer.injectd.plist" \
    "$MIP_RUNTIME/spacesrenamer.lsdinjector.plist" \
    "$APP/Contents/Resources/mip/"
else
  echo "warning: $MIP_RUNTIME not found; the app will not carry a private MIP runtime" >&2
fi

# The app validates its running code signature before elevating. Xcode's
# linker signature does not seal resources, so replace it after every resource
# has been embedded. Embedded Mach-Os are already linker-signed (arm64e
# requires it), so re-signing without --deep keeps them byte-identical to the
# packaged payloads that `make verify` compares against. A future Developer ID
# build must embed first and apply its distribution signature afterward
# instead of using this ad-hoc build path.
if [[ -x "$APP/Contents/MacOS/SpacesRenamer" ]]; then
  /usr/bin/codesign \
    --force \
    --sign - \
    --entitlements "$ROOT/SpacesRenamer/SpacesRenamer.entitlements" \
    "$APP"
fi

echo "Embedded injection stack into $APP"