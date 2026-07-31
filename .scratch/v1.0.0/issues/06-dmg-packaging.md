# 06 — DMG packaging with custom background

**What to build:** A tagged release ships `SpacesRenamer-v<version>.dmg` plus a `.sha256` sidecar instead of a zip, and building locally produces the same DMG via a `make dmg` target. Packaging assets live in the repo: the create-dmg invocation and a placeholder background (plain white/grey with "Drag into Applications" instructions baked in) so stray volume files (.icns etc.) are hidden.

**Blocked by:** 01 — Release artifacts match the cask's download contract.

**Status:** resolved

- [x] A test tag publishes `SpacesRenamer-v<version>.dmg` + `.sha256` (no zip)
- [x] `make dmg` produces the same DMG locally
- [x] DMG volume shows the app and baked-in instructions over the placeholder background, no stray files visible

## Answer

Implemented in `packaging/` (create-dmg invocation in `make-dmg.sh`, placeholder background in `render-background.swift` + committed `background.png`) with a `make dmg` target and `make background` regenerator. The release workflow now installs `create-dmg`, builds `SpacesRenamer-v${VERSION}.dmg` + `.sha256` via `packaging/make-dmg.sh`, and uploads those instead of the zip; the cask bump reads the DMG's sha256.

Verified locally: `make dmg` exit 0; mounted volume shows exactly `SpacesRenamer.app` + `Applications` drop-link over the white/grey background with baked-in "Drag to Applications" instructions and arrow; all other volume files (`.background/`, `.DS_Store`, `.VolumeIcon.icns`) are hidden. Finder icon positions confirmed `{200,190}`/`{600,190}` matching the background layout. DMG is a universal (arm64+x86_64) app; `.sha256` sidecar matches `shasum -a 256`. User visually approved.
