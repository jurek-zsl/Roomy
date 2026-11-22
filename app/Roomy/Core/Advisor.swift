import Foundation

// MARK: - Clues (`roomy inspect --json`)

struct TypeShare: Decodable, Sendable, Equatable {
    let ext: String
    let bytes: Int64
    let files: Int64
}

struct FolderItem: Decodable, Sendable, Equatable {
    let name: String
    let bytes: Int64
    let folder: Bool
}

struct FolderOwner: Decodable, Sendable, Equatable {
    let name: String
    /// "app" or "tool".
    let kind: String
    /// nil: can't tell (a tool whose command has another name).
    let installed: Bool?
    let running: Bool
}

/// Facts the engine gathered about one folder.
struct FolderClues: Decodable, Sendable, Equatable {
    let path: String
    let name: String
    let bytes: Int64
    let files: Int64
    let folders: Int64
    let newestDays: Int64?
    let types: [TypeShare]
    let biggest: [FolderItem]
    let owner: FolderOwner?
    let markers: [String]

    static func decode(_ data: Data) throws -> FolderClues {
        try engineDecoder().decode(FolderClues.self, from: data)
    }
}

// MARK: - Advice

enum FolderKind: String, Codable, Sendable, CaseIterable {
    case cache, appData, userFiles, buildOutput, aiModels, toolchain, installers, logs, leftover, unknown

    var title: String {
        switch self {
        case .cache: "Cache"
        case .appData: "App data"
        case .userFiles: "Your files"
        case .buildOutput: "Build output"
        case .aiModels: "AI models"
        case .toolchain: "Developer tools"
        case .installers: "Installers"
        case .logs: "Logs"
        case .leftover: "Leftover of a removed app"
        case .unknown: "Not sure"
        }
    }
}

enum Regrows: String, Codable, Sendable {
    case yes, no, unsure
}

enum AdviceVerdict: String, Codable, Sendable {
    /// Leave it alone.
    case keep
    /// Probably not needed: worth reviewing for removal.
    case review
}

struct FolderAdvice: Equatable, Sendable {
    var summary: String
    var kind: FolderKind
    var regrows: Regrows
    var verdict: AdviceVerdict
    var why: String
    /// Set when Roomy changed the model's verdict to be safe.
    var override: String?
}

enum AdvisorStatus: Equatable, Sendable {
    case ready
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// The model is still downloading or getting ready.
    case notReady
    /// This Mac or macOS version can't run it.
    case notSupported

    var message: String {
        switch self {
        case .ready: "Apple Intelligence is ready."
        case .notEnabled: "Turn on Apple Intelligence in System Settings to get an explanation written on this Mac."
        case .notReady: "Apple Intelligence is still getting ready (the model may be downloading). Try again in a while."
        case .notSupported: "This Mac can't run Apple Intelligence. The facts below are still Roomy's own."
        }
    }
}

/// Something that can explain a folder from its clues.
protocol FolderAdvisor: Sendable {
    var name: String { get }
    func status() -> AdvisorStatus
    func advise(_ clues: FolderClues) async throws -> FolderAdvice
}

enum AdvisorPrompt {
    static let instructions = """
    You help people free disk space on a Mac. You get facts about one folder that a disk scan found. \
    Say what the folder most likely is, and whether it is worth reviewing for removal.
    Rules:
    - Base every claim on the facts. Don't invent app names or details.
    - Never suggest removing the user's own documents, photos, music, projects or code.
    - App databases, messages, settings and saved games are app data: keep them while the app is installed.
    - Caches, logs, downloaded AI models, installers, build output, and folders of apps that are no longer installed are usually worth reviewing.
    - If you are unsure, the verdict is keep.
    """

