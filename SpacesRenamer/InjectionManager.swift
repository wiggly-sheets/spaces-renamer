import AppKit
import Foundation
import Observation
import os

enum InjectionState: Equatable {
  case unsupported(String)
  case prerequisitesMissing(String)
  case checking
  case inactive
  case activating
  case active
  case error(String)

  var title: String {
    switch self {
    case .unsupported: return "Unsupported"
    case .prerequisitesMissing: return "Setup required"
    case .checking: return "Checking…"
    case .inactive: return "Renaming off"
    case .activating: return "Activating…"
    case .active: return "Renaming active"
    case .error: return "Injection error"
    }
  }

  var detail: String {
    switch self {
    case .unsupported(let message): return message
    case .prerequisitesMissing(let message): return message
    case .checking: return "Checking injection status…"
    case .inactive: return "Dock renaming is not active."
    case .activating: return "Activating Dock renaming…"
    case .active: return "Space names are being applied."
    case .error(let message): return message
    }
  }

  var symbol: String {
    switch self {
    case .active: return "checkmark.circle.fill"
    case .error, .unsupported: return "xmark.circle.fill"
    case .prerequisitesMissing: return "exclamationmark.triangle.fill"
    default: return "syringe"
    }
  }
}

@MainActor
@Observable
final class InjectionManager {
  private(set) var state: InjectionState = .checking
  private(set) var operationInProgress = false
  private(set) var prerequisitesWarning: String?
  var backend: InjectorBackend = .dyld

  var isActive: Bool { activation.isActive }

  private weak var preferences: PreferencesStore?
  private let activation = ActivationModel()
  private var observers: [NSObjectProtocol] = []
  private var isAppleSilicon = true

  private static let log = Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")

  func start(preferences: PreferencesStore) {
    self.preferences = preferences
    isAppleSilicon = Self.isAppleSilicon
    bindActivation()
    observeHostLaunches()
    refresh()
  }

  func stop() {
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    observers.removeAll()
  }

  func refresh(injectIfEnabled: Bool = false) {
    updatePrerequisitesWarning()
    recomputeState()
    // Decide only after the fresh status lands: activate()'s reload is async, so
    // a synchronous !isActive check here would see stale pre-reload state and
    // re-inject at launch even when the plugin is already live.
    activation.refresh { [weak self] in
      guard let self else { return }
      if injectIfEnabled, preferences?.injectionConsentGranted == true, !isActive {
        injectNow()
      }
    }
  }

  func injectNow() {
    Self.log.debug("Manual activation requested")
    activation.backend = backend
    activation.activate()
  }

  func deactivate() {
    Self.log.debug("Deactivation requested")
    activation.backend = backend
    activation.deactivate()
  }

  // MARK: - Private

  private func bindActivation() {
    // ActivationModel is @Observable; re-arm the tracking whenever any observed
    // property changes so recomputeState() stays current for the app's lifetime.
    withObservationTracking {
      _ = activation.state
      _ = activation.hasLoaded
      _ = activation.isBusy
      _ = activation.pluginIsLive
    } onChange: {
      Task { @MainActor in
        self.recomputeState()
        self.bindActivation()
      }
    }
  }

  private func observeHostLaunches() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleID = app.bundleIdentifier,
            bundleID == "com.apple.dock" || bundleID == "com.apple.WindowManager" else { return }
      Task { @MainActor in self?.refresh(injectIfEnabled: true) }
    })
  }

  private func recomputeState() {
    operationInProgress = activation.isBusy
    guard isAppleSilicon else {
      state = .unsupported("Dock renaming requires Apple Silicon.")
      return
    }
    if let warning = prerequisitesWarning {
      state = .prerequisitesMissing(warning)
      return
    }
    if activation.isBusy {
      state = .activating
      return
    }
    if activation.pluginIsLive || activation.state.active != .none {
      state = .active
      return
    }
    state = activation.hasLoaded ? .inactive : .checking
  }

  private func updatePrerequisitesWarning() {
    var problems: [String] = []

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/nvram")
    process.arguments = ["boot-args"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let arguments = String(decoding: data, as: UTF8.self)
      let requiredArguments = ["-arm64e_preview_abi"]
      let tokens = Set(arguments.split(whereSeparator: \.isWhitespace).map(String.init))
      let missingArguments = requiredArguments.filter { !tokens.contains($0) }
      if !missingArguments.isEmpty {
        let noun = missingArguments.count == 1 ? "argument" : "arguments"
        problems.append("Missing required boot \(noun): \(missingArguments.joined(separator: " ")).")
      }
    } catch {
      problems.append("Could not verify the required boot argument.")
    }

    let sipProcess = Process()
    sipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
    sipProcess.arguments = ["status"]
    let sipOutput = Pipe()
    sipProcess.standardOutput = sipOutput
    sipProcess.standardError = sipOutput
    do {
      try sipProcess.run()
      sipProcess.waitUntilExit()
      let data = sipOutput.fileHandleForReading.readDataToEndOfFile()
      let status = String(decoding: data, as: UTF8.self).lowercased()
      if status.contains("custom configuration") {
        let requiredDisabledProtections = [
          "filesystem protections: disabled",
          "debugging restrictions: disabled",
          "nvram protections: disabled",
        ]
        let missingProtections = requiredDisabledProtections.filter {
          !status.contains($0)
        }
        if !missingProtections.isEmpty {
          problems.append("The partial System Integrity Protection configuration must disable filesystem, debugging, and NVRAM protections.")
        }
      } else if status.contains("status: enabled") {
        problems.append("System Integrity Protection is fully enabled; disable it or use the documented partial configuration.")
      } else if !status.contains("status: disabled") {
        problems.append("Could not verify that System Integrity Protection is disabled or partially disabled.")
      }
    } catch {
      problems.append("Could not verify System Integrity Protection status.")
    }

    prerequisitesWarning = problems.isEmpty ? nil : problems.joined(separator: " ")
  }

  private static var isAppleSilicon: Bool {
    var supported: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0) == 0 && supported == 1
  }
}
