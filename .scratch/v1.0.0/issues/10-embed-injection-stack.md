# 10 — Embed injection stack in app bundle

**What to build:** The app bundle carries the full injection stack at build time, so the GUI can drive injection without the standalone script checkout. Start from the item-3 branch's first pass; the privileged-helper files (XPC helper, its launchd plist, manage script) are removed — they are not the 1.0.0 path (see `docs/adr/0001-app-managed-injection-elevation.md`).

**Blocked by:** 08 — Rename injection branch.

**Status:** ready-for-agent

- [ ] The build copies the injection script, injector executable, and payload into the app bundle
- [ ] The privileged-helper files are cut from the branch
- [ ] After `make app`, the bundle contains the stack at a stable, code-signed-safe location