    /// The facts, as short plain lines.
    static func facts(_ c: FolderClues, home: String = NSHomeDirectory()) -> String {
        var lines = ["Folder: \(tildePath(c.path, home: home))",
                     "Size: \(formatBytes(c.bytes)) in \(c.files) files and \(c.folders) folders"]
        if let d = c.newestDays {
            lines.append("Last change inside: \(d == 0 ? "today" : "\(d) days ago")")
        }
        if let o = c.owner {
            switch (o.running, o.installed) {
            case (true, _): lines.append("Named after the \(o.kind) \"\(o.name)\", which is running right now")
            case (false, true?): lines.append("Named after the \(o.kind) \"\(o.name)\", which is installed")
            case (false, false?): lines.append("Named after the \(o.kind) \"\(o.name)\", which is NOT installed on this Mac")
            case (false, nil): lines.append("Named after the \(o.kind) \"\(o.name)\" (unknown whether it is still used)")
            }
        }
        if !c.types.isEmpty {
            let t = c.types.prefix(6).map { "\($0.ext.isEmpty ? "(no extension)" : "." + $0.ext) \(formatBytes($0.bytes))" }
            lines.append("File types: " + t.joined(separator: ", "))
        }
        if !c.biggest.isEmpty {
            let b = c.biggest.prefix(8).map { "\($0.name)\($0.folder ? "/" : "") \(formatBytes($0.bytes))" }
            lines.append("Biggest inside: " + b.joined(separator: ", "))
        }
        lines += c.markers
        return lines.joined(separator: "\n")
    }

    /// Roomy's own limits on top of the model: some answers are never "review".
    static func guarded(_ a: FolderAdvice, _ c: FolderClues) -> FolderAdvice {
        var a = a
        guard a.verdict == .review else { return a }
        if a.kind == .userFiles {
            a.verdict = .keep
            a.override = "Roomy never suggests removing your own files."
        } else if a.kind == .appData, c.owner?.installed == true {
            a.verdict = .keep
            a.override = "\(c.owner!.name) is installed, so its data stays."
        } else if c.owner?.running == true {
            a.verdict = .keep
            a.override = "\(c.owner!.name) is running and using it."
        } else if c.markers.contains(where: { $0.contains("git repository") }) {
            a.verdict = .keep
            a.override = "It's a git repository; Roomy's old-project check handles those."
        }
        return a
    }
}

// MARK: - Rules you accepted

/// Folders you agreed to review, kept as an engine rules file. The engine
/// lists them under Review first and cleans them like any other rule, with
/// all its checks: they only ever go to the Trash, after you confirm.
struct UserRules: Sendable {
    let file: URL
    let home: String

    static var standard: UserRules {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Roomy")
        return UserRules(file: dir.appending(path: "rules.toml"), home: NSHomeDirectory())
    }

    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// A stable id per folder.
    static func id(for path: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return "user-" + String(h, radix: 16)
    }

    /// The path as a glob that matches only itself, `~` for home.
    static func pattern(_ path: String, home: String) -> String {
        var p = path
        var prefix = ""
        if p.hasPrefix(home + "/") {
            prefix = "~/"
            p = String(p.dropFirst(home.count + 1))
        }
        let escaped = p.map { ch -> String in "[]*?".contains(ch) ? "[\(ch)]" : String(ch) }.joined()
        return prefix + escaped
    }

    static func tomlString(_ s: String) -> String {
        let body = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(body)\""
    }

    static func entry(path: String, name: String, explain: String, home: String) -> String {
        """

        [[rule]]
        id = \(tomlString(id(for: path)))
        name = \(tomlString(name))
        category = "ai"
        risk = "review"
        explain = \(tomlString(explain))
        match = { path = \(tomlString(pattern(path, home: home))) }

        """
    }

    func contains(_ path: String) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("id = \"\(UserRules.id(for: path))\"")
    }

    func add(path: String, name: String, explain: String) throws {
        guard !contains(path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: file, encoding: .utf8))
            ?? "# Folders you agreed to review in Roomy. Each one is listed under \"Review first\".\n"
        text += UserRules.entry(path: path, name: name, explain: explain, home: home)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Drop the rule for this folder.
    func remove(_ path: String) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let id = "id = \"\(UserRules.id(for: path))\""
        let blocks = text.components(separatedBy: "\n[[rule]]\n")
        let kept = blocks.enumerated().filter { i, b in i == 0 || !b.contains(id) }.map(\.element)
        try kept.joined(separator: "\n[[rule]]\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func count() -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "[[rule]]").count - 1
    }
}
