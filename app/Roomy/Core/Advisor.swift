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
    /// The command it runs isn't on this Mac.
    case notInstalled

    var message: String {
        switch self {
        case .ready: "Apple Intelligence is ready."
        case .notEnabled: "Turn on Apple Intelligence in System Settings to get an explanation written on this Mac."
        case .notReady: "Apple Intelligence is still getting ready (the model may be downloading). Try again in a while."
        case .notSupported: "This Mac can't run Apple Intelligence. The facts below are still Roomy's own."
        case .notInstalled: "It isn't installed on this Mac."
        }
    }
}

/// Something that can explain a folder from its clues.
protocol FolderAdvisor: Sendable {
    var id: String { get }
    var name: String { get }
    /// True when the facts go to a company's servers, so Roomy asks first.
    var sendsOffMac: Bool { get }
    func status() -> AdvisorStatus
    func statusMessage(_ status: AdvisorStatus) -> String
    func advise(_ clues: FolderClues) async throws -> FolderAdvice
}

extension FolderAdvisor {
    var id: String { name }
    var sendsOffMac: Bool { false }
    func statusMessage(_ status: AdvisorStatus) -> String { status.message }
}

enum AdvisorPrompt {
    static let instructions = """
    You explain one folder on a Mac to its owner, using facts a disk scan gathered. \
    Say what the folder holds, what kind of content it is, and whether it comes back by itself if it's removed.
    Rules:
    - Use only the facts. Don't invent app names or details.
    - In the summary, name the app or tool it belongs to and what the biggest items are, in plain words. Don't start with "This folder".
    - Databases, chat history, sessions, settings and saved games are app data.
    - Disk images (.img) or virtual machines that a running app uses are app data.
    - Packages, runtimes, wheels or models that a tool downloaded for itself are cache or AI models, and they come back.
    - Photos, videos, audio, documents, projects and code are the user's files, including renders and exports inside a project.
    - Build output is only what a compiler or bundler makes inside a project.
    - The summary is at most two sentences. Don't say whether to delete it; Roomy decides that.
    - It comes back ("yes") only if the app or tool downloads or rebuilds it by itself when it's missing.
    """

    /// Roomy's verdict from what the model saw. A small model labels
    /// folders well but weighs decisions poorly, so the rule lives here.
    static func decide(kind: FolderKind, regrows: Regrows) -> (verdict: AdviceVerdict, why: String) {
        switch (kind, regrows) {
        case (.leftover, _): (.review, "It looks like what's left of an app or tool that isn't on this Mac anymore.")
        case (.installers, _): (.review, "Installers and disk images aren't needed once the app is installed.")
        case (.logs, _): (.review, "Logs only help with fixing problems; nothing needs them to run.")
        case (.cache, .yes): (.review, "It's a cache that comes back by itself when it's needed.")
        case (.aiModels, .yes): (.review, "These AI models download again the next time they're needed.")
        case (.buildOutput, .yes): (.review, "It's build output that's made again on the next build.")
        case (.cache, _), (.aiModels, _), (.buildOutput, _): (.keep, "It may not come back by itself, so leave it unless you know you don't need it.")
        case (.userFiles, _): (.keep, "It looks like your own files.")
        case (.appData, _): (.keep, "It looks like app data, such as history, settings or saved work.")
        case (.toolchain, _): (.keep, "These are developer tools; remove them from the tool itself if you don't use them.")
        case (.unknown, _): (.keep, "It's not clear what this is, so it's safer to leave it.")
        }
    }

    /// The model's reading, decided by Roomy and held to its limits.
    static func advice(summary: String, kind: FolderKind, regrows: Regrows, clues: FolderClues,
                       home: String = NSHomeDirectory()) -> FolderAdvice {
        // "Leftover" needs a fact behind it: an owner that isn't installed.
        let kind = kind == .leftover && clues.owner?.installed != false ? .unknown : kind
        let d = decide(kind: kind, regrows: regrows)
        return guarded(FolderAdvice(summary: summary, kind: kind, regrows: regrows, verdict: d.verdict, why: d.why), clues, home: home)
    }

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
    /// Folders that hold what you made; Downloads is left out on purpose.
    static let yourFolders = ["Documents", "Desktop", "Movies", "Pictures", "Music"]

    static func guarded(_ a: FolderAdvice, _ c: FolderClues, home: String = NSHomeDirectory()) -> FolderAdvice {
        var a = a
        guard a.verdict == .review else { return a }
        if let top = yourFolders.first(where: { c.path.hasPrefix(home + "/" + $0 + "/") }) {
            a.verdict = .keep
            a.override = "It's inside your \(top) folder, so Roomy leaves it to you."
        } else if a.kind == .userFiles {
            a.verdict = .keep
            a.override = "Roomy never suggests removing your own files."
        } else if a.kind == .appData, c.owner?.installed == true {
            a.verdict = .keep
            a.override = "\(c.owner!.name) is installed, so its data stays."
        } else if c.owner?.running == true {
            a.verdict = .keep
            a.override = "\(c.owner!.name) is running and using it."
        } else if c.markers.contains(where: { $0.contains("databases") }), a.kind != .leftover {
            a.verdict = .keep
            a.override = "It has databases, which usually hold an app's own data."
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
