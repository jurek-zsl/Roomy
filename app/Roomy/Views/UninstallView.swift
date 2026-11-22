import AppKit
import SwiftUI

/// Remove an app with everything it left around the Mac, or clear leftovers
/// of apps that are already gone. Everything goes to the Trash.
struct UninstallView: View {
    @Bindable var uninstaller: Uninstaller
    @State private var search = ""
    @State private var sort: Sort = .size
    @State private var showLeftovers = false
    @State private var confirming = false

    enum Sort: String, CaseIterable { case size = "Size", name = "Name" }

    private var shown: [InstalledApp] {
        let list = uninstaller.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return sort == .name ? list : list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if uninstaller.apps.isEmpty { await uninstaller.loadApps() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search).textFieldStyle(.plain)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(10)
            Divider()
            List(selection: Binding(get: { showLeftovers ? "leftovers" : uninstaller.selectedApp },
                                    set: { pick($0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Leftovers of removed apps").fontWeight(.medium)
                        Text("Files of apps that are already gone").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shippingbox.and.arrow.backward.fill").foregroundStyle(.brown)
                }
                .tag("leftovers")
                SwiftUI.Section("Apps") {
                    ForEach(shown) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().frame(width: 28, height: 28)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            if let b = app.bytes {
                                Text(formatBytes(b)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .tag(app.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func pick(_ id: String?) {
        if id == "leftovers" {
            showLeftovers = true
            uninstaller.selectedApp = nil
            if uninstaller.orphanState == .idle { Task { await uninstaller.loadOrphans() } }
        } else {
            showLeftovers = false
            Task { await uninstaller.select(id) }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if showLeftovers {
            LeftoversView(uninstaller: uninstaller)
        } else {
            switch uninstaller.planState {
            case .idle:
                ContentUnavailableView("Pick an app", systemImage: "app.badge.checkmark",
                                       description: Text("Roomy shows the app and every file it keeps around your Mac: caches, settings, containers, logs and login items. You choose what goes to the Trash."))
            case .loading:
                ProgressView("Finding its files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                ContentUnavailableView("Couldn't look at this app", systemImage: "exclamationmark.triangle", description: Text(why))
            case .ready:
                if let plan = uninstaller.plan { planView(plan) }
            }
        }
    }

    private func planView(_ plan: UninstallPlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app)).resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.name).font(.title.weight(.semibold))
                            if let id = plan.bundleId { Text(id).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text("\(formatBytes(plan.totalBytes)) in all").font(.headline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if plan.running {
                        HStack {
                            Label("\(plan.name) is open. Quit it before uninstalling.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Quit \(plan.name)") { uninstaller.quit(plan); Task { try? await Task.sleep(for: .seconds(2)); await uninstaller.select(plan.app) } }
                        }
                        .padding(10)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(spacing: 0) {
                        FileRow(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app)), title: "The app", path: plan.app,
                                bytes: plan.appBytes, isOn: $uninstaller.removeApp, note: nil)
                        ForEach(plan.items) { item in
                            Divider()
                            FileRow(icon: Image(systemName: symbol(item.what)), title: item.what, path: item.path, bytes: item.bytes,
                                    isOn: Binding(get: { uninstaller.chosen.contains(item.path) },
                                                  set: { if $0 { uninstaller.chosen.insert(item.path) } else { uninstaller.chosen.remove(item.path) } }),
                                    note: item.admin ? "Shared by all users. Roomy leaves it; remove it in Finder if you want." : nil)
                                .disabled(item.admin)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    if plan.items.isEmpty {
                        Text("Roomy found no other files of this app.").foregroundStyle(.secondary)
                    }
                    result
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Everything goes to the Trash, so you can put it back.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirming = true } label: {
                    Text(uninstaller.removeApp ? "Uninstall · \(formatBytes(uninstaller.chosenBytes))" : "Remove Files · \(formatBytes(uninstaller.chosenBytes))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(plan.running || uninstaller.working || uninstaller.chosenBytes == 0 && !uninstaller.removeApp)
            }
            .padding(12)
        }
        .confirmationDialog("Move \(uninstaller.removeApp ? plan.name + " and its files" : "these files") to the Trash?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await uninstaller.uninstall() } }
        } message: {
            Text("\(formatBytes(uninstaller.chosenBytes)). You can put them back from the Trash until you empty it.")
        }
    }

    @ViewBuilder private var result: some View {
        if let report = uninstaller.report {
            Label(report, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        ForEach(uninstaller.skipped, id: \.path) { r in
            Label("\(friendlyPath(r.path)) \(r.error ?? "")", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func symbol(_ what: String) -> String {
        if what.hasPrefix("Caches") { return "internaldrive" }
        if what.hasPrefix("Settings") { return "gearshape" }
        if what.hasPrefix("Login item") || what == "Background service" || what == "Helper tool" { return "bolt.horizontal.circle" }
        switch what {
        case "Logs": return "doc.text"
        case "Sandbox container", "Shared container": return "shippingbox"
        case "Saved windows": return "macwindow"
        case "Web data", "Cookies": return "globe"
        default: return "folder"
        }
    }
}

private struct FileRow: View {
    let icon: Image
    let title: String
    let path: String
    let bytes: Int64
    @Binding var isOn: Bool
    let note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
            icon.resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(friendlyPath(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 8)
    }
}

private struct LeftoversView: View {
    @Bindable var uninstaller: Uninstaller
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Leftovers of removed apps").font(.title.weight(.semibold))
                    Text("Files named after apps that aren't on this Mac anymore. Roomy skips Apple's files, building blocks other apps use, and anything from a company that still has an app installed.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    switch uninstaller.orphanState {
                    case .loading, .idle: ProgressView("Looking…")
                    case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    case .ready where uninstaller.orphans.isEmpty:
                        Label("No leftovers found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .ready:
                        VStack(spacing: 0) {
                            ForEach(uninstaller.orphans) { o in
                                if o.id != uninstaller.orphans.first?.id { Divider() }
                                HStack(alignment: .top, spacing: 10) {
                                    Toggle("", isOn: Binding(get: { uninstaller.chosenOrphans.contains(o.id) },
                                                             set: { if $0 { uninstaller.chosenOrphans.insert(o.id) } else { uninstaller.chosenOrphans.remove(o.id) } }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(o.bundleId).fontWeight(.medium).textSelection(.enabled)
                                        ForEach(o.items) { i in
                                            Text("\(i.what): \(friendlyPath(i.path))").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    Text(formatBytes(o.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let report = uninstaller.report {
                        Label(report, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Look Again") { Task { await uninstaller.loadOrphans() } }
                Spacer()
                let bytes = uninstaller.orphans.filter { uninstaller.chosenOrphans.contains($0.id) }.reduce(0) { $0 + $1.bytes }
                Button("Move to Trash · \(formatBytes(bytes))", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(uninstaller.chosenOrphans.isEmpty || uninstaller.working)
            }
            .padding(12)
        }
        .confirmationDialog("Move the ticked leftovers to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await uninstaller.removeOrphans() } }
        }
    }
}
