import AppKit
import Observation

#if canImport(CGSPrivate)
import CGSPrivate
#endif

struct ManagedSpace: Identifiable, Hashable {
  let id: String
  let managedID: Int
  let index: Int
  let isCurrent: Bool
  let appNames: [String]
  let yabaiLabel: String?
}

struct DisplaySpaces: Identifiable, Hashable {
  let id: String
  let name: String
  let spaces: [ManagedSpace]
}

private struct YabaiWindow: Decodable {
  struct Frame: Decodable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
  }

  let id: Int
  let app: String
  let space: Int
  let frame: Frame
  let isHidden: Bool
  let isMinimized: Bool
  let role: String?
  let subrole: String?
  let isRootWindow: Bool?

  enum CodingKeys: String, CodingKey {
    case id, app, space, frame, role, subrole
    case isHidden = "is-hidden"
    case isMinimized = "is-minimized"
    case isRootWindow = "root-window"
  }

  var isStandardUserWindow: Bool {
    guard
      !isHidden,
      !isMinimized,
      id > 0,
      !app.isEmpty,
      space > 0,
      frame.w > 0,
      frame.h > 0
    else { return false }

    // Keep this aligned with Spacemap. `is-visible` is intentionally not
    // consulted because real windows on inactive Spaces report false.
    return role == "AXWindow"
      && subrole == "AXStandardWindow"
      && isRootWindow != false
  }
}

@MainActor
@Observable
final class SpaceStore {
  private(set) var snapshot: [DisplaySpaces] = []
  private(set) var errorMessage: String?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0

  @MainActor
  func refresh(
    for namingMode: NamingMode = .manual,
    showDuplicateApplications: Bool = false,
    completion: (() -> Void)? = nil
  ) {
    refreshGeneration += 1
    let generation = refreshGeneration
    refreshTask?.cancel()
    refreshTask = nil

    let connection = _CGSDefaultConnection()
    guard let monitors = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
      errorMessage = "Could not read macOS Spaces."
      return
    }

    if namingMode == .manual {
      apply(monitors: monitors, yabaiData: nil)
      completion?()
      return
    }

