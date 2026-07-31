import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Keeps automatic names fresh without polling. Yabai emits only when a
/// window/Space change can affect the generated names; bursts are debounced by
/// AppDelegate before the required yabai queries run.
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
  private let onChange: () -> Void
  private var server: Int32 = -1
  private var source: DispatchSourceRead?
  private var stopped = false

  init(onChange: @escaping () -> Void) {
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
    var byte: UInt8 = 0
    _ = read(client, &byte, 1)
    close(client)
    DispatchQueue.main.async { [weak self] in self?.onChange() }
  }

  private func registerSignals() {
    guard Self.yabaiPath != nil else { return }
    removeSignals()
    let action = "/bin/echo 1 | /usr/bin/nc -U \(socketPath)"
    for event in Self.events {
      _ = runYabai([
        "-m", "signal", "--add",
        "label=\(Self.label(for: event))",
        "event=\(event)",
        "action=\(action)"
      ])
    }
  }

  private func removeSignals() {
    guard Self.yabaiPath != nil else { return }
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
    guard let path = Self.yabaiPath else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func label(for event: String) -> String {
    "spaces_renamer_autoname_\(event)"
  }

  private static let yabaiPath: String? = {
    ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }()

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

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Manually wired `@main` entry point. Without this explicit implementation,
  /// the compiler-synthesized `main()` may not install the delegate for
  /// LSUIElement (.accessory) apps, causing `applicationDidFinishLaunching`
  /// to never fire.
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }

  private let preferences = PreferencesStore()
  private let spaces = SpaceStore()
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var settingsWindow: NSWindow?
  private var hotkeyMonitor: GlobalHotkeyMonitor?
  private var yabaiEventMonitor: YabaiEventMonitor?
  private var pendingAutomaticRefresh: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []

// Injected bundle manager for v1.0.0 app-managed injection
    private var injection: InjectionManager!
    private lazy var configFile = ConfigFile(preferences: preferences)

   // MARK: - Application Lifecycle

