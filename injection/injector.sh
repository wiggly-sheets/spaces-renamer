#!/bin/sh
#
# injector.sh — loads and unloads spaces-renamer.dylib into the process that draws the Mission
# Control Spaces bar (WindowManager on macOS 27+, Dock on macOS 26). It is the single mechanism
# behind both the app's activation UI and manual Terminal use, and supports two injectors:
#
#   dyld   DYLD_INSERT_LIBRARIES via a per-user LaunchAgent. No root. Reversible with `launchctl
#          unsetenv` and a host restart. The dylib is loaded into every GUI process launched
#          afterwards, but its constructor no-ops unless the host is WindowManager/Dock.
#
#   mip    A MIP bundle dropped into a MIP Bundles directory. Requires root. The app ships a
#          private MIP runtime that installs into /Library/SpacesRenamer/mip and owns its own
#          Mach service, so a system MIP install is used only when the app carries no runtime.
#          MIP loads the bundle only into the executables named in the bundle's Info.plist.
#          Survives reboot with no login agent.
#
# Usage:
#   injector.sh status
#   injector.sh host
#   injector.sh dyld on   <dylib>
#   injector.sh dyld off
#   injector.sh dyld boot                 # internal: invoked by the LaunchAgent at login
#   injector.sh mip  on   <assembled .bundle>   # needs root
#   injector.sh mip  off                        # needs root
#   injector.sh mip-runtime status              # the private runtime's state
#   injector.sh mip-runtime uninstall           # needs root
#
# Prerequisites for either injector: SIP disabled and `boot-args=-arm64e_preview_abi` (see README).

set -eu

SUPPORT="$HOME/Library/Application Support/SpacesRenamer"
DYLIB_STORE="$SUPPORT/spaces-renamer.dylib"
SCRIPT_STORE="$SUPPORT/injector.sh"

AGENT_LABEL="com.wiggly-sheets.SpacesRenamer.injector"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# The private MIP runtime: our own build of MIP. It installs into its own root and owns its
# own Mach service, so a system MIP install is never modified.
MIP_PRIVATE_ROOT="/Library/SpacesRenamer/mip"
MIP_SERVICE_NAME="com.wiggly-sheets.spaces-renamer.injectd"
MIP_INJECTD_LABEL="com.wiggly-sheets.spaces-renamer.injectd"
MIP_LSDINJECTOR_LABEL="com.wiggly-sheets.spaces-renamer.lsdinjector"
# The user's own MIP install, if any. Read-only for us: only our own bundle is ever removed
# from it, so the host does not load the bundle twice.
SYSTEM_MIP_ROOT="/Library/Apple/System/Library/Frameworks/mip"
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

# Active when the LaunchAgent is installed and the variable already names the
# stored payload — the state `dyld boot` produces, i.e. the host has restarted
# into the library. Shared by `status` and the `dyld on` idempotency guard.
dyld_is_active() {
	[ -f "$AGENT_PLIST" ] && [ "${1:-}" = "$DYLIB_STORE" ]
}

# ---------------------------------------------------------------------------- dyld

write_agent_plist() {
	/bin/mkdir -p "$(dirname "$AGENT_PLIST")"
	cat >"$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$SCRIPT_STORE</string>
		<string>dyld</string>
		<string>boot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$SUPPORT/injector.log</string>
</dict>
</plist>
PLIST
}