    refreshTask = Task { @MainActor [weak self] in
      let yabaiData = await Task.detached(priority: .userInitiated) {
        Self.namingDataFromYabai(
          includeApplications: namingMode == .applications,
          showDuplicateApplications: showDuplicateApplications
        )
      }.value
      guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
      self.refreshTask = nil
      self.apply(monitors: monitors, yabaiData: yabaiData)
      completion?()
    }
  }

  @MainActor
  private func apply(monitors: [[String: Any]], yabaiData: YabaiNamingData?) {
    snapshot = monitors.enumerated().map { monitorIndex, monitor in
      let currentUUID = (monitor["Current Space"] as? [String: Any])?["uuid"] as? String
      let rawSpaces = monitor["Spaces"] as? [[String: Any]] ?? []
      let displayID = monitor["Display Identifier"] as? String ?? "display-\(monitorIndex)"
      let spaces = rawSpaces.enumerated().compactMap { index, raw -> ManagedSpace? in
        guard let uuid = raw["uuid"] as? String else { return nil }
        let managedID = raw["ManagedSpaceID"] as? Int ?? 0
        return ManagedSpace(
          id: uuid,
          managedID: managedID,
          index: index + 1,
          isCurrent: uuid == currentUUID,
          appNames: yabaiData?.applicationsByWorkspace[managedID] ?? [],
          yabaiLabel: yabaiData?.labelsByWorkspace[managedID]
        )
      }
      return DisplaySpaces(
        id: displayID,
        name: monitors.count == 1 ? "Spaces" : "Display \(monitorIndex + 1)",
        spaces: spaces
      )
    }

    // Live preference-domain layout for the injected Dock bundle. Only write
    // when the value changed to avoid cfprefsd write churn on every refresh.
    let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    let previousMonitors = dockDefaults?.array(forKey: "SpacesRenamerMonitors")
    if previousMonitors == nil || !NSArray(array: monitors).isEqual(previousMonitors) {
      dockDefaults?.set(monitors, forKey: "SpacesRenamerMonitors")
    }
    errorMessage = nil
  }

  /// The text shown in the menu bar label for the current Space (empty when
  /// none is known, which the MenuBarExtra treats as the plain icon).
  func menuBarLabel(
    for displayMode: MenuBarDisplayMode,
    preferences: PreferencesStore
  ) -> String {
    guard let space = currentSpace else { return "" }
    let name = preferences.name(for: space.id)
    switch displayMode {
    case .icon:
      return ""
    case .spaceName:
      return name
    case .spaceNumberAndName:
      return "\(space.index). \(name)"
    }
  }

  private var currentSpace: ManagedSpace? {
    let all = snapshot.flatMap(\.spaces)
    return all.first(where: \.isCurrent) ?? all.first
  }

  private struct YabaiNamingData: Sendable {
    let applicationsByWorkspace: [Int: [String]]
    let labelsByWorkspace: [Int: String]
  }

  nonisolated private static func namingDataFromYabai(
    includeApplications: Bool,
    showDuplicateApplications: Bool
  ) -> YabaiNamingData? {
    struct YabaiSpace: Decodable {
      let id: Int
      let index: Int
      let label: String?
    }

    guard
      let spacesData = runYabaiQuery(["-m", "query", "--spaces"]),
      let spaces = try? JSONDecoder().decode([YabaiSpace].self, from: spacesData)
    else { return nil }

    var labelsByWorkspace: [Int: String] = [:]
    for space in spaces {
      if let label = space.label, !label.isEmpty {
        labelsByWorkspace[space.id] = label
      }
    }
    guard includeApplications else {
      return YabaiNamingData(
        applicationsByWorkspace: [:],
        labelsByWorkspace: labelsByWorkspace
      )
    }
    guard
      let windowsData = runYabaiQuery(["-m", "query", "--windows"])
    else { return nil }

    var managedIDByIndex: [Int: Int] = [:]
    for space in spaces { managedIDByIndex[space.index] = space.id }
    guard let applicationsByWorkspace = applicationsByManagedSpace(
      windowsJSON: windowsData,
      spaceIndexToID: managedIDByIndex,
      showDuplicateApplications: showDuplicateApplications
    ) else { return nil }
    return YabaiNamingData(
      applicationsByWorkspace: applicationsByWorkspace,
      labelsByWorkspace: labelsByWorkspace
    )
  }

  /// Pure real-window filter over a yabai `--windows` JSON payload, returning
  /// application names grouped by yabai Space id, ordered left-to-right then
  /// top-to-bottom. Returns nil when the payload does not decode (which the
  /// caller treats as a failed yabai query).
  nonisolated static func applicationsByManagedSpace(
    windowsJSON: Data,
    spaceIndexToID: [Int: Int],
    showDuplicateApplications: Bool
  ) -> [Int: [String]]? {
    guard let windows = try? JSONDecoder().decode([YabaiWindow].self, from: windowsJSON) else {
      return nil
    }

    var result: [Int: [String]] = [:]
    let spatiallyOrderedWindows = windows.sorted { left, right in
      if left.space != right.space { return left.space < right.space }
      if left.frame.x != right.frame.x { return left.frame.x < right.frame.x }
      if left.frame.y != right.frame.y { return left.frame.y < right.frame.y }
      return left.id < right.id
    }
    for window in spatiallyOrderedWindows {
      guard
        window.isStandardUserWindow,
        let managedID = spaceIndexToID[window.space],
        window.app != "Dock",
        window.app != "Spaces Renamer"
      else { continue }
      if showDuplicateApplications {
        result[managedID, default: []].append(window.app)
      } else {
        appendUnique(window.app, to: managedID, in: &result)
      }
    }
    return result
  }

  nonisolated private static func runYabaiQuery(_ arguments: [String]) -> Data? {
    YabaiClient.run(arguments)
  }

  nonisolated private static func appendUnique(
    _ application: String,
    to managedSpaceID: Int,
    in result: inout [Int: [String]]
  ) {
    guard !(result[managedSpaceID] ?? []).contains(where: {
      $0.localizedCaseInsensitiveCompare(application) == .orderedSame
    }) else { return }
    result[managedSpaceID, default: []].append(application)
  }
}
