import AppKit
import Combine

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

final class SpaceStore: ObservableObject {
  @Published private(set) var snapshot: [DisplaySpaces] = []
  @Published private(set) var errorMessage: String?

  func refresh(
    for namingMode: NamingMode = .manual,
    showDuplicateApplications: Bool = false
  ) {
    let connection = _CGSDefaultConnection()
    guard let monitors = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
      errorMessage = "Could not read macOS Spaces."
      return
    }

    let yabaiData = namingMode == .manual
      ? nil
      : Self.namingDataFromYabai(
        includeApplications: namingMode == .applications,
        showDuplicateApplications: showDuplicateApplications
      )
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

    let plist: NSDictionary = ["Monitors": monitors]
    try? FileManager.default.createDirectory(
      atPath: (Utils.listOfSpacesPlist as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    plist.write(toFile: Utils.listOfSpacesPlist, atomically: true)
    errorMessage = nil
  }

  private struct YabaiNamingData {
    let applicationsByWorkspace: [Int: [String]]
    let labelsByWorkspace: [Int: String]
  }

  private static func namingDataFromYabai(
    includeApplications: Bool,
    showDuplicateApplications: Bool
  ) -> YabaiNamingData? {
    struct YabaiSpace: Decodable {
      let id: Int
      let index: Int
      let label: String?
    }
    struct YabaiWindow: Decodable {
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

    guard
      let spacesData = runYabaiQuery(["-m", "query", "--spaces"]),
      let spaces = try? JSONDecoder().decode([YabaiSpace].self, from: spacesData)
    else { return nil }

    let labelsByWorkspace: [Int: String] = Dictionary(uniqueKeysWithValues: spaces.compactMap {
      space -> (Int, String)? in
      guard let label = space.label, !label.isEmpty else { return nil }
      return (space.id, label)
    })
    guard includeApplications else {
      return YabaiNamingData(
        applicationsByWorkspace: [:],
        labelsByWorkspace: labelsByWorkspace
      )
    }
    guard
      let windowsData = runYabaiQuery(["-m", "query", "--windows"]),
      let windows = try? JSONDecoder().decode([YabaiWindow].self, from: windowsData)
    else { return nil }

    let managedIDByIndex = Dictionary(uniqueKeysWithValues: spaces.map { ($0.index, $0.id) })
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
        let managedID = managedIDByIndex[window.space],
        window.app != "Dock",
        window.app != "Spaces Renamer"
      else { continue }
      if showDuplicateApplications {
        result[managedID, default: []].append(window.app)
      } else {
        appendUnique(window.app, to: managedID, in: &result)
      }
    }
    return YabaiNamingData(
      applicationsByWorkspace: result,
      labelsByWorkspace: labelsByWorkspace
    )
  }

  private static func runYabaiQuery(_ arguments: [String]) -> Data? {
    let candidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      return nil
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = Pipe()

    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return process.terminationStatus == 0 ? data : nil
    } catch {
      return nil
    }
  }

  private static func appendUnique(
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
