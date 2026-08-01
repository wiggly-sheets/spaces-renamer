# 03 — Prerelease flag follows the tag

**What to build:** Stable tags publish as stable GitHub Releases; prerelease tags (containing `-`) publish as prereleases, so a v1.0.0 milestone is not greyed out as a pre-release.

**Blocked by:** None — can start immediately.

**Status:** ready-for-human

- [x] Workflow omits `--prerelease` for stable tags
- [x] Workflow passes `--prerelease` for tags containing `-`

Live GitHub Release verification awaits stable and prerelease test tags.
