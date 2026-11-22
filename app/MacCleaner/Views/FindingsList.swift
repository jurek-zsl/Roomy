import SwiftUI

/// Items under this go into one "+ N smaller items" row per section.
private let smallBytes: Int64 = 10_000_000

struct FindingsList: View {
    @Environment(CleanerStore.self) private var store
    @Binding var selection: Finding.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(Section.allCases, id: \.self) { section in
                let items = store.items(section)
                if !items.isEmpty {
                    SwiftUI.Section {
                        let big = items.filter { $0.bytesFreed >= smallBytes }
                        let small = items.filter { $0.bytesFreed < smallBytes }
                        ForEach(small.count < 2 ? items : big) { FindingRow(finding: $0).tag($0.id) }
                        if small.count >= 2 {
                            SmallItems(items: small)
                        }
                    } header: {
                        SectionHeader(section: section, count: items.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private struct SmallItems: View {
    let items: [Finding]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(items) { FindingRow(finding: $0).tag($0.id) }
        } label: {
            HStack {
                Text("\(items.count) smaller items")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(items.reduce(0) { $0 + $1.bytesFreed }))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SectionHeader: View {
    @Environment(CleanerStore.self) private var store
    let section: Section
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if section != .blocked {
                Toggle("Tick all", isOn: allOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Tick or untick everything in this group")
            }
            Image(systemName: section.symbol)
                .foregroundStyle(section.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(section.title).font(.headline).foregroundStyle(.primary)
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(store.total(section)))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(section == .blocked ? .secondary : .primary)
        }
        .padding(.vertical, 8)
    }

    private var allOn: Binding<Bool> {
        Binding(
            get: { store.items(section).allSatisfy(store.isSelected) },
            set: { store.setAll(section, $0) })
    }
}

struct FindingRow: View {
    @Environment(CleanerStore.self) private var store
    let finding: Finding

    var body: some View {
        HStack(spacing: 12) {
            if finding.section == .blocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            } else {
                Toggle(finding.name, isOn: ticked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            ItemIcon(finding: finding)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name).fontWeight(.medium)
                Text(friendlyPath(finding.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if finding.section == .blocked, let reason = finding.reason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if let badge = store.method(for: finding).badge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(formatBytes(finding.bytesFreed))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(finding.section == .blocked ? 0.7 : 1)
        .contentShape(Rectangle())
    }

    private var ticked: Binding<Bool> {
        Binding(get: { store.isSelected(finding) }, set: { _ in store.toggle(finding) })
    }
}
