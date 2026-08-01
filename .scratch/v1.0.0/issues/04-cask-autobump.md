# 04 — Release workflow auto-bumps the Homebrew cask

**What to build:** After a release, the workflow updates the cask's version and sha256 in this repo (committed to master) and pushes the same file to the separate tap repo, so `brew install` finds a cask matching the release with zero manual steps.

**Blocked by:** 01 — Release artifacts match the cask's download contract.

**Status:** ready-for-human

- [x] Workflow updates version + sha256 in the local cask and commits to master
- [x] Workflow pushes the same file to the tap repo's Formula directory
- [x] Cask bump tests validate the release sha256 contract
- [x] Workflow uses the existing GH_TOKEN secret; no new credentials

The cross-repository push still requires live verification from a release tag.
