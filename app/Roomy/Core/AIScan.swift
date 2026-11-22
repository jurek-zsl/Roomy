import Foundation

/// What the AI answers for a whole-disk scan.
struct AIScanReply: Decodable, Sendable {
    struct Item: Decodable, Sendable, Equatable {
        let path: String
        let what: String
        let kind: FolderKind
        let regrows: Regrows
    }
    let overview: String
    let suggestions: [Item]
}

/// One folder the AI suggested, after Roomy looked at it and decided.
struct AISuggestion: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bytes: Int64
    let advice: FolderAdvice
}

struct AIScanResult: Equatable, Sendable {
    let overview: String
    let suggestions: [AISuggestion]
    let advisor: String
    let date: Date
}

/// The AI sees the whole disk map in one request, so a person doesn't have
/// to ask about folders one by one. Roomy checks every answer.
enum AIScanPrompt {
    static let instructions = """
    You help someone free disk space on their Mac. You get a map of the whole disk from Roomy, a cleaning app: \
    folders with their sizes, nested by indentation. [Roomy frees X] means Roomy's own rules already handle that much there. \
    A name after a dash (— uv cache) is what Roomy's own list of known folders says the folder is; Roomy already reviews those itself.
    Find the folders that are most likely safe to remove, or worth reviewing, that Roomy doesn't already handle or know. \
    Use what you know about macOS, developer tools, AI tools and common apps.
    Rules:
    - Copy each path exactly as it's written in the map. Don't invent paths or folders the map doesn't list.
    - Pick the most specific folder that holds the removable data, not a parent that also holds data the person needs.
    - Never suggest the person's own files (documents, photos, music, videos, projects, code) or apps in /Applications.
    - Never suggest data an installed app needs: databases, chat history, sessions, settings, saved games, mail, messages, libraries, backups.
    - Never suggest macOS itself or what it manages (/System, /usr, /private/var/vm, /private/var/db).
    - Good candidates: caches, logs, downloaded AI models, package manager caches, old installers and disk images, \
    build output, simulator runtimes, and leftovers of apps that aren't installed anymore (the installed apps are listed).
    - For each, say in one or two plain sentences what it is and whose it is, its kind, and whether it comes back \
    by itself if removed. Don't say whether to delete it; Roomy decides that.
    - Biggest first, at most 25. If nothing is worth it, return an empty list.
    - overview: two or three plain sentences on where the space goes and the biggest opportunities.
    """

    static let schema = """
    {"type":"object","properties":{"overview":{"type":"string"},"suggestions":{"type":"array","items":\
    {"type":"object","properties":{"path":{"type":"string"},"what":{"type":"string"},\
    "kind":{"type":"string","enum":[\(FolderKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},\
    "regrows":{"type":"string","enum":["yes","no","unsure"]}},"required":["path","what","kind","regrows"],\
    "additionalProperties":false}}},"required":["overview","suggestions"],"additionalProperties":false}
    """

    /// The map as indented lines. Personal folders show only their size
    /// unless `includePersonal`.
    static func outline(_ map: DiskMap, home: String, includePersonal: Bool, apps: [String],
                        minBytes: Int64 = 100_000_000) -> String {
        var lines: [String] = []
        if let used = map.usedBytes, let total = map.totalBytes, let free = map.freeBytes {
            lines.append("Disk: \(formatBytes(used)) used of \(formatBytes(total)), \(formatBytes(free)) free.")
        }
        if let sys = map.systemBytes, sys > 0 {
            lines.append("About \(formatBytes(sys)) is macOS itself and system data the map doesn't reach.")
        }
        if !apps.isEmpty {
            lines.append("Installed apps: " + apps.sorted().joined(separator: ", "))
        }
        lines.append("")
        func walk(_ n: MapNode, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let path = tildePath(n.path, home: home)
            let size = formatBytes(n.bytes)
            let frees = n.cleanable > 0 ? " [Roomy frees \(formatBytes(n.cleanable))]" : ""
            let known = n.known.flatMap { $0.isGeneral ? nil : " — \($0.name)" } ?? ""
            switch n.kind {
            case .other, .unreadable:
                return
            case .files:
                lines.append("\(pad)\(path)/ (loose files) \(size)")
            case .bundle:
                lines.append("\(pad)\(path) \(size) (app)\(frees)\(known)")
            case .personal where !includePersonal:
                lines.append("\(pad)\(path) \(size) (your files; contents not shared)")
            default:
                lines.append("\(pad)\(path) \(size)\(frees)\(known)")
                // Inside one tool's cache, model or build folder that Roomy knows,
                // there's nothing more to tell; a folder of many tools' caches goes on.
                if let k = n.known, !k.isGeneral, reviewKinds.contains(k.kind),
                   n.children.allSatisfy({ ($0.known?.owner ?? k.owner) == k.owner }) { return }
                for c in n.children where c.bytes >= minBytes { walk(c, depth + 1) }
            }
        }
        for r in map.roots { walk(r, 0) }
        return lines.joined(separator: "\n")
    }