dyld_on() {
	dylib=${1:-}
	[ -n "$dylib" ] || die "dyld on: missing <dylib> path"
	[ -f "$dylib" ] || die "dyld on: no dylib at $dylib"
	dylib=$(cd "$(dirname "$dylib")" && printf '%s/%s' "$(pwd)" "$(basename "$dylib")")

	env_val=$(launchctl getenv "$DYLD_VAR" 2>/dev/null || true)
	if dyld_is_active "$env_val"; then
		log "dyld already active"
		return 0
	fi

	/bin/mkdir -p "$SUPPORT"
	/bin/cp "$dylib" "$DYLIB_STORE"
	# Keep a stable copy of this script for the LaunchAgent, so activation survives moving the app.
	if [ "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" != "$SCRIPT_STORE" ]; then
		/bin/cp "$0" "$SCRIPT_STORE"
	fi

	write_agent_plist
	# (Re)load the agent for this login session; RunAtLoad runs `dyld boot`, which sets the
	# environment variable and restarts the host so it inherits the library.
	uid=$(id -u)
	launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
	launchctl bootstrap "gui/$uid" "$AGENT_PLIST"
	log "dyld injector activated ($DYLIB_STORE)"
}

# Invoked by the LaunchAgent (and once at activation): publish the variable and restart the host.
dyld_boot() {
	[ -f "$DYLIB_STORE" ] || die "dyld boot: dylib missing ($DYLIB_STORE); run 'dyld on <dylib>' first"
	launchctl setenv "$DYLD_VAR" "$DYLIB_STORE"
	restart_host
}

dyld_off() {
	uid=$(id -u)
	bootout_ok=0
	launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || bootout_ok=1
	/bin/rm -f "$AGENT_PLIST"
	launchctl unsetenv "$DYLD_VAR"
	restart_host
	if [ "$bootout_ok" -eq 0 ]; then
		/bin/rm -f "$DYLIB_STORE" "$SCRIPT_STORE"
		log "dyld injector removed"
	else
		log "warning: bootout failed (agent may still be registered); keeping $SCRIPT_STORE and $DYLIB_STORE for recovery"
	fi
}

# ---------------------------------------------------------------------------- mip

require_root() { [ "$(id -u)" -eq 0 ] || die "$1 requires root (run under sudo or the app's admin prompt)"; }

# The private runtime ships inside the app bundle, next to this script:
# Contents/Resources/mip. A checkout has no such directory, so there the user's own system
# MIP install is used instead.
mip_payload_dir() {
	dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || return 1
	[ -d "$dir/mip" ] || return 1
	printf '%s\n' "$dir/mip"
}

# Our runtime files are present in the private root.
mip_runtime_installed() {
	[ -f "$MIP_PRIVATE_ROOT/injectd" ] && [ -f "$MIP_PRIVATE_ROOT/loader.dylib" ] &&
		[ -f "$MIP_PRIVATE_ROOT/lsdinjector.dylib" ] && [ -f "$MIP_PRIVATE_ROOT/inject" ]
}

# The root the runtime in use lives in: the private one when it is installed there, the system
# MIP root when the user has MIP installed, and the private root as the intended target.
mip_runtime_root() {
	if mip_runtime_installed; then
		printf '%s\n' "$MIP_PRIVATE_ROOT"
	elif [ -d "$SYSTEM_MIP_ROOT" ]; then
		printf '%s\n' "$SYSTEM_MIP_ROOT"
	else
		printf '%s\n' "$MIP_PRIVATE_ROOT"
	fi
}

# The root `mip on` writes to: the private one when the app ships the runtime, the system MIP
# install otherwise.
mip_install_root() {
	if mip_payload_dir >/dev/null 2>&1; then
		printf '%s\n' "$MIP_PRIVATE_ROOT"
	else
		printf '%s\n' "$SYSTEM_MIP_ROOT"
	fi
}

# The bundle directory of a root.
mip_bundles_dir() { printf '%s/Bundles\n' "$1"; }

# The Mach service the runtime in use owns.
mip_service_name() {
	if [ "$(mip_runtime_root)" = "$MIP_PRIVATE_ROOT" ]; then
		printf '%s\n' "$MIP_SERVICE_NAME"
	else
		printf '%s\n' "local.injectd"
	fi
}

# The system MIP daemon, and ours. The system daemon is never touched: the private runtime
# owns its own service.
mip_system_daemon_alive() {
	launchctl print system/local.injectd >/dev/null 2>&1
}

