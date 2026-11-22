import Foundation

// The engine's JSON (`scan --json`, `clean --json`). The app shows these
// decisions as they are: it never works out on its own what is junk.

enum Section: String, Decodable, Sendable, CaseIterable {
    case safeNow = "safe-now"
    case review
    case blocked
}

enum Risk: String, Decodable, Sendable {
    case safe
    case quitApp = "quit-app"
    case review
}

enum Status: String, Decodable, Sendable {
    case ready
    case review
    case blocked
}

/// What `clean` does with an item.
enum Method: Decodable, Sendable, Hashable {
    case delete
    case trash
    case command(String)

    private enum Keys: String, CodingKey { case kind, command }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "delete": self = .delete
        case "trash": self = .trash
        case "command": self = .command(try c.decode(String.self, forKey: .command))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown method \(other)")
        }
    }
}

struct Finding: Decodable, Sendable, Equatable, Identifiable {
    var id: String { path }
    let rule: String
    let name: String
    let category: String
    let risk: Risk
    let status: Status
    let section: Section
    let reason: String?
    let path: String
    let bytesOnDisk: Int64
    let bytesFreed: Int64
    let files: Int64
    let clean: String?
    let explain: String
    let method: Method
    /// Context a finder added ("Last opened 7 months ago.").
    var detail: String? = nil
    /// What Clean does when "Move to the Trash instead" is on. Tool-only
    /// items (git, simulators) keep their tool even then.
    var trashMethod: Method? = nil
}

// MARK: - Space map (`map --json`)

enum MapKind: String, Decodable, Sendable {
    case folder, bundle, personal, files, other, unreadable
}

struct MapNode: Decodable, Sendable, Equatable, Identifiable, Hashable {
    /// Grouped rows ("Smaller items") share their parent's path, so the name is part of the id.
    var id: String { "\(path)#\(name)" }
    let path: String
    let name: String
    let kind: MapKind
    let bytes: Int64
    let cleanable: Int64
    let children: [MapNode]
    /// What Roomy's list of known folders says it is.
    var known: KnownFolder? = nil

    var canOpen: Bool { !children.isEmpty }
}

struct DiskMap: Decodable, Sendable, Equatable {
    let totalBytes: Int64?
    let usedBytes: Int64?
    let freeBytes: Int64?
    let mappedBytes: Int64
    let cleanableBytes: Int64
    let elapsedMs: Int64
    let roots: [MapNode]

    /// The top folders: of the disk (`/`) when it's mapped whole, else the roots.
    var places: [MapNode] {
        guard roots.count == 1, roots[0].path == "/" else { return roots }
        return roots[0].children.filter { $0.kind == .folder || $0.kind == .bundle || $0.kind == .personal }
    }

    /// macOS manages these itself (swap, system databases); never worth a look.
    static let managedByMacOS = ["/private/var/vm", "/private/var/db"]

    /// Used space the map doesn't reach: macOS itself, system data, snapshots.
    var systemBytes: Int64? { usedBytes.map { max(0, $0 - mappedBytes) } }

    /// The most specific big folders the rules barely explain (under a tenth
    /// cleanable). Your own files are left out. Biggest first.
    func unexplained(min: Int64 = 1_000_000_000, limit: Int = 8) -> [MapNode] {
        func managed(_ n: MapNode) -> Bool {
            DiskMap.managedByMacOS.contains { n.path == $0 || n.path.hasPrefix($0 + "/") }
        }
        func managedBytes(_ n: MapNode) -> Int64 {
            managed(n) ? n.bytes : n.children.reduce(0) { $0 + managedBytes($1) }
        }
        func qualifies(_ n: MapNode) -> Bool {
            // Size without what macOS manages inside it.
            let own = n.bytes - n.children.reduce(0) { $0 + managedBytes($1) }
            return n.kind == .folder && !managed(n) && n.known?.kind != .system && own >= min && n.cleanable * 10 < own
        }
        func collect(_ n: MapNode, into out: inout [MapNode]) {
            var deeper: [MapNode] = []
            for c in n.children where c.kind == .folder && !managed(c) { collect(c, into: &deeper) }
            if deeper.isEmpty, qualifies(n) { out.append(n) } else { out += deeper }
        }
        var out: [MapNode] = []
        for r in roots {
            for c in r.children { collect(c, into: &out) }
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    static func decode(_ data: Data) throws -> DiskMap {
        try engineDecoder().decode(DiskMap.self, from: data)
    }
}

struct ScanResult: Decodable, Sendable, Equatable {
    let freeBytes: Int64?
    let elapsedMs: Int64
    let findings: [Finding]

    static func decode(_ data: Data) throws -> ScanResult {
        try engineDecoder().decode(ScanResult.self, from: data)
    }
}

enum Outcome: Decodable, Sendable, Equatable {
    case cleaned(Method, note: String?)
    case skipped(reason: String)
    case failed(Method?, error: String)

    private enum Keys: String, CodingKey { case result, method, note, reason, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .result) {
        case "cleaned":
            self = .cleaned(try c.decode(Method.self, forKey: .method), note: try c.decodeIfPresent(String.self, forKey: .note))
        case "skipped":
            self = .skipped(reason: try c.decode(String.self, forKey: .reason))
        case "failed":
            self = .failed(try c.decodeIfPresent(Method.self, forKey: .method), error: try c.decode(String.self, forKey: .error))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .result, in: c, debugDescription: "unknown result \(other)")
        }
    }
}

struct CleanItem: Decodable, Sendable, Equatable {
    let index: Int
    let path: String
    let rule: String
    let name: String
    let bytes: Int64
    let outcome: Outcome
}

struct CleanDone: Decodable, Sendable, Equatable {
    let cleaned: Int
    let skipped: Int
    let failed: Int
    let freeBefore: Int64?
    let freeAfter: Int64?
    let trashedBytes: Int64
}

/// One line of `clean --json`.
enum CleanEvent: Sendable, Equatable {
    case plan(items: Int, bytes: Int64)
    case item(CleanItem)
    case done(CleanDone)
    case error(String)

    static func decode(line: String) throws -> CleanEvent {
        let data = Data(line.utf8)
        let d = engineDecoder()
        struct Head: Decodable { let event: String }
        struct Plan: Decodable { let items: Int; let bytes: Int64 }
        struct Failure: Decodable { let message: String }
        switch try d.decode(Head.self, from: data).event {
        case "plan":
            let p = try d.decode(Plan.self, from: data)
            return .plan(items: p.items, bytes: p.bytes)
        case "item": return .item(try d.decode(CleanItem.self, from: data))
        case "done": return .done(try d.decode(CleanDone.self, from: data))
        case "error": return .error(try d.decode(Failure.self, from: data).message)
        case let other: throw EngineError.badOutput("unknown event `\(other)`")
        }
    }
}

enum EngineError: Error, Equatable, LocalizedError {
    /// The engine isn't inside the app.
    case missing
    /// It ended with an error; carries the last lines it printed.
    case failed(String)
    /// It printed something that isn't the JSON we expect.
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missing: "The cleaning engine is missing from the app. Build the app again."
        case .failed(let why): "The engine stopped: \(why)"
        case .badOutput(let what): "The engine sent something unexpected: \(what)"
        }
    }
}

func engineDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}
