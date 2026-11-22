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

@Test func signInCheckFindsNodeNextToAnNpmInstalledTool() async throws {
    // Like `npm i -g @openai/codex`: a script that needs `node` from its own folder.
    let bin = FileManager.default.temporaryDirectory.appending(path: "roomy-npm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let node = bin.appending(path: "node")
    try "#!/bin/sh\necho 'Logged in using ChatGPT'\n".write(to: node, atomically: true, encoding: .utf8)
    let codex = bin.appending(path: "codex")
    try "#!/usr/bin/env node\n".write(to: codex, atomically: true, encoding: .utf8)
    for f in [node, codex] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
    #expect(await AISetup.check(.codex, binary: codex.path) == .ready)
}

@Test func cheapModelsByDefault() {
    let codexList = #"{"models":[{"slug":"gpt-6.2-astra","display_name":"GPT-6.2-Astra","visibility":"list","priority":2,"description":"Our most capable model"},{"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","visibility":"list","priority":11,"description":"Legacy fast model for simpler tasks."},{"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list","priority":8,"description":"Fast and affordable model for easier tasks."},{"slug":"hidden-luna","visibility":"hide","priority":1,"description":"affordable"}]}"#
    let pick = CLIAdvisor.codexFastModel(from: Data(codexList.utf8))
    #expect(pick?.slug == "gpt-6-luna")
    #expect(pick?.name == "GPT-6-Luna")
    let claude = CLIAdvisor.arguments(.claude, schema: "{}", model: "haiku")
    #expect(claude.contains("--model") && claude.contains("haiku"))
    let codex = CLIAdvisor.arguments(.codex, schema: "s.json", model: "gpt-6-luna")
    #expect(codex.contains("-m") && codex.contains("gpt-6-luna"))
    #expect(codex.contains("model_reasoning_effort=\"low\""), "Codex thinks briefly; this is an easy task")
    #expect(!CLIAdvisor.arguments(.claude, schema: "{}").contains("--model"), "no model: the person's own default")
}
