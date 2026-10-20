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

## Apple silicon only

The release ships one architecture per binary: `arm64` for the menu-bar app,
`arm64e` for the Dock hook, the injection payload and the bundled MIP runtime.
The cask in the tap declares `depends_on arch: :arm64`, so `brew install --cask`
refuses an Intel Mac instead of installing an app that cannot work.

The tap test on the arm64 runner is the only automated install check. To
reproduce it locally on an Apple silicon Mac:

```bash
brew tap wiggly-sheets/homebrew-tap
brew trust wiggly-sheets/homebrew-tap
brew install --cask spacesrenamer
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/SpacesRenamer.app/Contents/Info.plist
```

The installed version must equal the release tag version.

## Publish

```bash
git tag v1.0.0
git push origin v1.0.0
```

The Release workflow then:

1. builds the arm64 app + arm64e injection bundle;
2. packages `SpacesRenamer-v1.0.0.dmg` (via `packaging/make-dmg.sh`) plus a
   `.sha256` sidecar, named exactly as the Homebrew cask expects;
3. creates the GitHub Release with the CHANGELOG section as the notes
   (prerelease only when the tag contains a dash);
4. runs a non-gating tap test (`brew tap` + `brew install --cask` + version
   assert) on the arm64 runner, installing from the DMG.

Prerelease tags (e.g. `v1.0.0-rc.1`) create prerelease GitHub Releases but
skip the tap test, so the stable cask is never clobbered.

The cask itself is not part of this repository. The tap
`wiggly-sheets/homebrew-tap` renders `Casks/spacesrenamer.rb` from its own
template and follows the latest stable release, so a release needs no cask
change here.
