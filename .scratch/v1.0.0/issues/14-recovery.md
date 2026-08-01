# 14 — Recovery affordances

**What to build:** When the app is running but injection is inactive (e.g. Dock crashed or was restarted while automation was off), the user can recover in two clicks: a re-inject entry in the menu bar plus the Settings button.

**Blocked by:** 11 — GUI-driven injection with admin-prompt elevation.

**Status:** ready-for-human

- [x] Menu bar exposes a re-inject action with the current health state
- [x] Inactive-injection state is surfaced (menu bar + Settings) while the app runs
- [ ] Re-inject from either place restores injection (manual verification required)
