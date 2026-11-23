import SwiftUI

/// Settings > Automatic cleaning: on or off, how often, and what it did.
struct AutoCleanView: View {
    @State private var auto = AutoClean()

    var body: some View {
        @Bindable var auto = auto
        Toggle("Clean caches automatically", isOn: Binding(
            get: { auto.state == .on || auto.state == .needsApproval },
            set: { auto.setEnabled($0) }))
        Picker("How often", selection: $auto.everyDays) {
            Text("Every day").tag(1)
            Text("Every week").tag(7)
            Text("Every month").tag(30)
        }
        .disabled(auto.state != .on)
        switch auto.state {
        case .needsApproval:
            HStack {
                Text("macOS needs your OK first: turn Roomy on in Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { auto.openLoginItems() }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .on, .off:
            EmptyView()
        }
        if let last = auto.runs.last {
            let month = AutoCleanHistory.freed(auto.runs, since: Date().addingTimeInterval(-30 * 86_400))
            Text("Last cleaned \(last.at.formatted(.relative(presentation: .named))): \(formatBytes(last.freed)). \(formatBytes(month)) in the last 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Roomy removes app, browser and package caches and old logs by itself, even when Roomy isn't open. Apps that are open are skipped. Build folders, downloads, simulators and anything in Review first are never cleaned automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { auto.refresh() }
    }
}
