# v1.0.0

Breakdown of the v1.0.0 roadmap (`AGENTS.md` → `## v1.0.0 Roadmap`) into
tickets. Items 1–4 are in scope; item 5 is deferred to post-1.0.0.

## Tickets

- 01 Release artifacts match the cask's download contract
- 02 Release notes extracted from CHANGELOG
- 03 Prerelease flag follows the tag
- 04 Release workflow auto-bumps the Homebrew cask
- 05 Post-release tap test verifies installability
- 06 DMG packaging with custom background
- 07 Cask and tap test point at the DMG
- 08 Rename injection branch
- 09 Delete redundant branches
- 10 Embed injection stack in app bundle
- 11 GUI-driven injection with admin-prompt elevation
- 12 Persistent consent flow
- 13 Automatic reinjection
- 14 Recovery affordances

## Blocking structure

- 01 → 04 → 05 — release artifacts → cask bump → tap test (item 1)
- 02, 03 — parallel release polish, no blockers
- 01 → 06 → 07 — DMG packaging reuses the artifact machinery; cask/tap
  switch to the DMG (item 2)
- 08, 09 — branch cleanup, no blockers (item 4)
- 08 → 10 → 11 → 12 → 13 — branch prep → embed → GUI injection → consent →
  automation (item 3)
- 11 → 14 — recovery affordances, parallel to 12/13

Frontier (no blockers): 01, 02, 03, 08, 09.
