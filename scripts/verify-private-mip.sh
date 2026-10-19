#!/bin/bash
# Verify the private MIP runtime that SpacesRenamer installs.
#
#   sudo scripts/verify-private-mip.sh
#
# It removes the stale copy of our bundle from the SYSTEM MIP directory (so the
# hook is not loaded twice), restarts WindowManager so the private chain gets
# to load it, then prints the evidence. Read-only otherwise.

set -u
PRIVATE_ROOT=/Library/SpacesRenamer/mip
SYSTEM_MIP=/Library/Apple/System/Library/Frameworks/mip
SYSTEM_BUNDLE="$SYSTEM_MIP/Bundles/SpacesRenamer.mip.bundle"
BUNDLE="$PRIVATE_ROOT/Bundles/SpacesRenamer.mip.bundle"

section() { printf '\n=== %s ===\n' "$1"; }

section "0. stop the app (it would re-inject through the system MIP path)"
if pkill -x SpacesRenamer 2>/dev/null; then echo "app stopped"; else echo "app not running"; fi

section "1. remove the stale SYSTEM copy of our bundle (prevents a double load)"
if [ -d "$SYSTEM_BUNDLE" ]; then
	/bin/rm -rf "$SYSTEM_BUNDLE"
	echo "removed $SYSTEM_BUNDLE"
else
	echo "already absent"
fi
ls -la "$SYSTEM_MIP/Bundles/"

section "2. private runtime files and ownership"
ls -ld "$PRIVATE_ROOT" "$PRIVATE_ROOT/Bundles" "$BUNDLE"
ls -l "$BUNDLE/Contents/MacOS/"
/usr/bin/file "$BUNDLE/Contents/MacOS/SpacesRenamer"

section "3. private daemons"
/bin/launchctl print system/com.wiggly-sheets.spaces-renamer.injectd 2>&1 | grep -E "state =|program =" | head -4
/bin/launchctl print system/com.wiggly-sheets.spaces-renamer.lsdinjector 2>&1 | grep -E "state =|program =|runs =|last exit code" | head -6

section "4. restart the host so the private chain can load the bundle"
/usr/bin/killall WindowManager
sleep 12
LSD=$(/usr/bin/pgrep -x launchservicesd | head -1)
WM=$(/usr/bin/pgrep -x WindowManager | head -1)
echo "launchservicesd pid=$LSD   WindowManager pid=$WM"

section "5. launchservicesd carries BOTH lsdinjectors (system + private)"
/usr/sbin/lsof -p "$LSD" 2>/dev/null | grep lsdinjector || echo "(none: the chain is broken)"

section "6. WindowManager loaded our dylib from the PRIVATE root"
/usr/sbin/lsof -p "$WM" 2>/dev/null | grep -E "SpacesRenamer/mip|spaces-renamer" || echo "(no mip image: the bundle was not loaded)"

section "7. handshake marker (LoadedAt must be now, HostPID the new WindowManager pid)"
/usr/bin/defaults read com.apple.WindowManager SpacesRenamerPlugin 2>&1

section "8. coexistence: a GUI app carries BOTH loaders"
FDR=$(/usr/bin/pgrep -x Finder | head -1)
/usr/sbin/lsof -p "$FDR" 2>/dev/null | grep "mip/loader" || echo "(no loader in Finder)"

section "9. system MIP chain untouched"
/bin/launchctl print system/local.injectd 2>&1 | grep -E "state =|program =" | head -3

section "10. done - relaunch the app: open -a SpacesRenamer"
