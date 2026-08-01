# 11 — GUI-driven injection with admin-prompt elevation

**What to build:** The Settings → Injection section shows health state and an Inject button. Clicking Inject runs the embedded stack via an `osascript` admin prompt (standard password / Touch ID dialog) — no terminal, no deprecated authorization APIs. Health state comes from the Dock handshake (ping + payload version); a successful injector exit alone is never treated as proof the bundle is active.

**Blocked by:** 10 — Embed injection stack in app bundle.

**Status:** ready-for-human

- [x] Inject button appears in Settings with the health state visible
- [ ] Clicking Inject shows the system admin prompt and injects when approved
- [x] Health reflects the Dock handshake result (injected, Dock PID, payload version), not just the injector exit
- [x] Failed or declined injection leaves the app running and reports a clear state
