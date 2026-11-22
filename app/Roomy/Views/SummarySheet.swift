import SwiftUI

struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CleanSummary

    private var ok: Bool { summary.failed.isEmpty && summary.error == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(ok ? "Done" : "Done, with problems", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(ok ? Color.green : Color.orange)
                if let freed = summary.freed {
                    Text("Freed \(formatBytes(freed))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                } else {
                    Text("Cleaned \(summary.cleaned) \(summary.cleaned == 1 ? "item" : "items")")
                        .font(.title.weight(.bold))
                }
                if let before = summary.freeBefore, let after = summary.freeAfter {
                    Text("Free space went from \(formatBytes(before)) to \(formatBytes(after)) · \(summary.cleaned) \(summary.cleaned == 1 ? "item" : "items") cleaned")
                        .foregroundStyle(.secondary)
                }
            }
            if summary.trashedBytes > 0 {
                Label("\(formatBytes(summary.trashedBytes)) is in the Trash. Empty the Trash to get that space back.", systemImage: "trash")
            }
            if let error = summary.error {
                Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
            list("Skipped", "forward.fill", summary.skipped)
            list("Failed", "xmark.octagon", summary.failed)
            Text("Roomy is scanning again: cleaning one thing can make another freeable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder private func list(_ title: String, _ symbol: String, _ lines: [SummaryLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { l in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.name)
                                Text("\(friendlyPath(l.path)): \(l.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }
}
