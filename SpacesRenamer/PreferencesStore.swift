import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

extension Notification.Name {
  static let spacesRenamerPreferencesChanged = Notification.Name("SpacesRenamerPreferencesChanged")
}

struct SpaceProfile: Codable, Identifiable, Hashable {
  var id: UUID
  var name: String
  var names: [String: String]

  init(id: UUID = UUID(), name: String, names: [String: String] = [:]) {
    self.id = id
    self.name = name
    self.names = names
  }
}

struct HotkeyPreference: Codable, Hashable {
  var keyCode: UInt32 = 15 // R
  var command = false
  var option = true
  var control = true
  var shift = false

  var carbonModifiers: UInt32 {
    (command ? UInt32(cmdKey) : 0)
      | (option ? UInt32(optionKey) : 0)
      | (control ? UInt32(controlKey) : 0)
      | (shift ? UInt32(shiftKey) : 0)
  }
}

enum NamingMode: String, Codable, CaseIterable, Identifiable {
  case manual
  case applications
  case yabaiLabels

  var id: Self { self }

  var title: String {
    switch self {
    case .manual: return "Manual Profiles"
    case .applications: return "Apps in Space"
    case .yabaiLabels: return "yabai Space Labels"
    }
  }

  var summary: String {
    switch self {
    case .manual: return "Names use the active profile."
    case .applications: return "Names follow the real app windows in each Space."
    case .yabaiLabels: return "Names follow labels reported by yabai."
    }
  }
}

enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
  case icon
  case spaceName
  case spaceNumberAndName

  var id: Self { self }

  var title: String {
    switch self {
    case .icon: return "Icon"
    case .spaceName: return "Current Space name"
    case .spaceNumberAndName: return "Space number and name"
    }
  }
}

private struct StoredPreferences: Codable {
  var profiles: [SpaceProfile]
  var activeProfileID: UUID
  var automaticNaming: Bool?
  var namingMode: NamingMode?
  var hotkey: HotkeyPreference
  var showMenuBarIcon: Bool?
  var menuBarDisplayMode: MenuBarDisplayMode?
  var showDuplicateApplications: Bool?
  var showSpaceChangeHUD: Bool?
  var automaticInjectionEnabled: Bool?
  var injectionConsentGranted: Bool?
}

@MainActor
@Observable
final class PreferencesStore {
  private(set) var profiles: [SpaceProfile]
  private(set) var activeProfileID: UUID
  private(set) var namingMode: NamingMode
  private(set) var hotkey: HotkeyPreference
  private(set) var showMenuBarIcon: Bool
  private(set) var menuBarDisplayMode: MenuBarDisplayMode
  private(set) var showDuplicateApplications: Bool
  private(set) var showSpaceChangeHUD: Bool
  private(set) var automaticInjectionEnabled: Bool
  private(set) var injectionConsentGranted: Bool?
  private(set) var loginItemEnabled: Bool = false
  var lastError: String?

  private let fileURL: URL
  private var lastGeneratedNames: [String: String] = [:]

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SpacesRenamer", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    fileURL = support.appendingPathComponent("preferences.json")