@MainActor
func applicationDidFinishLaunching(_ notification: Notification) {
      NSApp.setActivationPolicy(.accessory)
      ProcessInfo.processInfo.disableAutomaticTermination("Spaces Renamer provides a persistent menu-bar item")

installCLISymlink()
_ = configFile
        // Initialize injection manager on main thread
        injection = InjectionManager()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.autosaveName = "SpacesRenamerStatusItem.v2"
    configureStatusItem()
    configurePopover()
    configureObservers()
    configureAutomaticNameUpdates()
    configureHotkey()
    refreshSpaces()
    DispatchQueue.main.async {
      NativeAppManagement.promptToMoveIfNeeded()
    }
// Start injection subsystem after preferences are ready
     injection.start(preferences: preferences)
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { handleDeeplink(url) }
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if hasVisibleWindows {
      settingsWindow?.close()
    } else {
      openSettings()
    }
    return true
  }

  // MARK: - Deeplink Handling

  private func handleDeeplink(_ url: URL) {
    guard url.scheme == "spacesrenamer", let host = url.host else { return }
    let components = [host] + url.pathComponents.dropFirst()
    guard components.count >= 1 else { return }

    switch (components.count, components[safe: 0], components[safe: 1], components[safe: 2]) {
    case (1, "settings", _, _):
      openSettings()
    case (1, "renamer", _, _):
      togglePopover()
    case (3, "profile", "switch", let uuid):
      if let uuidStr = uuid, let id = UUID(uuidString: uuidStr) {
        preferences.activateProfile(id)
      }
    case (2, "profile", "list", _):
      writeStatusJSON()
    case (2, "naming", let mode, _):
      if let modeStr = mode, let namingMode = NamingMode(rawValue: modeStr) {
        preferences.setNamingMode(namingMode)
      }
    case (3, "space", let uuid, "name"):
      if let name = url.queryParameters?["name"]?.removingPercentEncoding,
         let uuidStr = uuid {
        preferences.setName(name, for: uuidStr)
      }
    case (1, "status", _, _):
      writeStatusJSON()
    default:
      break
    }
  }

  private func writeStatusJSON() {
    let dict: [String: Any] = [
      "activeProfile": preferences.activeProfile.name,
      "activeProfileID": preferences.activeProfileID.uuidString,
      "namingMode": preferences.namingMode.rawValue,
      "showMenuBar": preferences.showMenuBarIcon,
      "menuBarDisplay": preferences.menuBarDisplayMode.rawValue,
      "profiles": preferences.profiles.map { ["id": $0.id.uuidString, "name": $0.name, "spaceCount": $0.names.count] },
      "spaces": spaces.snapshot.flatMap(\.spaces).map { ["id": $0.id, "index": $0.index, "name": preferences.name(for: $0.id)] },
    ]
    let uid = getuid()
    let url = URL(fileURLWithPath: "/tmp/spaces-renamer-status-\(uid).json")
    do {
      let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: url, options: .atomic)
    } catch {
      NSLog("Failed to write status JSON: \(error.localizedDescription)")
    }
  }

  // MARK: - CLI Symlink

  private func installCLISymlink() {
    let fileManager = FileManager.default
    let symlinkDir = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin")
    let symlinkPath = symlinkDir.appendingPathComponent("sr")
    let resourcePath: String

    if let path = Bundle.main.url(forResource: "sr", withExtension: nil)?.path {
      resourcePath = path
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

    if fileManager.fileExists(atPath: symlinkPath.path) {
      if symlinkPath.resolvingSymlinksInPath().path == resourcePath {
        return
      }
      do {
        try fileManager.removeItem(at: symlinkPath)
      } catch {
        NSLog("Could not remove stale symlink: \(error.localizedDescription)")
      }
    }

    do {
      try fileManager.createSymbolicLink(at: symlinkPath, withDestinationURL: URL(fileURLWithPath: resourcePath))
      NSLog("Symlinked \(symlinkPath.path) → \(resourcePath)")
    } catch {
      NSLog("Could not symlink CLI tool: \(error.localizedDescription)")
    }
  }

  // MARK: - Status Item

  private func configureStatusItem() {
    statusItem.isVisible = preferences.showMenuBarIcon
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(statusItemPressed(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    updateStatusItemContent()
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 560, height: 330)
    popover.contentViewController = NSHostingController(
      rootView: RenamerView()
        .environmentObject(preferences)
        .environmentObject(spaces)
    )
  }

  private func updateStatusItemContent() {
    guard let button = statusItem.button else { return }

    switch preferences.menuBarDisplayMode {
    case .icon:
      button.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "Spaces Renamer")
      button.title = ""
      statusItem.length = NSStatusItem.squareLength
      button.imagePosition = .imageLeft
    case .spaceName, .spaceNumberAndName:
      let label = currentSpaceLabel()
      if label.isEmpty {
        button.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "Spaces Renamer")
        button.title = ""
        statusItem.length = NSStatusItem.squareLength
        button.imagePosition = .imageLeft
      } else {
        button.image = nil
        button.title = label
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .noImage
      }
    }
    button.toolTip = "Spaces Renamer"
  }

  private func currentSpaceLabel() -> String {
    let all = spaces.snapshot.flatMap(\.spaces)
    guard let current = all.first(where: { $0.isCurrent }) ?? all.first else { return "" }
    let name = preferences.name(for: current.id)
    switch preferences.menuBarDisplayMode {
    case .icon:
      return ""
    case .spaceName:
      return name
    case .spaceNumberAndName:
      return "\(current.index). \(name)"
    }
  }

  // MARK: - Actions

  @MainActor
  @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }

    if event.type == .rightMouseUp {
      let menu = NSMenu()
      menu.addItem(NSMenuItem(title: "Profiles", action: nil, keyEquivalent: ""))
      for profile in preferences.profiles {
        let item = NSMenuItem(title: profile.name, action: #selector(switchProfile(_:)), keyEquivalent: "")
        item.state = profile.id == preferences.activeProfileID ? .on : .off
        item.representedObject = profile.id.uuidString
        menu.addItem(item)
      }
      menu.addItem(.separator())
      menu.addItem(NSMenuItem(title: "Naming", action: nil, keyEquivalent: ""))
      for mode in NamingMode.allCases {
        let item = NSMenuItem(title: mode.title, action: #selector(switchNamingMode(_:)), keyEquivalent: "")
        item.state = preferences.namingMode == mode ? .on : .off
        item.representedObject = mode.rawValue
        menu.addItem(item)
      }
      // Injection section (v1.0.0)
      menu.addItem(.separator())
      menu.addItem(NSMenuItem(title: "Injection", action: nil, keyEquivalent: ""))
      let stateItem = NSMenuItem(title: injection.state.title, action: nil, keyEquivalent: "")
      stateItem.state = .off // no rich state; we rely on detail text
      menu.addItem(stateItem)
      let injectItem = NSMenuItem(title: "Inject Dock Hook", action: #selector(injectFromMenu(_:)), keyEquivalent: "")
      injectItem.representedObject = "inject"
      injectItem.isEnabled = !injection.operationInProgress
      menu.addItem(injectItem)
      let reinjectItem = NSMenuItem(title: "Automatic Reinjection", action: #selector(toggleAutomaticInjection(_:)), keyEquivalent: "")
      reinjectItem.state = preferences.automaticInjectionEnabled ? .on : .off
      reinjectItem.representedObject = "auto"
      menu.addItem(reinjectItem)

      statusItem.menu = menu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
      return
    }

    if popover.isShown {
      popover.close()
    } else {
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc private func switchProfile(_ sender: NSMenuItem) {
    guard let uuidStr = sender.representedObject as? String,
          let id = UUID(uuidString: uuidStr) else { return }
    preferences.activateProfile(id)
  }

  @objc private func switchNamingMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let mode = NamingMode(rawValue: raw) else { return }
    preferences.setNamingMode(mode)
  }

  @MainActor
  @objc private func injectFromMenu(_ sender: NSMenuItem) {
    injection.injectNow()
  }

  @MainActor
@objc private func toggleAutomaticInjection(_ sender: NSMenuItem) {
    if let isAuto = sender.representedObject as? String, isAuto == "auto" {
      let now = !preferences.automaticInjectionEnabled
      if now {
        // Enabling requires explicit consent
        preferences.setInjectionConsent(true)
      } else {
        preferences.setAutomaticInjectionEnabled(false)
      }
      injection.refresh(injectIfEnabled: preferences.automaticInjectionEnabled)
    }
  }

  @objc func openSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = NSHostingController(
      rootView: SettingsView()
        .environmentObject(preferences)
        .environmentObject(spaces)
        .environmentObject(injection)
    )
    let window = NSWindow(contentViewController: controller)
    window.title = "Spaces Renamer Settings"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 780, height: 520))
    window.minSize = NSSize(width: 680, height: 440)
    window.center()
    window.isReleasedWhenClosed = false
    settingsWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func togglePopover() {
    guard preferences.showMenuBarIcon else {
      openSettings()
      return
    }
    if popover.isShown {
      popover.close()
    } else {
      guard let button = statusItem.button else { return }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // MARK: - Notifications

  private func configureObservers() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .spacesRenamerPreferencesChanged,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.preferencesChanged()
      }
    )

    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshSpaces()
      }
    )

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshSpaces()
      }
    )

    let workspaceNC = NSWorkspace.shared.notificationCenter
    observers.append(
      workspaceNC.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.scheduleAutomaticRefresh()
      }
    )
    observers.append(
      workspaceNC.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.scheduleAutomaticRefresh()
      }
    )
  }

  @MainActor
