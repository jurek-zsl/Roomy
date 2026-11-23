import Foundation

/// A report of big folders Roomy can't explain, for people without an AI
/// agent: it becomes a GitHub issue, and the folders get added to the
/// known list in a later update. Paths start at ~, so your user name stays out.
enum UnknownReport {
    static let newIssue = "https://github.com/jurek-zsl/Roomy/issues/new"
    /// GitHub turns down much longer links.
    static let maxBody = 6_000

    /// Markdown for the issue: one row per folder, with the biggest things
    /// inside it as a clue, and what the person knows.
    static func body(_ folders: [MapNode], home: String, note: String, version: String, macOS: String) -> String {
        var lines = ["Big folders Roomy doesn't know yet (Roomy \(version), macOS \(macOS)).", "",
                     "| Folder | Size | Biggest inside |", "|---|---|---|"]
        for f in folders {
            let inside = f.children.filter { $0.kind != .other }.sorted { $0.bytes > $1.bytes }.prefix(3)
                .map { "\($0.name) \(formatBytes($0.bytes))" }.joined(separator: ", ")
            let row = "| `\(tildePath(f.path, home: home))` | \(formatBytes(f.bytes)) | \(inside.isEmpty ? "–" : inside) |"
            if (lines + [row]).joined(separator: "\n").count > maxBody - 600 { break }
            lines.append(row)
        }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        lines += ["", "**What I know about them:** \(n.isEmpty ? "Nothing yet." : String(n.prefix(500)))"]
        return lines.joined(separator: "\n")
    }

    static func url(body: String) -> URL? {
        var c = URLComponents(string: newIssue)
        c?.queryItems = [URLQueryItem(name: "title", value: "Folders Roomy doesn't know"),
                         URLQueryItem(name: "labels", value: "known-folders"),
                         URLQueryItem(name: "body", value: body)]
        return c?.url
    }
}
