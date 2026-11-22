import Foundation
import Testing

@Test func bytesMatchCli() {
    #expect(formatBytes(999) == "999 B")
    #expect(formatBytes(1_500) == "2 KB")
    #expect(formatBytes(25_000_000) == "25 MB")
    #expect(formatBytes(2_900_000_000) == "2.9 GB")
    #expect(formatBytes(61_800_000_000) == "61.8 GB")
}

@Test func tildePaths() {
    #expect(tildePath("/Users/me/x", home: "/Users/me") == "~/x")
    #expect(tildePath("/Users/me", home: "/Users/me") == "~")
    #expect(tildePath("/opt/x", home: "/Users/me") == "/opt/x")
    #expect(tildePath("/Users/meow/x", home: "/Users/me") == "/Users/meow/x")
}

@Test func agoText() {
    let now = Date()
    #expect(formatAgo(now.addingTimeInterval(-20), now: now) == "just now")
    #expect(formatAgo(now.addingTimeInterval(-125), now: now) == "2 min ago")
    #expect(formatAgo(now.addingTimeInterval(-3 * 3600 - 10), now: now) == "3 h ago")
    #expect(formatAgo(now.addingTimeInterval(-50 * 3600), now: now) == "2 days ago")
}

@Test func friendlyPaths() {
    let tmp = "/var/folders/77/abc"
    #expect(friendlyPath("/Users/me/.cargo", home: "/Users/me", tmpRoot: tmp) == "~/.cargo")
    #expect(friendlyPath("/var/folders/77/abc/C/clang/ModuleCache", home: "/Users/me", tmpRoot: tmp) == "Temp/C/clang/ModuleCache")
    #expect(friendlyPath("/private/var/folders/77/abc/T/_MEI1", home: "/Users/me", tmpRoot: tmp) == "Temp/T/_MEI1")
    #expect(friendlyPath("/opt/x", home: "/Users/me", tmpRoot: nil) == "/opt/x")
}

@Test func commandsShowTilde() {
    #expect(shortCommand("cargo clean --manifest-path '/Users/me/My App'/Cargo.toml", home: "/Users/me")
            == "cargo clean --manifest-path ~/'My App'/Cargo.toml")
    #expect(shortCommand("brew cleanup", home: "/Users/me") == "brew cleanup")
}

@Test func appOwnerFromPath() {
    #expect(appOwner("/Users/me/Library/Application Support/Notion/Partitions/notion/Cache") == "Notion")
    #expect(appOwner("/Users/me/.cache/uv") == nil)
}
