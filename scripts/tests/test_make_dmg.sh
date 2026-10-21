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
# capture it), and creates the requested output .dmg. Prepend it to PATH so
# the real create-dmg (and its Finder AppleScript) never runs.
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

# 1. Produces SpacesRenamer-v<VERSION>.dmg with the packaging flags. The
#    checksum file is written by the Makefile target `release-artifacts`.
make_fake_app "$TMP/SpacesRenamer.app" "yes"
"$SCRIPT" 1.2.3 "$TMP/SpacesRenamer.app" "$TMP/out"
assert_eq "creates dmg" "SpacesRenamer-v1.2.3.dmg" "$(basename "$TMP/out"/*.dmg)"
assert_eq "writes no checksum file" "0" "$(find "$TMP/out" -name '*.sha256' | wc -l | tr -d ' ')"
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

# 3. The version is required: it comes from the caller, never from a file of
#    the repository.
if "$SCRIPT" "" "$TMP/SpacesRenamer.app" "$TMP/out3" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL - a missing version should exit non-zero"
else
  pass=$((pass + 1))
  echo "ok - a missing version exits non-zero"
fi

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

# 7. The committed background is a valid 1600x900 PNG and the renderer still
#    runs and produces a same-sized PNG. Byte-exact comparison is skipped:
#    AppKit rasterization is not pixel-deterministic across OS versions.
png_dims() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
    | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'
}

assert_eq "committed background is a valid PNG" \
  "yes" \
  "$(file -b "$ROOT/packaging/background.png" | grep -q "PNG image data" && echo yes || echo no)"
assert_eq "committed background is 1600x900" \
  "1600x900" \
  "$(png_dims "$ROOT/packaging/background.png")"

if ! swift "$ROOT/packaging/render-background.swift" "$TMP/background.png" >/dev/null; then
  fail=$((fail + 1))
  echo "FAIL - renderer runs successfully"
else
  pass=$((pass + 1))
  echo "ok - renderer runs successfully"
fi
assert_eq "fresh render is a valid 1600x900 PNG" \
  "1600x900" \
  "$(png_dims "$TMP/background.png")"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
