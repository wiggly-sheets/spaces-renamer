import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
  case general = "General"
  case profiles = "Profiles"
  case hotkey = "Hotkey"
  case automatic = "Naming"

  var id: Self { self }
  var icon: String {
    switch self {
    case .general: return "gearshape"
    case .profiles: return "person.crop.rectangle.stack"
    case .hotkey: return "keyboard"
    case .automatic: return "wand.and.stars"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var spaces: SpaceStore
  @State private var selection: SettingsSection? = .general

  var body: some View {
    NavigationSplitView {
      List(SettingsSection.allCases, selection: $selection) { section in
        Label(section.rawValue, systemImage: section.icon)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 190)
    } detail: {
      Group {
        switch selection ?? .general {
        case .general: GeneralSettingsView()
        case .profiles: ProfileSettingsView()
        case .hotkey: HotkeySettingsView()
        case .automatic: AutomaticNamingSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(28)
    }
  }
}

private struct GeneralSettingsView: View {
  @EnvironmentObject private var preferences: PreferencesStore

  var body: some View {
    SettingsPage(title: "General", subtitle: "Menu bar, startup, and installation") {
      Toggle("Show menu bar item", isOn: Binding(
        get: { preferences.showMenuBarIcon },
        set: { preferences.setShowMenuBarIcon($0) }
      ))

      Text("If hidden, reopen Spaces Renamer from Applications to show Settings.")
        .font(.callout)
        .foregroundStyle(.secondary)

      Picker("Menu bar display", selection: Binding(
        get: { preferences.menuBarDisplayMode },
        set: { preferences.setMenuBarDisplayMode($0) }
      )) {
        ForEach(MenuBarDisplayMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.radioGroup)
      .disabled(!preferences.showMenuBarIcon)

      Text("Show the Spaces Renamer symbol, the current name such as “Code,” or its number and name such as “1. Code.”")
        .font(.callout)
        .foregroundStyle(.secondary)

      Divider()

      Toggle("Launch Spaces Renamer at login", isOn: Binding(
        get: { preferences.loginItemEnabled },
        set: { preferences.setLoginItemEnabled($0) }
      ))

      Divider()

      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(NativeAppManagement.isInApplicationsFolder ? "Installed in Applications" : "App location")
            .font(.headline)
          Text(NativeAppManagement.isInApplicationsFolder
            ? "Spaces Renamer is in the recommended location."
            : "Move the app to /Applications for reliable login-item behavior.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !NativeAppManagement.isInApplicationsFolder {
          Button("Move to Applications") {
            NativeAppManagement.moveToApplications()
          }
        }
      }

      if let error = preferences.lastError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
  }
}

private struct ProfileSettingsView: View {
  @EnvironmentObject private var preferences: PreferencesStore
  @State private var selectedProfileID: UUID?
  @State private var editedName = ""

  var body: some View {
    SettingsPage(title: "Profiles", subtitle: "Use different desktop names for work, home, or any context") {
      HStack(alignment: .top, spacing: 18) {
        List(selection: $selectedProfileID) {
          ForEach(preferences.profiles) { profile in
            HStack {
              Text(profile.name)
              Spacer()
              if profile.id == preferences.activeProfileID {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.tint)
              }
            }
            .tag(profile.id)
          }
        }
        .frame(width: 220)
        .frame(minHeight: 260)
        .overlay {
          RoundedRectangle(cornerRadius: 8).stroke(.separator)
        }

        VStack(alignment: .leading, spacing: 14) {
          TextField("Profile name", text: $editedName)
            .textFieldStyle(.roundedBorder)
            .onSubmit { saveSelectedName() }
          Button("Make Active") {
            if let selectedProfileID { preferences.activateProfile(selectedProfileID) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(selectedProfileID == nil || selectedProfileID == preferences.activeProfileID)

          Text("Switching profiles updates the Dock-compatible names file immediately. No app relaunch is needed.")
            .font(.callout)
            .foregroundStyle(.secondary)

          Spacer()

          HStack {
            Button {
              preferences.addProfile()
              selectedProfileID = preferences.activeProfileID
            } label: {
              Label("Add", systemImage: "plus")
            }
            Button(role: .destructive) {
              if let selectedProfileID {
                preferences.deleteProfile(selectedProfileID)
                self.selectedProfileID = preferences.activeProfileID
              }
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .disabled(preferences.profiles.count <= 1 || selectedProfileID == nil)
          }
        }
      }
    }
    .onAppear {
      selectedProfileID = preferences.activeProfileID
      updateDraftName()
    }
    .onChange(of: selectedProfileID) { _ in updateDraftName() }
  }

  private func updateDraftName() {
    editedName = preferences.profiles.first(where: { $0.id == selectedProfileID })?.name ?? ""
  }

  private func saveSelectedName() {
    guard let selectedProfileID else { return }
    preferences.renameProfile(selectedProfileID, to: editedName)
    updateDraftName()
  }
}

private struct HotkeySettingsView: View {
  @EnvironmentObject private var preferences: PreferencesStore

  var body: some View {
    SettingsPage(title: "Hotkey", subtitle: "Toggle the Spaces Renamer popover from anywhere") {
      HStack {
        Text("Shortcut")
          .frame(width: 80, alignment: .leading)
        HotkeyRecorder(value: Binding(
          get: { preferences.hotkey },
          set: { preferences.updateHotkey($0) }
        ))
        .frame(width: 220, height: 32)
      }

      Button("Restore Default") {
        preferences.updateHotkey(HotkeyPreference())
      }

      Text("Click the recorder, then press a shortcut containing at least one modifier. Press Escape to cancel. Changes apply immediately.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

private struct HotkeyRecorder: NSViewRepresentable {
  @Binding var value: HotkeyPreference

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> HotkeyRecorderButton {
    let button = HotkeyRecorderButton()
    button.value = value
    button.onRecord = { context.coordinator.record($0) }
    return button
  }

  func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
    context.coordinator.parent = self
    button.value = value
  }

  final class Coordinator {
    var parent: HotkeyRecorder

    init(_ parent: HotkeyRecorder) {
      self.parent = parent
    }

    func record(_ value: HotkeyPreference) {
      parent.value = value
    }
  }
}

private final class HotkeyRecorderButton: NSButton {
  var value = HotkeyPreference() {
    didSet {
      if !isRecording { title = Self.description(for: value) }
    }
  }
  var onRecord: ((HotkeyPreference) -> Void)?

  private var isRecording = false
  private var eventMonitor: Any?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    bezelStyle = .rounded
    font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    target = self
    action = #selector(beginRecording)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    removeEventMonitor()
  }

  @objc private func beginRecording() {
    isRecording = true
    title = "Type shortcut…"
    window?.makeFirstResponder(self)
    installEventMonitor()
  }

  private func installEventMonitor() {
    removeEventMonitor()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isRecording else { return event }
      self.capture(event)
      return nil
    }
  }

  private func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func capture(_ event: NSEvent) {
    if event.keyCode == 53 {
      finishRecording()
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasModifier = flags.contains(.command)
      || flags.contains(.option)
      || flags.contains(.control)
      || flags.contains(.shift)
    guard hasModifier else {
      NSSound.beep()
      title = "Include a modifier"
      return
    }

    let recorded = HotkeyPreference(
      keyCode: UInt32(event.keyCode),
      command: flags.contains(.command),
      option: flags.contains(.option),
      control: flags.contains(.control),
      shift: flags.contains(.shift)
    )
    value = recorded
    onRecord?(recorded)
    finishRecording()
  }

  private func finishRecording() {
    isRecording = false
    removeEventMonitor()
    title = Self.description(for: value)
  }

  private static func description(for value: HotkeyPreference) -> String {
    var result = ""
    if value.control { result += "⌃" }
    if value.option { result += "⌥" }
    if value.shift { result += "⇧" }
    if value.command { result += "⌘" }
    result += keyNames[value.keyCode] ?? "Key \(value.keyCode)"
    return result
  }

  private static let keyNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
    44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
    51: "⌫", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5",
    97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
    113: "F15", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
    120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
  ]
}

private struct AutomaticNamingSettingsView: View {
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var spaces: SpaceStore

  var body: some View {
    SettingsPage(title: "Naming", subtitle: "Choose where desktop names come from") {
      Picker("Naming mode", selection: Binding(
        get: { preferences.namingMode },
        set: { preferences.setNamingMode($0) }
      )) {
        ForEach(NamingMode.allCases) { mode in
          VStack(alignment: .leading) {
            Text(mode.title)
            Text(mode.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(mode)
        }
      }
      .pickerStyle(.radioGroup)

      Text(modeExplanation)
        .font(.callout)
        .foregroundStyle(.secondary)

      if preferences.namingMode == .applications {
        Toggle("List each window separately", isOn: Binding(
          get: { preferences.showDuplicateApplications },
          set: { preferences.setShowDuplicateApplications($0) }
        ))

        Text("When enabled, two Safari windows appear as “Safari · Safari.” Off by default.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Divider()
      Text("Preview")
        .font(.headline)
      ForEach(spaces.snapshot.flatMap(\.spaces)) { space in
        HStack {
          Text("Space \(space.index)")
          Spacer()
          Text(previewName(for: space))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var modeExplanation: String {
    switch preferences.namingMode {
    case .manual:
      return "Names come from the active profile and remain directly editable."
    case .applications:
      return "Up to three real app windows are ordered left to right and joined with a middle dot. Requires yabai."
    case .yabaiLabels:
      return "Names use the live labels returned by `yabai -m query --spaces`. Requires yabai; unlabeled Spaces fall back to the active profile."
    }
  }

  private func previewName(for space: ManagedSpace) -> String {
    switch preferences.namingMode {
    case .manual:
      let name = preferences.name(for: space.id)
      return name.isEmpty ? "Unnamed" : name
    case .applications:
      return space.appNames.isEmpty
        ? "No detected apps"
        : space.appNames.prefix(3).joined(separator: " · ")
    case .yabaiLabels:
      return space.yabaiLabel ?? "No yabai label"
    }
  }
}

private struct SettingsPage<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).foregroundStyle(.secondary)
      }
      content
      Spacer()
    }
  }
}
