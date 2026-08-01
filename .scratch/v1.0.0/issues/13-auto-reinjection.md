# 13 — Automatic reinjection

**What to build:** With consent granted, the app keeps itself injected: it reinjects when Dock restarts and at computer restart via the existing launch-at-login, controlled by a Settings toggle.

**Blocked by:** 12 — Persistent consent flow.

**Status:** ready-for-human

- [ ] Killing/restarting Dock triggers reinjection when the toggle is on
- [x] Launch-at-login reinjects after a computer restart
- [x] Toggle in Settings enables/disables automatic reinjection
