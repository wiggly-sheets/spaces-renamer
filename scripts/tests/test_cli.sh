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

# Both reply commands share one contract: open the endpoint with a
# request-specific reply path and print exactly the reply the app wrote.
check_reply_command() {
  local endpoint="$1" log="$2" output opened path
  read -r -a args <<<"$endpoint"
  output="$({ PATH="$TMP/bin:$PATH" SR_TEST_OPEN_LOG="$log" "$ROOT/cli/sr" "${args[@]}"; } 2>&1)" || true
  assert_eq "$endpoint waits for its request-specific response" '{"source":"fresh"}' "$output"

  path="${endpoint// /\/}"
  opened="$(tail -n 1 "$log")"
  if [[ "$opened" == spacesrenamer://$path\?reply=* ]]; then
    pass=$((pass + 1))
    echo "ok - $endpoint sends a request-specific reply path"
  else
    fail=$((fail + 1))
    echo "FAIL - $endpoint sends a request-specific reply path"
    echo "  actual: $opened"
  fi
}

check_reply_command "status" "$TMP/open.log"
check_reply_command "profile list" "$TMP/profile.log"

for mode in manual applications yabaiLabels; do
  naming_log="$TMP/naming-$mode.log"
  naming_status=0
  PATH="$TMP/bin:/bin" SR_TEST_OPEN_LOG="$naming_log" \
    "$ROOT/cli/sr" naming "$mode" >/dev/null 2>&1 || naming_status=$?
  assert_eq "naming opens the $mode deeplink" \
    "spacesrenamer://naming/$mode" \
    "$(test -f "$naming_log" && tail -n 1 "$naming_log" || true)"
  assert_eq "naming accepts $mode" "0" "$naming_status"
done

invalid_log="$TMP/invalid.log"
invalid_status=0
PATH="$TMP/bin:/bin" SR_TEST_OPEN_LOG="$invalid_log" "$ROOT/cli/sr" naming solarium >/dev/null 2>&1 || invalid_status=$?
assert_eq "naming rejects an unknown mode" "non-zero" "$([[ "$invalid_status" -ne 0 ]] && echo non-zero || echo zero)"
assert_eq "naming rejects before opening a URL" "no" "$(test -f "$invalid_log" && echo yes || echo no)"

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
