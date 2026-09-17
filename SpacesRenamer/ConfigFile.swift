import Foundation

@MainActor
final class ConfigFile: ObservableObject {
  static let directoryURL: URL = {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/spacesrenamer")
  }()

  static let fileURL: URL = directoryURL.appendingPathComponent("config.toml")

  @Published private(set) var lastReadError: String?
  @Published private(set) var lastWatchError: String?

  private var watcher: ReplacingFileWatcher?
  private let preferences: PreferencesStore

  private struct ParsedSettings {
    var namingMode: NamingMode?
    var showMenuBarIcon: Bool?
    var menuBarDisplayMode: MenuBarDisplayMode?
    var showDuplicateApplications: Bool?
    var hotkey: HotkeyPreference?
    var loginItemEnabled: Bool?
    var activeProfileID: UUID?
  }

  init(preferences: PreferencesStore) {
    self.preferences = preferences
    createIfMissing()
    read()
    startWatching()
  }

  var fileExists: Bool {
    FileManager.default.fileExists(atPath: Self.fileURL.path)
  }

  func stopWatching() {
    watcher?.stop()
    watcher = nil
  }

  // MARK: - Read & Parse

  func read() {
    guard fileExists else { return }
    do {
      let contents = try String(contentsOf: Self.fileURL, encoding: .utf8)
      let parsed = try TOML.parse(contents)
      let settings = try parsedSettings(from: parsed)
      let namesByProfileID = parsedProfileNames(from: parsed)
      preferences.applyConfiguration(
        namingMode: settings.namingMode,
        showMenuBarIcon: settings.showMenuBarIcon,
        menuBarDisplayMode: settings.menuBarDisplayMode,
        showDuplicateApplications: settings.showDuplicateApplications,
        hotkey: settings.hotkey,
        activeProfileID: settings.activeProfileID,
        namesByProfileID: namesByProfileID
      )
      if let loginItemEnabled = settings.loginItemEnabled,
         loginItemEnabled != preferences.loginItemEnabled {
        preferences.setLoginItemEnabled(loginItemEnabled)
      }
      lastReadError = nil
    } catch {
      lastReadError = error.localizedDescription
    }
  }

  private func parsedSettings(
    from parsed: [String: [String: [String: TOMLValue]]]
  ) throws -> ParsedSettings {
    guard let settings = parsed["settings"]?[""] else { return ParsedSettings() }
    var result = ParsedSettings()
    var hotkey = preferences.hotkey
    var hasHotkeySetting = false

    for (key, value) in settings {
      switch key {
      case "naming_mode":
        if let s = value.stringValue, let mode = NamingMode(rawValue: s) {
          result.namingMode = mode
        }
      case "show_menu_bar":
        result.showMenuBarIcon = value.boolValue
      case "menu_bar_display":
        if let s = value.stringValue, let mode = MenuBarDisplayMode(rawValue: s) {
          result.menuBarDisplayMode = mode
        }
      case "show_duplicate_apps":
        result.showDuplicateApplications = value.boolValue
      case "hotkey_key":
        if let i = value.intValue {
          hotkey.keyCode = try ConfigPolicy.hotkeyKeyCode(from: i)
          hasHotkeySetting = true
        }
      case "hotkey_ctrl":
        if let b = value.boolValue { hotkey.control = b; hasHotkeySetting = true }
      case "hotkey_opt":
        if let b = value.boolValue { hotkey.option = b; hasHotkeySetting = true }
      case "hotkey_cmd":
        if let b = value.boolValue { hotkey.command = b; hasHotkeySetting = true }
      case "hotkey_shift":
        if let b = value.boolValue { hotkey.shift = b; hasHotkeySetting = true }
      case "login_item":
        result.loginItemEnabled = value.boolValue
      case "active_profile_id":
        if let s = value.stringValue, let uuid = UUID(uuidString: s) {
          result.activeProfileID = uuid
        }
      default:
        break
      }
    }
    if hasHotkeySetting { result.hotkey = hotkey }
    return result
  }

  private func parsedProfileNames(
    from parsed: [String: [String: [String: TOMLValue]]]
  ) -> [UUID: [String: String]] {
    guard let configuredProfiles = parsed["profiles"] else { return [:] }
    var namesByProfileID: [UUID: [String: String]] = [:]
    let profileIdentities = preferences.profiles.map {
      ConfigProfileIdentity(id: $0.id, name: $0.name)
    }

    for (profileName, names) in configuredProfiles {
      let profileID = ConfigPolicy.matchingProfileID(
        configuredUUID: names["uuid"]?.stringValue,
        sectionName: profileName,
        profiles: profileIdentities
      )
      guard let profileID else { continue }

      var configuredNames: [String: String] = [:]
      for (spaceID, value) in names where spaceID != "uuid" {
        if let displayName = value.stringValue {
          configuredNames[spaceID] = displayName
        }
      }
      if !configuredNames.isEmpty {
        namesByProfileID[profileID, default: [:]].merge(configuredNames) { _, latest in latest }
      }
    }
    return namesByProfileID
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
    lastWatchError = nil
    let watcher = ReplacingFileWatcher(
      fileURL: Self.fileURL,
      onChange: { [weak self] in
        Task { @MainActor in self?.read() }
      },
      onError: { [weak self] message in
        Task { @MainActor in self?.lastWatchError = message }
      }
    )
    self.watcher = watcher
    watcher.start()
  }
}
