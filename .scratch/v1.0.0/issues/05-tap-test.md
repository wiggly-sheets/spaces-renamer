# 05 — Post-release tap test verifies installability

**What to build:** A non-gating CI job after each release proves the tap works end-to-end: tap, install the cask, and assert the installed version matches the tag, on the arm64 runner. Intel stays a documented manual pre-release check.

**Blocked by:** 04 — Release workflow auto-bumps the Homebrew cask.

**Status:** ready-for-agent

- [ ] After a release, the job runs `brew tap` + `brew install --cask` successfully
- [ ] The installed app version equals the released tag
- [ ] Job failure does not gate or roll back the release
- [ ] Intel verification documented as a manual pre-release step
