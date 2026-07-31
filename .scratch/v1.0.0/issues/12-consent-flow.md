# 12 — Persistent consent flow

**What to build:** The first launch (or any launch while injection is off) asks for consent to inject. A grant persists; later launches auto-inject silently. Declining or revoking keeps the manual button path.

**Blocked by:** 11 — GUI-driven injection with admin-prompt elevation.

**Status:** ready-for-agent

- [ ] First launch with injection off prompts for consent
- [ ] Grant persists across launches and auto-injects silently on later launches
- [ ] Declining leaves injection off and never prompts on every launch
