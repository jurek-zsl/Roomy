import Foundation

/// Explains folders with the Claude Code or Codex command you already use,
/// on your own subscription or API key. It runs with no tools, read-only,
/// in an empty folder, and gets only Roomy's facts (names, sizes, dates).
/// Those facts leave the Mac, so Roomy shows them and asks before each send.
struct CLIAdvisor: FolderAdvisor {
    enum Tool: String, Sendable, CaseIterable {
        case claude, codex

        var title: String { self == .claude ? "Claude" : "Codex" }
        var product: String { self == .claude ? "Claude Code" : "the Codex CLI" }
        var company: String { self == .claude ? "Anthropic" : "OpenAI" }
    }

    let tool: Tool
    let binary: String?
    var timeout: TimeInterval = 120

    var id: String { tool.rawValue }
    var name: String { tool.title }
    var sendsOffMac: Bool { true }

    /// Both tools, wherever they're installed.
    static var all: [any FolderAdvisor] {
        Tool.allCases.map { CLIAdvisor(tool: $0, binary: locate($0.rawValue)) }
    }

    func status() -> AdvisorStatus { binary == nil ? .notInstalled : .ready }

    func statusMessage(_ status: AdvisorStatus) -> String {
        switch status {
        case .notInstalled:
            "Roomy can't find the \(tool.rawValue) command. Install \(tool.product) and sign in to it, then open Roomy again."
        default:
            "Uses your own \(tool.product) account. The facts are sent to \(tool.company) only when you ask."
        }
    }

    // MARK: Finding the command

    /// Apps don't get your shell's PATH, so look where installers put these.
    static let homeDirs = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", "bin"]
    static let systemDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func locate(_ command: String, home: String = NSHomeDirectory(),
                       path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
            + homeDirs.map { home + "/" + $0 } + systemDirs
        return dirs.map { $0 + "/" + command }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: The request

    static let schema = """
    {"type":"object","properties":{"summary":{"type":"string"},\
    "kind":{"type":"string","enum":[\(FolderKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},\
    "regrows":{"type":"string","enum":["yes","no","unsure"]}},\
    "required":["summary","kind","regrows"],"additionalProperties":false}
    """

    /// No tools, no saved session, no MCP servers, read-only.
    static func arguments(_ tool: Tool, schema: String, answer: String = "answer.json") -> [String] {
        switch tool {
        case .claude:
            ["-p", "--output-format", "json", "--json-schema", schema, "--tools", "", "--strict-mcp-config",
             "--no-session-persistence", "--setting-sources", "", "--system-prompt", AdvisorPrompt.instructions]
        case .codex:
            ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
             "--output-schema", schema, "--output-last-message", answer, "-"]
        }
    }

    /// What goes to the tool on its input.
    static func input(_ tool: Tool, facts: String) -> String {
        switch tool {
        case .claude: facts
        case .codex: AdvisorPrompt.instructions + "\nReply with JSON only.\n\nFacts:\n" + facts
        }
    }

    struct Reply: Decodable, Equatable {
        let summary: String
        let kind: FolderKind
        let regrows: Regrows
    }

    private struct ClaudeResult: Decodable {
        let isError: Bool?
        let result: String?
        let structuredOutput: Reply?
    }

    static func parse(_ tool: Tool, _ data: Data) throws -> Reply {
        switch tool {
        case .codex:
            return try JSONDecoder().decode(Reply.self, from: data)
        case .claude:
            let r = try engineDecoder().decode(ClaudeResult.self, from: data)
            guard r.isError != true, let reply = r.structuredOutput else {
                throw EngineError.failed(r.result ?? "Claude sent no answer.")
            }
            return reply
        }
    }

    // MARK: Running it

    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        guard let binary else { throw EngineError.failed(statusMessage(.notInstalled)) }
        let tool = tool, timeout = timeout
        let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Reply, Error>) in
            DispatchQueue.global().async {
                cont.resume(with: Result {
                    try CLIAdvisor.run(tool, binary: binary, facts: AdvisorPrompt.facts(clues), timeout: timeout)
                })
            }
        }
        return AdvisorPrompt.advice(summary: reply.summary, kind: reply.kind, regrows: reply.regrows, clues: clues)
    }

    private static func run(_ tool: Tool, binary: String, facts: String, timeout: TimeInterval) throws -> Reply {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "roomy-ask-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let schemaFile = dir.appending(path: "schema.json")
        let answerFile = dir.appending(path: "answer.json")
        try schema.write(to: schemaFile, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments(tool, schema: tool == .claude ? schema : schemaFile.path, answer: answerFile.path)
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: binary).deletingLastPathComponent().path
        env["PATH"] = ([binDir] + systemDirs + ["/usr/bin", "/bin", env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()

        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        stdin.fileHandleForWriting.write(Data(input(tool, facts: facts).utf8))
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()

        if p.terminationReason == .uncaughtSignal {
            throw EngineError.failed("\(tool.title) took longer than \(Int(timeout)) seconds.")
        }
        switch tool {
        case .claude where !out.isEmpty:
            return try parse(.claude, out)
        case .codex where p.terminationStatus == 0:
            if let answer = try? Data(contentsOf: answerFile) { return try parse(.codex, answer) }
        default:
            break
        }
        let said = String(decoding: errData.isEmpty ? out : errData, as: UTF8.self)
            .split(separator: "\n").suffix(2).joined(separator: " ")
        throw EngineError.failed(said.isEmpty ? "\(tool.title) didn't answer." : "\(tool.title): \(said)")
    }
}
