# 07 — Cask and tap test point at the DMG

**What to build:** Homebrew installs the same artifact users download. The cask's URL and sha256 target the published DMG, the automatic cask bump hashes the DMG, and the post-release tap test installs from the DMG.

**Blocked by:** 05 — Post-release tap test verifies installability; 06 — DMG packaging with custom background.

**Status:** resolved

- [x] Cask URL resolves to the DMG asset and sha256 matches the published DMG
- [x] Auto-bump keeps the cask's version + sha256 correct for DMG artifacts
- [x] Tap test installs the app from the DMG and asserts the released version

## Answer

`homebrew/spacesrenamer.rb` URL now points at `SpacesRenamer-v#{version}.dmg`; the workflow's auto-bump step hashes the DMG (`cut -d' ' -f1` of the `.dmg.sha256` sidecar) and the tap-test job installs from the updated URL. `bump-cask.sh` needed no changes (URL line untouched; version/sha256 sed-targeted) beyond the test fixture moving to `.dmg`.

Verified locally:
- cask is valid Ruby; URL ends `.dmg`; artifact naming matches the workflow's `SpacesRenamer-v${VERSION}.dmg` exactly.
- `bump-cask.sh 1.0.0 <real DMG sha>` on a cask copy: version `1.0.0`, sha256 = real 64-hex DMG hash, URL intact.
- End-to-end local tap (`brew tap wiggly-sheets/spacesrenamer` against a local git repo, `brew install --cask --appdir=...` from the DMG via `file://`): installed `SpacesRenamer.app`, PlistBuddy `CFBundleShortVersionString` = `0.9.0`, then uninstalled + untapped cleanly. (Local taps need `brew trust`; GitHub-hosted taps do not.)