mip_private_daemon_alive() {
	launchctl print "system/$MIP_INJECTD_LABEL" >/dev/null 2>&1
}

# The daemon that backs the root in use. In the system-root case either daemon counts: a
# private runtime may still be running from an earlier install.
mip_daemon_alive() {
	if [ "$(mip_runtime_root)" = "$MIP_PRIVATE_ROOT" ]; then
		mip_private_daemon_alive
	else
		mip_system_daemon_alive || mip_private_daemon_alive
	fi
}

mip_lsd_pid() {
	/usr/bin/pgrep -x launchservicesd 2>/dev/null | head -1
}

# The MIP hook is a dylib mapped into launchservicesd. Root can read the mapping list, so the
# check is exact. Both the system MIP install and the private runtime map a file called
# lsdinjector.dylib.
mip_lsd_hooked() {
	pid=$(mip_lsd_pid)
	[ -n "$pid" ] || return 1
	/usr/sbin/lsof -p "$pid" 2>/dev/null | grep -q "lsdinjector.dylib"
}

# Remove our bundle from a root. Only our bundle: the runtime in that root and every other
# bundle stay untouched.
mip_remove_bundle() {
	dest="$(mip_bundles_dir "$1")/$MIP_BUNDLE_NAME"
	if [ -d "$dest" ]; then
		/bin/rm -rf "$dest"
		log "removed our bundle from $dest"
	fi
}

# MIP hooks launchservicesd with a one-shot boot job. When launchservicesd is replaced after
# that job ran, the new process has no hook, so no GUI app receives the loader and the bundle
# is never loaded. Re-run the job so the current launchservicesd gets the hook. Never fatal:
# the hook may already be in place, and a stacked hook would hand every GUI app the loader
# more than once.
mip_repair_chain() {
	root=$(mip_install_root)
	if [ "$root" = "$MIP_PRIVATE_ROOT" ]; then
		label=$MIP_LSDINJECTOR_LABEL
		injector="$MIP_PRIVATE_ROOT/inject"
	else
		label="local.lsdinjector"
		injector="/usr/local/bin/inject"
	fi
	if mip_lsd_hooked; then
		log "MIP hook already present in launchservicesd (pid $(mip_lsd_pid))"
		return 0
	fi
	attempted=0
	if launchctl kickstart -k "system/$label" >/dev/null 2>&1; then
		attempted=1
	elif [ -x "$injector" ] && [ -f "$root/lsdinjector.dylib" ]; then
		if "$injector" launchservicesd "$root/lsdinjector.dylib" -w4 >/dev/null 2>&1; then
			attempted=1
		fi
	fi
	if [ "$attempted" -eq 1 ] && mip_lsd_hooked; then
		log "re-injected the MIP hook into launchservicesd (pid $(mip_lsd_pid))"
		return 0
	fi
	log "warning: MIP hook is still not visible in launchservicesd"
	return 1
}

# Write one of the runtime's LaunchDaemon plists with the install-time placeholders
# substituted.
mip_write_plist() {
	src=$1
	dst="/Library/LaunchDaemons/$2.plist"
	tmp=$(/usr/bin/mktemp)
	/usr/bin/sed -e "s=@MIP_ROOT@=$MIP_PRIVATE_ROOT=g" -e "s=@MIP_SERVICE_NAME@=$MIP_SERVICE_NAME=g" \
		"$src" >"$tmp"
	/usr/bin/install -m 0644 -o root -g wheel "$tmp" "$dst"
	/bin/rm -f "$tmp"
}

# Register a LaunchDaemon we own. A job that is already registered is left alone; launchd
# would refuse the second bootstrap anyway.
mip_bootstrap_daemon() {
	label=$1
	if launchctl print "system/$label" >/dev/null 2>&1; then
		log "$label is already registered"
		return 0
	fi
	launchctl bootstrap system "/Library/LaunchDaemons/$label.plist" 2>/dev/null ||
		log "warning: could not bootstrap $label"
}

