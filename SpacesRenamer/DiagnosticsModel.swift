import AppKit
import Observation

/// Where `injector.sh` stages the DYLD payload. The script does not report whether the file
/// is still there, so the check tests the path itself.
private let dyldLibraryPath = NSHomeDirectory() + "/Library/Application Support/SpacesRenamer/spaces-renamer.dylib"

/// A one-tap fix offered next to a failing check.
enum RemedyAction: Equatable {
  /// Copy a Terminal command to the clipboard (used where macOS forbids automating the step).
  case copyCommand(String)
  /// Add `-arm64e_preview_abi` to boot-args (admin prompt), then offer to restart.
  case enableARM64e

  var buttonTitle: String {
    switch self {
    case .copyCommand: "Copy command"
    case .enableARM64e: "Enable & restart…"
    }
  }
}

struct DiagnosticCheck: Identifiable {
  enum Status: Equatable {
    case pass, fail, unknown
  }

  let title: String
  var status: Status = .unknown
  var finding: String = "Not checked yet"
  /// Shown only for failures.
  var remedy: String?
  /// Optional one-tap fix shown only for failures.
  var action: RemedyAction?

  var id: String { title }
}

/// The environment checks the Spaces-bar plugin depends on. Checks run off the main thread.
@MainActor
@Observable
final class DiagnosticsModel {
  nonisolated static let activationRemedy = "Turn on an injector in the Injection settings, then re-run checks."

  /// The checks in display order. The placeholder list and a finished run share it, so the two
  /// can never drift apart.
  nonisolated static let checkTitles = [
    "System Integrity Protection",
    "Boot arguments",
    "Injection runtime",
    "LaunchAgent injector (backup)",
    "Plugin version",
    "Plugin active in host",
  ]

  private(set) var checks: [DiagnosticCheck] = DiagnosticsModel.checkTitles.map { DiagnosticCheck(title: $0) }
  private(set) var isRunning = false
  /// Feedback for the most recent remedy button (a copy confirmation or an error).
  private(set) var actionNote: String?

  func runChecks() {
    guard !isRunning else { return }
    isRunning = true
    Task.detached(priority: .userInitiated) {
      let results = Self.runAll()
      await MainActor.run {
        self.checks = results
        self.isRunning = false
      }
    }
  }

  func perform(_ action: RemedyAction) {
    actionNote = nil
    switch action {
    case .copyCommand(let command):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      actionNote = "Copied “\(command)” to the clipboard."
    case .enableARM64e:
      enableARM64e()
    }
  }

  private func enableARM64e() {
    Task {
      do {
        try await Task.detached(priority: .userInitiated) { try Injector.enableARM64e() }.value
        runChecks()
        offerRestart()
      } catch InjectorError.cancelled {
      } catch {
        actionNote = error.localizedDescription
      }
    }
  }