    if
      let data = try? Data(contentsOf: fileURL),
      let stored = try? JSONDecoder().decode(StoredPreferences.self, from: data),
      !stored.profiles.isEmpty
    {
      let normalizedProfiles = Self.normalizedProfiles(stored.profiles)
      profiles = normalizedProfiles
      activeProfileID = normalizedProfiles.contains(where: { $0.id == stored.activeProfileID })
        ? stored.activeProfileID
        : normalizedProfiles[0].id
      namingMode = stored.namingMode
        ?? ((stored.automaticNaming ?? false) ? .applications : .manual)
      hotkey = stored.hotkey
      showMenuBarIcon = stored.showMenuBarIcon ?? true
      menuBarDisplayMode = stored.menuBarDisplayMode ?? .icon
      showDuplicateApplications = stored.showDuplicateApplications ?? false
      showSpaceChangeHUD = stored.showSpaceChangeHUD ?? true
      automaticInjectionEnabled = stored.automaticInjectionEnabled ?? false
      injectionConsentGranted = stored.injectionConsentGranted
    } else {
      let work = SpaceProfile(name: "Work")
      let home = SpaceProfile(name: "Home")
      profiles = [work, home]
      activeProfileID = work.id
      namingMode = .manual
      hotkey = HotkeyPreference()
      showMenuBarIcon = true
      menuBarDisplayMode = .icon
      showDuplicateApplications = false
      showSpaceChangeHUD = true
      automaticInjectionEnabled = false
      injectionConsentGranted = nil
    }
    refreshLoginItemStatus()
    persist()
  }

  var activeProfile: SpaceProfile {
    profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
  }

  func activateProfile(_ id: UUID) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    persistAndNotify()
  }

  func addProfile(named requestedName: String = "New Profile") {
    let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = uniqueProfileName(base.isEmpty ? "New Profile" : base)
    let profile = SpaceProfile(name: name)
    profiles.append(profile)
    activeProfileID = profile.id
    persistAndNotify()
  }

  func deleteProfile(_ id: UUID) {
    guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    profiles.remove(at: index)
    if activeProfileID == id {
      activeProfileID = profiles[min(index, profiles.count - 1)].id
    }
    persistAndNotify()
  }

  func renameProfile(_ id: UUID, to requestedName: String) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    profiles[index].name = uniqueProfileName(trimmed, excluding: id)
    persistAndNotify()
  }

  func name(for spaceID: String) -> String {
    if namingMode != .manual, let generated = lastGeneratedNames[spaceID], !generated.isEmpty {
      return generated
    }
    return activeProfile.names[spaceID] ?? ""
  }

  func setName(_ name: String, for spaceID: String) {
    applyNames([spaceID: name], toProfile: activeProfileID)
  }

  func applyNames(_ names: [String: String], toProfile profileID: UUID) {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
    var updatedNames = profiles[index].names
    for (spaceID, name) in names {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        updatedNames.removeValue(forKey: spaceID)
      } else {
        updatedNames[spaceID] = trimmed
      }
    }
    guard updatedNames != profiles[index].names else { return }
    profiles[index].names = updatedNames
    persistAndNotify()
  }

  func setNamingMode(_ mode: NamingMode) {
    namingMode = mode
    persistAndNotify()
  }

  func setShowMenuBarIcon(_ visible: Bool) {
    showMenuBarIcon = visible
    persistAndNotify()
  }

  func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
    menuBarDisplayMode = mode
    persistAndNotify()
  }

  func setShowDuplicateApplications(_ enabled: Bool) {
    showDuplicateApplications = enabled
    persistAndNotify()
  }

  func setShowSpaceChangeHUD(_ enabled: Bool) {
    showSpaceChangeHUD = enabled
    persistAndNotify()
  }

  func setAutomaticInjectionEnabled(_ enabled: Bool) {
    automaticInjectionEnabled = enabled
    persistAndNotify()
  }

  func setInjectionConsent(_ granted: Bool) {
    injectionConsentGranted = granted
    automaticInjectionEnabled = granted
    persistAndNotify()
  }

  func applyGeneratedNames(from snapshot: [DisplaySpaces]) {
    guard namingMode != .manual else {
      if !lastGeneratedNames.isEmpty {
        lastGeneratedNames = [:]
        persistAndNotify()
      }
      return
    }
    var generated: [String: String] = [:]
    for space in snapshot.flatMap(\.spaces) {
      let generatedName: String
      switch namingMode {
      case .manual:
        continue
      case .applications:
        guard !space.appNames.isEmpty else { continue }
        generatedName = space.appNames.prefix(3).joined(separator: " · ")
      case .yabaiLabels:
        guard let label = space.yabaiLabel, !label.isEmpty else { continue }
        generatedName = label
      }
      generated[space.id] = generatedName
    }
    guard generated != lastGeneratedNames else { return }
    lastGeneratedNames = generated
    persistAndNotify()
  }

  func updateHotkey(_ newValue: HotkeyPreference) {
    hotkey = newValue
    persistAndNotify()
  }

  func applyConfiguration(
    namingMode configuredNamingMode: NamingMode?,
    showMenuBarIcon configuredShowMenuBarIcon: Bool?,
    menuBarDisplayMode configuredMenuBarDisplayMode: MenuBarDisplayMode?,
    showDuplicateApplications configuredShowDuplicateApplications: Bool?,
    hotkey configuredHotkey: HotkeyPreference?,
    activeProfileID configuredActiveProfileID: UUID?,
    namesByProfileID: [UUID: [String: String]]
  ) {
    var changed = false

    if let configuredNamingMode, configuredNamingMode != namingMode {
      namingMode = configuredNamingMode
      changed = true
    }
    if let configuredShowMenuBarIcon, configuredShowMenuBarIcon != showMenuBarIcon {
      showMenuBarIcon = configuredShowMenuBarIcon
      changed = true
    }
    if let configuredMenuBarDisplayMode, configuredMenuBarDisplayMode != menuBarDisplayMode {
      menuBarDisplayMode = configuredMenuBarDisplayMode
      changed = true
    }
    if let configuredShowDuplicateApplications,
       configuredShowDuplicateApplications != showDuplicateApplications {
      showDuplicateApplications = configuredShowDuplicateApplications
      changed = true
    }
    if let configuredHotkey, configuredHotkey != hotkey {
      hotkey = configuredHotkey
      changed = true
    }
    if let configuredActiveProfileID,
       configuredActiveProfileID != activeProfileID,
       profiles.contains(where: { $0.id == configuredActiveProfileID }) {
      activeProfileID = configuredActiveProfileID
      changed = true
    }

    for index in profiles.indices {
      guard let configuredNames = namesByProfileID[profiles[index].id] else { continue }
      var updatedNames = profiles[index].names
      for (spaceID, name) in configuredNames {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          updatedNames.removeValue(forKey: spaceID)
        } else {
          updatedNames[spaceID] = trimmed
        }
      }
      if updatedNames != profiles[index].names {
        profiles[index].names = updatedNames
        changed = true
      }
    }

    if changed { persistAndNotify() }
  }

  @discardableResult
  func setLoginItemEnabled(_ enabled: Bool) -> Bool {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLoginItemStatus()
      lastError = loginItemEnabled == enabled
        ? nil
        : "macOS did not apply the Launch at Login change. Check System Settings → General → Login Items."
    } catch {
      lastError = error.localizedDescription
      refreshLoginItemStatus()
    }
    return loginItemEnabled == enabled
  }

  func refreshLoginItemStatus() {
    loginItemEnabled = SMAppService.mainApp.status == .enabled
  }

  private func uniqueProfileName(_ base: String, excluding excludedID: UUID? = nil) -> String {
    ProfileNamePolicy.uniqueName(
      base,
      existingNames: profiles.compactMap { profile in
        profile.id == excludedID ? nil : profile.name
      }
    )
  }

  private static func normalizedProfiles(_ storedProfiles: [SpaceProfile]) -> [SpaceProfile] {
    let names = ProfileNamePolicy.normalizedNames(storedProfiles.map(\.name))
    return zip(storedProfiles, names).map { profile, name in
      var normalized = profile
      normalized.name = name
      return normalized
    }
  }

  private func persistAndNotify() {
    persist()
    NotificationCenter.default.post(name: .spacesRenamerPreferencesChanged, object: self)
  }

  private func persist() {
    let stored = StoredPreferences(
      profiles: profiles,
      activeProfileID: activeProfileID,
      automaticNaming: namingMode == .applications,
      namingMode: namingMode,
      hotkey: hotkey,
      showMenuBarIcon: showMenuBarIcon,
      menuBarDisplayMode: menuBarDisplayMode,
      showDuplicateApplications: showDuplicateApplications,
      showSpaceChangeHUD: showSpaceChangeHUD,
      automaticInjectionEnabled: automaticInjectionEnabled,
      injectionConsentGranted: injectionConsentGranted
    )
    if let data = try? JSONEncoder().encode(stored) {
      try? data.write(to: fileURL, options: .atomic)
    }

    // Live preference-domain names for the injected Dock bundle.
    let displayedNames = namingMode != .manual
      ? activeProfile.names.merging(lastGeneratedNames) { _, generated in generated }
      : activeProfile.names
    UserDefaults(suiteName: "com.apple.dock")?.set(displayedNames, forKey: "SpacesRenamerNames")
  }
}

enum NativeAppManagement {
  static var isInApplicationsFolder: Bool {
    Bundle.main.bundleURL.path.hasPrefix("/Applications/")
  }

  /// Returns true when a copy in /Applications is being launched and this
  /// process will terminate. Callers must stop onboarding in that case.
  static func promptToMoveIfNeeded() -> Bool {
    guard !isInApplicationsFolder, !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else {
      return false
    }
    let alert = NSAlert()
    alert.messageText = "Move Spaces Renamer to Applications?"
    alert.informativeText = "Keeping the app in Applications makes launch at login and updates more reliable."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
      return moveToApplications()
    } else {
      UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
      return false
    }
  }

  @discardableResult
  static func moveToApplications() -> Bool {
    guard !isInApplicationsFolder else { return false }
    let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    do {
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists)
      }
      try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: destination)
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
        if let error {
          presentError(error)
        } else {
          NSApp.terminate(nil)
        }
      }
      return true
    } catch {
      presentError(error)
      return false
    }
  }

  private static func presentError(_ error: Error) {
    DispatchQueue.main.async {
      let alert = NSAlert(error: error)
      alert.informativeText += "\nMove the app to /Applications in Finder, then reopen it."
      alert.runModal()
    }
  }
}