# Install the private runtime: the four binaries, the two LaunchDaemon plists and the
# library-validation exception the runtime needs to load into signed system processes.
mip_install_runtime() {
	payload=$1
	/bin/mkdir -p "$MIP_BUNDLES" "$MIP_PRIVATE_ROOT/user_data"
	# Overwriting a signed Mach-O in place breaks its signature, so the files are replaced
	# instead of written over.
	/bin/rm -f "$MIP_PRIVATE_ROOT/injectd" "$MIP_PRIVATE_ROOT/loader.dylib" \
		"$MIP_PRIVATE_ROOT/lsdinjector.dylib" "$MIP_PRIVATE_ROOT/inject"
	/bin/cp "$payload/injectd" "$payload/loader.dylib" "$payload/lsdinjector.dylib" \
		"$payload/inject" "$MIP_PRIVATE_ROOT/"
	/usr/sbin/chown -R root:wheel "$MIP_PRIVATE_ROOT"
	/bin/chmod 0755 "$MIP_PRIVATE_ROOT/injectd" "$MIP_PRIVATE_ROOT/lsdinjector.dylib" \
		"$MIP_PRIVATE_ROOT/inject"
	/bin/chmod 0644 "$MIP_PRIVATE_ROOT/loader.dylib"

	mip_write_plist "$payload/spacesrenamer.injectd.plist" "$MIP_INJECTD_LABEL"
	mip_write_plist "$payload/spacesrenamer.lsdinjector.plist" "$MIP_LSDINJECTOR_LABEL"

	# Signed system processes refuse to load libraries that are not signed by Apple. Only
	# write the key when it is missing or still false.
	value=$(/usr/bin/defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist \
		DisableLibraryValidation 2>/dev/null || true)
	case "$value" in
	1 | true | YES | yes) ;;
	*) /usr/bin/defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist \
		DisableLibraryValidation -bool true ;;
	esac
}

mip_on() {
	bundle=${1:-}
	require_root "mip on"
	[ -n "$bundle" ] || die "mip on: missing assembled <.bundle> path"
	[ -d "$bundle" ] || die "mip on: no bundle directory at $bundle"

	root=$(mip_install_root)
	if [ "$root" = "$MIP_PRIVATE_ROOT" ]; then
		log "installing the bundled runtime into $MIP_PRIVATE_ROOT"
		mip_install_runtime "$(mip_payload_dir)"
		mip_bootstrap_daemon "$MIP_INJECTD_LABEL"
		launchctl enable "system/$MIP_INJECTD_LABEL" 2>/dev/null || true
		mip_bootstrap_daemon "$MIP_LSDINJECTOR_LABEL"
		# The one-shot hook job needs a moment to inject into launchservicesd.
		sleep 1
		# A copy of our bundle in the system root would be loaded a second time.
		mip_remove_bundle "$SYSTEM_MIP_ROOT"
	else
		log "no bundled runtime found; using the system MIP install at $root"
		[ -d "$root" ] || die "MIP is not installed at $root (see README: install LIJI32/MIP first)"
		mip_system_daemon_alive || die "MIP daemon not running (start MIP first)"
		mip_remove_bundle "$MIP_PRIVATE_ROOT"
	fi

	mip_repair_chain || log "warning: MIP hook repair failed; the host may not load the bundle"

	dest="$(mip_bundles_dir "$root")/$MIP_BUNDLE_NAME"
	/bin/mkdir -p "$(dirname "$dest")"
	/bin/rm -rf "$dest"
	/bin/cp -R "$bundle" "$dest"
	# Apple-signed hosts refuse to load libraries not owned by root.
	/usr/sbin/chown -R root:wheel "$dest"
	restart_host
	log "mip bundle installed to $dest"
}

