import SwiftUI

struct DiagnosticsView: View {
  @State private var diagnostics = DiagnosticsModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(diagnostics.checks) { check in
        HStack(alignment: .top, spacing: 8) {
          Self.icon(for: check.status)
            .font(.title3)
            .frame(width: 20)
          VStack(alignment: .leading, spacing: 2) {
            Text(check.title)
              .font(.headline)
            Text(check.finding)
              .textSelection(.enabled)
            if let remedy = check.remedy {
              Text(remedy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let action = check.action, check.status == .fail {
              Button(action.buttonTitle) { diagnostics.perform(action) }
                .controlSize(.small)
                .padding(.top, 2)
            }
          }
        }
      }

      if let note = diagnostics.actionNote {
        Text(note)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Divider()

      HStack(spacing: 8) {
        Button("Re-run checks") { diagnostics.runChecks() }
          .disabled(diagnostics.isRunning)
        if diagnostics.isRunning {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
      }
    }
    .frame(minWidth: 480, alignment: .leading)
    .onAppear {
      diagnostics.runChecks()
    }
  }

  private static func icon(for status: DiagnosticCheck.Status) -> some View {
    switch status {
    case .pass:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
    case .fail:
      Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
    case .unknown:
      Image(systemName: "questionmark.circle").foregroundStyle(Color.secondary)
    }
  }
}