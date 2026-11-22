import Foundation

/// Explains folders with the AI command line tool you already use (Claude
/// Code, the Codex CLI or Google's Antigravity CLI), on your own subscription
/// or API key. It runs without tools or in a sandbox, read-only, in an empty
/// folder, and gets only Roomy's facts (names, sizes, dates). Those facts
/// leave the Mac, so Roomy shows them and asks before each send.
struct CLIAdvisor: FolderAdvisor {
    enum Tool: String, Sendable, CaseIterable {
        case claude, codex, gemini

        var command: String { self == .gemini ? "agy" : rawValue }
        var title: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .gemini: "Gemini"
            }
        }
        var product: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "the Codex CLI"
            case .gemini: "the Antigravity CLI"
            }
        }
        /// The company's Mac apps, for their icon: first one installed wins.
        var appIDs: [String] {
            switch self {
            case .claude: ["com.anthropic.claudefordesktop"]
            case .codex: ["com.openai.codex", "com.openai.chat"]
            case .gemini: ["com.google.GeminiMacOS", "com.google.antigravity"]
            }
        }
        var company: String {
            switch self {
            case .claude: "Anthropic"
            case .codex: "OpenAI"
            case .gemini: "Google"
            }
        }
    }

    let tool: Tool
    let binary: String?
    var timeout: TimeInterval = 120

    var id: String { tool.rawValue }
    var name: String { tool.title }
    var sendsOffMac: Bool { true }

    /// Every tool, wherever it's installed.
    static var all: [any FolderAdvisor] {
        Tool.allCases.map { CLIAdvisor(tool: $0, binary: locate($0.command)) }
    }

    func status() -> AdvisorStatus { binary == nil ? .notInstalled : .ready }

    func statusMessage(_ status: AdvisorStatus) -> String {
        switch status {
        case .notInstalled:
            "Roomy can't find the \(tool.command) command. Install \(tool.product) and sign in to it, then open Roomy again."
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

    /// No tools (Claude) or a read-only sandbox (Codex, Antigravity); no saved session where the tool allows it.
    static func arguments(_ tool: Tool, schema: String, answer: String = "answer.json", prompt: String = "",
                          system: String = AdvisorPrompt.instructions, timeout: TimeInterval = 120,
                          model: String? = nil) -> [String] {
        switch tool {
        case .claude:
            ["-p", "--output-format", "json", "--json-schema", schema, "--tools", "", "--strict-mcp-config",
             "--no-session-persistence", "--setting-sources", "", "--system-prompt", system]
        case .codex:
            ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
             "--output-schema", schema, "--output-last-message", answer, "-"]
        case .gemini:
            ["--output-format", "json", "--json-schema", schema, "--sandbox", "--disable-slash-commands",
             "--print-timeout", "\(Int(timeout))s"] + (model.map { ["--model", $0] } ?? []) + ["-p", prompt]
        }
    }

    /// The lightest Flash model `agy models` lists; its default thinks for a long time.
    static func fastModel(from list: String) -> String? {
        let ids = list.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
            .filter { $0.contains("flash") }
        return ids.first { $0.hasSuffix("-low") } ?? ids.first { !$0.contains("-high") } ?? ids.first
    }

    private static let modelCache = ModelCache()

    /// Asked once per run of the app.
    private final class ModelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: String?] = [:]
        func model(for binary: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            if let m = found[binary] { return m }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["models"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var m: String?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                m = CLIAdvisor.fastModel(from: String(decoding: data, as: UTF8.self))
            }
            found[binary] = m
            return m
        }
    }

    /// The whole message, for tools without a separate system prompt.
    static func combined(system: String, prompt: String) -> String {
        system + "\nReply with JSON only.\n\n" + prompt
    }

    struct Reply: Decodable, Equatable {
        let summary: String
        let kind: FolderKind
        let regrows: Regrows
    }

    /// The structured answer inside a tool's output, as JSON.
    static func structured(_ tool: Tool, _ data: Data) throws -> Data {
        if tool == .codex { return data }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let failed = obj["is_error"] as? Bool == true || (obj["status"] as? String).map { $0 != "SUCCESS" } == true
        guard !failed, let out = obj["structured_output"], JSONSerialization.isValidJSONObject(out) else {
            let said = ((obj["result"] ?? obj["response"] ?? obj["error"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = (obj["status"] as? String).map { " (\($0))" } ?? ""
            throw EngineError.failed(said?.isEmpty == false ? said! : "\(tool.title) sent no answer\(status).")
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    static func parse(_ tool: Tool, _ data: Data) throws -> Reply {
        try JSONDecoder().decode(Reply.self, from: structured(tool, data))
    }

    // MARK: Running it

    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        let data = try await request(system: AdvisorPrompt.instructions, prompt: AdvisorPrompt.facts(clues), schema: CLIAdvisor.schema)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return AdvisorPrompt.advice(summary: reply.summary, kind: reply.kind, regrows: reply.regrows, clues: clues)
    }

    /// Ask anything with a JSON schema; returns the structured answer.
    func request(system: String, prompt: String, schema: String) async throws -> Data {
        try await request(system: system, prompt: prompt, schema: schema, timeout: timeout)
    }

    func request(system: String, prompt: String, schema: String, timeout: TimeInterval) async throws -> Data {
        guard let binary else { throw EngineError.failed(statusMessage(.notInstalled)) }
        let tool = tool
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                cont.resume(with: Result {
                    try CLIAdvisor.run(tool, binary: binary, system: system, prompt: prompt, schema: schema, timeout: timeout)
                })
            }
        }
    }

    private static func run(_ tool: Tool, binary: String, system: String, prompt: String, schema: String,
                            timeout: TimeInterval) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "roomy-ask-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let schemaFile = dir.appending(path: "schema.json")
        let answerFile = dir.appending(path: "answer.json")
        try schema.write(to: schemaFile, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        let whole = combined(system: system, prompt: prompt)
        p.arguments = arguments(tool, schema: tool == .codex ? schemaFile.path : schema, answer: answerFile.path,
                                prompt: whole, system: system, timeout: timeout,
                                model: tool == .gemini ? modelCache.model(for: binary) : nil)
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
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 10) { if p.isRunning { p.terminate() } }
        let input: String = switch tool {
        case .claude: prompt
        case .codex: whole
        case .gemini: ""
        }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()

        if p.terminationReason == .uncaughtSignal {
            throw EngineError.failed("\(tool.title) took longer than \(Int(timeout)) seconds.")
        }
        if tool == .codex {
            if p.terminationStatus == 0, let answer = try? Data(contentsOf: answerFile) { return answer }
        } else if !out.isEmpty {
            return try structured(tool, out)
        }
        let said = String(decoding: errData.isEmpty ? out : errData, as: UTF8.self)
            .split(separator: "\n").suffix(2).joined(separator: " ")
        throw EngineError.failed(said.isEmpty ? "\(tool.title) didn't answer." : "\(tool.title): \(said)")
    }
}
