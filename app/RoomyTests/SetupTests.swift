import Foundation
import Testing

@Test func readsEachToolsSignInStatus() {
    #expect(AISetup.state(.claude, output: #"{"loggedIn": true, "authMethod": "claude.ai"}"#, exit: 0) == .ready)
    #expect(AISetup.state(.claude, output: #"{"loggedIn": false}"#, exit: 1) == .signedOut)
    #expect(AISetup.state(.codex, output: "Logged in using ChatGPT", exit: 0) == .ready)
    #expect(AISetup.state(.codex, output: "Not logged in", exit: 1) == .signedOut)
    #expect(AISetup.state(.gemini, output: "", exit: 0) == .installed, "agy has no status command")
}

@Test func terminalScriptRunsTheCommandThenSaysWhatsNext() throws {
    let s = AISetup.terminalScript("claude auth login", binDir: "/Users/me/.local/bin")
    #expect(s.hasPrefix("#!/bin/zsh -l\n"))
    #expect(s.contains("export PATH=\"/Users/me/.local/bin:$PATH\""))
    #expect(s.contains("\nclaude auth login\n"))
    #expect(s.contains("go back to Roomy"))
}

@Test func fullDiskAccessIsSeenByReadingAProtectedFile() throws {
    let f = FileManager.default.temporaryDirectory.appending(path: "roomy-fda-\(UUID().uuidString)")
    try Data("x".utf8).write(to: f)
    #expect(FullDiskAccess.granted(probes: ["/nope/never", f.path]))
    #expect(!FullDiskAccess.granted(probes: ["/nope/never"]))
}
