# Homebrew Tap for Spaces Renamer

## Setup

Create a GitHub repo named `homebrew-spacesrenamer` under the `wiggly-sheets` org.
Copy `spacesrenamer.rb` into `Formula/` in that repo.

```bash
git clone https://github.com/wiggly-sheets/homebrew-spacesrenamer
cd homebrew-spacesrenamer
mkdir -p Formula
cp /path/to/spaces-renamer/homebrew/spacesrenamer.rb Formula/
git add Formula/spacesrenamer.rb
git commit -m "feat: add spacesrenamer cask"
git push
```

## Usage

```bash
brew tap wiggly-sheets/spacesrenamer
brew install --cask spacesrenamer
```

## Updating for a new release

Stable releases are automatic: tagging `vX.Y.Z` updates `version` and
`sha256` in `spacesrenamer.rb`, commits the change to the release repo's
master, and pushes the same file into this tap's `Formula/` directory. No
manual steps are required.

See `docs/release.md` for the full release process, including the manual
Intel pre-release check.
