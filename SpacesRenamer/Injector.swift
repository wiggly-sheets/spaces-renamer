import AppKit
import Observation

/// Parsed output of `injector.sh status`.
struct InjectorState {
  enum Active: String {
    case none, mip
  }

  var host = "WindowManager"
  var mipInstalled = false
  var mipBundleOn = false
  /// Root in use for MIP. Nil when the script did not report the key.
  var runtimeRoot: String?
  /// Whether our private runtime files are present.
  var runtimeInstalled: Bool?
  /// Whether our bundle is installed in the active root.
  var runtimeBundle: Bool?
  /// Whether the running host has loaded the bundle.
  var runtimeLoaded: Bool?
  var active: Active = .none
  /// Set when the injector script itself could not be read. Lets callers distinguish
  /// "status unknown" from "status read, nothing configured".
  var readError: String?

  init() {}

  init(statusOutput: String) {
    for line in statusOutput.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let value = String(parts[1])
      switch parts[0] {
      case "host": host = value
      case "mip_installed": mipInstalled = value == "yes"
      case "mip_bundle": mipBundleOn = value == "on"
      case "runtime_root": runtimeRoot = value
      case "runtime_installed": runtimeInstalled = value == "on"
      case "runtime_bundle": runtimeBundle = value == "on"
      case "runtime_loaded": runtimeLoaded = value == "on"
      case "active": active = Active(rawValue: value) ?? .none
      default: break
      }
    }
  }

  /// The runtime root, or a placeholder when the injector did not report one.
  var runtimeRootDescription: String { runtimeRoot ?? "unknown root" }

  /// The runtime facts, spelled out so a missing bundle or an unloaded host stays visible
  /// instead of reading as "everything is fine".
  var runtimeFacts: [String] {
    [
      runtimeInstalled.map { $0 ? "installed" : "not installed" } ?? "install state unknown",
      runtimeBundle.map { $0 ? "bundle installed" : "bundle not installed" } ?? "bundle state unknown",
      runtimeLoaded.map { $0 ? "loader active" : "loader inactive" } ?? "loader state unknown",
    ]
  }

  /// One line describing the runtime, for example
  /// "Runtime: /Users/me/Library/.../mip (installed, bundle installed, loader active)".
  var runtimeSummary: String {
    "Runtime: \(runtimeRootDescription) (\(runtimeFacts.joined(separator: ", ")))"
  }
}

enum InjectorError: LocalizedError {
  case notEmbedded
  case cancelled
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .notEmbedded:
      "This build has no embedded injector. Rebuild the app with `make` (it embeds the plugin, the mechanism script and the MIP bundle)."
    case .cancelled:
      "Authorization was cancelled."
    case .failed(let message):
      message.isEmpty ? "The injector command failed." : message
    }
  }
}

/// The app's front-end to `injector.sh`, embedded in the app bundle. The MIP loader and bundle
/// live in the user's Application Support, so activation is unprivileged.
enum Injector {
  static var scriptURL: URL? {
    Bundle.main.url(forResource: "injector", withExtension: "sh")
  }

  static var mipBundleURL: URL? {
    Bundle.main.url(forResource: "SpacesRenamer.mip", withExtension: "bundle")
  }

  /// True when the pieces MIP activation needs are present in this build.
  static var isEmbedded: Bool {
    guard let script = scriptURL, let bundle = mipBundleURL else { return false }
    return FileManager.default.fileExists(atPath: script.path)
      && FileManager.default.fileExists(atPath: bundle.path)
      && mipRuntimeEmbedded
  }

  static func status() throws -> InjectorState {
    guard scriptURL != nil, let output = try? sh(["status"]) else {
      var state = InjectorState()
      state.host = defaultHost
      state.readError = "Could not read injector status."
      return state
    }
    return InjectorState(statusOutput: output)
  }

  /// Installs the loader and bundle, then restarts the host into them.
  static func activate() throws -> String {
    guard let bundle = mipBundleURL else { throw InjectorError.notEmbedded }
    return try sh(["mip", "on", bundle.path])
  }

  /// Unloads the hook by restarting the host without the loader.
  static func deactivate() throws -> String {
    return try sh(["mip", "off"])
  }

  /// Adds `-arm64e_preview_abi` to boot-args via an admin prompt (root writes NVRAM).
  static func enableARM64e() throws {
    guard let script = scriptURL else { throw InjectorError.notEmbedded }
    _ = try admin("/bin/sh \(shellQuote(script.path)) arm64e on")
  }

