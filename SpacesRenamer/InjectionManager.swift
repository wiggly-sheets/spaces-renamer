import AppKit
import Foundation

enum InjectionState: Equatable {
  case unsupported(String)
  case helperNotInstalled
  case connecting
  case helperReady
  case injecting
  case injected(pid: Int32)
  case error(String)

  var title: String {
    switch self {
    case .unsupported: return "Unavailable"
    case .helperNotInstalled: return "Helper not installed"
    case .connecting: return "Checking helper"
    case .helperReady: return "Ready to inject"
    case .injecting: return "Injecting"
    case .injected: return "Injected"
    case .error: return "Needs attention"
    }
  }

  var detail: String {
    switch self {
    case .unsupported(let reason), .error(let reason):
      return reason
    case .helperNotInstalled:
      return "Install the fixed-purpose helper once with an administrator password."
    case .connecting:
      return "Connecting to the privileged helper…"
    case .helperReady:
      return "The helper is installed; Dock is not currently reporting the payload."
    case .injecting:
      return "Loading the bundled payload into Dock…"
    case .injected(let pid):
      return "The current Dock process (PID \(pid)) has loaded Spaces Renamer."
    }
  }

  var symbol: String {
    switch self {
    case .injected: return "checkmark.circle.fill"
    case .connecting, .injecting: return "clock.arrow.circlepath"
    case .helperReady: return "checkmark.shield"
    case .helperNotInstalled: return "lock.shield"
    case .unsupported, .error: return "exclamationmark.triangle.fill"
    }
  }
}

@MainActor
final class InjectionManager: ObservableObject {
  @Published private(set) var state: InjectionState = .connecting
  @Published private(set) var operationInProgress = false
  @Published private(set) var bootArgumentsWarning: String?

  private weak var preferences: PreferencesStore?
  private var connection: NSXPCConnection?
  private var observers: [NSObjectProtocol] = []
  private var reinjectionWorkItem: DispatchWorkItem?

  private static let helperDirectory =
    "/Library/PrivilegedHelperTools/com.wiggly-sheets.SpacesRenamer.Injection"
  private static let handshakeURL = URL(
    fileURLWithPath: "/tmp/spaces-renamer-injection-\(getuid()).json"
  )

  func start(preferences: PreferencesStore) {
    self.preferences = preferences
    checkPlatform()
    guard case .unsupported = state else {
      observeDockAndPayload()
      refresh(injectIfEnabled: true)
      return
    }
  }

  func stop() {
    reinjectionWorkItem?.cancel()
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers.removeAll()
    DistributedNotificationCenter.default().removeObserver(self)
    invalidateConnection()
  }

  func refresh(injectIfEnabled: Bool = false) {
    guard isAppleSilicon else {
      state = .unsupported("Dock injection is supported only on Apple silicon.")
      return
    }
    updateBootArgumentsWarning()

    if let pid = injectedDockPID() {
      state = .injected(pid: pid)
      return
    }
    guard helperIsInstalled else {
      state = .helperNotInstalled
      return
    }

    state = .connecting
    ping { [weak self] ready, message in
      guard let self else { return }
      if ready {
        self.state = .helperReady
        if injectIfEnabled, self.preferences?.automaticInjectionEnabled == true {
          self.injectNow()
        }
      } else {
        self.state = .error(message)
      }
    }
  }

  func installHelper() {
    runManagementAction("install") { [weak self] succeeded, message in
      guard let self else { return }
      if succeeded {
        self.refresh(injectIfEnabled: self.preferences?.automaticInjectionEnabled == true)
      } else {
        self.state = .error(message)
      }
    }
  }

  func uninstallHelper() {
    runManagementAction("uninstall") { [weak self] succeeded, message in
      guard let self else { return }
      self.invalidateConnection()
      self.state = succeeded ? .helperNotInstalled : .error(message)
    }
  }

  func injectNow() {
    guard helperIsInstalled else {
      state = .helperNotInstalled
      return
    }
    operationInProgress = true
    state = .injecting
    let proxy = xpcProxy { [weak self] error in
      Task { @MainActor in
        self?.operationInProgress = false
        self?.state = .error(error.localizedDescription)
      }
    }
    proxy?.inject { [weak self] succeeded, message, dockPID in
      Task { @MainActor in
        guard let self else { return }
        self.operationInProgress = false
        if succeeded {
          self.scheduleHandshakeCheck(expectedPID: dockPID?.int32Value)
        } else {
          self.state = .error(message)
        }
      }
    }
  }

