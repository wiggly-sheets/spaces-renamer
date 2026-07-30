import AppKit
import Carbon.HIToolbox
import Darwin
import ServiceManagement
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let preferences = PreferencesStore()
  private let spaces = SpaceStore()
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var settingsWindow: NSWindow?
  private var hotkeyMonitor: GlobalHotkeyMonitor?
  private var yabaiEventMonitor: YabaiEventMonitor?
  private var pendingAutomaticRefresh: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    ProcessInfo.processInfo.disableAutomaticTermination("Spaces Renamer provides a persistent menu-bar item")
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
  }

  func applicationWillTerminate(_ notification: Notification) {
    pendingAutomaticRefresh?.cancel()
    yabaiEventMonitor?.stop()
    observers.forEach(NotificationCenter.default.removeObserver)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    openSettings()
    return true
  }

  private func configureStatusItem() {
    statusItem.isVisible = preferences.showMenuBarIcon
    guard let button = statusItem.button else { return }
    button.image = Self.makeStatusItemImage()
    button.imagePosition = .imageOnly
    button.title = ""
    button.toolTip = "Spaces Renamer"
    button.target = self
    button.action = #selector(statusItemPressed(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private static func makeStatusItemImage() -> NSImage? {
    guard let symbol = NSImage(
      systemSymbolName: "rectangle.grid.2x2",
      accessibilityDescription: "Spaces Renamer"
    ) else { return nil }
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    return symbol.withSymbolConfiguration(configuration) ?? symbol
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

  private func configureObservers() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.refreshSpaces() })
    observers.append(center.addObserver(
      forName: .spacesRenamerPreferencesChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.configureHotkey()
      self?.configureStatusItem()
      self?.refreshSpaces()
    })
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceChanged(_:)),
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceApplicationsChanged(_:)),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceApplicationsChanged(_:)),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
  }

  private func configureHotkey() {
    hotkeyMonitor = GlobalHotkeyMonitor(
      keyCode: preferences.hotkey.keyCode,
      modifiers: preferences.hotkey.carbonModifiers
    ) { [weak self] in
      DispatchQueue.main.async { self?.toggleRenamer() }
    }
  }

  private func configureAutomaticNameUpdates() {
    yabaiEventMonitor = YabaiEventMonitor { [weak self] in
      self?.scheduleAutomaticRefresh()
    }
  }

  private func scheduleAutomaticRefresh(after delay: TimeInterval = 0.35) {
    guard preferences.namingMode != .manual else { return }
    pendingAutomaticRefresh?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pendingAutomaticRefresh = nil
      self?.refreshSpaces()
    }
    pendingAutomaticRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func refreshSpaces() {
    spaces.refresh(
      for: preferences.namingMode,
      showDuplicateApplications: preferences.showDuplicateApplications
    )
    preferences.applyGeneratedNames(from: spaces.snapshot)
  }

  @objc private func workspaceApplicationsChanged(_ notification: Notification) {
    scheduleAutomaticRefresh()
  }

  @objc private func workspaceChanged(_ notification: Notification) {
    refreshSpaces()
  }

  @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showContextMenu()
    } else {
      toggleRenamer()
    }
  }

  private func toggleRenamer() {
    guard preferences.showMenuBarIcon else {
      openSettings()
      return
    }
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      refreshSpaces()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func showContextMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Open Spaces Renamer", action: #selector(openRenamer), keyEquivalent: "")

    let profilesItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
    let profilesMenu = NSMenu(title: "Profile")
    for profile in preferences.profiles {
      let item = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
      item.representedObject = profile.id.uuidString
      item.target = self
      item.state = profile.id == preferences.activeProfileID ? .on : .off
      profilesMenu.addItem(item)
    }
    profilesItem.submenu = profilesMenu
    menu.addItem(profilesItem)

    let namingItem = NSMenuItem(title: "Naming Mode", action: nil, keyEquivalent: "")
    let namingMenu = NSMenu(title: "Naming Mode")
    for mode in NamingMode.allCases {
      let item = NSMenuItem(
        title: mode.title,
        action: #selector(selectNamingMode(_:)),
        keyEquivalent: ""
      )
      item.representedObject = mode.rawValue
      item.target = self
      item.state = mode == preferences.namingMode ? .on : .off
      namingMenu.addItem(item)
    }
    namingItem.submenu = namingMenu
    menu.addItem(namingItem)

    menu.addItem(.separator())
    let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(.separator())
    let quit = menu.addItem(withTitle: "Quit Spaces Renamer", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self

    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func openRenamer() {
    toggleRenamer()
  }

  @objc private func selectProfile(_ sender: NSMenuItem) {
    guard
      let rawID = sender.representedObject as? String,
      let id = UUID(uuidString: rawID)
    else { return }
    preferences.activateProfile(id)
  }

  @objc private func selectNamingMode(_ sender: NSMenuItem) {
    guard
      let rawValue = sender.representedObject as? String,
      let mode = NamingMode(rawValue: rawValue)
    else { return }
    preferences.setNamingMode(mode)
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
}

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
