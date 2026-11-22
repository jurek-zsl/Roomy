import AppKit
import SwiftUI

/// What "System Data" is made of, and the parts you can do something about:
/// Time Machine's local snapshots, swap, purgeable space.
struct SystemDataView: View {
    let bytes: Int64
    @Environment(\.dismiss) private var dismiss
    @State var facts: SystemData.Facts? = nil
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS & system data").font(.title2.weight(.semibold))
                        Text("About \(formatBytes(bytes)) the map can't open folder by folder: macOS itself, its swap, Time Machine's snapshots and space macOS keeps for later. Most of it macOS manages on its own.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let f = facts {
                        snapshots(f)
                        part("externaldrive.fill.badge.timemachine", .green, "Time Machine backups",
                             f.backupDisk.map { "Backing up to \($0). Backups live on that disk, not this one." }
                                ?? "Time Machine isn't set up. A backup disk keeps your files safe, and Roomy's Trash-first cleaning even safer.") {
                            Button("Open Time Machine Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
                            }
                        }
                        part("arrow.triangle.2.circlepath", .blue, "Purgeable space",
                             "\(formatBytes(f.purgeable ?? 0)) macOS can free by itself whenever an app needs room: caches, snapshots and iCloud files that are also in the cloud. Nothing to do here; Finder already counts it as available.") { EmptyView() }
                        part("memorychip", .orange, "Swap and sleep image",
                             "\(formatBytes(f.swap ?? 0)) in /private/var/vm: memory macOS moved to disk, and a copy of memory for sleep. Restarting the Mac shrinks swap; don't remove these files.") { EmptyView() }
                    } else {
                        ProgressView("Looking…")
                    }
                    part("lock.shield", .gray, "macOS itself",
                         "The system lives on its own sealed, read-only volume, with one snapshot macOS keeps for updates. Neither can be removed, and macOS replaces the snapshot with each update.") {
                        command("diskutil apfs listSnapshots /")
                    }
                    part("person.2", .purple, "Other users and shared files",
                         "Other accounts on this Mac and /Users/Shared count here too. Look at them from those accounts.") { EmptyView() }
                }
                .padding(22)
            }
            Divider()
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .task { if facts == nil { facts = await Task.detached { SystemData.gather() }.value } }
    }

    @ViewBuilder private func snapshots(_ f: SystemData.Facts) -> some View {
        let text = f.snapshots.isEmpty
            ? "None right now. When your backup disk isn't connected, Time Machine keeps hourly snapshots of your changes on this disk. They're removed after 24 hours, or sooner when space runs low."
            : "\(f.snapshots.count) snapshot\(f.snapshots.count == 1 ? "" : "s"), the oldest from \(f.snapshots[0].formatted(date: .abbreviated, time: .shortened)). Time Machine keeps them on this disk until your backup disk is back, and removes them after 24 hours or when space runs low. Their size isn't shown anywhere, but they can hold many GB."
        part("clock.arrow.circlepath", .teal, "Time Machine local snapshots", text) {
            VStack(alignment: .leading, spacing: 6) {
                if !f.snapshots.isEmpty {
                    Button(deleting ? "Deleting…" : "Delete Local Snapshots…") {
                        deleting = true
                        Task {
                            let error = await Task.detached { SystemData.deleteSnapshots() }.value
                            message = error ?? "Local snapshots deleted. Backups on your backup disk are untouched."
                            facts = await Task.detached { SystemData.gather() }.value
                            deleting = false
                        }
                    }
                    .disabled(deleting)
                    Text("macOS asks for your password. Backups on your backup disk stay.").font(.caption).foregroundStyle(.secondary)
                }
                command("tmutil listlocalsnapshots /")
                command("sudo tmutil deletelocalsnapshots /")
            }
        }
    }

    private func part<Extra: View>(_ symbol: String, _ tint: Color, _ title: String, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }

    private func command(_ c: String) -> some View {
        HStack(spacing: 6) {
            Text(c).font(.caption.monospaced()).textSelection(.enabled)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