private func preferencesChanged() {
    statusItem.isVisible = preferences.showMenuBarIcon
    updateStatusItemContent()
    configureHotkey()
    refreshSpaces()
    injection.refresh(injectIfEnabled: false)
  }

  // MARK: - Automatic Naming

  @MainActor
private func configureAutomaticNameUpdates() {
    yabaiEventMonitor = YabaiEventMonitor { [weak self] in
      self?.scheduleAutomaticRefresh()
    }
  }

  @MainActor
private func scheduleAutomaticRefresh() {
    guard preferences.namingMode != .manual else { return }
    pendingAutomaticRefresh?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.refreshSpaces()
      self?.pendingAutomaticRefresh = nil
    }
    pendingAutomaticRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  @MainActor
private func refreshSpaces() {
    spaces.refresh(for: preferences.namingMode, showDuplicateApplications: preferences.showDuplicateApplications)
    preferences.applyGeneratedNames(from: spaces.snapshot)
    updateStatusItemContent()
    injection.refresh(injectIfEnabled: preferences.automaticInjectionEnabled && preferences.injectionConsentGranted == true)
  }

  @MainActor
private func configureHotkey() {
    let p = preferences.hotkey
    hotkeyMonitor = GlobalHotkeyMonitor(keyCode: p.keyCode, modifiers: p.carbonModifiers) { [weak self] in
      DispatchQueue.main.async { self?.togglePopover() }
    }
  }

  // MARK: - Teardown

  func applicationWillTerminate(_ notification: Notification) {
    pendingAutomaticRefresh?.cancel()
    yabaiEventMonitor?.stop()
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

private extension URL {
  var queryParameters: [String: String]? {
    guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
          let items = components.queryItems else { return nil }
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
      item.value.map { (item.name, $0) }
    })
  }
}