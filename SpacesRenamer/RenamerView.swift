import SwiftUI

struct RenamerView: View {
  @Environment(PreferencesStore.self) private var preferences
  @Environment(SpaceStore.self) private var spaces
  @Environment(InjectionManager.self) private var injection
  @Environment(AppModel.self) private var appModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(preferences.activeProfile.name)
            .font(.headline)
          Text(namingModeSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          ForEach(preferences.profiles) { profile in
            Button {
              preferences.activateProfile(profile.id)
            } label: {
              if profile.id == preferences.activeProfileID {
                Label(profile.name, systemImage: "checkmark")
              } else {
                Text(profile.name)
              }
            }
          }
        } label: {
          Label("Profile", systemImage: "person.crop.rectangle.stack")
        }
        Button {
          appModel.openSettings(preferences: preferences, spaces: spaces, injection: injection)
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Settings")
      }

      if let error = spaces.errorMessage {
        VStack(spacing: 10) {
          Image(systemName: "rectangle.3.group")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("Spaces unavailable")
            .font(.headline)
          Text(error)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(spaces.snapshot) { display in
              VStack(alignment: .leading, spacing: 8) {
                if spaces.snapshot.count > 1 {
                  Text(display.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                  ForEach(display.spaces) { space in
                    SpaceCell(space: space)
                  }
                }
              }
            }
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 520, minHeight: 280)
    .onAppear {
      spaces.refresh(
        for: preferences.namingMode,
        showDuplicateApplications: preferences.showDuplicateApplications
      )
    }
  }

  private var namingModeSubtitle: String {
    switch preferences.namingMode {
    case .manual: return "Rename each desktop"
    case .applications: return "Names follow open apps"
    case .yabaiLabels: return "Names follow yabai Space labels"
    }
  }
}
