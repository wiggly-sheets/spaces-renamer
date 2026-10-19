# Homebrew Tap for Spaces Renamer

Spaces Renamer is published through the consolidated
[`wiggly-sheets/homebrew-tap`](https://github.com/wiggly-sheets/homebrew-tap)
repository, alongside the other wiggly-sheets macOS utilities. There is no
per-app tap.

## Setup

No per-app repo to create. The cask lives in the consolidated tap's
`Casks/spacesrenamer.rb`.

## Usage

```bash
brew tap wiggly-sheets/homebrew-tap
brew trust wiggly-sheets/homebrew-tap
brew install --cask spacesrenamer
```

Or install directly from the raw cask URL:

```bash
brew install --cask wiggly-sheets/homebrew-tap/spacesrenamer
```

## Updating for a new release

Stable releases are automatic: tagging `vX.Y.Z` updates `version` and
`sha256` in `spacesrenamer.rb`, commits the change to the release repo's
master, and pushes the same file into the consolidated tap's `Casks/`
directory. No manual steps are required.

See `docs/release.md` for the full release process. The cask is Apple silicon
only (`depends_on arch: :arm64`), so Homebrew refuses an Intel Mac.