#!/usr/bin/env bash
# Print the CHANGELOG section for VERSION, or a generic release note.
#
# Usage: release-notes.sh VERSION [CHANGELOG.md]
#
# Finds the first "## VERSION" header (optionally "## vVERSION", optionally
# followed by a "(date)" suffix) and prints everything up to the next "##"
# header. Prints "Release VERSION" when there is no matching section, when the
# section is empty, or when the changelog file is missing. Never fails, so a
# release can never be blocked on release-note text.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 VERSION [CHANGELOG.md]" >&2
  exit 2
fi
CHANGELOG="${2:-CHANGELOG.md}"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "Release ${VERSION}"
  exit 0
fi

# The version becomes part of an awk regex, so escape metacharacters that can
# appear in semver tags (`.` and `+`). Without this, `1.0.0` would also match
# headers like `## 1X0Y0`.
VERSION_RE="${VERSION//./\\.}"
VERSION_RE="${VERSION_RE//+/\\+}"

section="$(
  awk -v version="$VERSION" -v version_re="$VERSION_RE" '
    BEGIN { found = 0; started = 0 }
    $0 ~ "^## v?" version_re "([ ]|$)" { found = 1; next }
    found && /^## / { exit }
    found && !started && /^[[:space:]]*$/ { next }
    found { started = 1; print }
  ' "$CHANGELOG"
)"

if [[ -z "$section" ]]; then
  section="Release ${VERSION}"
fi

printf '%s\n' "$section"
