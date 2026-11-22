import SwiftUI

/// Homebrew formulae and apps, and global npm, uv and pipx tools. Each is
/// removed with its own manager, one at a time.
struct PackagesView: View {
    @Bindable var uninstaller: Uninstaller
    @State private var filter: Filter = .yours
    @State private var search = ""
    @State private var confirming: Package?

    enum Filter: String, CaseIterable {
        case yours = "Installed by you", deps = "Dependencies", all = "All"
    }

    private var shown: [Package] {
        (uninstaller.packages?.packages ?? []).filter { p in
            let f: Bool = switch filter {
            case .yours: p.requested
            case .deps: !p.requested
            case .all: true
            }
            return f && (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || (p.description ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Homebrew & command-line tools").font(.title.weight(.semibold))
                Text("Packages installed with Homebrew, npm, uv and pipx. Each is removed with its own manager, the way it would be in Terminal, so nothing gets out of sync. Packages that something else needs can't be removed.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                if let auto = uninstaller.packages?.autoremove, !auto.isEmpty {
                    HStack(alignment: .top) {
                        Label("\(auto.count) Homebrew dependencies aren't needed by anything anymore: \(auto.prefix(6).joined(separator: ", "))\(auto.count > 6 ? "…" : "")",
                              systemImage: "sparkles")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Remove Them") { Task { await uninstaller.autoremove() } }
                            .disabled(uninstaller.removing != nil)
                    }
                    .padding(10)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if let report = uninstaller.report {
                    Label(report, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            switch uninstaller.packageState {
            case .idle, .loading:
                ProgressView("Asking Homebrew, npm, uv and pipx…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                ContentUnavailableView("Couldn't list packages", systemImage: "exclamationmark.triangle", description: Text(why))
            case .ready where (uninstaller.packages?.packages ?? []).isEmpty:
                ContentUnavailableView("No packages", systemImage: "shippingbox", description: Text("Roomy didn't find Homebrew, npm, uv or pipx on this Mac."))
            case .ready:
                List(shown) { p in row(p) }
            }
        }
        .task { if uninstaller.packageState == .idle { await uninstaller.loadPackages() } }
        .confirmationDialog("Remove \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { p in
            Button("Remove", role: .destructive) { Task { await uninstaller.remove(p) } }
        } message: { p in
            Text("Roomy runs \(p.command). You can install it again the same way.")
        }
    }

    private func row(_ p: Package) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(p.manager))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint(p.manager).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).fontWeight(.medium)
                    if let v = p.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                    Text(p.managerTitle).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let d = p.description { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if !p.neededBy.isEmpty {
                    Text("Needed by \(p.neededBy.prefix(4).joined(separator: ", "))\(p.neededBy.count > 4 ? " and \(p.neededBy.count - 4) more" : "")")
                        .font(.caption).foregroundStyle(.orange)
                } else if let d = p.lastUsedDays {
                    Text(d == 0 ? "Used today" : "Last used \(d) days ago").font(.caption).foregroundStyle(d > 60 ? .orange : .secondary)
                }
            }
            Spacer()
            Text(formatBytes(p.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if uninstaller.removing == p.id {
                ProgressView().controlSize(.small).frame(width: 70)
            } else {
                Button("Remove") { confirming = p }
                    .disabled(!p.neededBy.isEmpty || uninstaller.removing != nil)
                    .help(p.neededBy.isEmpty ? p.command : "Other packages need it")
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ m: String) -> String {
        switch m {
        case "cask": "app.fill"
        case "npm", "uv", "pipx": "terminal.fill"
        default: "mug.fill"
        }
    }

    private func tint(_ m: String) -> Color {
        switch m {
        case "brew", "cask": .orange
        case "npm": .red
        case "uv": .purple
        default: .blue
        }
    }
}
