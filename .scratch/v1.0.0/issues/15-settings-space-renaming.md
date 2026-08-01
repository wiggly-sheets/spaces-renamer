# 15 — Space renaming in Settings

**What to build:** Settings exposes the same per-display Space-name editor as
the menu-bar popover so hiding the menu-bar item does not remove direct naming.

**Blocked by:** None.

**Status:** resolved

- [x] Settings navigation includes a Spaces section
- [x] Manual names are editable for the active profile
- [x] Generated naming modes remain read-only and show their source

## Answer

Settings now reuses `SpaceNameCard` from the popover and refreshes the Space
snapshot when the section appears. The universal build succeeds.
