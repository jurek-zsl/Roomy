import AppKit
import SwiftUI

extension Section {
    var title: String {
        switch self {
        case .safeNow: "Safe to clean now"
        case .review: "Review first"
        case .blocked: "In use right now"
        }
    }

    var subtitle: String {
        switch self {
        case .safeNow: "Caches and build output. Apps and tools make them again when needed."
        case .review: "Might hold something you want. Tick what you don't need; these go to the Trash."
        case .blocked: "An app or tool is using these. Quit it, then scan again."
        }
    }

    var symbol: String {
        switch self {
        case .safeNow: "checkmark.seal.fill"
        case .review: "eye.fill"
        case .blocked: "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safeNow: .green
        case .review: .orange
        case .blocked: .secondary
        }
    }
}

/// Icon and colour for a kind of item.
struct CategoryStyle {
    let symbol: String
    let tint: Color

    init(_ category: String) {
        switch category {
        case "package-cache": (symbol, tint) = ("shippingbox.fill", .blue)
        case "build-output": (symbol, tint) = ("hammer.fill", .purple)
        case "app-cache": (symbol, tint) = ("app.dashed", .teal)
        case "developer": (symbol, tint) = ("chevron.left.forwardslash.chevron.right", .indigo)
        case "leftover", "old-version": (symbol, tint) = ("clock.arrow.circlepath", .brown)
        case "temp": (symbol, tint) = ("tray.full.fill", .gray)
        default: (symbol, tint) = ("folder.fill", .gray)
        }
    }
}

extension Method {
    /// Short badge text; nil for a plain delete.
    var badge: String? {
        switch self {
        case .delete: nil
        case .trash: "→ Trash"
        case .command(let c): "via \(c.split(separator: " ").first ?? "tool")"
        }
    }

    var sentence: String {
        switch self {
        case .delete: "Deleted right away."
        case .trash: "Moved to the Trash, so you can get it back. The space comes back when you empty the Trash."
        case .command(let c): "Cleaned by its own tool: \(shortCommand(c))"
        }
    }
}

extension CleanerStore {
    /// What Clean will really do with this item, with the Trash setting applied.
    func method(for f: Finding) -> Method {
        trashInstead ? .trash : f.method
    }
}

/// Real app icons for per-app caches ("Notion web cache").
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for app: String) -> NSImage? {
        if let hit = cache[app] { return hit }
        let names = [app, app.capitalized]
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
        let found = dirs.lazy.flatMap { d in names.map { "\(d)/\($0).app" } }
            .first { FileManager.default.fileExists(atPath: $0) }
        let image = found.map { NSWorkspace.shared.icon(forFile: $0) }
        cache[app] = image
        return image
    }

    static func running(_ app: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
                || $0.bundleURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(app) == .orderedSame
        }
    }
}

/// Rules that belong to one app, for its icon.
private func ruleApp(_ rule: String) -> String? {
    if rule.hasPrefix("xcode") || rule.hasPrefix("simulator") { return "Xcode" }
    if rule.hasPrefix("roblox") { return "Roblox" }
    if rule.hasPrefix("godot") { return "Godot" }
    return nil
}

/// The square icon in front of each item.
struct ItemIcon: View {
    let finding: Finding
    var size: CGFloat = 28

    var body: some View {
        if let app = appOwner(finding.path) ?? ruleApp(finding.rule), let image = AppIcons.icon(for: app) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size + 4, height: size + 4)
                .padding(-2)
        } else {
            let style = CategoryStyle(finding.category)
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(style.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

/// Used / safe / review / free, as one bar.
struct StorageBar: View {
    let s: StorageBreakdown
    var height: CGFloat = 12
    var showLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let total = max(Double(s.total), 1)
                let w = { (b: Int64) in max(0, geo.size.width * Double(b) / total) }
                HStack(spacing: 2) {
                    Rectangle().fill(Color.primary.opacity(0.28)).frame(width: w(s.used))
                    Rectangle().fill(Color.green.gradient).frame(width: max(w(s.safe), s.safe > 0 ? 3 : 0))
                    Rectangle().fill(Color.orange.gradient).frame(width: max(w(s.review), s.review > 0 ? 3 : 0))
                    Rectangle().fill(Color.primary.opacity(0.07))
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel("Disk: \(formatBytes(s.used)) used, \(formatBytes(s.safe)) safe to clean, \(formatBytes(s.review)) to review, \(formatBytes(s.free)) free")
            if showLegend {
                HStack(spacing: 16) {
                    legend(Color.primary.opacity(0.28), "Used", s.used)
                    legend(.green, "Safe to clean", s.safe)
                    legend(.orange, "Review", s.review)
                    legend(Color.primary.opacity(0.12), "Free", s.free)
                }
                .font(.caption)
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(formatBytes(bytes)).monospacedDigit()
        }
    }
}
