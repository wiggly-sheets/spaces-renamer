# 05 — Post-release tap test verifies installability

**What to build:** A non-gating CI job after each release proves the tap works end-to-end: tap, install the cask, and assert the installed version matches the tag, on the arm64 runner. Intel stays a documented manual pre-release check.

**Blocked by:** 04 — Release workflow auto-bumps the Homebrew cask.

**Status:** ready-for-human

- [x] Job runs `brew tap` + `brew install --cask`
- [x] Job asserts the installed app version equals the released tag
- [x] Job is non-gating (`continue-on-error: true`)
- [x] Intel verification is documented as a manual pre-release step

The active workflow has no GitHub run yet; end-to-end tap installation remains
a post-tag manual check.
