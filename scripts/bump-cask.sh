#!/usr/bin/env bash
# Update the version and sha256 lines of a Homebrew cask file in place.
#
# Usage: bump-cask.sh VERSION SHA256 [CASK]
#
# CASK defaults to homebrew/spacesrenamer.rb. SHA256 must be a 64-character
# lowercase hex string. The file is only modified when the expected
# `  key "value"` lines are present; otherwise the script fails without
# producing a broken cask.
set -euo pipefail

VERSION="${1:-}"
SHA256="${2:-}"
CASK="${3:-homebrew/spacesrenamer.rb}"

if [[ -z "$VERSION" || -z "$SHA256" ]]; then
  echo "usage: $0 VERSION SHA256 [CASK]" >&2
  exit 2
fi

if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: sha256 must be 64 lowercase hex characters" >&2
  exit 2
fi

if [[ ! -f "$CASK" ]]; then
  echo "error: cask file not found: $CASK" >&2
  exit 1
fi

sed -i '' -E "s/^( *version \")[^\"]*(\")/\1${VERSION}\2/" "$CASK"
sed -i '' -E "s/^( *sha256 \")[^\"]*(\")/\1${SHA256}\2/" "$CASK"

if ! grep -q "^ *version \"${VERSION}\"" "$CASK"; then
  echo "error: failed to update version line in ${CASK}" >&2
  exit 1
fi
if ! grep -q "^ *sha256 \"${SHA256}\"" "$CASK"; then
  echo "error: failed to update sha256 line in ${CASK}" >&2
  exit 1
fi
