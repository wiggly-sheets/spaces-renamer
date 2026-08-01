# 16 — Injection security prerequisites documentation

**What to build:** Clearly document the required arm64e boot argument, the optional AMFI troubleshooting argument, and the full
or partial SIP configurations without changing those settings automatically.

**Blocked by:** None.

**Status:** resolved

- [x] The required argument and optional AMFI troubleshooting combination are documented without overwriting existing values
- [x] Full and partial SIP commands are documented as Recovery operations
- [x] Security impact and restart requirement are explicit
- [x] The app and script validate `-arm64e_preview_abi`; AMFI is optional troubleshooting

## Answer

README and Settings now describe the requirements. `injection/run.sh` requires
both flags and avoids nested `sudo` when the app has already elevated it.
