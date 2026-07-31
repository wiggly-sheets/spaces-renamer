# 02 — Release notes extracted from CHANGELOG

**What to build:** The GitHub Release page for a tag shows the changelog section matching that version, so release text is written once in the changelog and reused. Missing changelog text falls back to a generic note and never fails the release.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A release whose tag matches a CHANGELOG section publishes that section as the release notes
- [ ] A release with no matching section publishes a generic note without failing
