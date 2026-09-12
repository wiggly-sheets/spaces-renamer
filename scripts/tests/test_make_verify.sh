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

assert_command "app requires both supported architectures" \
  'lipo ".build/DerivedData/Build/Products/Release/SpacesRenamer.app/Contents/MacOS/SpacesRenamer" -verify_arch arm64 x86_64'
assert_command "Dock bundle requires arm64e and Intel" \
  'lipo ".build/DerivedData/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer" -verify_arch arm64e x86_64'
assert_command "packaged payload requires arm64e" \
  'lipo injection/lib/spaces-renamer.dylib -verify_arch arm64e'
assert_command "embedded injector requires arm64e" \
  'lipo ".build/DerivedData/Build/Products/Release/SpacesRenamer.app/Contents/Resources/Injection/lib/dylinject" -verify_arch arm64e'
assert_command "embedded payload requires arm64e" \
  'lipo ".build/DerivedData/Build/Products/Release/SpacesRenamer.app/Contents/Resources/Injection/lib/spaces-renamer.dylib" -verify_arch arm64e'
assert_command "embedded payload must match the packaged payload" \
  'cmp -s injection/lib/spaces-renamer.dylib ".build/DerivedData/Build/Products/Release/SpacesRenamer.app/Contents/Resources/Injection/lib/spaces-renamer.dylib"'
assert_command "the final app must have a sealed resource manifest" \
  'test -f ".build/DerivedData/Build/Products/Release/SpacesRenamer.app/Contents/_CodeSignature/CodeResources"'
assert_command "the final app signature and resource seal must validate" \
  'codesign --verify --deep --strict --all-architectures ".build/DerivedData/Build/Products/Release/SpacesRenamer.app"'

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
