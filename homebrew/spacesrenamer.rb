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
  version "1.0.0"
  sha256 "2708b50a0ccd9bc0e3cbdd4739fac47c451c91431bd2e1836cb22fad416ad574"

  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.dmg"
  name "Spaces Renamer"
  desc "Give macOS Spaces persistent names in Mission Control"
  homepage "https://github.com/wiggly-sheets/spaces-renamer"

  depends_on macos: :ventura

  app "SpacesRenamer.app"

  zap trash: [
    "~/Library/Application Support/SpacesRenamer",
    "~/Library/Containers/com.alexbeals.spacesrenamer",
    "~/.config/spacesrenamer",
  ]
end
