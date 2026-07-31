#!/usr/bin/env bash
# Tests for packaging/make-dmg.sh. Uses a stub create-dmg so no real DMG or
# Finder AppleScript runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/packaging/make-dmg.sh"
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

# Stub create-dmg: logs its arguments (one per line), records the staging
# folder contents (the script deletes the folder on exit, so the stub must
# capture it), and creates the requested output .dmg so the script's sha256
# step succeeds. Prepend it to PATH so the real create-dmg (and its Finder
# AppleScript) never runs.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/create-dmg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MAKE_DMG_LOG"
printf '%s\n' '--- SOURCE ---' >> "$MAKE_DMG_LOG"
ls -A "${@: -1}" >> "$MAKE_DMG_LOG"
for arg in "$@"; do
  case "$arg" in
    *.dmg)
      mkdir -p "$(dirname "$arg")"
      : > "$arg"
      ;;
  esac
done
EOF
chmod +x "$TMP/bin/create-dmg"
export PATH="$TMP/bin:$PATH"
export MAKE_DMG_LOG="$TMP/args.log"

make_fake_app() {
  local app="$1" with_icon="$2"
  mkdir -p "$app/Contents/Resources"
  printf 'app' > "$app/Contents/Info.plist"
  if [[ "$with_icon" == "yes" ]]; then
    printf 'icns' > "$app/Contents/Resources/AppIcon.icns"
  fi
}

# Reads the N arguments that follow FLAG in the stub's argument log and joins
# them into one space-separated string.
flag_args() {
  local flag="$1" count="$2"
  grep -A"$count" "^${flag}$" "$MAKE_DMG_LOG" | tail -n "$count" | tr '\n' ' ' | sed 's/ $//'
}

# 1. Produces SpacesRenamer-v<VERSION>.dmg + .sha256 with the packaging flags.
make_fake_app "$TMP/SpacesRenamer.app" "yes"
"$SCRIPT" 1.2.3 "$TMP/SpacesRenamer.app" "$TMP/out"
assert_eq "creates dmg" "SpacesRenamer-v1.2.3.dmg" "$(basename "$TMP/out"/*.dmg)"
assert_eq "creates sha256 sidecar" "SpacesRenamer-v1.2.3.dmg.sha256" "$(basename "$TMP/out"/*.sha256)"
assert_eq "sidecar names the dmg" \
  "SpacesRenamer-v1.2.3.dmg" \
  "$(basename "$(awk '{print $2}' "$TMP/out/SpacesRenamer-v1.2.3.dmg.sha256")")"
assert_eq "sidecar hash is 64 hex chars" \
  "ok" \
  "$(cut -d' ' -f1 "$TMP/out/SpacesRenamer-v1.2.3.dmg.sha256" | grep -E '^[0-9a-f]{64}$' >/dev/null && echo ok)"
assert_eq "uses volume name" "Spaces Renamer" "$(flag_args '--volname' 1)"
assert_eq "uses packaged background" "$ROOT/packaging/background.png" "$(flag_args '--background' 1)"
assert_eq "sets window size" "800 450" "$(flag_args '--window-size' 2)"
assert_eq "positions app icon" "SpacesRenamer.app 200 190" "$(flag_args '--icon' 3)"
assert_eq "positions applications drop link" "600 190" "$(flag_args '--app-drop-link' 2)"
assert_eq "uses volume icon when present" "$TMP/SpacesRenamer.app/Contents/Resources/AppIcon.icns" "$(flag_args '--volicon' 1)"
assert_eq "stages only the app" "SpacesRenamer.app" "$(sed -n '/^--- SOURCE ---$/,$p' "$MAKE_DMG_LOG" | tail -n +2)"

# 2. Omits --volicon when the app has no icon.
make_fake_app "$TMP/NoIcon.app" "no"
"$SCRIPT" 2.0.0 "$TMP/NoIcon.app" "$TMP/out2"
if grep -q '^--volicon$' "$MAKE_DMG_LOG"; then
  fail=$((fail + 1))
  echo "FAIL - --volicon should be omitted without an app icon"
else
  pass=$((pass + 1))
  echo "ok - --volicon omitted without an app icon"
fi

# 3. Version defaults to MARKETING_VERSION from the Xcode project.
EXPECTED="$(grep -m1 'MARKETING_VERSION' "$ROOT/spaces-renamer.xcodeproj/project.pbxproj" \
  | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' \
  | tr -d '[:space:]')"
"$SCRIPT" "" "$TMP/SpacesRenamer.app" "$TMP/out3"
assert_eq "derives version from project" "SpacesRenamer-v${EXPECTED}.dmg" "$(basename "$TMP/out3"/*.dmg)"

# 4. Missing app is an error.
if "$SCRIPT" 1.0.0 "$TMP/missing.app" "$TMP/out4" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing app should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing app exits non-zero"
fi

# 5. Missing create-dmg is an error.
if PATH="/usr/bin:/bin" "$SCRIPT" 1.0.0 "$TMP/SpacesRenamer.app" "$TMP/out5" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - missing create-dmg should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - missing create-dmg exits non-zero"
fi

# 6. A version with a slash is rejected (it would escape OUTPUT_DIR).
if "$SCRIPT" "../evil" "$TMP/SpacesRenamer.app" "$TMP/out6" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - version with slash should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - version with slash exits non-zero"
fi

# 7. The committed background matches a fresh deterministic render, so the
#    artwork can never silently drift from the script that produces it.
swift "$ROOT/packaging/render-background.swift" "$TMP/background.png" >/dev/null
assert_eq "committed background matches fresh render" \
  "$(shasum -a 256 "$ROOT/packaging/background.png" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$TMP/background.png" | cut -d' ' -f1)"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
