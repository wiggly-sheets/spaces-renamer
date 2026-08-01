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
  version "1.0.1"
  sha256 "0bdc9382a76299fc0f292a2fa988dff66bd53df3f3a8a07aa8c195ad0b0e26ec"

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
