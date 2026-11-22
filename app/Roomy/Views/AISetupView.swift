import AppKit
import SwiftUI

/// Claude, Codex and Gemini: install, sign in, and pick the one Roomy asks.
struct AISetupView: View {
    @Environment(CleanerStore.self) private var store
    @State private var states: [CLIAdvisor.Tool: AISetup.State] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CLIAdvisor.Tool.allCases, id: \.self) { tool in
                row(tool)
                if tool != CLIAdvisor.Tool.allCases.last { Divider() }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        store.reloadAdvisors()
        for tool in CLIAdvisor.Tool.allCases {
            states[tool] = await AISetup.check(tool)
        }
    }

    private func row(_ tool: CLIAdvisor.Tool) -> some View {
        let state = states[tool]
        let inUse = store.advisorID == tool.rawValue && (state == .ready || state == .installed)
        return HStack(spacing: 12) {
            ToolIcon(tool: tool, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.headline)
                Text(caption(tool, state)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case nil:
                ProgressView().controlSize(.small)
            case .notInstalled?:
                Button("Install…") { AISetup.install(tool) }
            case .signedOut?:
                Button("Sign In…") { AISetup.signIn(tool) }
            case .installed?, .ready?:
                if inUse {
                    Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Use \(tool.title)") { store.advisorID = tool.rawValue }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func caption(_ tool: CLIAdvisor.Tool, _ state: AISetup.State?) -> String {
        let what = "\(tool.product.prefix(1).uppercased() + tool.product.dropFirst()), by \(tool.company)"
        switch state {
        case nil: return what
        case .notInstalled?: return "\(what). Not installed."
        case .signedOut?: return "\(what). Installed; sign in with your account."
        case .installed?: return "\(what). Installed. If it asks you to sign in, click Sign In."
        case .ready?: return "\(what). Signed in and ready."
        }
    }
}

/// Whether Roomy can read every folder, and how to allow it.
struct DiskAccessView: View {
    @State private var granted = FullDiskAccess.granted()
    @State private var asked = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if granted {
                Label("Roomy can see every folder on this Mac.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Turn on Roomy in Privacy & Security → Full Disk Access. If Roomy isn't in the list, click + and choose it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") {
                        asked = true
                        FullDiskAccess.openSettings()
                    }
                    if asked {
                        Button("Quit & Reopen Roomy") { FullDiskAccess.relaunch() }
                            .help("macOS may only apply the change after Roomy starts again.")
                    }
                }
            }
        }
        .onReceive(timer) { _ in granted = FullDiskAccess.granted() }
    }
}
