#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
recipe="$(make -n -C "$ROOT" verify)"

pass=0
fail=0

assert_command() {
  local description="$1" command="$2"
  if printf '%s\n' "$recipe" | grep -Fq -- "$command"; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
  fi
}

# One -verify_arch per invocation: the multi-arch form trips
# `lipo: -verify_arch requires exactly one input file` on this machine.
assert_command "app requires arm64" \
  'lipo ".build/SpacesRenamer.app/Contents/MacOS/SpacesRenamer" -verify_arch arm64'
assert_command "app requires Intel" \
  'lipo ".build/SpacesRenamer.app/Contents/MacOS/SpacesRenamer" -verify_arch x86_64'
assert_command "plugin dylib requires arm64e" \
  'lipo ".build/DerivedData/Build/Products/Release/spaces-renamer.dylib" -verify_arch arm64e'
assert_command "plugin dylib requires Intel" \
  'lipo ".build/DerivedData/Build/Products/Release/spaces-renamer.dylib" -verify_arch x86_64'
assert_command "packaged payload requires arm64e" \
  'lipo injection/lib/spaces-renamer.dylib -verify_arch arm64e'
assert_command "embedded injector script is executable" \
  'test -x ".build/SpacesRenamer.app/Contents/Resources/injector.sh"'
assert_command "embedded PlugIns payload requires arm64e" \
  'lipo ".build/SpacesRenamer.app/Contents/PlugIns/spaces-renamer.dylib" -verify_arch arm64e'
assert_command "embedded payload must match the packaged payload" \
  'cmp -s injection/lib/spaces-renamer.dylib ".build/SpacesRenamer.app/Contents/PlugIns/spaces-renamer.dylib"'
assert_command "embedded MIP bundle is present" \
  'test -d ".build/SpacesRenamer.app/Contents/Resources/SpacesRenamer.mip.bundle"'
assert_command "MIP bundle names the WindowManager host" \
  'grep -q WindowManager ".build/SpacesRenamer.app/Contents/Resources/SpacesRenamer.mip.bundle/Contents/Info.plist"'
assert_command "MIP bundle names the Dock host" \
  'grep -q Dock ".build/SpacesRenamer.app/Contents/Resources/SpacesRenamer.mip.bundle/Contents/Info.plist"'
assert_command "the final app must have a sealed resource manifest" \
  'test -f ".build/SpacesRenamer.app/Contents/_CodeSignature/CodeResources"'
assert_command "the final app signature and resource seal must validate" \
  'codesign --verify --deep --strict --all-architectures ".build/SpacesRenamer.app"'
assert_command "the legacy run.sh/dylinject layout must not be embedded" \
  'test ! -e ".build/SpacesRenamer.app/Contents/Resources/Injection"'

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]