    /// Keep only real folders from the map, once each, not nested in another
    /// suggestion, never your home or a top folder. Biggest first.
    static func validate(_ reply: AIScanReply, map: DiskMap, home: String,
                         limit: Int = 30) -> [(node: MapNode, item: AIScanReply.Item)] {
        var nodes: [String: MapNode] = [:]
        func index(_ n: MapNode) {
            if n.kind == .folder || n.kind == .bundle { nodes[n.path] = n }
            n.children.forEach(index)
        }
        map.roots.forEach(index)
        let tooBroad: Set<String> = Set(["/", home, "/Users", "/Applications", "/Library", "/System", "/private", "/opt", "/usr"])
        var picked: [(node: MapNode, item: AIScanReply.Item)] = []
        for item in reply.suggestions {
            let path = item.path.hasPrefix("~/") ? home + item.path.dropFirst(1) : item.path
            guard let node = nodes[path], !tooBroad.contains(path), !picked.contains(where: { $0.node.path == path }) else { continue }
            picked.append((node, item))
        }
        let paths = picked.map(\.node.path)
        picked.removeAll { p in paths.contains { $0 != p.node.path && p.node.path.hasPrefix($0 + "/") } }
        return Array(picked.sorted { $0.node.bytes > $1.node.bytes }.prefix(limit))
    }

    /// Kinds Roomy reviews when they come back by itself (or always, for logs and installers).
    static let reviewKinds: Set<FolderKind> = [.cache, .aiModels, .buildOutput, .logs, .installers]

    /// Folders Roomy's own list says are worth reviewing, no AI needed: the
    /// most specific known ones, outside your own folders and macOS, that
    /// Roomy's rules don't already clean. Biggest first.
    static func knownCandidates(_ map: DiskMap, home: String, min: Int64 = 50_000_000, limit: Int = 30) -> [MapNode] {
        func worth(_ n: MapNode) -> Bool {
            guard let k = n.known, n.kind == .folder || n.kind == .bundle, reviewKinds.contains(k.kind) else { return false }
            return AdvisorPrompt.decide(kind: k.kind, regrows: k.regrows).verdict == .review
        }
        func yours(_ path: String) -> Bool {
            AdvisorPrompt.yourFolders.contains { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }
        }
        func collect(_ n: MapNode) -> [MapNode] {
            guard n.kind != .personal, n.bytes >= min, !yours(n.path) else { return [] }
            let deeper = n.children.flatMap(collect)
            // A folder that holds several tools' caches (~/.cache) gives way to
            // what's inside it; one tool's own folder (uv's cache) stays whole.
            if worth(n), let owner = n.known?.owner {
                return deeper.allSatisfy { $0.known?.owner == owner } ? [n] : deeper
            }
            return deeper
        }
        let picked = map.roots.flatMap(collect).filter { $0.cleanable * 2 < $0.bytes }
        return Array(picked.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Names of the apps in /Applications and ~/Applications.
    static func installedApps(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        return ["/Applications", "/Applications/Utilities", home + "/Applications"].flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
    }
}
