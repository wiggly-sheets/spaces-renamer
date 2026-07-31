# 01 — Release artifacts match the cask's download contract

**What to build:** Tagging a release produces one deterministic, checksummed archive named exactly as the Homebrew cask expects, so downstream installers can rely on the asset name. Today the archive name never matches the cask URL, so Homebrew installs from any release fail.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A test tag publishes an archive named `SpacesRenamer-v<version>.zip` (no `.app` infix) plus a `.sha256` sidecar
- [ ] The archive name matches the cask URL pattern exactly
- [ ] In-flight uncommitted workflow fixes (gh CLI path cleanup, sequestered resource copy) are absorbed and committed
