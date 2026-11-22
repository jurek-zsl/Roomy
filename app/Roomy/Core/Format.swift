import Foundation

/// Decimal units, the same as the engine's report and Finder.
func formatBytes(_ b: Int64) -> String {
    let d = Double(b)
    if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.0f MB", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0f KB", d / 1e3) }
    return "\(b) B"
}

/// Paths under home shown as `~/...`.
func tildePath(_ p: String, home: String = NSHomeDirectory()) -> String {
    if p == home { return "~" }
    if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
    return p
}

func formatAgo(_ date: Date, now: Date = .now) -> String {
    let s = now.timeIntervalSince(date)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86_400 { return "\(Int(s / 3600)) h ago" }
    let days = Int(s / 86_400)
    return days == 1 ? "1 day ago" : "\(days) days ago"
}

/// The per-user temp area (`/var/folders/xx/yyy`), the engine's `$USERTMP`.
let userTmpRoot: String? = {
    let t = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
    guard t.lastPathComponent == "T", t.path.contains("/var/folders/") else { return nil }
    return t.deletingLastPathComponent().path
}()

/// `~/...` for home, `Temp/...` for the per-user temp area.
func friendlyPath(_ p: String, home: String = NSHomeDirectory(), tmpRoot: String? = userTmpRoot) -> String {
    if let t = tmpRoot {
        let bare = t.hasPrefix("/private/") ? String(t.dropFirst("/private".count)) : t
        for root in [bare, "/private" + bare] where p.hasPrefix(root + "/") {
            return "Temp" + p.dropFirst(root.count)
        }
    }
    return tildePath(p, home: home)
}

/// A clean command with the home folder shown as `~`, still valid to paste.
func shortCommand(_ c: String, home: String = NSHomeDirectory()) -> String {
    c.replacingOccurrences(of: "'\(home)/", with: "~/'").replacingOccurrences(of: home, with: "~")
}

/// `.../Application Support/Notion/...` → "Notion".
func appOwner(_ path: String) -> String? {
    let parts = path.split(separator: "/")
    guard let i = parts.firstIndex(of: "Application Support"), i + 1 < parts.count else { return nil }
    return String(parts[i + 1])
}

/// How the disk splits up, for the storage bar.
struct StorageBreakdown: Equatable, Sendable {
    let total: Int64
    let free: Int64
    let safe: Int64
    let review: Int64
    /// Everything else. Never negative, even if the numbers disagree a little.
    var used: Int64 { max(0, total - free - safe - review) }
}
