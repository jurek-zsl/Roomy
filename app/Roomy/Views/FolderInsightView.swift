import AppKit
import SwiftUI

/// What a folder is: Roomy's own facts, and an AI's reading of them.
struct FolderInsightView: View {
    @Environment(CleanerStore.self) private var store
    let node: MapNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.folder.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(formatBytes(node.bytes)).font(.headline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                switch store.insights[node.path] {
                case .ready(let clues, let advice):
                    aiCard(clues, advice)
                    FactsView(clues: clues)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { Task { await store.explain(node.path) } }
                case .loading, nil:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking inside…").foregroundStyle(.secondary)
                    }
                }
                Text(friendlyPath(node.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: node.path) { await store.explain(node.path) }
    }

    @ViewBuilder private func aiCard(_ clues: FolderClues, _ advice: FolderAdvice?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ToolIcon(tool: (store.advisor as? CLIAdvisor)?.tool, size: 16)
                Text(store.advisor.name)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if let advice {
                Text(advice.summary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill(text: advice.kind.title, color: .blue)
                    Pill(text: regrowsText(advice.regrows), color: advice.regrows == .yes ? .green : .secondary)
                }
                verdictLine(advice)
                actions(advice)
                Text(store.advisor.sendsOffMac
                     ? "Written by \(store.advisor.name) from the facts below; it never saw your files. It can be wrong, so check before you agree."
                     : "Written on this Mac; nothing was sent anywhere. It can be wrong, so check before you agree.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if store.asking.contains(node.path) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.advisor.sendsOffMac ? "Asking \(store.advisor.name)…" : "Thinking on this Mac…").foregroundStyle(.secondary)
                }
            } else if store.advisorStatus == .ready, store.advisor.sendsOffMac {
                askOffMac
            } else if store.advisorStatus != .ready {
                Text(store.advisor.statusMessage(store.advisorStatus)).fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Set Up AI…") }
            }
            if store.advice(for: node.path) == nil, !store.asking.contains(node.path), let error = store.adviceError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if !store.advisor.sendsOffMac, store.advisorStatus == .ready {
                    Button("Try Again") { Task { await store.ask(node.path) } }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Ask first: these facts leave the Mac, so show them and wait.
    @ViewBuilder private var askOffMac: some View {
        let tool = (store.advisor as? CLIAdvisor)?.tool
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await store.ask(node.path) }
            } label: {
                Label("Ask \(store.advisor.name)", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.outgoing(node.path) == nil)
            Text("Roomy sends only the facts below to \(tool?.company ?? "the company behind it") through your own \(tool?.rawValue ?? "") command: names, sizes and dates, never file contents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = store.outgoing(node.path) {
                DisclosureGroup("Exactly what's sent") {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder private func verdictLine(_ advice: FolderAdvice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch advice.verdict {
            case .review:
                Label("Probably not needed", systemImage: "eye.fill").foregroundStyle(.orange).fontWeight(.semibold)
            case .keep:
                Label("Keep it", systemImage: "checkmark.shield.fill").foregroundStyle(.green).fontWeight(.semibold)
            }
            Text(advice.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let override = advice.override {
                Label(override, systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func actions(_ advice: FolderAdvice) -> some View {
        if store.isAccepted(node.path) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Listed under Review first", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Stop Listing It") { Task { await store.removeSuggestion(node.path) } }
                    .buttonStyle(.link)
            }
        } else if advice.verdict == .review {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await store.acceptSuggestion(node.path) }
                } label: {
                    Label("Add to Review", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                Text("It shows up under Review first in Clean. You still tick it and confirm, and it goes to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func regrowsText(_ r: Regrows) -> String {
        switch r {
        case .yes: "Comes back by itself"
        case .no: "Won't come back"
        case .unsure: "May not come back"
        }
    }
}

/// Roomy's own facts about the folder.
private struct FactsView: View {
    let clues: FolderClues

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT ROOMY SEES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let o = clues.owner {
                fact("app.badge", ownerText(o))
            }
            if let d = clues.newestDays {
                fact("clock", d == 0 ? "Changed today" : "Last changed \(d) days ago")
            }
            fact("doc.on.doc", "\(clues.files) files in \(clues.folders) folders")
            if !clues.types.isEmpty {
                fact("square.stack.3d.up", clues.types.prefix(4)
                    .map { "\($0.ext.isEmpty ? "no extension" : "." + $0.ext) \(formatBytes($0.bytes))" }
                    .joined(separator: " · "))
            }
            ForEach(clues.markers, id: \.self) { fact("lightbulb", $0) }
            if !clues.biggest.isEmpty {
                Text("BIGGEST INSIDE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(clues.biggest.prefix(6), id: \.name) { item in
                    HStack {
                        Image(systemName: item.folder ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func ownerText(_ o: FolderOwner) -> String {
        let what = o.kind == "app" ? "the app" : "the tool"
        if o.running { return "Belongs to \(what) \(o.name), which is running" }
        switch o.installed {
        case true?: return "Belongs to \(what) \(o.name), which is installed"
        case false?: return "Named after \(what) \(o.name), which isn't installed"
        case nil: return "Named after \(what) \(o.name)"
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
