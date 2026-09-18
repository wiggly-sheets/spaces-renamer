import SwiftUI

@main
struct SpacesRenamerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // SceneBuilder on this SDK supports runtime conditionals only via
    // #available, so the MenuBarExtra stays present and the label view
    // goes empty when the item is hidden (a hidden item cannot be clicked,
    // and reopening the app/hotkey opens Settings via AppDelegate).
    MenuBarExtra {
      PopoverContent(appDelegate: appDelegate)
        .environment(appDelegate.preferences)
        .environment(appDelegate.spaces)
        .environment(appDelegate.injection)
        .environment(appDelegate.appModel)
    } label: {
      menuBarLabel
    }
    .menuBarExtraStyle(.window)
    // Scene-root injection: every system-driven instantiation of this scene's
    // content (hotkey, deeplink, menu-bar navigation) inherits these objects.
    .environment(appDelegate.preferences)
    .environment(appDelegate.spaces)
    .environment(appDelegate.injection)
    .environment(appDelegate.appModel)
  }

  @ViewBuilder
  private var menuBarLabel: some View {
    if appDelegate.preferences.showMenuBarIcon {
      switch appDelegate.preferences.menuBarDisplayMode {
      case .icon:
        Image(systemName: "rectangle.grid.2x2")
      case .spaceName, .spaceNumberAndName:
        let label = appDelegate.spaces.menuBarLabel(
          for: appDelegate.preferences.menuBarDisplayMode,
          preferences: appDelegate.preferences
        )
        if label.isEmpty {
          Image(systemName: "rectangle.grid.2x2")
        } else {
          Text(label)
        }
      }
    } else {
      EmptyView()
    }
  }
}

/// The menu-bar popover: the rename grid plus the actions formerly in the
/// status item's right-click menu (naming mode, injection, Settings, Quit).
private struct PopoverContent: View {
  let appDelegate: AppDelegate

  @Environment(PreferencesStore.self) private var preferences
  @Environment(InjectionManager.self) private var injection
  @Environment(AppModel.self) private var appModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RenamerView()
      Divider()
      footer
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Menu {
          ForEach(NamingMode.allCases) { mode in
            Button {
              preferences.setNamingMode(mode)
            } label: {
              if mode == preferences.namingMode {
                Label(mode.title, systemImage: "checkmark")
              } else {
                Text(mode.title)
              }
            }
          }
        } label: {
          Label(preferences.namingMode.title, systemImage: "wand.and.stars")
        }
        .help("Naming mode")

        Spacer()

        Label(injection.state.title, systemImage: injection.state.symbol)
          .foregroundStyle(injectionTint)
          .help(injection.state.detail)

        Button {
          if injection.state == .active {
            preferences.setAutomaticInjectionEnabled(false)
            injection.deactivate()
          } else {
            injection.injectNow()
          }
        } label: {
          Text(injection.state == .active ? "Deactivate" : "Inject Now")
        }
        .disabled(injection.operationInProgress)

        Button {
          appDelegate.quit()
        } label: {
          Image(systemName: "power")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Quit")
        .keyboardShortcut("q", modifiers: .command)
      }

      Toggle("Keep Dock Renaming Active", isOn: Binding(
        get: { preferences.automaticInjectionEnabled },
        set: { enabled in
          if enabled {
            preferences.setInjectionConsent(true)
            if injection.state != .active {
              injection.injectNow()
            }
          } else {
            preferences.setInjectionConsent(false)
            injection.deactivate()
          }
        }
      ))
      .toggleStyle(.switch)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .controlSize(.small)
  }

  private var injectionTint: Color {
    switch injection.state {
    case .active: return .green
    case .error, .unsupported: return .red
    case .prerequisitesMissing: return .orange
    default: return .secondary
    }
  }
}