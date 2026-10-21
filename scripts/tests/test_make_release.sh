#!/usr/bin/env bash
# Tests for the release contract of the Makefile: the shared target names, the
# format of the checksum file and the refusals of `make release`. The
# refusals run in a throwaway git repository, so no build starts and no tag
# is created.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEFILE="$ROOT/Makefile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
    echo "ok - $desc"
  else
    fail=$((fail + 1))
    echo "FAIL - $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    pass=$((pass + 1))
    echo "ok - $desc"
  else
    fail=$((fail + 1))
    echo "FAIL - $desc"
    echo "  missing: $needle"
  fi
}

assert_absent() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    fail=$((fail + 1))
    echo "FAIL - $desc"
    echo "  found: $needle"
  else
    pass=$((pass + 1))
    echo "ok - $desc"
  fi
}

# 1. The default goal prints the list of the shared targets.
default_output="$(make -s -C "$ROOT" 2>&1)"
assert_contains "make without a target prints the help" "Spaces Renamer — build targets." "$default_output"
for target in help build test app dmg release-artifacts release clean; do
  assert_contains "the help lists $target" "  $target " "$default_output"
done

# 2. The checksum file holds the digest and the bare file name.
artifacts="$(make -n -C "$ROOT" release-artifacts VERSION=9.9.9 2>&1)"
assert_contains "the checksum file names the bare asset" \
  'shasum -a 256 "SpacesRenamer-v9.9.9.dmg" > "SpacesRenamer-v9.9.9.dmg.sha256"' "$artifacts"
assert_absent "the checksum file names no path" \
  'shasum -a 256 ".build/DerivedData/SpacesRenamer-v9.9.9.dmg"' "$artifacts"

# 3. The release prepares the release and stops there.
release_recipe="$(make -n -C "$ROOT" release VERSION=9.9.9 2>&1)"
assert_contains "the release refuses a dirty working tree" "the working tree is dirty" "$release_recipe"
assert_contains "the release refuses a tag that exists" "already exists" "$release_recipe"
assert_contains "the release checks the version of the bundle" "CFBundleShortVersionString" "$release_recipe"
assert_contains "the release creates an annotated tag" 'git tag -a "v9.9.9"' "$release_recipe"
assert_contains "the release prints the push command" "git push origin master v9.9.9" "$release_recipe"

# 4. The version comes from the command line, never from a file.
assert_absent "the Makefile reads no version from the Xcode project" "project.pbxproj" \
  "$(cat "$MAKEFILE")"

# 5. The refusals of `make release`, in a throwaway git repository.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=release@example.com -c user.name=Release \
  commit -q --allow-empty -m init

out="$(cd "$REPO" && make -f "$MAKEFILE" release 2>&1 || true)"
assert_contains "a release without a version is refused" "make release needs a version" "$out"
if (cd "$REPO" && make -f "$MAKEFILE" release >/dev/null 2>&1); then
  fail=$((fail + 1))
  echo "FAIL - a release without a version should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - a release without a version exits non-zero"
fi

touch "$REPO/dirty.txt"
out="$(cd "$REPO" && make -f "$MAKEFILE" release VERSION=9.9.9 2>&1 || true)"
assert_contains "a release on a dirty tree is refused" "the working tree is dirty" "$out"
if (cd "$REPO" && make -f "$MAKEFILE" release VERSION=9.9.9 >/dev/null 2>&1); then
  fail=$((fail + 1))
  echo "FAIL - a release on a dirty tree should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - a release on a dirty tree exits non-zero"
fi

rm "$REPO/dirty.txt"
git -C "$REPO" tag v9.9.9
out="$(cd "$REPO" && make -f "$MAKEFILE" release VERSION=9.9.9 2>&1 || true)"
assert_contains "a release with an existing tag is refused" "already exists" "$out"
if (cd "$REPO" && make -f "$MAKEFILE" release VERSION=9.9.9 >/dev/null 2>&1); then
  fail=$((fail + 1))
  echo "FAIL - a release with an existing tag should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - a release with an existing tag exits non-zero"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
