import Foundation

/// Preference domains shared with the injected Dock bundle. The Dock hook is
/// sandboxed away from `~/Library/Application Support`, so the live data
/// channel is the `com.apple.dock` preference domain.
enum Paths {
  static let bundleIdentifier = "com.wiggly-sheets.SpacesRenamer"

  /// Domain the plugin can read from inside its host; the app writes names and monitors here.
  static let dockDomain = "com.apple.dock"
  static let namesKey = "SpacesRenamerNames"
  static let monitorsKey = "SpacesRenamerMonitors"

  private static let library = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library", directoryHint: .isDirectory)

  /// System Spaces database; rewritten by Dock whenever Spaces are added or removed.
  static let systemSpaces = library.appending(path: "Preferences/com.apple.spaces.plist").path
}