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

1. Download the release zip from GitHub
2. Get the SHA256: `shasum -a 256 SpacesRenamer-v1.0.0.zip`
3. Update `version` and `sha256` in `spacesrenamer.rb`

The release workflow produces the checksum automatically.
