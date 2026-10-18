import AppKit
import Observation
import SwiftUI

/// Shows a brief HUD centered on every display when the Space changes, each display
/// showing its own current Space's name. Reacts to `SpaceStore.snapshot` changes
/// rather than registering its own `activeSpaceDidChangeNotification` observer,
/// so only one refresh path exists and the HUD never races a second refresh.
/// Gated on the user setting. Pure app UI, independent of the injected plugin.
@MainActor
final class SpaceHUDController {
  private let preferences: PreferencesStore
  private let spaces: SpaceStore
  /// One reusable panel per display, keyed by the display's snapshot id.
  private var panels: [String: SpaceHUDPanel] = [:]
  /// Tracks the last Space id the HUD displayed so the card only appears on a
  /// real Space switch rather than on every snapshot refresh.
  private var lastShownSpaceID: String?
  /// Guard flag; checked on the main actor after each snapshot change.
  private var stopped = false

  init(preferences: PreferencesStore, spaces: SpaceStore) {
    self.preferences = preferences
    self.spaces = spaces
    armObservation()
  }

  func stop() {
    stopped = true
  }

  private func armObservation() {
    withObservationTracking {
      _ = spaces.snapshot
    } onChange: { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        guard !self.stopped else { return }
        self.spaceChanged()
        self.armObservation()
      }
    }
  }

  private func spaceChanged() {
    guard preferences.showSpaceChangeHUD else { return }
    let currentID = spaces.snapshot.flatMap(\.spaces).first(where: \.isCurrent)?.id
    guard let currentID else { return }
    // First snapshot change (app launch) records the baseline without showing.
    if lastShownSpaceID == nil {
      lastShownSpaceID = currentID
      return
    }
    if currentID == lastShownSpaceID { return }
    lastShownSpaceID = currentID
    showHUD()
  }

  private func showHUD() {
    let displays = spaces.snapshot
    guard !displays.isEmpty else { return }
    // Prune panels for displays no longer in the current snapshot. Without
    // this, disconnected/reconnected displays leak NSPanel + NSHostingView
    // instances that never get released.
    for staleKey in panels.keys where !displays.contains(where: { $0.id == staleKey }) {
      panels.removeValue(forKey: staleKey)
    }
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