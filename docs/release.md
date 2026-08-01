# Release Process

Cutting a release is two manual steps (prepare, tag); the Release workflow in
`.github/workflows/release.yml` handles everything after that.

## Prepare

1. Bump `MARKETING_VERSION` in `spaces-renamer.xcodeproj` (all four build
   configurations) to the new version, e.g. `1.0.0`.
2. Add a `## <version> (YYYY-MM-DD)` section to `CHANGELOG.md` describing the
   changes. Release notes are extracted from this section, so write the notes
   once here. A missing or empty section is fine — the release falls back to a
   generic note and never fails.
3. Sanity-check the DMG locally:

   ```bash
   brew install create-dmg scdoc   # required once
   make dmg
   open .build/DerivedData/SpacesRenamer-v<version>.dmg
   ```

   The volume must show `SpacesRenamer.app` over the placeholder background
   with the baked-in "Drag to Applications" instructions and an Applications
   drop-link — no stray files.
4. Commit and push the version bump and changelog.

## Manual Intel (x86_64) pre-release check

The automated tap test runs only on the arm64 runner. Before cutting a stable
release, manually verify the tap on an Intel Mac:

```bash
brew tap wiggly-sheets/spacesrenamer
brew install --cask spacesrenamer
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/SpacesRenamer.app/Contents/Info.plist
```

The installed version must equal the release tag version. The app bundle and
Dock injection payload are universal binaries, but this manual check is the
only thing that exercises the Intel install path.

## Publish

```bash
git tag v1.0.0
git push origin v1.0.0
```

The Release workflow then:

1. builds the universal app + injection bundle;
2. packages `SpacesRenamer-v1.0.0.dmg` (via `packaging/make-dmg.sh`) plus a
   `.sha256` sidecar, named exactly as the Homebrew cask expects;
3. creates the GitHub Release with the CHANGELOG section as the notes
   (prerelease only when the tag contains a dash);
4. bumps `homebrew/spacesrenamer.rb` (version + sha256 from the published
   DMG), commits it to master, and pushes the same file to the
   `wiggly-sheets/homebrew-spacesrenamer` tap repo;
5. runs a non-gating tap test (`brew tap` + `brew install --cask` + version
   assert) on the arm64 runner, installing from the DMG.

Prerelease tags (e.g. `v1.0.0-rc.1`) create prerelease GitHub Releases but
skip the cask bump and tap test, so the stable cask is never clobbered.
