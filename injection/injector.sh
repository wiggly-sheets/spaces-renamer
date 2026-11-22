#!/bin/sh
#
# injector.sh — loads and unloads spaces-renamer.dylib into the process that draws the Mission
# Control Spaces bar (WindowManager on macOS 27+, Dock on macOS 26). It is the single mechanism
# behind both the app's activation UI and manual Terminal use:
#
#   mip    A MIP loader loaded into the host for one restart. The app ships the loader and a
#          bundle; both install in the user's Application Support. The loader maps the bundle
#          only into the executables named in its Info.plist. No daemon and no root install.
#
# Usage:
#   injector.sh status
#   injector.sh host
#   injector.sh mip  on   <assembled .bundle>
#   injector.sh mip  off
#   injector.sh mip-runtime status              # the private runtime's state
#   injector.sh mip-runtime uninstall
#
# Prerequisites: SIP disabled and `boot-args=-arm64e_preview_abi` (see README).

set -eu

# The private MIP loader and bundle. The loader reads Bundles from its own directory, so a
# user-owned root is enough.
MIP_PRIVATE_ROOT="$HOME/Library/Application Support/SpacesRenamer/mip"
MIP_BUNDLES="$MIP_PRIVATE_ROOT/Bundles"
MIP_BUNDLE_NAME="SpacesRenamer.mip.bundle"

DYLD_VAR="DYLD_INSERT_LIBRARIES"
ARM64E_FLAG="-arm64e_preview_abi"

log() { printf 'injector: %s\n' "$*" >&2; }
die() {
	log "$*"
	exit 1
}

# The process that renders the Spaces bar for this macOS release.
host_process() {
	major=$(sw_vers -productVersion | cut -d. -f1)
	if [ "$major" -ge 27 ] 2>/dev/null; then echo WindowManager; else echo Dock; fi
}

restart_host() {
	host=$(host_process)
	/usr/bin/killall "$host" 2>/dev/null || true
	log "restarted $host"
}

# ---------------------------------------------------------------------------- mip

# The private MIP path loads the loader into the host only. The loader reads its own directory
# for Bundles, so the loader and the bundle share a user-owned root. No daemon, no Mach service,
# and no root install are involved: a short-lived DYLD_INSERT_LIBRARIES window during a host
# restart is enough, and the loader filters by the bundle's Info.plist.
mip_payload_dir() {
  dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || return 1
  [ -f "$dir/mip/loader.dylib" ] || return 1
  printf '%s\n' "$dir/mip"
}

mip_runtime_installed() {
  [ -f "$MIP_PRIVATE_ROOT/loader.dylib" ]
}

mip_bundle_installed() {
  [ -d "$MIP_BUNDLES/$MIP_BUNDLE_NAME" ]
}

host_pid() {
  /usr/bin/pgrep -x "$(host_process)" 2>/dev/null | /usr/bin/head -1
}

# The marker's HostPID names the running host. A stale marker from before a host restart does
# not count as loaded.
mip_loaded() {
  pid=$(host_pid || true)
  [ -n "$pid" ] || return 1
  case "$(host_process)" in
  WindowManager) domain=com.apple.WindowManager ;;
  *) domain=com.apple.dock ;;
  esac
  marker=$(/usr/bin/defaults read "$domain" SpacesRenamerPlugin 2>/dev/null || true)
  marker_pid=$(printf '%s\n' "$marker" | /usr/bin/awk '/HostPID/ { print $3 }' | /usr/bin/tr -d ';')
  [ -n "$marker_pid" ] && [ "$marker_pid" = "$pid" ]
}

# The loader is the only runtime file. Replacing it in place would break its signature, so
# remove the old vnode first.
mip_install_runtime() {
  payload=$1
  /bin/mkdir -p "$MIP_BUNDLES"
  /bin/rm -f "$MIP_PRIVATE_ROOT/loader.dylib"
  /bin/cp "$payload/loader.dylib" "$MIP_PRIVATE_ROOT/loader.dylib"
  /bin/chmod 0644 "$MIP_PRIVATE_ROOT/loader.dylib"
}

# The loader is user-owned and ad-hoc signed, so the platform host only maps it when the
# system-wide Library Validation exception is present. Writing it needs admin once; activation
# stays unprivileged.
library_validation_disabled() {
  value=$(/usr/bin/defaults read \
    /Library/Preferences/com.apple.security.libraryvalidation.plist \
    DisableLibraryValidation 2>/dev/null || true)
  case "$value" in
  1 | true | YES | yes) return 0 ;;
  *) return 1 ;;
  esac
}

