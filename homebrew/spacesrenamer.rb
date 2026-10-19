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
  version "1.1.1"
  sha256 "106c2df0acb63441452f6b8c1ce3408dd06a23cb08143512ee165454c90e63c1"

  url "https://github.com/wiggly-sheets/spaces-renamer/releases/download/v#{version}/SpacesRenamer-v#{version}.dmg"
  name "Spaces Renamer"
  desc "Give macOS Spaces persistent names in Mission Control"
  homepage "https://github.com/wiggly-sheets/spaces-renamer"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SpacesRenamer.app"

  zap trash: [
    "~/Library/Application Support/SpacesRenamer",
    "~/Library/Containers/com.alexbeals.spacesrenamer",
    "~/.config/spacesrenamer",
  ]
end
