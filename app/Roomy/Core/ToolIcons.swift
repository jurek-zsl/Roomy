import AppKit

/// The real Claude, ChatGPT and Gemini icons, taken from the apps on this
/// Mac. Roomy ships no logos; without the app it shows a plain badge.
@MainActor
enum ToolIcons {
    private static var cache: [CLIAdvisor.Tool: NSImage?] = [:]

    nonisolated static func appPath(for tool: CLIAdvisor.Tool,
                                    lookup: (String) -> String? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }) -> String? {
        tool.appIDs.lazy.compactMap(lookup).first
    }

    static func icon(for tool: CLIAdvisor.Tool) -> NSImage? {
        if let hit = cache[tool] { return hit }
        let image = appPath(for: tool).map { NSWorkspace.shared.icon(forFile: $0) }
        cache[tool] = image
        return image
    }
}