# Set the variable just long enough to restart the host, then remove it. The install root is
# user-owned, so this needs no elevation. The loader maps only into WindowManager/Dock.
mip_activate() {
  loader="$MIP_PRIVATE_ROOT/loader.dylib"
  [ -f "$loader" ] || die "mip activate: loader missing ($loader)"
  old=$(host_pid || true)
  launchctl setenv "$DYLD_VAR" "$loader"
  trap 'launchctl unsetenv "$DYLD_VAR" 2>/dev/null || true' EXIT HUP INT TERM
  restart_host
  new=""
  i=0
  while [ "$i" -lt 50 ]; do
    /bin/sleep 0.1
    new=$(host_pid || true)
    if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
    i=$((i + 1))
  done
  launchctl unsetenv "$DYLD_VAR"
  trap - EXIT HUP INT TERM
  if [ -z "$new" ] || [ "$new" = "$old" ]; then
    die "mip activate: the host did not restart"
  fi
  log "MIP loader active in $(host_process) (pid $new)"
}

mip_on() {
  bundle=${1:-}
  [ -n "$bundle" ] || die "mip on: missing assembled <.bundle> path"
  [ -d "$bundle" ] || die "mip on: no bundle directory at $bundle"
  if ! library_validation_disabled; then
    die "mip on: Library Validation is enabled. Run once: sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true"
  fi
  payload=$(mip_payload_dir) || die "mip on: no loader next to this script (Contents/Resources/mip)"
  mip_install_runtime "$payload"
  dest="$MIP_BUNDLES/$MIP_BUNDLE_NAME"
  /bin/rm -rf "$dest"
  /bin/cp -R "$bundle" "$dest"
  log "installed MIP loader and bundle in $MIP_PRIVATE_ROOT"
  mip_activate
}

mip_off() {
  launchctl unsetenv "$DYLD_VAR" 2>/dev/null || true
  restart_host
  log "MIP loader unloaded"
}

mip_runtime_uninstall() {
  mip_off
  /bin/rm -rf "$MIP_PRIVATE_ROOT"
  log "private MIP runtime removed from $MIP_PRIVATE_ROOT"
}

# ---------------------------------------------------------------------------- arm64e ABI

current_boot_args() {
	/usr/sbin/nvram boot-args 2>/dev/null | sed -e 's/^boot-args[[:space:]]*//'
}

arm64e_state() {
	case " $(current_boot_args) " in
	*" $ARM64E_FLAG "*) echo on ;;
	*) echo off ;;
	esac
}

# Add the preview-ABI flag to boot-args without disturbing any flags already there. Takes effect
# on the next reboot. Root, because it writes NVRAM.
arm64e_on() {
	require_root "arm64e on"
	if [ "$(arm64e_state)" = on ]; then
		log "arm64e ABI already enabled"
		return 0
	fi
	args=$(current_boot_args)
	newargs=$(printf '%s %s' "$args" "$ARM64E_FLAG" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	/usr/sbin/nvram boot-args="$newargs"
	log "boot-args set to: $newargs (reboot to apply)"
}

# ---------------------------------------------------------------------------- status

# The private runtime's state. The same keys are printed by `status` and by
# `mip-runtime status`, so the app can read them from either.
mip_runtime_status() {
	echo "runtime_root=$MIP_PRIVATE_ROOT"
	if mip_runtime_installed; then echo "runtime_installed=on"; else echo "runtime_installed=off"; fi
	if mip_bundle_installed; then
		echo "runtime_bundle=on"
	else
		echo "runtime_bundle=off"
	fi
	if mip_loaded; then echo "runtime_loaded=on"; else echo "runtime_loaded=off"; fi
}

status() {
	echo "host=$(host_process)"

	if mip_runtime_installed; then echo "mip_installed=yes"; else echo "mip_installed=no"; fi
	if mip_bundle_installed; then mipb=on; else mipb=off; fi
	echo "mip_bundle=$mipb"

	if [ "$mipb" = on ] && mip_loaded; then active=mip; else active=none; fi
	echo "arm64e=$(arm64e_state)"
	echo "active=$active"
	mip_runtime_status
}

# ---------------------------------------------------------------------------- dispatch

cmd=${1:-status}
case "$cmd" in
status) status ;;
host) host_process ;;
arm64e)
	sub=${2:-}
	case "$sub" in
	on) arm64e_on ;;
	*) die "usage: injector.sh arm64e on  (root)" ;;
	esac
	;;
mip)
	sub=${2:-}
	case "$sub" in
	on) mip_on "${3:-}" ;;
	off) mip_off ;;
	*) die "usage: injector.sh mip on <.bundle> | off" ;;
	esac
	;;
mip-runtime)
	sub=${2:-}
	case "$sub" in
	status) mip_runtime_status ;;
	uninstall) mip_runtime_uninstall ;;
	*) die "usage: injector.sh mip-runtime status | uninstall" ;;
	esac
	;;
*) die "usage: injector.sh {status|host|mip|mip-runtime|arm64e} ..." ;;
esac
