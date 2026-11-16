#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
recipe="$(make -n -C "$ROOT" verify)"
MAKEFILE="$ROOT/Makefile"

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

assert_fixed() {
	local description="$1" text="$2" file="$3"
	if grep -F -q -e "$text" "$file"; then
		pass=$((pass + 1))
		echo "ok - $description"
	else
		fail=$((fail + 1))
		echo "FAIL - $description"
	fi
}

assert_absent() {
	local description="$1" text="$2" file="$3"
	local status=0
	grep -F -q -e "$text" "$file" || status=$?
	case "$status" in
	0)
		fail=$((fail + 1))
		echo "FAIL - $description"
		;;
	1)
		pass=$((pass + 1))
		echo "ok - $description"
		;;
	*)
		fail=$((fail + 1))
		echo "FAIL - $description (grep could not read $file, status $status)"
		;;
	esac
}

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

# One -verify_arch per invocation: the multi-arch form trips
# `lipo: -verify_arch requires exactly one input file` on this machine.
assert_command "app requires arm64" \
	'lipo ".build/SpacesRenamer.app/Contents/MacOS/SpacesRenamer" -verify_arch arm64'
assert_command "plugin dylib requires arm64e" \
	'lipo ".build/DerivedData/Build/Products/Release/spaces-renamer.dylib" -verify_arch arm64e'
assert_command "packaged payload requires arm64e" \
	'lipo injection/lib/spaces-renamer.dylib -verify_arch arm64e'
assert_command "embedded injector script is executable" \
	'test -x ".build/SpacesRenamer.app/Contents/Resources/injector.sh"'
assert_command "embedded PlugIns payload requires arm64e" \
	'lipo ".build/SpacesRenamer.app/Contents/PlugIns/spaces-renamer.dylib" -verify_arch arm64e'
assert_command "the app must be a thin arm64 slice" \
	'test "$(lipo -archs ".build/SpacesRenamer.app/Contents/MacOS/SpacesRenamer")" = arm64'
assert_command "the plugin must be a thin arm64e slice" \
	'test "$(lipo -archs ".build/DerivedData/Build/Products/Release/spaces-renamer.dylib")" = arm64e'
assert_command "the packaged payload must be a thin arm64e slice" \
	'test "$(lipo -archs injection/lib/spaces-renamer.dylib)" = arm64e'
assert_command "the private MIP runtime must be arm64e" \
	'lipo injection/mip/$f -verify_arch arm64e'
assert_command "the private MIP runtime must be a thin arm64e slice" \
	'test "$(lipo -archs injection/mip/$f)" = arm64e'
assert_command "the embedded MIP runtime must be arm64e" \
	'lipo ".build/SpacesRenamer.app/Contents/Resources/mip/$f" -verify_arch arm64e'
assert_command "the embedded MIP runtime must be a thin arm64e slice" \
	'test "$(lipo -archs ".build/SpacesRenamer.app/Contents/Resources/mip/$f")" = arm64e'
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

# Build contracts: Apple silicon only, one app target, one build entry point.
assert_fixed "the app target builds arm64 only" "ARCHS='arm64'" "$MAKEFILE"
assert_fixed "the plugin target builds arm64e only" "'ARCHS=arm64e'" "$MAKEFILE"
assert_absent "the Makefile builds no Intel slice" "x86_64" "$MAKEFILE"
assert_fixed "the build-all target exists" "build-all: app" "$MAKEFILE"

# The private MIP runtime is committed, so its slices are checked always.
# Built app artifacts are deliberately not inspected here: a stale .build tree
# from another checkout revision would fail this test for no product defect.
# `make verify` checks the real built bundle after `make app`.
echo
echo "Private MIP runtime checks (committed artifacts):"
for f in injectd loader.dylib lsdinjector.dylib inject; do
	assert_pass "private MIP runtime $f is a thin arm64e slice" \
		test "$(lipo -archs "$ROOT/injection/mip/$f")" = arm64e
done

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
