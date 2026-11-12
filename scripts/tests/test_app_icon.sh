#!/usr/bin/env bash
# The app ships an Icon Composer document so macOS 26/27 renders the layered
# Liquid Glass icon; actool also emits the legacy .icns for older releases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ICON="$ROOT/SpacesRenamer/AppIcon.icon"
MAKEFILE="$ROOT/Makefile"

pass=0
fail=0

assert_pass() {
  local description="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      pass=$((pass + 1))
      echo "ok - $description"
      ;;
    *)
      fail=$((fail + 1))
      echo "FAIL - $description"
      ;;
  esac
}

assert_absent() {
  local description="$1" text="$2" file="$3"
  if grep -F -q -e "$text" "$file"; then
    fail=$((fail + 1))
    echo "FAIL - $description"
  else
    pass=$((pass + 1))
    echo "ok - $description"
  fi
}

assert_pass "the Icon Composer document exists" test -f "$ICON/icon.json"
assert_pass "the Icon Composer document parses" \
  plutil -convert xml1 -o /dev/null "$ICON/icon.json"
assert_pass "the layered artwork exists" test -f "$ICON/Assets/SpaceTiles.png"

width="$(sips -g pixelWidth "$ICON/Assets/SpaceTiles.png" | awk '/pixelWidth/ { print $2 }')"
height="$(sips -g pixelHeight "$ICON/Assets/SpaceTiles.png" | awk '/pixelHeight/ { print $2 }')"
if [[ "$width" == "1024" && "$height" == "1024" ]]; then
  pass=$((pass + 1))
  echo "ok - the layered artwork is 1024x1024"
else
  fail=$((fail + 1))
  echo "FAIL - the layered artwork is 1024x1024 (got ${width}x${height})"
fi

xml="$(plutil -convert xml1 -o - "$ICON/icon.json")"
assert_contains "the icon targets macOS squares" "$xml" "<string>macOS</string>"
assert_contains "the artwork layer uses native glass" "$xml" "<key>glass</key>"
assert_contains "the artwork layer is referenced" "$xml" "<string>SpaceTiles.png</string>"

if grep -F -q 'actool SpacesRenamer/AppIcon.icon' "$MAKEFILE"; then
  pass=$((pass + 1))
  echo "ok - make app compiles the Icon Composer document"
else
  fail=$((fail + 1))
  echo "FAIL - make app compiles the Icon Composer document"
fi
assert_absent \
  "make app no longer compiles the legacy appiconset" \
  'actool SpacesRenamer/Assets.xcassets' "$MAKEFILE"

PROJECT="$ROOT/spaces-renamer.xcodeproj/project.pbxproj"
assert_contains \
  "the Xcode project references the Icon Composer document" \
  "$(cat "$PROJECT")" \
  'A80DDE2F1FBCE4D600794F8F /* AppIcon.icon */'
assert_contains \
  "the Xcode project opens it as an Icon Composer document" \
  "$(cat "$PROJECT")" \
  'lastKnownFileType = folder.iconcomposer.icon'
assert_absent \
  "the Xcode project no longer references the legacy catalog" \
  'Assets.xcassets' "$PROJECT"
assert_pass \
  "the legacy asset catalog is gone" \
  test ! -e "$ROOT/SpacesRenamer/Assets.xcassets"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
