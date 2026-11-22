import AppKit
import SwiftUI

/// Icon and free space, in the menu bar.
struct MenuBarLabel: View {
    @Environment(CleanerStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.isWorking ? "arrow.triangle.2.circlepath" : "internaldrive")
            if let free = store.freeBytes {
                Text(formatBytes(free))
            }
        }
    }
}

struct MenuBarPanel: View {
    @Environment(CleanerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    /// First click asks, second click cleans. An alert would close the panel.
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.freeBytes.map(formatBytes) ?? "–")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("free").foregroundStyle(.secondary)
                Spacer()
                if let total = store.totalBytes {
                    Text("of \(formatBytes(total))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = store.storage {
                StorageBar(s: s, height: 8, showLegend: false)
            }
            status
            if let s = store.summary, !store.isWorking {
                Text(lastClean(s)).font(.caption).foregroundStyle(.secondary)
            }
            cleanButton
            Divider()
            HStack(spacing: 14) {
                Button("Scan Now") { Task { await store.scan() } }
                    .disabled(store.isWorking || !store.hasSeenIntro)
                Button("Open Roomy") { openMain() }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Roomy")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            confirming = false
            store.refreshFree()
            Task { await store.scanIfStale(maxAge: 600) }
        }
    }

    @ViewBuilder private var status: some View {
        switch store.phase {
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning…").foregroundStyle(.secondary)
            }
        case .cleaning(let done, let total, let current):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(current.isEmpty ? "Starting…" : "\(done) of \(total) · \(friendlyPath(current))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle:
            if !store.hasSeenIntro {
                Text("Open Roomy to do the first scan.").foregroundStyle(.secondary)
            } else if let last = store.lastScan {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("\(formatBytes(store.total(.safeNow))) safe to clean")
                        Text("· \(formatAgo(last, now: context.date))").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            } else {
                Text("Not scanned yet").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var cleanButton: some View {
        let safe = store.items(.safeNow)
        let bytes = store.total(.safeNow)
        if confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text("Clean \(safe.count) safe \(safe.count == 1 ? "item" : "items") (about \(formatBytes(bytes)))? Each one is checked again first.\(store.trashInstead ? " They go to the Trash." : "")")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { confirming = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Clean \(formatBytes(bytes))") {
                        confirming = false
                        Task { await store.cleanSafe() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            Button {
                confirming = true
            } label: {
                Label(safe.isEmpty ? "Nothing safe to clean" : "Clean Safe Items · \(formatBytes(bytes))", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(safe.isEmpty || store.isWorking)
        }
    }

    private func lastClean(_ s: CleanSummary) -> String {
        var text = "Last clean: \(s.cleaned) cleaned"
        if let freed = s.freed { text += ", freed \(formatBytes(freed))" }
        if !s.skipped.isEmpty { text += ", \(s.skipped.count) skipped" }
        if !s.failed.isEmpty { text += ", \(s.failed.count) failed" }
        return text
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
