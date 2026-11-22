import Foundation
import Testing

private func n(_ p: String, _ gb: Double, kind: MapKind = .folder, cleanable: Double = 0, _ kids: [MapNode] = []) -> MapNode {
    MapNode(path: p, name: (p as NSString).lastPathComponent, kind: kind, bytes: Int64(gb * 1e9),
            cleanable: Int64(cleanable * 1e9), children: kids)
}

private let map = DiskMap(totalBytes: 500_000_000_000, usedBytes: 300_000_000_000, freeBytes: 200_000_000_000,
                          mappedBytes: 250_000_000_000, cleanableBytes: 0, elapsedMs: 1, roots: [
    n("/", 250, [
        n("/Users", 200, [n("/Users/me", 200, [
            n("/Users/me/Documents", 50, kind: .personal, [n("/Users/me/Documents/secret-project", 50)]),
            n("/Users/me/.cache", 20, [n("/Users/me/.cache/uv", 12), n("/Users/me/.cache/uv/wheels", 8)]),
            n("/Users/me/Library/Caches", 5, cleanable: 4),
            n("/Users/me", 0.5, kind: .files),
            n("/Users/me", 0.2, kind: .other),
        ])]),
        n("/Applications", 30, [n("/Applications/Xcode.app", 30, kind: .bundle)]),
    ]),
])

@Test func outlineIsTheWholeDiskInPlainLines() {
    let o = AIScanPrompt.outline(map, home: "/Users/me", includePersonal: false, apps: ["Xcode", "Safari"])
    #expect(o.contains("Disk: 300.0 GB used of 500.0 GB, 200.0 GB free"))
    #expect(o.contains("    ~/.cache 20.0 GB"))
    #expect(o.contains("~/Library/Caches 5.0 GB [Roomy frees 4.0 GB]"))
    #expect(o.contains("~/Documents 50.0 GB (your files; contents not shared)"))
    #expect(!o.contains("secret-project"), "personal folders stay private by default")
    #expect(o.contains("/Applications/Xcode.app 30.0 GB (app)"))
    #expect(!o.contains("Smaller items") && !o.contains("other"))
    #expect(o.contains("Installed apps: Safari, Xcode"))
    #expect(AIScanPrompt.outline(map, home: "/Users/me", includePersonal: true, apps: []).contains("secret-project"))
}

@Test func onlyPathsFromTheMapSurvive() throws {
    let reply = try JSONDecoder().decode(AIScanReply.self, from: Data(#"""
    {"overview":"o","suggestions":[
      {"path":"~/.cache/uv/wheels","what":"w","kind":"cache","regrows":"yes"},
      {"path":"~/.cache/uv","what":"uv's cache","kind":"cache","regrows":"yes"},
      {"path":"/Users/me/made-up","what":"x","kind":"cache","regrows":"yes"},
      {"path":"~/.cache/uv","what":"again","kind":"cache","regrows":"yes"},
      {"path":"/Users/me","what":"loose files","kind":"cache","regrows":"yes"}
    ]}
    """#.utf8))
    let kept = AIScanPrompt.validate(reply, map: map, home: "/Users/me")
    #expect(kept.map(\.node.path) == ["/Users/me/.cache/uv"], "made-up paths, duplicates, nested ones and home itself go")
    #expect(kept.first?.item.what == "uv's cache")
}

