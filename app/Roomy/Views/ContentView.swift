import SwiftUI

enum MainTab: String, CaseIterable {
    case clean, space

    var title: String {
        switch self {
        case .clean: "Clean"
        case .space: "Space Map"
        }
    }
}

struct ContentView: View {
    @Environment(CleanerStore.self) private var store
    @AppStorage("tab") private var tab: MainTab = .clean
    @State private var selection: Finding.ID?
    /// Set once when Clean is clicked, so the sheet keeps one identity.
    @State private var confirming: Pending?

    var body: some View {
        Group {
            if store.hasSeenIntro && tab == .space {
                SpaceMapView()
            } else {
                content
            }
        }
            .navigationTitle("Roomy")
            .toolbar {
                if store.hasSeenIntro {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $tab) {
                            ForEach(MainTab.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings (⌘,)")
                }
                ToolbarItem(placement: .primaryAction) {
                    if tab == .space && store.hasSeenIntro {
                        Button {
                            Task { await store.loadMap() }
                        } label: {
                            Label("Map Again", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r")
                        .disabled(store.mapState == .loading)
                        .help("Map the disk again (⌘R)")
                    } else {
                        Button {
                            Task { await store.scan() }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r")
                        .disabled(store.isWorking || !store.hasSeenIntro)
                        .help("Scan again (⌘R)")
                    }
                }
            }
            .sheet(item: $confirming) { pending in
                ConfirmSheet(items: pending.list)
            }
            .sheet(isPresented: summaryShown) {
                if let s = store.summary { SummarySheet(summary: s) }
            }
            .onChange(of: store.result) {
                // The selected item may be gone after a rescan.
                if let sel = selection, store.result?.findings.contains(where: { $0.id == sel }) != true {
                    selection = nil
                }
            }
            .task {
                store.refreshFree()
                if store.hasSeenIntro && store.result == nil { await store.scan() }
            }
    }

    @ViewBuilder private var content: some View {
        if !store.hasSeenIntro {
            IntroView()
        } else if let result = store.result {
            VStack(spacing: 0) {
                Header()
                Divider()
                if result.findings.isEmpty {
                    ContentUnavailableView("Nothing to clean right now", systemImage: "sparkles",
                                           description: Text("Caches grow back as you work. Roomy checks again every few hours."))
                } else {
                    FindingsList(selection: $selection)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar(confirm: { confirming = Pending(list: $0) }) }
            .inspector(isPresented: inspectorShown) {
                if let f = result.findings.first(where: { $0.id == selection }) {
                    DetailView(finding: f)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
            }
        } else if case .error(let message) = store.phase {
            ContentUnavailableView {
                Label("Couldn't scan", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await store.scan() } }
            }
        } else {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Looking for space you can get back…").font(.title3)
                Text("Caches, build folders, old versions and leftovers. Usually a few seconds.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })
    }

    private var summaryShown: Binding<Bool> {
        Binding(get: { store.summary != nil }, set: { if !$0 { store.summary = nil } })
    }
}

/// The items are captured when the sheet opens, so a rescan behind it
/// can't change what's being confirmed.
private struct Pending: Identifiable {
    let id = UUID()
    let list: [Finding]
}

private struct Header: View {
    @Environment(CleanerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You can safely free")
                        .foregroundStyle(.secondary)
                    Text(formatBytes(store.total(.safeNow)))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.green.gradient)
                        .contentTransition(.numericText())
                    if store.total(.review) > 0 {
                        Text("and \(formatBytes(store.total(.review))) more if you agree to the review items")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if let free = store.freeBytes, let total = store.totalBytes {
                        Text("\(formatBytes(free)) free of \(formatBytes(total))")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let last = store.lastScan {
                            Text("Scanned \(formatAgo(last, now: context.date))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let s = store.storage {
                StorageBar(s: s)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

private struct BottomBar: View {
    @Environment(CleanerStore.self) private var store
    let confirm: ([Finding]) -> Void

    var body: some View {
        HStack(spacing: 12) {
            status
            Spacer()
            let items = store.selectedItems
            Button {
                confirm(items)
            } label: {
                Label(items.isEmpty ? "Clean" : "Clean \(formatBytes(store.selectedBytes))", systemImage: "sparkles")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(items.isEmpty || store.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var status: some View {
        switch store.phase {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning…").foregroundStyle(.secondary)
            }
        case .cleaning(let done, let total, let current):
            HStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 140)
                Text(current.isEmpty ? "Starting…" : "\(done) of \(total) · \(friendlyPath(current))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .lineLimit(2)
        case .idle:
            let n = store.selectedItems.count
            Text(n == 0 ? "Tick what you want to clean." : "\(n) \(n == 1 ? "item" : "items") ticked. Nothing is removed until you confirm.")
                .foregroundStyle(.secondary)
        }
    }
}
