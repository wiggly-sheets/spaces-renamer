import SwiftUI

struct RenamerView: View {
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var spaces: SpaceStore

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
          (NSApp.delegate as? AppDelegate)?.openSettings()
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
                    SpaceNameCard(space: space)
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

private struct SpaceNameCard: View {
  @EnvironmentObject private var preferences: PreferencesStore
  let space: ManagedSpace
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Space \(space.index)", systemImage: space.isCurrent ? "circle.inset.filled" : "circle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(space.isCurrent ? Color.accentColor : .secondary)
        Spacer()
        if let sourceDescription {
          Text(sourceDescription)
            .lineLimit(1)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      TextField("Unnamed", text: $draft)
        .textFieldStyle(.roundedBorder)
        .disabled(preferences.namingMode != .manual)
        .onSubmit { preferences.setName(draft, for: space.id) }
    }
    .padding(10)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(space.isCurrent ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
    }
    .onAppear { draft = preferences.name(for: space.id) }
    .onChange(of: preferences.activeProfileID) { _ in draft = preferences.name(for: space.id) }
    .onChange(of: preferences.namingMode) { _ in draft = preferences.name(for: space.id) }
    .onDisappear {
      if preferences.namingMode == .manual {
        preferences.setName(draft, for: space.id)
      }
    }
  }

  private var sourceDescription: String? {
    switch preferences.namingMode {
    case .manual:
      return nil
    case .applications:
      return space.appNames.isEmpty ? nil : space.appNames.prefix(2).joined(separator: ", ")
    case .yabaiLabels:
      return space.yabaiLabel
    }
  }
}
