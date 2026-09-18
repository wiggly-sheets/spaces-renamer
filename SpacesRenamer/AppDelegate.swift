import AppKit
import Carbon.HIToolbox
import Darwin
import ServiceManagement

/// Keeps automatic names fresh without polling. Yabai emits only when a
/// window/Space change can affect the generated names; AppDelegate coalesces
/// bursts without allowing repeated move/resize events to starve the refresh.
private final class YabaiEventMonitor {
  private static let events = [
    "application_hidden",
    "application_visible",
    "window_created",
    "window_destroyed",
    "window_moved",
    "window_resized",
    "window_minimized",
    "window_deminimized",
    "space_changed",
    "space_created",
    "space_destroyed",
    "display_changed",
    "display_added",
    "display_removed",
    "display_moved",
    "display_resized",
    "mission_control_enter"
  ]

  private let socketPath = "/tmp/spaces-renamer-\(getuid()).sock"
  private let queue = DispatchQueue(label: "com.wiggly-sheets.SpacesRenamer.yabai-events")
  private let onChange: (String) -> Void
  private var server: Int32 = -1
  private var source: DispatchSourceRead?
  private var stopped = false

  init(onChange: @escaping (String) -> Void) {
    self.onChange = onChange
    queue.async { [weak self] in self?.start() }
  }

  func stop() {
    queue.sync {
      guard !stopped else { return }
      stopped = true
      removeSignals()
      tearDownSocket()
    }
  }

  private func start() {
    guard !stopped else { return }
    unlink(socketPath)

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      pathBytes.withUnsafeBytes { source in
        destination.copyMemory(from: UnsafeRawBufferPointer(
          start: source.baseAddress,
          count: min(source.count, destination.count - 1)
        ))
      }
    }

    let didBind = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard didBind == 0, listen(descriptor, 8) == 0 else {
      close(descriptor)
      unlink(socketPath)
      return
    }

    server = descriptor
    let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    readSource.setEventHandler { [weak self] in self?.acceptEvent() }
    readSource.resume()
    source = readSource
    registerSignals()
  }

  private func acceptEvent() {
    let client = Darwin.accept(server, nil, nil)
    guard client >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 8)
    let byteCount = read(client, &buffer, buffer.count)
    close(client)
    guard
      byteCount > 0,
      let rawIndex = String(bytes: buffer.prefix(byteCount), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let index = Int(rawIndex),
      Self.events.indices.contains(index)
    else { return }
    let event = Self.events[index]
    DispatchQueue.main.async { [weak self] in self?.onChange(event) }
  }

  private func registerSignals() {
    guard YabaiClient.findExecutableURL() != nil else { return }
    removeSignals()
    for (index, event) in Self.events.enumerated() {
      // `index` comes only from the fixed event allowlist above.
      let action = "/usr/bin/printf \(index) | /usr/bin/nc -U \(socketPath)"
      _ = runYabai([
        "-m", "signal", "--add",
        "label=\(Self.label(for: event))",
        "event=\(event)",
        "action=\(action)"
      ])
    }
  }

  private func removeSignals() {
    guard YabaiClient.findExecutableURL() != nil else { return }
    for event in Self.events {
      _ = runYabai(["-m", "signal", "--remove", Self.label(for: event)])
    }
  }

  private func tearDownSocket() {
    source?.cancel()
    source = nil
    if server >= 0 {
      close(server)
      server = -1
    }
    unlink(socketPath)
  }

  private func runYabai(_ arguments: [String]) -> Bool {
    YabaiClient.run(arguments, captureOutput: false) != nil
  }

  private static func label(for event: String) -> String {
    "spaces_renamer_autoname_\(event)"
  }

  deinit {
    if !stopped {
      source?.cancel()
      if server >= 0 { close(server) }
      unlink(socketPath)
    }
  }
}

final class GlobalHotkeyMonitor {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let callback: () -> Void