  private var helperIsInstalled: Bool {
    FileManager.default.isExecutableFile(
      atPath: "\(Self.helperDirectory)/SpacesRenamerInjectionHelper"
    )
  }

  private var isAppleSilicon: Bool {
    var supported: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0) == 0
      && supported == 1
  }

  private func checkPlatform() {
    if !isAppleSilicon {
      state = .unsupported("Dock injection is supported only on Apple silicon.")
    }
  }

  private func updateBootArgumentsWarning() {
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
      bootArgumentsWarning =
        arguments.contains("-arm64e_preview_abi") ||
        arguments.contains("amfi_get_out_of_my_way=1")
          ? nil
          : "Required reduced-security boot arguments were not detected."
    } catch {
      bootArgumentsWarning = "Could not verify the required boot arguments."
    }
  }

  private func ping(completion: @escaping (Bool, String) -> Void) {
    let proxy = xpcProxy { error in
      Task { @MainActor in completion(false, error.localizedDescription) }
    }
    proxy?.ping { protocolVersion, _ in
      Task { @MainActor in
        guard protocolVersion == SpacesRenamerInjectionProtocolVersion else {
          completion(false, "The installed helper uses an incompatible protocol.")
          return
        }
        completion(true, "")
      }
    }
  }

  private func xpcProxy(
    errorHandler: @escaping (Error) -> Void
  ) -> SpacesRenamerInjectionXPC? {
    if connection == nil {
      let newConnection = NSXPCConnection(
        machServiceName: SpacesRenamerInjectionMachService,
        options: .privileged
      )
      newConnection.remoteObjectInterface =
        NSXPCInterface(with: SpacesRenamerInjectionXPC.self)
      newConnection.invalidationHandler = { [weak self] in
        Task { @MainActor in self?.connection = nil }
      }
      newConnection.interruptionHandler = { [weak self] in
        Task { @MainActor in self?.connection = nil }
      }
      newConnection.activate()
      connection = newConnection
    }
    return connection?.remoteObjectProxyWithErrorHandler(errorHandler)
      as? SpacesRenamerInjectionXPC
  }

  private func invalidateConnection() {
    connection?.invalidate()
    connection = nil
  }

  private func runManagementAction(
    _ action: String,
    completion: @escaping (Bool, String) -> Void
  ) {
    guard
      let resources = Bundle.main.resourceURL?.appendingPathComponent("Injection"),
      FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("manage-helper.sh").path
      )
    else {
      state = .error("This app build does not contain the injection helper resources.")
      return
    }

    operationInProgress = true
    let script = resources.appendingPathComponent("manage-helper.sh").path
    let command = "/bin/bash \(shellQuoted(script)) \(action)"
    let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
    DispatchQueue.global(qos: .userInitiated).async {
      let appleScript = NSAppleScript(source: source)
      var errorInfo: NSDictionary?
      appleScript?.executeAndReturnError(&errorInfo)
      let message = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? ""
      Task { @MainActor in
        self.operationInProgress = false
        completion(errorInfo == nil, message.isEmpty ? "Administrator authorization was cancelled." : message)
      }
    }
  }

  private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func appleScriptQuoted(_ value: String) -> String {
    "\"" + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  private func observeDockAndPayload() {
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        application.bundleIdentifier == "com.apple.dock"
      else { return }
      Task { @MainActor in self?.dockDidRestart() }
    })
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(payloadDidLoad(_:)),
      name: Notification.Name("com.wiggly-sheets.SpacesRenamer.Injected"),
      object: nil
    )
  }

  private func dockDidRestart() {
    reinjectionWorkItem?.cancel()
    guard preferences?.automaticInjectionEnabled == true else {
      refresh()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in self?.refresh(injectIfEnabled: true) }
    }
    reinjectionWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
  }

  @objc private func payloadDidLoad(_ notification: Notification) {
    refresh()
  }

  private func scheduleHandshakeCheck(expectedPID: Int32?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self else { return }
      if let pid = self.injectedDockPID(), expectedPID == nil || expectedPID == pid {
        self.state = .injected(pid: pid)
      } else {
        self.state = .error("The injector finished, but Dock did not report the payload.")
      }
    }
  }

  private func injectedDockPID() -> Int32? {
    guard
      let data = try? Data(contentsOf: Self.handshakeURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let protocolVersion = object["protocolVersion"] as? String,
      protocolVersion == SpacesRenamerInjectionProtocolVersion,
      let number = object["dockPID"] as? NSNumber
    else { return nil }
    let pid = number.int32Value
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
      ? pid
      : nil
  }

  deinit {
    connection?.invalidate()
  }
}