  /// Quotes a path as one POSIX shell word, so paths with spaces stay intact.
  private static func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// User-space restart through System Events, so no extra privilege is needed.
  static func restartMac() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"System Events\" to restart"]
    try? process.run()
  }

  // MARK: - Running the script

  /// Runs the embedded script unprivileged, returning combined stdout+stderr.
  @discardableResult
  private static func sh(_ arguments: [String]) throws -> String {
    guard let script = scriptURL else { throw InjectorError.notEmbedded }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      throw InjectorError.failed(error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else { throw InjectorError.failed(output) }
    return output
  }

  /// Runs a shell command as root via an `osascript` admin prompt, returning the
  /// combined stdout+stderr so the caller can show why the command failed.
  private static func admin(_ command: String) throws -> String {
    let appleScript = "do shell script \"\(escapeAppleScript(command))\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      throw InjectorError.failed(error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      // osascript reports a user-cancelled authorization dialog as error -128.
      if output.contains("-128") { throw InjectorError.cancelled }
      throw InjectorError.failed(output)
    }
    return output
  }

  /// Escapes a string for use inside an AppleScript double-quoted string literal.
  /// Only `\\` and `"` need escaping; AppleScript treats other characters literally.
  private static func escapeAppleScript(_ string: String) -> String {
    return string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  static var defaultHost: String {
    host(forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
  }

  /// The process that draws the Spaces bar for a macOS release. Dock keeps running on macOS 27,
  /// so only one of the two can be the host the hook must load into.
  static func host(forMajorVersion majorVersion: Int) -> String {
    majorVersion >= 27 ? "WindowManager" : "Dock"
  }

  /// Root of the private loader the app installs on demand.
  static var privateMIPRoot: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SpacesRenamer/mip").path
  }

  /// True when this build carries the private runtime payload, so MIP can be used without a
  /// separate user install.
  static var mipRuntimeEmbedded: Bool {
    guard let root = Bundle.main.resourceURL?.appendingPathComponent("mip") else { return false }
    let manager = FileManager.default
    return manager.fileExists(atPath: root.appendingPathComponent("loader.dylib").path)
  }

  /// Removes the private loader and bundle from the user's Application Support.
  static func uninstallMIPRuntime() throws -> String {
    _ = try sh(["mip-runtime", "uninstall"])
    return ""
  }
}

/// Status entry the plugin writes to its host's own preference domain under `SpacesRenamerPlugin`:
/// `com.apple.WindowManager` on macOS 27+, `com.apple.dock` on macOS 26.
struct PluginMarker {
  static let key = "SpacesRenamerPlugin"

  /// The domain of the process that draws the Spaces bar on this macOS release. Dock keeps
  /// running on macOS 27, so its marker cannot prove the WindowManager hook is loaded.
  static var hostDomain: String {
    hostDomain(forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
  }

  /// Preference domain of the release's Spaces bar host, where the plugin writes its marker.
  static func hostDomain(forMajorVersion majorVersion: Int) -> String {
    majorVersion >= 27 ? "com.apple.WindowManager" : "com.apple.dock"
  }

  let version: String
  let build: String
  let hostPID: Int
  let hostBundleID: String
  let loadedAt: Date
  /// `hostPID` is the pid of the running app with `hostBundleID`.
  let isLive: Bool

  var hostName: String {
    let last = hostBundleID.split(separator: ".").last.map(String.init) ?? hostBundleID
    return last.prefix(1).uppercased() + last.dropFirst()
  }

  /// The marker the current release's host wrote, live or stale. Nil when that host never
  /// loaded the hook, even if the other release's host still carries a marker.
  static func current() -> PluginMarker? {
    UserDefaults(suiteName: hostDomain)?
      .dictionary(forKey: key)
      .flatMap(PluginMarker.init(raw:))
  }

  /// Whether this marker comes from the same payload as the app. The build stamps the app and
  /// the payload with the same git-describe version, so an exact match is the whole test: a
  /// marker from another version means the host still runs an older payload, for example after
  /// an app update, and the app must inject again instead of reporting the old hook as current.
  func isCurrent(forAppVersion appVersion: String?) -> Bool {
    Self.versionMatches(markerVersion: version, appVersion: appVersion)
  }

  /// Pure comparison behind `isCurrent(forAppVersion:)`; exposed for tests.
  static func versionMatches(markerVersion: String, appVersion: String?) -> Bool {
    guard let appVersion else { return true }
    return markerVersion == appVersion
  }

  private init?(raw: [String: Any]) {
    guard let hostPID = raw["HostPID"] as? Int, let hostBundleID = raw["HostBundleID"] as? String else { return nil }
    self.hostPID = hostPID
    self.hostBundleID = hostBundleID
    self.version = raw["Version"] as? String ?? "unknown"
    self.build = raw["Build"] as? String ?? "unknown"
    self.loadedAt = raw["LoadedAt"] as? Date ?? .distantPast
    self.isLive = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
      .contains { Int($0.processIdentifier) == hostPID }
  }
}

/// Drives the Activation section of the Diagnostics pane: current injector state plus activate and
/// deactivate actions. Blocking script work runs off the main actor.
@MainActor
@Observable
final class ActivationModel {
  private(set) var state = InjectorState()
  /// True once the first status read has completed, so the UI can distinguish "not active" from
  /// "not read yet" and avoid flashing a prompt at an already-active user.
  private(set) var hasLoaded = false
  private(set) var isBusy = false
  /// The plugin's own report that it is loaded in the running host, independent of which injector
  /// (if any) this app manages. This is the ground truth for "renaming is on".
  private(set) var pluginIsLive = false
  /// Whether the live plugin reports this app's version. A host that survived an app update
  /// keeps running the old payload until it is injected again.
  private(set) var pluginIsCurrent = false
  /// The output of the last injector command, successful or not. Kept so the UI
  /// can show why an activation failed instead of only "Renaming off".
  private(set) var lastOutput: String?
  /// Number of finished activation attempts. Observers use it to detect the end
  /// of an attempt without polling.
  private(set) var completedAttempts = 0
  var errorMessage: String?