  init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
    self.callback = callback
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue().callback()
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handler
    )
    let identifier = EventHotKeyID(signature: OSType(0x53524E4D), id: 1) // SRNM
    RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
  }

  deinit {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let preferences = PreferencesStore()
  let spaces = SpaceStore()
  let appModel = AppModel()
  private var hotkeyMonitor: GlobalHotkeyMonitor?
  private var yabaiEventMonitor: YabaiEventMonitor?
  private var pendingAutomaticRefresh: DispatchWorkItem?
  private var automaticRefreshGeneration = 0
  private var observers: [NSObjectProtocol] = []

  let injection = InjectionManager()
  private var spaceHUD: SpaceHUDController?
  private lazy var configFile = ConfigFile(preferences: preferences)

  // MARK: - Application Lifecycle

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    ProcessInfo.processInfo.disableAutomaticTermination("Spaces Renamer provides a persistent menu-bar item")

    installCLISymlink()
    installManPageSymlink()
    _ = configFile
    configureObservers()
    configureAutomaticNameUpdates()
    configureHotkey()
    spaceHUD = SpaceHUDController(preferences: preferences, spaces: spaces)
    refreshSpaces()
    injection.start(preferences: preferences)
    if !preferences.showMenuBarIcon {
      appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
    }
    DispatchQueue.main.async { [weak self] in
      self?.completeStartupInjectionFlow()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { handleDeeplink(url) }
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
    return true
  }

  // MARK: - Deeplink Handling

  private func handleDeeplink(_ url: URL) {
    guard url.scheme == "spacesrenamer", let host = url.host else { return }
    let components = [host] + url.pathComponents.dropFirst()
    guard components.count >= 1 else { return }

    switch (components.count, components[safe: 0], components[safe: 1], components[safe: 2]) {
    case (1, "settings", _, _):
      appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
    case (1, "renamer", _, _):
      // MenuBarExtra cannot be opened programmatically; Settings is the only
      // actionable destination the `sr renamer` CLI can open.
      appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
    case (3, "profile", "switch", let uuid):
      if let uuidStr = uuid, let id = UUID(uuidString: uuidStr) {
        preferences.activateProfile(id)
      }
    case (2, "profile", "list", _):
      writeStatusJSON(for: url)
    case (2, "naming", let mode, _):
      if let modeStr = mode, let namingMode = NamingMode(rawValue: modeStr) {
        preferences.setNamingMode(namingMode)
      }
    case (3, "space", let uuid, "name"):
      if let name = url.firstQueryValue(named: "name"),
         let uuidStr = uuid {
        preferences.setName(name, for: uuidStr)
      }
    case (1, "status", _, _):
      writeStatusJSON(for: url)
    default:
      break
    }
  }

  private func writeStatusJSON(for requestURL: URL) {
    let dict: [String: Any] = [
      "activeProfile": preferences.activeProfile.name,
      "activeProfileID": preferences.activeProfileID.uuidString,
      "namingMode": preferences.namingMode.rawValue,
      "showMenuBar": preferences.showMenuBarIcon,
      "menuBarDisplay": preferences.menuBarDisplayMode.rawValue,
      "profiles": preferences.profiles.map { ["id": $0.id.uuidString, "name": $0.name, "spaceCount": $0.names.count] },
      "spaces": spaces.snapshot.flatMap(\.spaces).map { ["id": $0.id, "index": $0.index, "name": preferences.name(for: $0.id)] },
    ]
    guard let destination = statusReplyDestination(for: requestURL) else { return }
    do {
      let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: destination.url, options: .atomic)
    } catch {
      NSLog("Failed to write status JSON: \(error.localizedDescription)")
    }
  }

  private struct StatusReplyDestination {
    let url: URL
  }

  private func statusReplyDestination(for requestURL: URL) -> StatusReplyDestination? {
    let replyValues = requestURL.queryValues(named: "reply")
    guard !replyValues.isEmpty else {
      return StatusReplyDestination(
        url: URL(fileURLWithPath: "/tmp/spaces-renamer-status-\(getuid()).json")
      )
    }
    guard replyValues.count == 1,
          let destination = CLIReplyPathPolicy.validatedURL(path: replyValues[0]) else {
      NSLog("Rejected invalid or ambiguous CLI reply path.")
      return nil
    }
    return StatusReplyDestination(url: destination)
  }

  // MARK: - CLI Symlink

  private func installCLISymlink() {
    let fileManager = FileManager.default
    let symlinkDir = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin")
    let symlinkPath = symlinkDir.appendingPathComponent("sr")
    let resourceURL: URL

    if let url = Bundle.main.url(forResource: "sr", withExtension: nil) {
      resourceURL = url
    } else {
      NSLog("CLI resource 'sr' not found in bundle; skipping symlink.")
      return
    }

    var isDir: ObjCBool = false
    if !fileManager.fileExists(atPath: symlinkDir.path, isDirectory: &isDir) {
      do {
        try fileManager.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
      } catch {
        NSLog("Could not create \(symlinkDir.path): \(error.localizedDescription)")
        return
      }
    }
    guard isDir.boolValue else {
      NSLog("Could not install CLI tool: \(symlinkDir.path) is not a directory.")
      return
    }

    installManagedSymlink(
      at: symlinkPath,
      to: resourceURL,
      resourcePathWithinBundle: "sr",
      description: "CLI tool"
    )
  }

  private func installManPageSymlink() {
    guard let resource = Bundle.main.resourceURL?
      .appendingPathComponent("man/man1/sr.1"),
      FileManager.default.fileExists(atPath: resource.path)
    else { return }

    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/man/man1", isDirectory: true)
    let destination = directory.appendingPathComponent("sr.1")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      NSLog("Could not create \(directory.path): \(error.localizedDescription)")
      return
    }
    installManagedSymlink(
      at: destination,
      to: resource,
      resourcePathWithinBundle: "man/man1/sr.1",
      description: "sr(1) man page"
    )
  }

  private func installManagedSymlink(
    at destination: URL,
    to resource: URL,
    resourcePathWithinBundle: String,
    description: String
  ) {
    switch ManagedSymlinkInstaller.install(
      at: destination,
      to: resource,
      resourcePathWithinBundle: resourcePathWithinBundle
    ) {
    case .unchanged:
      break
    case .installed, .replaced:
      NSLog("Symlinked \(destination.path) → \(resource.path)")
    case .preserved:
      NSLog("Preserving existing \(destination.path); it is not a Spaces Renamer symlink.")
    case .failed(let message):
      NSLog("Could not install \(description): \(message)")
    }
  }

  // MARK: - Injection Consent Flow

  @MainActor
  private func completeStartupInjectionFlow() {
    // Moving launches a new copy from /Applications. Let that process resume
    // onboarding so dialogs never overlap or refer to the temporary copy.
    guard !NativeAppManagement.promptToMoveIfNeeded() else { return }

    if preferences.injectionConsentGranted == nil {
      promptForInjectionConsentIfNeeded()
      return
    }

    offerLaunchAtLoginIfNeeded()
    injection.refresh(injectIfEnabled: true)
  }

  @MainActor
  private func promptForInjectionConsentIfNeeded() {
    guard preferences.injectionConsentGranted == nil else { return }
    let alert = NSAlert()
    alert.messageText = "Enable Dock renaming?"
    alert.informativeText = "Spaces Renamer injects its bundled hook into Dock to rename Spaces in Mission Control. Your choice persists: renaming is re-applied automatically after Dock or WindowManager restarts and at login. Administrator approval is requested only for the managed injection mode or boot-argument changes."
    alert.addButton(withTitle: "Enable and Inject")
    alert.addButton(withTitle: "Not Now")

    let launchAtLogin = NSButton(
      checkboxWithTitle: "Launch Spaces Renamer at login (Recommended)",
      target: nil,
      action: nil
    )
    launchAtLogin.state = .on
    launchAtLogin.frame.size = launchAtLogin.fittingSize
    alert.accessoryView = launchAtLogin

    let granted = alert.runModal() == .alertFirstButtonReturn
    preferences.setInjectionConsent(granted)
    UserDefaults.standard.set(true, forKey: "offeredLaunchAtLoginForInjection")
    if granted {
      if launchAtLogin.state == .on {
        preferences.setLoginItemEnabled(true)
        showLaunchAtLoginErrorIfNeeded()
      }
      injection.refresh()
      if let warning = injection.prerequisitesWarning {
        showInjectionSetupRequiredAlert(warning)
      } else if !injection.isActive {
        injection.injectNow()
      }
    }
  }

  @MainActor
  private func offerLaunchAtLoginIfNeeded() {
    guard preferences.automaticInjectionEnabled, !preferences.loginItemEnabled else { return }
    let defaultsKey = "offeredLaunchAtLoginForInjection"
    guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
    UserDefaults.standard.set(true, forKey: defaultsKey)

    let alert = NSAlert()
    alert.messageText = "Keep Dock renaming available after restarting your Mac?"
    alert.informativeText = "Launch Spaces Renamer at login so it can detect the new Dock process and request administrator approval to restore the hook."
    alert.addButton(withTitle: "Enable Launch at Login")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
      preferences.setLoginItemEnabled(true)
      showLaunchAtLoginErrorIfNeeded()
    }
  }

  @MainActor
  private func showLaunchAtLoginErrorIfNeeded() {
    guard let error = preferences.lastError else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Launch at Login needs attention"
    alert.informativeText = error
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @MainActor
  private func showInjectionSetupRequiredAlert(_ warning: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Injection setup required"
    alert.informativeText = "\(warning) Spaces Renamer saved your choice. After completing setup and restarting your Mac, it will request administrator approval to inject."
    alert.addButton(withTitle: "Open Injection Settings")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
    }
  }

  // MARK: - Menu Bar Actions

  func quit() {
    NSApp.terminate(nil)
  }

  // MARK: - Notifications

  private func configureObservers() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .spacesRenamerPreferencesChanged,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.preferencesChanged() }
      }
    )

    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshSpaces() }
      }
    )

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshSpaces() }
      }
    )

    let workspaceNC = NSWorkspace.shared.notificationCenter
    observers.append(
      workspaceNC.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.scheduleAutomaticRefresh() }
      }
    )
    observers.append(
      workspaceNC.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.scheduleAutomaticRefresh() }
      }
    )
  }

  @MainActor
  private func preferencesChanged() {
    configureHotkey()
    refreshSpaces()
  }

  // MARK: - Automatic Naming

  @MainActor
  private func configureAutomaticNameUpdates() {
    yabaiEventMonitor = YabaiEventMonitor { [weak self] event in
      Task { @MainActor in self?.scheduleAutomaticRefresh(for: event) }
    }
  }

  @MainActor
  private func scheduleAutomaticRefresh(for event: String? = nil) {
    guard preferences.namingMode != .manual else { return }
    automaticRefreshGeneration += 1

    // Dock begins constructing Mission Control immediately after this event.
    // Publish the newest yabai snapshot before the injected hook reads it.
    if event == "mission_control_enter" {
      pendingAutomaticRefresh?.cancel()
      pendingAutomaticRefresh = nil
      refreshSpaces()
      return
    }

    // Do not let a stream of move/resize events postpone refresh forever.
    // The first pass is fixed; a second pass converges if the burst continued.
    guard pendingAutomaticRefresh == nil else { return }
    scheduleAutomaticRefreshPass(generation: automaticRefreshGeneration)
  }

  @MainActor
  private func scheduleAutomaticRefreshPass(generation: Int) {
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.refreshSpaces()
      self.pendingAutomaticRefresh = nil
      if self.automaticRefreshGeneration != generation {
        self.scheduleAutomaticRefreshPass(generation: self.automaticRefreshGeneration)
      }
    }
    pendingAutomaticRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  @MainActor
  private func refreshSpaces() {
    spaces.refresh(
      for: preferences.namingMode,
      showDuplicateApplications: preferences.showDuplicateApplications
    ) { [weak self] in
      guard let self else { return }
      self.preferences.applyGeneratedNames(from: self.spaces.snapshot)
    }
  }

  @MainActor
  private func configureHotkey() {
    let p = preferences.hotkey
    hotkeyMonitor = GlobalHotkeyMonitor(keyCode: p.keyCode, modifiers: p.carbonModifiers) { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.appModel.openSettings(preferences: self.preferences, spaces: self.spaces, injection: self.injection)
      }
    }
  }

  // MARK: - Teardown

  func applicationWillTerminate(_ notification: Notification) {
    pendingAutomaticRefresh?.cancel()
    yabaiEventMonitor?.stop()
    spaceHUD?.stop()
    observers.forEach(NotificationCenter.default.removeObserver)
    injection.stop()
  }
}

// MARK: - Extensions

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}