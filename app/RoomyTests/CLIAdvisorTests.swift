import Foundation
import Testing

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "roomy-cli-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func script(_ body: String, in dir: URL, name: String = "claude") -> URL {
    let f = dir.appending(path: name)
    try! ("#!/bin/sh\n" + body).write(to: f, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f
}

@Test func findsTheCommandOutsideTheAppsPath() {
    let home = tempDir()
    let bin = home.appending(path: ".local/bin")
    try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    _ = script("exit 0", in: bin, name: "codex")
    #expect(CLIAdvisor.locate("codex", home: home.path, path: "/usr/bin:/bin") == bin.appending(path: "codex").path)
    #expect(CLIAdvisor.locate("claude", home: home.path, path: "/usr/bin:/bin") == nil)
}

@Test func runsReadOnlyWithNoTools() {
    let c = CLIAdvisor.arguments(.claude, schema: "{}")
    #expect(c.contains("-p"))
    #expect(c.firstIndex(of: "--tools").map { c[$0 + 1] } == "")
    #expect(c.contains("--no-session-persistence"))
    #expect(c.contains("--strict-mcp-config"))
    let x = CLIAdvisor.arguments(.codex, schema: "/tmp/s.json")
    #expect(x.firstIndex(of: "--sandbox").map { x[$0 + 1] } == "read-only")
    #expect(x.contains("--ephemeral"))
    for a in [c, x] { #expect(!a.contains { $0.contains("dangerously") || $0.contains("bypass") }) }
}

@Test func readsBothReplies() throws {
    let claude = #"{"type":"result","is_error":false,"structured_output":{"summary":"Hugging Face models.","kind":"aiModels","regrows":"yes"}}"#
    let r = try CLIAdvisor.parse(.claude, Data(claude.utf8))
    #expect(r.summary == "Hugging Face models.")
    #expect(r.kind == .aiModels && r.regrows == .yes)
    let codex = #"{"summary":"uv's cache.","kind":"cache","regrows":"yes"}"#
    #expect(try CLIAdvisor.parse(.codex, Data(codex.utf8)).kind == .cache)
    #expect(throws: (any Error).self) { try CLIAdvisor.parse(.claude, Data(#"{"type":"result","is_error":true,"result":"Not logged in"}"#.utf8)) }
}

@Test func asksTheCommandThenRoomyDecides() async throws {
    let dir = tempDir()
    let bin = script(#"""
    cat > "$PWD/sent.txt"
    echo '{"type":"result","is_error":false,"structured_output":{"summary":"OldApp cache.","kind":"cache","regrows":"yes"}}'
    """#, in: dir)
    let advisor = CLIAdvisor(tool: .claude, binary: bin.path)
    #expect(advisor.status() == .ready)
    #expect(advisor.sendsOffMac)
    let a = try await advisor.advise(sampleClues())
    #expect(a.summary == "OldApp cache.")
    #expect(a.verdict == .review)
    #expect(a.why == AdvisorPrompt.decide(kind: .cache, regrows: .yes).why)
}

@Test func missingCommandSaysHowToGetIt() {
    let a = CLIAdvisor(tool: .codex, binary: nil)
    #expect(a.status() == .notInstalled)
    #expect(a.statusMessage(.notInstalled).contains("codex"))
}

@Test func geminiRunsThroughAgySandboxed() throws {
    let a = CLIAdvisor.arguments(.gemini, schema: "{}", prompt: "Facts here")
    #expect(a.contains("--sandbox"))
    #expect(a.suffix(2) == ["-p", "Facts here"], "agy takes the prompt as an argument")
    #expect(!a.contains { $0.contains("dangerously") })
    #expect(CLIAdvisor.Tool.gemini.command == "agy")
    let reply = #"{"status":"SUCCESS","response":"…","structured_output":{"summary":"uv's cache.","kind":"cache","regrows":"yes"}}"#
    #expect(try CLIAdvisor.parse(.gemini, Data(reply.utf8)).kind == .cache)
    #expect(throws: (any Error).self) { try CLIAdvisor.parse(.gemini, Data(#"{"status":"ERROR","response":"Sign in first"}"#.utf8)) }
}

@Test func asksAnySchemaForAScan() async throws {
    let dir = tempDir()
    let bin = script(#"echo '{"type":"result","is_error":false,"structured_output":{"suggestions":[]}}'"#, in: dir)
    let data = try await CLIAdvisor(tool: .claude, binary: bin.path).request(system: "s", prompt: "p", schema: "{}")
    #expect(String(decoding: data, as: UTF8.self).contains("suggestions"))
}

@Test func picksTheLightestFlashModel() {
    let list = "Fetching available models...\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\ngemini-3.8-flash-low\tGemini 3.8 Flash (Low)\nclaude-sonnet-4-6\tClaude"
    #expect(CLIAdvisor.fastModel(from: list) == "gemini-3.8-flash-low")
    #expect(CLIAdvisor.fastModel(from: "gemini-9-flash\tX\ngemini-9-pro\tY") == "gemini-9-flash")
    #expect(CLIAdvisor.fastModel(from: "") == nil)
    #expect(CLIAdvisor.arguments(.gemini, schema: "{}", prompt: "p", model: "m").contains("m"))
}

@Test func emptyFailuresStillSaySomething() {
    #expect(throws: EngineError.failed("Gemini sent no answer (TIMEOUT).")) {
        try CLIAdvisor.parse(.gemini, Data(#"{"status":"TIMEOUT","response":""}"#.utf8))
    }
}
