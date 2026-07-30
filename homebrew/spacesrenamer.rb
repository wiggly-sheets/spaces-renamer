# Homebrew formula for Spaces Renamer
#
# Install from the custom tap:
#   brew tap wiggly-sheets/spacesrenamer
#   brew install spacesrenamer
#
# Or directly from the raw formula URL:
#   brew install wiggly-sheets/spacesrenamer/homebrew/spacesrenamer.rb
#
# This formula installs the .app bundle to /Applications.
# The Dock injection bundle is bundled inside the app.

cask "spacesrenamer" do
  version "0.9.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.zip"
  name "Spaces Renamer"
  desc "Give macOS Spaces persistent names in Mission Control"
  homepage "https://github.com/wiggly-sheets/spaces-renamer"

  depends_on macos: ">= :ventura"

  app "SpacesRenamer.app"

  zap trash: [
    "~/Library/Application Support/SpacesRenamer",
    "~/Library/Containers/com.alexbeals.spacesrenamer",
    "~/.config/spacesrenamer",
  ]
end
