# Release Process

The version comes from the tag. `make release VERSION=x.y.z` prepares the
release and creates the tag; the Release workflow in
`.github/workflows/release.yml` handles everything after the tag is pushed.

## Prepare

1. Add a `## <version> (YYYY-MM-DD)` section to `CHANGELOG.md` describing the
   changes. Release notes are extracted from this section, so write the notes
   once here. A missing or empty section is fine — the release falls back to a
   generic note and never fails.
2. Sanity-check the disk image locally:

   ```bash
   brew install create-dmg scdoc   # required once
   make release-artifacts VERSION=1.0.0
   open .build/DerivedData/SpacesRenamer-v1.0.0.dmg
   ```

   The volume must show `SpacesRenamer.app` over the placeholder background
   with the baked-in "Drag to Applications" instructions and an Applications
   drop-link — no stray files.

   `make release-artifacts` writes the disk image and the checksum file next
   to it. The checksum file holds one line: the digest, two spaces, the bare
   file name `SpacesRenamer-v1.0.0.dmg`.
3. Commit and push the changelog.

There is no version to bump in the Xcode project. `MARKETING_VERSION` in
`spaces-renamer.xcodeproj` is a build setting that the Makefile overrides, and
the tag is the only source of the version.

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
make release VERSION=1.0.0
git push origin master v1.0.0
```

`make release` refuses a dirty working tree, a version whose tag already
exists, and a bundle that reports another version than the one asked for. It
builds the artifacts, creates the annotated tag `v1.0.0` and prints the push
command. It never pushes by itself.

The Release workflow then:

1. builds the arm64 app + arm64e injection bundle with `make release-artifacts`,
   which writes `SpacesRenamer-v1.0.0.dmg` and the `.sha256` sidecar, named
   exactly as the tap expects;
2. checks that the built bundle reports the version of the tag;
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
