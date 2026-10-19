# Homebrew formula for Spaces Renamer
#
# Install from the consolidated tap:
#   brew tap wiggly-sheets/homebrew-tap
#   brew install --cask spacesrenamer
#
# Or directly from the raw cask URL:
#   brew install --cask wiggly-sheets/homebrew-tap/spacesrenamer.rb
#
# This formula installs the .app bundle to /Applications.
# The Dock injection bundle is bundled inside the app.

cask "spacesrenamer" do
  version "1.1.0"
  sha256 "90802a5cc053878792b7ac2218245504b628214ef38d79270e355940fc8fa5ac"

  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.dmg"
  name "Spaces Renamer"
  desc "Give macOS Spaces persistent names in Mission Control"
  homepage "https://github.com/wiggly-sheets/spaces-renamer"

  depends_on macos: :sonoma

  app "SpacesRenamer.app"

  zap trash: [
    "~/Library/Application Support/SpacesRenamer",
    "~/Library/Containers/com.alexbeals.spacesrenamer",
    "~/.config/spacesrenamer",
  ]
end
