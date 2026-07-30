#!/bin/bash
set -euo pipefail

label="com.wiggly-sheets.SpacesRenamer.InjectionHelper"
install_dir="/Library/PrivilegedHelperTools/com.wiggly-sheets.SpacesRenamer.Injection"
launch_daemon="/Library/LaunchDaemons/${label}.plist"
resources_dir="$(cd "$(dirname "$0")" && pwd)"
action="${1:-}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This operation must run as root." >&2
  exit 1
fi

case "$action" in
  install)
    /bin/launchctl bootout system "$launch_daemon" 2>/dev/null || true
    /usr/bin/install -d -o root -g wheel -m 0755 "$install_dir"
    /usr/bin/install -o root -g wheel -m 0755 \
      "$resources_dir/SpacesRenamerInjectionHelper" \
      "$install_dir/SpacesRenamerInjectionHelper"
    /usr/bin/install -o root -g wheel -m 0755 \
      "$resources_dir/dylinject" \
      "$install_dir/dylinject"
    /usr/bin/install -o root -g wheel -m 0644 \
      "$resources_dir/spaces-renamer.dylib" \
      "$install_dir/spaces-renamer.dylib"
    /usr/bin/install -o root -g wheel -m 0644 \
      "$resources_dir/${label}.plist" \
      "$launch_daemon"
    /usr/bin/xattr -c "$install_dir/dylinject" 2>/dev/null || true
    /usr/bin/xattr -c "$install_dir/spaces-renamer.dylib" 2>/dev/null || true
    /usr/bin/codesign --verify --strict "$install_dir/SpacesRenamerInjectionHelper"
    /bin/launchctl bootstrap system "$launch_daemon"
    /bin/launchctl enable "system/${label}"
    ;;
  uninstall)
    /bin/launchctl bootout system "$launch_daemon" 2>/dev/null || true
    /bin/rm -f "$launch_daemon"
    /bin/rm -rf "$install_dir"
    ;;
  *)
    echo "Usage: $0 install|uninstall" >&2
    exit 64
    ;;
esac
