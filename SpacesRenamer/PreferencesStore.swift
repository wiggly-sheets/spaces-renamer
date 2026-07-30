import AppKit
import Carbon.HIToolbox
import Combine
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
  var automaticInjectionEnabled: Bool?
}

final class PreferencesStore: ObservableObject {
  @Published private(set) var profiles: [SpaceProfile]
  @Published private(set) var activeProfileID: UUID
  @Published private(set) var namingMode: NamingMode
  @Published private(set) var hotkey: HotkeyPreference
  @Published private(set) var showMenuBarIcon: Bool
  @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
  @Published private(set) var showDuplicateApplications: Bool
  @Published private(set) var automaticInjectionEnabled: Bool
  @Published private(set) var loginItemEnabled: Bool = false
  @Published var lastError: String?

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
      profiles = stored.profiles
      activeProfileID = stored.activeProfileID
      namingMode = stored.namingMode
        ?? ((stored.automaticNaming ?? false) ? .applications : .manual)
      hotkey = stored.hotkey
      showMenuBarIcon = stored.showMenuBarIcon ?? true
      menuBarDisplayMode = stored.menuBarDisplayMode ?? .icon
      showDuplicateApplications = stored.showDuplicateApplications ?? false
      automaticInjectionEnabled = stored.automaticInjectionEnabled ?? false
    } else {
      let migratedNames = Self.loadLegacyNames()
      let work = SpaceProfile(name: "Work", names: migratedNames)
      let home = SpaceProfile(name: "Home")
      profiles = [work, home]
      activeProfileID = work.id
      namingMode = .manual
      hotkey = HotkeyPreference()
      showMenuBarIcon = true
      menuBarDisplayMode = .icon
      showDuplicateApplications = false
      automaticInjectionEnabled = false
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
    profiles[index].name = trimmed
    persistAndNotify()
  }

  func name(for spaceID: String) -> String {
    if namingMode != .manual, let generated = lastGeneratedNames[spaceID], !generated.isEmpty {
      return generated
    }
    return activeProfile.names[spaceID] ?? ""
  }

  func setName(_ name: String, for spaceID: String) {
    guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      profiles[index].names.removeValue(forKey: spaceID)
    } else {
      profiles[index].names[spaceID] = trimmed
    }
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

  func setAutomaticInjectionEnabled(_ enabled: Bool) {
    automaticInjectionEnabled = enabled
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
    let generated: [String: String] = Dictionary(uniqueKeysWithValues: snapshot.flatMap(\.spaces).compactMap { space -> (String, String)? in
      let generatedName: String
      switch namingMode {
      case .manual:
        return nil
      case .applications:
        guard !space.appNames.isEmpty else { return nil }
        generatedName = space.appNames.prefix(3).joined(separator: " · ")
      case .yabaiLabels:
        guard let label = space.yabaiLabel, !label.isEmpty else { return nil }
        generatedName = label
      }
      return (space.id, generatedName)
    })
    guard generated != lastGeneratedNames else { return }
    lastGeneratedNames = generated
    persistAndNotify()
  }

  func updateHotkey(_ newValue: HotkeyPreference) {
    hotkey = newValue
    persistAndNotify()
  }

  func setLoginItemEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLoginItemStatus()
    } catch {
      lastError = error.localizedDescription
      refreshLoginItemStatus()
    }
  }

  func refreshLoginItemStatus() {
    loginItemEnabled = SMAppService.mainApp.status == .enabled
  }

  private func uniqueProfileName(_ base: String) -> String {
    var candidate = base
    var suffix = 2
    while profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
      candidate = "\(base) \(suffix)"
      suffix += 1
    }
    return candidate
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
      automaticInjectionEnabled: automaticInjectionEnabled
    )
    if let data = try? JSONEncoder().encode(stored) {
      try? data.write(to: fileURL, options: .atomic)
    }

    // Compatibility contract for the injected Dock bundle.
    let profileMappings = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0.names) })
    let displayedNames = namingMode != .manual
      ? activeProfile.names.merging(lastGeneratedNames) { _, generated in generated }
      : activeProfile.names
    let legacy: NSDictionary = [
      "spaces_renaming": displayedNames,
      "profiles": profileMappings,
      "active_profile": activeProfile.name,
      "automatic_naming": namingMode != .manual,
      "naming_mode": namingMode.rawValue
    ]
    try? FileManager.default.createDirectory(
      atPath: (Utils.customNamesPlist as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    legacy.write(toFile: Utils.customNamesPlist, atomically: true)
  }

  private static func loadLegacyNames() -> [String: String] {
    guard
      let dictionary = NSDictionary(contentsOfFile: Utils.customNamesPlist),
      let names = dictionary["spaces_renaming"] as? [String: String]
    else { return [:] }
    return names
  }
}

enum NativeAppManagement {
  static var isInApplicationsFolder: Bool {
    Bundle.main.bundleURL.path.hasPrefix("/Applications/")
  }

  static func promptToMoveIfNeeded() {
    guard !isInApplicationsFolder, !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return }
    let alert = NSAlert()
    alert.messageText = "Move Spaces Renamer to Applications?"
    alert.informativeText = "Keeping the app in Applications makes launch at login and updates more reliable."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
      moveToApplications()
    } else {
      UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
    }
  }

  static func moveToApplications() {
    guard !isInApplicationsFolder else { return }
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
    } catch {
      presentError(error)
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