mip_off() {
	require_root "mip off"
	# Our bundle only: the runtime in either root stays in place.
	mip_remove_bundle "$MIP_PRIVATE_ROOT"
	mip_remove_bundle "$SYSTEM_MIP_ROOT"
	restart_host
	log "mip bundle removed"
}

# Remove the private runtime: both of our daemons, both of our plists and the private root.
# The system MIP install and the system launchd jobs are never touched.
mip_runtime_uninstall() {
	require_root "mip-runtime uninstall"
	launchctl bootout "system/$MIP_INJECTD_LABEL" 2>/dev/null || true
	launchctl bootout "system/$MIP_LSDINJECTOR_LABEL" 2>/dev/null || true
	/bin/rm -f "/Library/LaunchDaemons/$MIP_INJECTD_LABEL.plist" \
		"/Library/LaunchDaemons/$MIP_LSDINJECTOR_LABEL.plist"
	mip_remove_bundle "$SYSTEM_MIP_ROOT"
	/bin/rm -rf "$MIP_PRIVATE_ROOT"
	log "private runtime removed from $MIP_PRIVATE_ROOT"
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
	rt_root=$(mip_runtime_root)
	echo "runtime_root=$rt_root"
	if mip_runtime_installed; then echo "runtime_installed=on"; else echo "runtime_installed=off"; fi
	if mip_daemon_alive; then echo "runtime_daemon=up"; else echo "runtime_daemon=down"; fi
	if mip_lsd_hooked; then echo "runtime_hooked=on"; else echo "runtime_hooked=off"; fi
	if [ -d "$(mip_bundles_dir "$rt_root")/$MIP_BUNDLE_NAME" ]; then
		echo "runtime_bundle=on"
	else
		echo "runtime_bundle=off"
	fi
	echo "runtime_service=$(mip_service_name)"
}

status() {
	echo "host=$(host_process)"

	env_val=$(launchctl getenv "$DYLD_VAR" 2>/dev/null || true)
	if [ -f "$AGENT_PLIST" ]; then echo "dyld_agent=present"; else echo "dyld_agent=absent"; fi
	if [ -n "$env_val" ]; then echo "dyld_env=set"; else echo "dyld_env=unset"; fi
	if dyld_is_active "$env_val"; then dyld=on; else dyld=off; fi
	echo "dyld=$dyld"

	if mip_runtime_installed || [ -d "$SYSTEM_MIP_ROOT" ]; then echo "mip_installed=yes"; else echo "mip_installed=no"; fi
	if [ -d "$(mip_bundles_dir "$(mip_runtime_root)")/$MIP_BUNDLE_NAME" ]; then mipb=on; else mipb=off; fi
	echo "mip_bundle=$mipb"
	if mip_daemon_alive; then echo "mip_daemon=up"; else echo "mip_daemon=down"; fi

	if [ "$mipb" = on ] && mip_daemon_alive; then
		active=mip
	elif [ "$dyld" = on ]; then
		active=dyld
	else active=none; fi
	echo "arm64e=$(arm64e_state)"
	echo "active=$active"
	mip_runtime_status
}

# ---------------------------------------------------------------------------- dispatch

cmd=${1:-status}
case "$cmd" in
status) status ;;
host) host_process ;;
dyld)
	sub=${2:-}
	case "$sub" in
	on) dyld_on "${3:-}" ;;
	off) dyld_off ;;
	boot) dyld_boot ;;
	*) die "usage: injector.sh dyld on <dylib> | off" ;;
	esac
	;;
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
	*) die "usage: injector.sh mip on <.bundle> | off  (root)" ;;
	esac
	;;
mip-runtime)
	sub=${2:-}
	case "$sub" in
	status) mip_runtime_status ;;
	uninstall) mip_runtime_uninstall ;;
	*) die "usage: injector.sh mip-runtime status | uninstall  (uninstall needs root)" ;;
	esac
	;;
*) die "usage: injector.sh {status|host|dyld|mip|mip-runtime|arm64e} ..." ;;
esac
