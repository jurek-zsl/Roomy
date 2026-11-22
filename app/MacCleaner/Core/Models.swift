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
