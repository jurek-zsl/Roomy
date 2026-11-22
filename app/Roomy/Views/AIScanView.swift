import AppKit
import SwiftUI

/// Let an AI read the map of the whole disk at once and suggest what could
/// go. Roomy checks every folder it names; nothing is cleaned from here.
struct AIScanView: View {
    @Environment(CleanerStore.self) private var store
    var goToClean: () -> Void = {}
    @State private var added = false

    private var installed: [any FolderAdvisor] { store.advisors.filter { $0.status() == .ready } }
    private var tool: CLIAdvisor.Tool? { (store.advisor as? CLIAdvisor)?.tool }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Scan").font(.largeTitle.weight(.bold))
                    Text("An AI reads the map of your whole disk at once and suggests what could go. Roomy checks every folder it names, and nothing is cleaned from here.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                setup
                switch store.aiScanState {
                case .idle:
                    EmptyView()
                case .working(let what):
                    working(what)
                case .failed(let why):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await store.runAIScan() } }
                    }
                case .ready:
                    if let scan = store.aiScan { results(scan) }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Setup and consent

    @ViewBuilder private var setup: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            if installed.isEmpty {
                Label("No AI tool is set up yet. Roomy works with Claude Code, the Codex CLI and the Antigravity CLI, on your own account.",
                      systemImage: "sparkles")
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Set Up AI…") }
            } else {
                HStack(spacing: 12) {
                    Picker("Ask", selection: $store.advisorID) {
                        ForEach(installed, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 200)
                    Spacer()
                    if store.aiScanPreview == nil {
                        Button {
                            Task { await store.loadMap() }
                        } label: {
                            Label("Map the Disk First", systemImage: "chart.pie")
                        }
                        .disabled(store.mapState == .loading)
                    } else {
                        Button {
                            added = false
                            Task { await store.runAIScan() }
                        } label: {
                            Label("Scan with \(store.advisor.name)", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || store.advisorStatus != .ready)
                    }
                }
                Toggle("Also share what's inside Documents, Desktop, Movies, Pictures and Music", isOn: $store.aiScanIncludesPersonal)
                    .font(.callout)
                Text("Roomy sends the map below \(tool.map { "to \($0.company) through your own \($0.command) command" } ?? "to \(store.advisor.name)"): folder names and sizes, never file contents. One request, usually under two minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.mapState == .loading && store.aiScanPreview == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Mapping the disk…").foregroundStyle(.secondary)
                    }
                } else if let preview = store.aiScanPreview {
                    DisclosureGroup("Exactly what's sent (\(preview.split(separator: "\n").count) lines)") {
                        ScrollView {
                            Text(preview)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isWorking: Bool {
        if case .working = store.aiScanState { return true }
        return false
    }

    private func working(_ what: String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(what).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Results

    @ViewBuilder private func results(_ scan: AIScanResult) -> some View {
        let review = scan.suggestions.filter { $0.advice.verdict == .review }
        let keep = scan.suggestions.filter { $0.advice.verdict == .keep }
        VStack(alignment: .leading, spacing: 8) {
            Label("\(scan.advisor)'s overview", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(scan.overview).fixedSize(horizontal: false, vertical: true)
        }
        if scan.suggestions.isEmpty {
            Label("Nothing more worth removing, beyond what Roomy already finds.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if !review.isEmpty {
            section("Probably not needed", review)
            addBar(review)
        }
        if !keep.isEmpty {
            section("Roomy keeps these", keep)
        }
        Text("Suggested by \(scan.advisor) from names and sizes only. It can be wrong, so check before you agree.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func section(_ title: String, _ items: [AISuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(items) { s in
                SuggestionRow(suggestion: s)
                if s.id != items.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private func addBar(_ review: [AISuggestion]) -> some View {
        let picked = review.filter { store.aiSelected.contains($0.path) }
        HStack {
            if added && picked.isEmpty {
                Label("Added. They're under Review first in Clean.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Go to Clean", action: goToClean)
            } else {
                Text("You still tick and confirm each one in Clean, and they go to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        await store.addAISuggestions()
                        added = true
                    }
                } label: {
                    Text(picked.isEmpty ? "Add to Review"
                         : "Add \(picked.count) to Review · \(formatBytes(picked.reduce(0) { $0 + $1.bytes }))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SuggestionRow: View {
    @Environment(CleanerStore.self) private var store
    let suggestion: AISuggestion

    var body: some View {
        let s = suggestion
        let canAdd = s.advice.verdict == .review && !store.isAccepted(s.path)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { store.aiSelected.contains(s.path) },
                set: { on in if on { store.aiSelected.insert(s.path) } else { store.aiSelected.remove(s.path) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canAdd)
                .opacity(s.advice.verdict == .review ? 1 : 0)
            Image(nsImage: NSWorkspace.shared.icon(forFile: s.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(formatBytes(s.bytes)).font(.headline).monospacedDigit()
                }
                Text(friendlyPath(s.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(s.advice.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(s.advice.kind.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(.blue)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                    if store.isAccepted(s.path) {
                        Label("In Review", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Label(s.advice.override ?? s.advice.why,
                      systemImage: s.advice.override == nil ? "info.circle" : "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }
}
