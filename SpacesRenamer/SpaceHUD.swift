import AppKit
import SwiftUI

/// Shows a brief HUD centered on every display when the Space changes, each display
/// showing its own current Space's name. Driven by `activeSpaceDidChangeNotification`;
/// gated on the user setting. Pure app UI, independent of the injected plugin.
@MainActor
final class SpaceHUDController {
  private let preferences: PreferencesStore
  private let spaces: SpaceStore
  private var observer: (any NSObjectProtocol)?
  /// One reusable panel per display, keyed by the display's snapshot id.
  private var panels: [String: SpaceHUDPanel] = [:]

  init(preferences: PreferencesStore, spaces: SpaceStore) {
    self.preferences = preferences
    self.spaces = spaces
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.spaceChanged() }
    }
  }

  func stop() {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      self.observer = nil
    }
  }

  private func spaceChanged() {
    guard preferences.showSpaceChangeHUD else { return }
    spaces.refresh(
      for: preferences.namingMode,
      showDuplicateApplications: preferences.showDuplicateApplications
    ) { [weak self] in
      self?.showHUD()
    }
  }

  private func showHUD() {
    let displays = spaces.snapshot
    guard !displays.isEmpty else { return }
    let screens = NSScreen.screens
    for (index, display) in displays.enumerated() {
      guard let current = display.spaces.first(where: \.isCurrent) else { continue }
      let label = "\(current.index). \(preferences.name(for: current.id))"
      let panel = panels[display.id] ?? SpaceHUDPanel()
      panels[display.id] = panel
      let screen: NSScreen? = screens.count == displays.count && screens.indices.contains(index)
        ? screens[index]
        : NSScreen.main
      guard let screen else { continue }
      panel.show(label, on: screen)
    }
  }
}

/// A borderless, click-through floating panel that fades a `SpaceHUDView` in and back out.
@MainActor
private final class SpaceHUDPanel {
  private let panel: NSPanel
  private let hosting: NSHostingView<SpaceHUDView>
  private var dismiss: DispatchWorkItem?

  init() {
    hosting = NSHostingView(rootView: SpaceHUDView(label: ""))
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.contentView = hosting
    panel.alphaValue = 0
  }

  func show(_ label: String, on screen: NSScreen) {
    hosting.rootView = SpaceHUDView(label: label)
    let size = hosting.fittingSize
    let origin = CGPoint(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.midY - size.height / 2)
    panel.setFrame(CGRect(origin: origin, size: size), display: true)
    panel.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = panel.alphaValue == 0 ? 0.16 : 0
      panel.animator().alphaValue = 1
    }

    dismiss?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
    dismiss = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
  }

  private func fadeOut() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.35
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak panel] in
      Task { @MainActor in panel?.orderOut(nil) }
    })
  }
}

/// The HUD card itself: the Space name on a translucent material.
private struct SpaceHUDView: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 26, weight: .semibold, design: .rounded))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .padding(.horizontal, 30)
      .padding(.vertical, 20)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
      .padding(24)
      .fixedSize()
  }
}