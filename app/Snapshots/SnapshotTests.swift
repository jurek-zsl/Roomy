import AppKit
import SwiftUI
import Testing

/// Renders the app's screens off-screen into PNGs (no screen capture), so the
/// design can be checked without opening the app. Output: app/build/snapshots/
@MainActor
enum Snap {
    static let dir: URL = {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let d = here.deletingLastPathComponent().appending(path: "build/snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func render<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.windowBackground))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (lists lay out a pass later).
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: dir.appending(path: "\(name)\(dark ? "-dark" : "").png"))
    }
}

final class FixtureEngine: CleanEngine, @unchecked Sendable {
    let result: ScanResult
    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "scan.json")
        result = try ScanResult.decode(Data(contentsOf: url))
    }
    func scan() async throws -> ScanResult { result }
    func inspect(path: String) async throws -> FolderClues {
        FolderClues(path: path, name: "huggingface", bytes: 4_100_000_000, files: 212, folders: 40, newestDays: 96,
                    types: [TypeShare(ext: "safetensors", bytes: 3_800_000_000, files: 9), TypeShare(ext: "json", bytes: 2_000_000, files: 60)],
                    biggest: [FolderItem(name: "hub", bytes: 4_000_000_000, folder: true), FolderItem(name: "xet", bytes: 90_000_000, folder: true)],
                    owner: FolderOwner(name: "huggingface", kind: "tool", installed: nil, running: false),
                    markers: ["93% of it is AI model weight files (.safetensors, .gguf, .bin, ...); they download again when needed."])
    }

    func map() async throws -> DiskMap {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "map.json")
        return try DiskMap.decode(Data(contentsOf: url))
    }
    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
func scannedStore() async throws -> CleanerStore {
    let d = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
    d.set(true, forKey: "seenIntro")
    let store = CleanerStore(engine: try FixtureEngine(), defaults: d)
    await store.scan()
    return store
}

@MainActor @Test func snapshotScreens() async throws {
    let store = try await scannedStore()
    for dark in [false, true] {
        try Snap.render("window", ContentView().environment(store), size: CGSize(width: 900, height: 720), dark: dark)
        try Snap.render("menubar", MenuBarPanel().environment(store), size: CGSize(width: 320, height: 240), dark: dark)
    }
    await store.loadMap()
    for dark in [false, true] {
        try Snap.render("map", SpaceMapView().environment(store), size: CGSize(width: 900, height: 760), dark: dark)
    }
    let runtime = try #require(store.result?.findings.first { $0.rule == "simulator-runtime" })
    try Snap.render("detail", DetailView(finding: runtime).environment(store), size: CGSize(width: 320, height: 560))
    let fresh = CleanerStore(engine: try FixtureEngine(), defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!)
    try Snap.render("intro", ContentView().environment(fresh), size: CGSize(width: 900, height: 720))
    try Snap.render("confirm", ConfirmSheet(items: store.selectedItems).environment(store), size: CGSize(width: 440, height: 330))
    var s = CleanSummary()
    s.cleaned = 14; s.freeBefore = 58_700_000_000; s.freeAfter = 61_800_000_000; s.trashedBytes = 350_000_000
    s.skipped = [SummaryLine(name: "uv Python cache", path: "/Users/you/.cache/uv", reason: "another program is using it (lock held)")]
    store.summary = s
    try Snap.render("summary", SummarySheet(summary: s).environment(store), size: CGSize(width: 460, height: 380))
}


struct SnapAdvisor: FolderAdvisor {
    let name = "Apple Intelligence"
    let current: AdvisorStatus
    func status() -> AdvisorStatus { current }
    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        FolderAdvice(summary: "Downloaded AI models from Hugging Face, kept so Python tools don't fetch them again.",
                     kind: .aiModels, regrows: .yes, verdict: .review,
                     why: "Nothing used them for 96 days, and they download again when a tool needs them.")
    }
}

@MainActor @Test func snapshotInsight() async throws {
    let node = MapNode(path: "/Users/you/.cache/huggingface", name: "huggingface", kind: .folder, bytes: 4_100_000_000, cleanable: 0, children: [])
    for (status, file) in [(AdvisorStatus.ready, "insight"), (.notEnabled, "insight-no-ai")] {
        let d = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
        let store = CleanerStore(engine: try FixtureEngine(), defaults: d, advisor: SnapAdvisor(current: status),
                                 userRules: UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you"))
        await store.explain(node.path)
        try Snap.render(file, FolderInsightView(node: node).environment(store), size: CGSize(width: 340, height: 720))
    }
}

@MainActor @Test func snapshotAskClaude() async throws {
    let node = MapNode(path: "/Users/you/.cache/huggingface", name: "huggingface", kind: .folder, bytes: 4_100_000_000, cleanable: 0, children: [])
    let claude = CLIAdvisor(tool: .claude, binary: "/usr/bin/true")
    let store = CleanerStore(engine: try FixtureEngine(), defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!,
                             advisor: claude, cloudAdvisors: [],
                             userRules: UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you"))
    await store.explain(node.path)
    try Snap.render("insight-ask", FolderInsightView(node: node).environment(store), size: CGSize(width: 340, height: 720))
}