  private func offerRestart() {
    let alert = NSAlert()
    alert.messageText = "Restart to apply the arm64e ABI?"
    alert.informativeText = "boot-args now includes -arm64e_preview_abi; it takes effect after a restart."
    alert.addButton(withTitle: "Restart Now")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      Injector.restartMac()
    }
  }

  nonisolated static func runAll() -> [DiagnosticCheck] {
    let marker = PluginMarker.current()
    // One status read feeds both injector checks, so the script runs once per pass.
    let state = injectorStatus()
    return [
      sip(),
      bootArgs(),
      injectionRuntime(state),
      launchAgentInjector(state: state, libraryStaged: dyldLibraryStaged()),
      pluginVersion(marker),
      pluginActive(marker),
    ]
  }

  /// The injector status, read once per pass. A script that cannot be run yields a state that
  /// carries the error, so both injector checks report it instead of showing stale facts.
  nonisolated private static func injectorStatus() -> InjectorState {
    do {
      return try Injector.status()
    } catch {
      var fallback = InjectorState()
      fallback.host = Injector.defaultHost
      fallback.readError = error.localizedDescription
      return fallback
    }
  }

  /// True when the DYLD payload still sits where the LaunchAgent expects it.
  nonisolated private static func dyldLibraryStaged() -> Bool {
    FileManager.default.fileExists(atPath: dyldLibraryPath)
  }

  // MARK: - Checks

  nonisolated private static func sip() -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "System Integrity Protection")
    guard let output = run("/usr/bin/csrutil", ["status"]) else {
      check.finding = "Could not run csrutil"
      return check
    }
    let line = output.split(separator: "\n").first.map(String.init) ?? output
    let lowered = output.lowercased()
    if lowered.contains("status: disabled") {
      check.status = .pass
      check.finding = line
      return check
    }
    if lowered.contains("custom configuration") {
      let required: [(String, String)] = [
        ("Filesystem protections", "filesystem protections: disabled"),
        ("Debugging restrictions", "debugging restrictions: disabled"),
        ("NVRAM protections", "nvram protections: disabled"),
      ]
      let missing = required.filter { !lowered.contains($1) }
      if missing.isEmpty {
        check.status = .pass
        check.finding = line
      } else {
        check.status = .fail
        check.finding = line
        check.remedy = "Partial SIP must disable filesystem, debugging, and NVRAM protections. Missing: \(missing.map(\.0).joined(separator: ", "))."
        check.action = .copyCommand("csrutil disable")
      }
      return check
    }
    check.status = .fail
    check.finding = line
    check.remedy = "macOS can only disable SIP from Recovery: reboot holding the power button, open Terminal, run `csrutil disable`, reboot. Copy the command below."
    check.action = .copyCommand("csrutil disable")
    return check
  }

  nonisolated private static func bootArgs() -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Boot arguments")
    let output = run("/usr/sbin/nvram", ["boot-args"]) ?? ""
    let value = output.split(separator: "\t", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    if output.contains("-arm64e_preview_abi") {
      check.status = .pass
      check.finding = "boot-args = \(value)"
    } else {
      check.status = .fail
      check.finding = value.isEmpty || output.contains("Error") ? "boot-args not set" : "boot-args = \(value)"
      check.remedy = "Adds `-arm64e_preview_abi` to boot-args (keeping any existing flags) and takes effect after a restart."
      check.action = .enableARM64e
    }
    return check
  }

  nonisolated static func injectionRuntime(_ state: InjectorState) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Injection runtime")
    guard state.readError == nil else {
      check.finding = "Could not read the injector status"
      return check
    }
    check.finding = state.runtimeSummary
    if state.runtimeInstalled == true {
      if state.runtimeDaemon == true {
        check.status = .pass
      } else if state.runtimeDaemon == false {
        check.status = .fail
        check.remedy = "The runtime is installed, but its daemon is not running. Activate the injection again to start it."
      } else {
        check.status = .unknown
      }
    } else if state.runtimeInstalled == false {
      check.status = .fail
      check.remedy = activationRemedy
    }
    return check
  }

  /// The DYLD path is the backup injector, used only when the MIP path is unavailable. An
  /// unarmed backup is therefore unknown, never a failure; only a broken arming fails.
  nonisolated static func launchAgentInjector(state: InjectorState, libraryStaged: Bool) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "LaunchAgent injector (backup)")
    guard state.readError == nil else {
      check.finding = "Could not read the injector status"
      return check
    }
    let facts = "\(state.dyldAgent ? "login agent present" : "no login agent"), "
      + "\(state.dyldEnv ? "environment set" : "environment unset"), "
      + "\(libraryStaged ? "library staged" : "library not staged")"
    if state.dyldOn {
      if libraryStaged {
        check.status = .pass
        check.finding = "armed: \(facts)"
      } else {
        // The environment names a payload that is gone, so every app launched from now on
        // would fail to load the library: broken, not unused.
        check.status = .fail
        check.finding = "broken: armed, but the staged library is missing (\(dyldLibraryPath))"
        check.remedy = "Activate the LaunchAgent injector again to restage the library."
      }
    } else {
      check.status = .unknown
      check.finding = "not armed: \(facts). Backup path, used only when MIP is unavailable."
    }
    return check
  }

  nonisolated private static func pluginVersion(_ marker: PluginMarker?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin version")
    guard let marker else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationRemedy
      return check
    }
    check.status = .pass
    check.finding = "Version \(marker.version), build \(marker.build)"
    return check
  }

  nonisolated private static func pluginActive(_ marker: PluginMarker?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin active in host")
    guard let marker else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationRemedy
      return check
    }
    if marker.isLive {
      check.status = .pass
      check.finding = "active in \(marker.hostName) (pid \(marker.hostPID), \(marker.hostBundleID))"
    } else {
      check.status = .fail
      check.finding = "stale: loaded into \(marker.hostName) pid \(marker.hostPID) (\(marker.hostBundleID)), which is no longer running"
      check.remedy = activationRemedy
    }
    return check
  }

  // MARK: - Helpers

  /// Combined stdout+stderr of a finished process, or nil if it could not be launched.
  nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}