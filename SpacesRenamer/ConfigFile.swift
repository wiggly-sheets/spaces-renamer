import Foundation

final class ConfigFile: ObservableObject {
  static let directoryURL: URL = {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/spacesrenamer")
  }()

  static let fileURL: URL = directoryURL.appendingPathComponent("config.toml")

  @Published private(set) var lastReadError: String?
  @Published private(set) var lastWatchError: String?

  private var source: DispatchSourceFileSystemObject?
  private let preferences: PreferencesStore

  init(preferences: PreferencesStore) {
    self.preferences = preferences
    createIfMissing()
    read()
    startWatching()
  }

  deinit { stopWatching() }

  var fileExists: Bool {
    FileManager.default.fileExists(atPath: Self.fileURL.path)
  }

  func stopWatching() {
    source?.cancel()
    source = nil
  }

  // MARK: - Read & Parse

  func read() {
    guard fileExists else { return }
    do {
      let contents = try String(contentsOf: Self.fileURL, encoding: .utf8)
      let parsed = try TOML.parse(contents)
      applySettings(parsed)
      applyProfiles(parsed)
      lastReadError = nil
    } catch {
      lastReadError = error.localizedDescription
    }
  }

  private func applySettings(_ parsed: [String: [String: [String: TOMLValue]]]) {
    guard let settings = parsed["settings"]?[""] else { return }
    for (key, value) in settings {
      switch key {
      case "naming_mode":
        if let s = value.stringValue, let mode = NamingMode(rawValue: s) {
          preferences.setNamingMode(mode)
        }
      case "show_menu_bar":
        if let b = value.boolValue { preferences.setShowMenuBarIcon(b) }
      case "menu_bar_display":
        if let s = value.stringValue, let mode = MenuBarDisplayMode(rawValue: s) {
          preferences.setMenuBarDisplayMode(mode)
        }
      case "show_duplicate_apps":
        if let b = value.boolValue { preferences.setShowDuplicateApplications(b) }
      case "hotkey_key":
        if let i = value.intValue { var h = preferences.hotkey; h.keyCode = UInt32(i); preferences.updateHotkey(h) }
      case "hotkey_ctrl":
        if let b = value.boolValue { var h = preferences.hotkey; h.control = b; preferences.updateHotkey(h) }
      case "hotkey_opt":
        if let b = value.boolValue { var h = preferences.hotkey; h.option = b; preferences.updateHotkey(h) }
      case "hotkey_cmd":
        if let b = value.boolValue { var h = preferences.hotkey; h.command = b; preferences.updateHotkey(h) }
      case "hotkey_shift":
        if let b = value.boolValue { var h = preferences.hotkey; h.shift = b; preferences.updateHotkey(h) }
      case "login_item":
        if let b = value.boolValue { preferences.setLoginItemEnabled(b) }
      case "active_profile_id":
        if let s = value.stringValue, let uuid = UUID(uuidString: s) {
          preferences.activateProfile(uuid)
        }
      default:
        break
      }
    }
  }

  private func applyProfiles(_ parsed: [String: [String: [String: TOMLValue]]]) {
    guard let profiles = parsed["profiles"] else { return }

    for (profileName, names) in profiles {
      // Match by UUID first, fall back to name matching
      let matches: Bool
      if let uuidStr = names["uuid"]?.stringValue, let uuid = UUID(uuidString: uuidStr) {
        matches = uuid == preferences.activeProfileID
      } else {
        matches = profileName == preferences.activeProfile.name
      }
      guard matches else { continue }

      for (spaceID, value) in names where spaceID != "uuid" {
        if let displayName = value.stringValue {
          preferences.setName(displayName, for: spaceID)
        }
      }
    }
  }

  // MARK: - File Management

  func createIfMissing() {
    guard !fileExists else { return }
    try? FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
    let content = """
    # Spaces Renamer Configuration
    # Managed by the application. Manual edits are merged on save.

    [settings]
    # naming_mode = "manual"
    # show_menu_bar = true
    # menu_bar_display = "icon"
    # show_duplicate_apps = false
    # hotkey_key = 15
    # hotkey_ctrl = true
    # hotkey_opt = true
    # hotkey_cmd = false
    # hotkey_shift = false
    # login_item = false
    # active_profile_id = ""

    # Profiles are matched by the `uuid` field if present, falling back to
    # section name matching.
    [profiles.Work]
    # uuid = "00000000-0000-0000-0000-000000000000"
    # "space-uuid" = "Display Name"

    """
    try? content.write(to: Self.fileURL, atomically: true, encoding: .utf8)
  }

  // MARK: - Watching

  private func startWatching() {
    let fd = open(Self.fileURL.path, O_EVTONLY)
    guard fd >= 0 else { return }

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend],
      queue: .main
    )

    src.setEventHandler { [weak self] in
      self?.read()
    }

    src.setCancelHandler { close(fd) }
    source = src
    src.resume()
  }
}