  var isEmbedded: Bool { Injector.isEmbedded }

  /// Renaming is active only when the plugin itself reports it is loaded into the running host
  /// at this app's version. An installed loader or bundle does not prove the dylib ever loaded —
  /// the plugin handshake is the ground truth.
  var isActive: Bool { pluginIsLive && pluginIsCurrent }

  func refresh(completion: (() -> Void)? = nil) {
    Task { await reload(); completion?() }
  }

  func activate() {
    perform(waitsForPlugin: true) { try Injector.activate() }
  }

  func deactivate() {
    perform { try Injector.deactivate() }
  }

  /// Removes the private runtime. Only the user asks for this; the app never uninstalls the
  /// runtime on its own.
  func uninstallRuntime() {
    perform { try Injector.uninstallMIPRuntime() }
  }

  private func perform(
    waitsForPlugin: Bool = false,
    _ work: @escaping @Sendable () throws -> String?
  ) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    Task {
      var succeeded = false
      do {
        let output = try await Task.detached(priority: .userInitiated) { try work() }.value
        lastOutput = output
        succeeded = true
      } catch let error as InjectorError {
        errorMessage = error.localizedDescription
        lastOutput = error.localizedDescription
      } catch {
        errorMessage = error.localizedDescription
        lastOutput = error.localizedDescription
      }
      if succeeded, waitsForPlugin {
        // The bundle loads into the restarted host, so the plugin handshake
        // arrives a moment after the injector command returns.
        let live = await waitForPluginLoad()
        if !live {
          let host = hasLoaded ? state.host : Injector.defaultHost
          errorMessage = "The injector ran, but the plugin did not load into \(host) within 15 s. "
            + "Check the -arm64e_preview_abi boot argument, then activate again."
        }
      }
      await reload()
      isBusy = false
      completedAttempts += 1
    }
  }

  /// The app's own version, compared against the plugin marker to detect a payload from a
  /// previous release still running in a host that survived an update.
  static var appVersion: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  /// Polls the plugin handshake until the host reports the current payload, or 15 s pass.
  private func waitForPluginLoad() async -> Bool {
    let appVersion = Self.appVersion
    return await Task.detached(priority: .userInitiated) { () -> Bool in
      for _ in 0..<30 {
        if let marker = PluginMarker.current(),
           marker.isLive,
           marker.isCurrent(forAppVersion: appVersion) {
          return true
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
      guard let marker = PluginMarker.current() else { return false }
      return marker.isLive && marker.isCurrent(forAppVersion: appVersion)
    }.value
  }

  private func reload() async {
    let appVersion = Self.appVersion
    let snapshot = await Task.detached(priority: .userInitiated) {
      let status: InjectorState
      do {
        status = try Injector.status()
      } catch {
        var fallback = InjectorState()
        fallback.host = Injector.defaultHost
        fallback.readError = error.localizedDescription
        status = fallback
      }
      let marker = PluginMarker.current()
      return (
        status: status,
        live: marker?.isLive ?? false,
        current: marker?.isCurrent(forAppVersion: appVersion) ?? false
      )
    }.value
    state = snapshot.status
    pluginIsLive = snapshot.live
    pluginIsCurrent = snapshot.current
    hasLoaded = true
    // A live, current plugin outranks an earlier failure: the hook did load.
    if snapshot.live, snapshot.current { errorMessage = nil }
  }
}
