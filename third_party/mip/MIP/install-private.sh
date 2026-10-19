#!/bin/bash
#
# install-private.sh — install the private MIP runtime.
#
# Installs the built runtime into a private root and registers the private LaunchDaemons.
# It never touches an existing system MIP install: not its root, not its LaunchDaemons,
# not /usr/local/bin/inject and not the user's ~/Library/MIP symlink.
#
# Usage (as root):  ./install-private.sh <root> <build-dir> <injectd-label> <lsdinjector-label>

set -euo pipefail

ROOT=${1:-/Library/SpacesRenamer/mip}
BUILD=${2:?build directory}
INJECTD_LABEL=${3:-com.wiggly-sheets.spaces-renamer.injectd}
LSDINJECTOR_LABEL=${4:-com.wiggly-sheets.spaces-renamer.lsdinjector}

if [ "$(id -u)" -ne 0 ]; then
	echo "install-private.sh must run as root" >&2
	exit 1
fi

for binary in injectd loader.dylib lsdinjector.dylib inject; do
	if [ ! -f "$BUILD/$binary" ]; then
		echo "missing build artifact: $BUILD/$binary" >&2
		exit 1
	fi
done

echo "==> installing private MIP runtime into $ROOT"
mkdir -p "$ROOT/user_data" "$ROOT/Bundles"
chown -R root:wheel "$ROOT"
chmod 755 "$ROOT" "$ROOT/user_data" "$ROOT/Bundles"

# Remove the old binaries first: overwriting a signed Mach-O in place breaks its signature.
rm -f "$ROOT/injectd" "$ROOT/loader.dylib" "$ROOT/lsdinjector.dylib" "$ROOT/inject"
install -m 755 -o root -g wheel "$BUILD/injectd" "$ROOT/injectd"
install -m 755 -o root -g wheel "$BUILD/loader.dylib" "$ROOT/loader.dylib"
install -m 755 -o root -g wheel "$BUILD/lsdinjector.dylib" "$ROOT/lsdinjector.dylib"
install -m 755 -o root -g wheel "$BUILD/inject" "$ROOT/inject"

echo "==> installing LaunchDaemons"
install -m 644 -o root -g wheel "$BUILD/$INJECTD_LABEL.plist" "/Library/LaunchDaemons/$INJECTD_LABEL.plist"
install -m 644 -o root -g wheel "$BUILD/$LSDINJECTOR_LABEL.plist" "/Library/LaunchDaemons/$LSDINJECTOR_LABEL.plist"

# Signed system processes refuse to load libraries that are not signed by Apple. The system
# MIP install usually already disabled library validation; only write the key when missing.
if ! /usr/bin/defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation >/dev/null 2>&1; then
	echo "==> disabling library validation (required to load the runtime into signed processes)"
	/usr/bin/defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
fi

echo "==> (re)loading LaunchDaemons"
/bin/launchctl bootout "system/$INJECTD_LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$LSDINJECTOR_LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "/Library/LaunchDaemons/$INJECTD_LABEL.plist"
/bin/launchctl bootstrap system "/Library/LaunchDaemons/$LSDINJECTOR_LABEL.plist"

echo "==> done"
/bin/launchctl print "system/$INJECTD_LABEL" | head -3
