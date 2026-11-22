import AppKit
import Foundation

/// Full Disk Access lets Roomy (and its engine) read every folder, such as
/// Mail, Safari and other apps' containers. macOS only grants it in System
/// Settings; an app can't ask with a prompt.
enum FullDiskAccess {
    /// Files only readable with Full Disk Access.
    static let probes = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        NSHomeDirectory() + "/Library/Mail",
    ]

    static func granted(probes: [String] = probes) -> Bool {
        probes.contains { p in
            if let h = FileHandle(forReadingAtPath: p) {
                try? h.close()
                return true
            }
            return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies the grant to a fresh launch.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Install, sign in and pick an AI tool.
enum AISetup {
    enum State: Equatable {
        case notInstalled
        /// Installed, but its sign-in can't be checked (agy).
        case installed
        case signedOut
        case ready
    }

    /// Read a tool's own status output.
    static func state(_ tool: CLIAdvisor.Tool, output: String, exit: Int32) -> State {
        switch tool {
        case .claude:
            let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            return json?["loggedIn"] as? Bool == true ? .ready : .signedOut
        case .codex:
            return exit == 0 && output.localizedCaseInsensitiveContains("logged in")
                && !output.localizedCaseInsensitiveContains("not logged in") ? .ready : .signedOut
        case .gemini:
            return .installed
        }
    }

    static func statusArguments(_ tool: CLIAdvisor.Tool) -> [String]? {
        switch tool {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        case .gemini: nil
        }
    }

    /// Check one tool; runs its status command (a second or so).
    static func check(_ tool: CLIAdvisor.Tool) async -> State {
        guard let binary = CLIAdvisor.locate(tool.command) else { return .notInstalled }
        guard let args = statusArguments(tool) else { return .installed }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                guard (try? p.run()) != nil else { return cont.resume(returning: .signedOut) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: state(tool, output: String(decoding: data, as: UTF8.self), exit: p.terminationStatus))
            }
        }
    }

    /// Official install: a command Roomy runs in Terminal, or the tool's page.
    static func install(_ tool: CLIAdvisor.Tool) {
        switch tool {
        case .claude: openInTerminal("curl -fsSL https://claude.ai/install.sh | bash")
        case .codex: NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex#readme")!)
        case .gemini: NSWorkspace.shared.open(URL(string: "https://antigravity.google/")!)
        }
    }

    static func signIn(_ tool: CLIAdvisor.Tool) {
        let bin = CLIAdvisor.locate(tool.command).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        switch tool {
        case .claude: openInTerminal("claude auth login", binDir: bin)
        case .codex: openInTerminal("codex login", binDir: bin)
        case .gemini: openInTerminal("agy", binDir: bin)
        }
    }

    static func terminalScript(_ command: String, binDir: String? = nil) -> String {
        var s = "#!/bin/zsh -l\n"
        if let binDir { s += "export PATH=\"\(binDir):$PATH\"\n" }
        s += "clear\n\(command)\n"
        s += "echo\necho \"Done. You can close this window and go back to Roomy.\"\n"
        return s
    }

    /// Opens Terminal running `command` (a .command file needs no extra permission).
    static func openInTerminal(_ command: String, binDir: String? = nil) {
        let f = FileManager.default.temporaryDirectory.appending(path: "roomy-setup-\(UUID().uuidString).command")
        do {
            try terminalScript(command, binDir: binDir).write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
            NSWorkspace.shared.open(f)
        } catch {
            NSSound.beep()
        }
    }
}
