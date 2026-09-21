import SwiftUI

// The launch report. Feature 20 grows this into the real first launch gate.
struct HealthView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MyCMS")
                    .font(.largeTitle.weight(.semibold))
                Text("Checking the three things this app needs from your machine.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(environment.health.results) { result in
                    CheckRow(result: result)
                    if result.id != environment.health.results.last?.id {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            Spacer()
        }
        .padding(32)
    }
}

private struct CheckRow: View {
    let result: CheckResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.name.rawValue)
                    .font(.headline)
                Text(result.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let errorText = result.errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(result.name.isFatal ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    @ViewBuilder private var icon: some View {
        switch result.state {
        case .pending:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            // Only the database is fatal, so the other two never wear the blocking symbol.
            Image(systemName: result.name.isFatal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.name.isFatal ? .red : .orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HealthView()
        .frame(width: 700, height: 420)
        .environment(AppEnvironment())
}
