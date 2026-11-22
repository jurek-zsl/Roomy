import SwiftUI

struct ConfirmSheet: View {
    @Environment(CleanerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let items: [Finding]

    var body: some View {
        @Bindable var store = store
        let total = items.reduce(0) { $0 + $1.bytesFreed }
        let methods = items.map(store.method(for:))
        let deleted = methods.filter { $0 == .delete }.count
        let trashed = methods.filter { $0 == .trash }.count
        let tools = methods.count - deleted - trashed

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free about \(formatBytes(total))?")
                        .font(.title2.weight(.semibold))
                    Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if deleted > 0 { line("trash.slash", "\(deleted) deleted right away") }
                if trashed > 0 { line("trash", "\(trashed) moved to the Trash, so you can get them back") }
                if tools > 0 { line("wrench.and.screwdriver", "\(tools) cleaned by their own tool (brew, pnpm, …)") }
            }
            Toggle("Move everything to the Trash instead", isOn: $store.trashInstead)
            Label("Each item is checked again right before it's cleaned. Anything in use by then is skipped.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean") {
                    dismiss()
                    Task { await store.clean(items) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}
