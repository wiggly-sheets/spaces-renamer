# 17 — scdoc manual page

**What to build:** Ship an `sr(1)` manual generated from scdoc source.

**Blocked by:** None.

**Status:** resolved

- [x] `docs/sr.1.scd` documents every CLI command
- [x] `make man` generates `.build/man/sr.1`
- [x] The app bundles the generated page and installs a user-local symlink
- [x] Release CI installs scdoc and the test suite verifies rendered content
