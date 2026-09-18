import SwiftUI

/// One renameable Space in a grid. Merges the fork's full-screen indicator and
/// focus tracking with the app's manual-profile editing behavior.
struct SpaceCell: View {
  @Environment(PreferencesStore.self) private var preferences
  let space: ManagedSpace
  @State private var draft = ""
  @FocusState private var focused: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("\(space.index)")
          .font(.headline)
          .foregroundStyle(space.isCurrent ? Color.accentColor : Color.secondary)
        // The snapshot cannot distinguish true full-screen Spaces; use the
        // presence of apps as the heuristic.
        if !space.appNames.isEmpty {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Full-screen app")
        }
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
        .focused($focused, equals: space.id)
        .onSubmit { preferences.setName(draft, for: space.id) }
    }
    .padding(10)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(space.isCurrent ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
    }
    .onAppear { draft = preferences.name(for: space.id) }
    .onChange(of: preferences.activeProfileID) { _, _ in draft = preferences.name(for: space.id) }
    .onChange(of: preferences.namingMode) { _, _ in draft = preferences.name(for: space.id) }
    .onDisappear {
      if preferences.namingMode == .manual {
        preferences.setName(draft, for: space.id)
      }
    }
    .id(space.id)
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