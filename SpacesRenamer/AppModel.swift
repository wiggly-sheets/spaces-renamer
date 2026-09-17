import AppKit
import SwiftUI

/// Owns the Settings window. Kept out of AppDelegate so the delegate focuses on
/// application behavior; the window is reused (never recreated) across opens.
@MainActor
@Observable
final class AppModel {
  var settingsWindow: NSWindow?

  func openSettings(preferences: PreferencesStore, spaces: SpaceStore, injection: InjectionManager) {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = NSHostingController(
      rootView: SettingsView()
        .environment(preferences)
        .environment(spaces)
        .environment(injection)
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
}