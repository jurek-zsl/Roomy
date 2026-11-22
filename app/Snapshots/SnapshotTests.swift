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
    /// What the labelled fixture map knows about a path.
    func known(_ path: String) -> KnownFolder? {
        func find(_ n: MapNode) -> MapNode? { n.path == path ? n : n.children.lazy.compactMap(find).first }
        return (try? map()).flatMap { $0.roots.lazy.compactMap(find).first }?.known
    }
    func inspect(path: String) async throws -> FolderClues {
        FolderClues(path: path, name: (path as NSString).lastPathComponent, bytes: 4_100_000_000, files: 212, folders: 40, newestDays: 96,
                    types: [TypeShare(ext: "safetensors", bytes: 3_800_000_000, files: 9), TypeShare(ext: "json", bytes: 2_000_000, files: 60)],
                    biggest: [FolderItem(name: "hub", bytes: 4_000_000_000, folder: true), FolderItem(name: "xet", bytes: 90_000_000, folder: true)],
                    owner: FolderOwner(name: "huggingface", kind: "tool", installed: nil, running: false),
                    markers: ["93% of it is AI model weight files (.safetensors, .gguf, .bin, ...); they download again when needed."],
                    known: known(path))
    }

    func map() throws -> DiskMap {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "map.json")
        return try DiskMap.decode(Data(contentsOf: url))
    }
    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func uninstallPlan(app: String) async throws -> UninstallPlan {
        let id = "com.tinyspeck.slackmacgap"
        return UninstallPlan(app: app, name: "Slack", bundleId: id, appBytes: 512_000_000, running: false, items: [
            AppFile(path: "/Users/you/Library/Application Support/Slack", bytes: 1_240_000_000, what: "Support files", admin: false),
            AppFile(path: "/Users/you/Library/Caches/\(id).ShipIt", bytes: 218_000_000, what: "Caches", admin: false),
            AppFile(path: "/Users/you/Library/Containers/\(id)", bytes: 4_200_000, what: "Sandbox container", admin: false),
            AppFile(path: "/Users/you/Library/Logs/Slack", bytes: 2_100_000, what: "Logs", admin: false),
            AppFile(path: "/Users/you/Library/Saved Application State/\(id).savedState", bytes: 61_000, what: "Saved windows", admin: false),
            AppFile(path: "/Users/you/Library/Preferences/\(id).plist", bytes: 8_000, what: "Settings", admin: false),
            AppFile(path: "/Library/LaunchDaemons/\(id).helper.plist", bytes: 4_000, what: "Background service", admin: true),
        ])
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
    let name = "Claude"
    let current: AdvisorStatus
    func status() -> AdvisorStatus { current }
    func request(system: String, prompt: String, schema: String, timeout: TimeInterval) async throws -> Data {
        Data(#"""
        {"overview":"Most of your space is in Claude's app data and developer caches. The biggest easy wins are downloaded AI models and the uv package cache, which come back by themselves when needed.","suggestions":[
         {"path":"~/.cache/huggingface","what":"AI models that Python tools downloaded from Hugging Face. They download again the next time a tool needs one.","kind":"aiModels","regrows":"yes"},
         {"path":"~/.cache/uv","what":"The uv package manager's cache of Python packages. uv fills it again as you install packages.","kind":"cache","regrows":"yes"},
         {"path":"~/Library/pnpm","what":"pnpm's shared store of JavaScript packages. Projects download them again on the next install.","kind":"cache","regrows":"yes"},
         {"path":"~/Library/Application Support/Steam","what":"Steam's games and their saved data.","kind":"appData","regrows":"no"},
         {"path":"/Users/you/not-on-the-map","what":"Made up.","kind":"cache","regrows":"yes"}]}
        """#.utf8)
    }
    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        FolderAdvice(summary: "Downloaded AI models from Hugging Face, kept so Python tools don't fetch them again.",
                     kind: .aiModels, regrows: .yes, verdict: .review,
                     why: "Nothing used them for 96 days, and they download again when a tool needs them.")
    }
}

@MainActor @Test func snapshotInsight() async throws {
    let known = MapNode(path: "/Users/you/.cache/huggingface", name: "huggingface", kind: .folder, bytes: 4_100_000_000, cleanable: 0, children: [])
    let store = CleanerStore(engine: try FixtureEngine(), defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!,
                             advisors: [SnapAdvisor(current: .ready)],
                             userRules: UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you"))
    await store.explain(known.path)
    try Snap.render("insight-known", FolderInsightView(node: known).environment(store), size: CGSize(width: 340, height: 720))
    try Snap.render("insight-known", FolderInsightView(node: known).environment(store), size: CGSize(width: 340, height: 720), dark: true)
    let node = MapNode(path: "/Users/you/Library/Application Support/Mystery/models", name: "models", kind: .folder, bytes: 4_100_000_000, cleanable: 0, children: [])
    for (status, file) in [(AdvisorStatus.ready, "insight"), (.notInstalled, "insight-no-ai")] {
        let d = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
        let store = CleanerStore(engine: try FixtureEngine(), defaults: d, advisors: [SnapAdvisor(current: status)],
                                 userRules: UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you"))
        await store.explain(node.path)
        try Snap.render(file, FolderInsightView(node: node).environment(store), size: CGSize(width: 340, height: 720))
    }
}

@MainActor @Test func snapshotAskClaude() async throws {
    let node = MapNode(path: "/Users/you/Library/Application Support/Mystery/models", name: "models", kind: .folder, bytes: 4_100_000_000, cleanable: 0, children: [])
    let claude = CLIAdvisor(tool: .claude, binary: "/usr/bin/true")
    let store = CleanerStore(engine: try FixtureEngine(), defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!,
                             advisors: [claude],
                             userRules: UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you"))
    await store.explain(node.path)
    try Snap.render("insight-ask", FolderInsightView(node: node).environment(store), size: CGSize(width: 340, height: 720))
}


@MainActor @Test func snapshotOnboardingAndAIScan() async throws {
    let rules = UserRules(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())/r.toml"), home: "/Users/you")
    let d = UserDefaults(suiteName: "snap-\(UUID().uuidString)")!
    let store = CleanerStore(engine: try FixtureEngine(), defaults: d, advisors: [SnapAdvisor(current: .ready)], userRules: rules)
    for step in [1, 2] {
        try Snap.render("welcome-\(step)", IntroView(step: step).environment(store), size: CGSize(width: 760, height: 640))
    }
    try Snap.render("ai-scan-start", AIScanView().environment(store), size: CGSize(width: 900, height: 480))
    await store.loadMap()
    await store.runQuickScan()
    try Snap.render("quick-scan", AIScanView().environment(store), size: CGSize(width: 900, height: 900))
    try Snap.render("quick-scan", AIScanView().environment(store), size: CGSize(width: 900, height: 900), dark: true)
    await store.runAIScan()
    try Snap.render("ai-scan", AIScanView().environment(store), size: CGSize(width: 900, height: 1100))
    try Snap.render("ai-scan", AIScanView().environment(store), size: CGSize(width: 900, height: 1100), dark: true)
}


@MainActor @Test func snapshotUninstallAndSystemData() async throws {
    let apps = [("Slack", 1_976_000_000), ("Xcode", 4_010_000_000), ("Microsoft Word", 2_950_000_000), ("Spotify", 460_000_000), ("Figma", 520_000_000)]
    let u = Uninstaller(engine: try FixtureEngine(), listApps: {
        apps.map { InstalledApp(path: "/Applications/\($0.0).app", name: $0.0, bundleId: nil, bytes: Int64($0.1)) }
    })
    await u.loadApps()
    await u.select("/Applications/Slack.app")
    u.selectedApp = nil  // a selected row renders black off screen
    for dark in [false, true] {
        try Snap.render("uninstall", UninstallView(uninstaller: u), size: CGSize(width: 900, height: 620), dark: dark)
    }
    var f = SystemData.Facts()
    f.snapshots = [Date(timeIntervalSinceNow: -7_200), Date(timeIntervalSinceNow: -3_600)]
    f.purgeable = 6_400_000_000
    f.swap = 2_150_000_000
    try Snap.render("system-data", SystemDataView(bytes: 41_700_000_000, facts: f), size: CGSize(width: 560, height: 640))
}
