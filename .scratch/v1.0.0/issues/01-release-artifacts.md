# 01 — Release artifacts match the cask's download contract

**What to build:** Tagging a release produces one deterministic, checksummed archive named exactly as the Homebrew cask expects, so downstream installers can rely on the asset name. Today the archive name never matches the cask URL, so Homebrew installs from any release fail.

**Blocked by:** None — can start immediately.

**Status:** ready-for-human

- [x] Workflow publishes `SpacesRenamer-v<version>.dmg` plus a `.sha256` sidecar
- [x] The artifact name matches the cask URL pattern exactly
- [x] In-flight workflow fixes are absorbed into master

The workflow is active on GitHub, but no run exists yet; a v1.0.0 test tag is
still required for live verification.
