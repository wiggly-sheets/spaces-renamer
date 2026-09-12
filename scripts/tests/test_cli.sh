#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
    echo "ok - $description"
  else
    fail=$((fail + 1))
    echo "FAIL - $description"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/open" <<'MOCK_OPEN'
#!/usr/bin/env bash
set -euo pipefail
url="$1"
printf '%s\n' "$url" >> "$SR_TEST_OPEN_LOG"
case "$url" in
  *\?reply=*)
    reply="${url#*?reply=}"
    reply="${reply//%2F//}"
    reply="${reply//%2f//}"
    (
      sleep 0.25
      printf '{"source":"fresh"}\n' > "$reply"
    ) &
    ;;
esac
MOCK_OPEN
chmod 0755 "$TMP/bin/open"

output="$({ PATH="$TMP/bin:$PATH" SR_TEST_OPEN_LOG="$TMP/open.log" "$ROOT/cli/sr" status; } 2>&1)" || true
assert_eq "status waits for its request-specific response" '{"source":"fresh"}' "$output"

opened_url="$(tail -n 1 "$TMP/open.log")"
case "$opened_url" in
  spacesrenamer://status\?reply=*)
    pass=$((pass + 1))
    echo "ok - status sends a request-specific reply path"
    ;;
  *)
    fail=$((fail + 1))
    echo "FAIL - status sends a request-specific reply path"
    ;;
esac

profile_output="$({ PATH="$TMP/bin:$PATH" SR_TEST_OPEN_LOG="$TMP/profile.log" "$ROOT/cli/sr" profile list; } 2>&1)" || true
assert_eq "profile list waits for its request-specific response" '{"source":"fresh"}' "$profile_output"
case "$(tail -n 1 "$TMP/profile.log")" in
  spacesrenamer://profile/list\?reply=*)
    pass=$((pass + 1))
    echo "ok - profile list sends a request-specific reply path"
    ;;
  *)
    fail=$((fail + 1))
    echo "FAIL - profile list sends a request-specific reply path"
    ;;
esac

name_url_log="$TMP/name.log"
name_status=0
PATH="$TMP/bin:/bin" SR_TEST_OPEN_LOG="$name_url_log" "$ROOT/cli/sr" space 00000000-0000-0000-0000-000000000001 name 'Café & Notes' >/dev/null 2>&1 || name_status=$?
assert_eq "space name succeeds without python3" "0" "$name_status"
assert_eq \
  "space names are UTF-8 percent-encoded without python3" \
  'spacesrenamer://space/00000000-0000-0000-0000-000000000001/name?name=Caf%C3%A9%20%26%20Notes' \
  "$(test -f "$name_url_log" && tail -n 1 "$name_url_log" || true)"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
