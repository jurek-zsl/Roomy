import AppKit
import SwiftUI

struct DetailView: View {
    @Environment(CleanerStore.self) private var store
    let finding: Finding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ItemIcon(finding: finding, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.name).font(.title3.weight(.semibold))
                        Text("Frees \(formatBytes(finding.bytesFreed))")
                            .font(.headline)
                            .foregroundStyle(finding.section.tint)
                            .monospacedDigit()
                    }
                }
                if finding.bytesOnDisk > finding.bytesFreed + finding.bytesFreed / 10 {
                    note("square.on.square",
                         "\(formatBytes(finding.bytesOnDisk)) on disk, but the rest is shared with copies elsewhere. Deleting this frees only \(formatBytes(finding.bytesFreed)). Other cleaners would count the full size.")
                }
                if finding.section == .blocked {
                    blocked
                }
                block("What it is", finding.explain)
                if let reason = finding.reason, finding.section != .blocked {
                    block("Note", reason)
                }
                block("What Clean does", store.method(for: finding).sentence)
                block("Where", friendlyPath(finding.path), selectable: true)
                Text("\(finding.files) files · rule \(finding.rule)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Why it's blocked, and a way out when an app holds it.
    @ViewBuilder private var blocked: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(finding.reason ?? "In use right now", systemImage: "lock.fill")
                .foregroundStyle(.orange)
            if let app = appOwner(finding.path), let running = AppIcons.running(app) {
                Button("Quit \(running.localizedName ?? app)") {
                    running.terminate()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await store.scan()
                    }
                }
                Text("The app closes normally and may ask you to save. Roomy scans again after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func block(_ title: String, _ text: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if selectable {
                Text(text).textSelection(.enabled)
            } else {
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
