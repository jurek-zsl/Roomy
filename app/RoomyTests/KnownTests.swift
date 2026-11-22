import Foundation
import Testing

private func known(_ name: String, _ kind: FolderKind, _ regrows: Regrows, owner: String = "uv",
                   how: String? = nil, inside: Bool? = nil, running: Bool? = nil) -> KnownFolder {
    KnownFolder(name: name, owner: owner, what: "\(name) explained.", kind: kind, regrows: regrows,
                how: how, inside: inside, running: running)
}

private func clues(_ path: String, known k: KnownFolder?, owner: FolderOwner? = nil, markers: [String] = []) -> FolderClues {
    FolderClues(path: path, name: (path as NSString).lastPathComponent, bytes: 5_000, files: 9, folders: 2, newestDays: 3,
                types: [], biggest: [], owner: owner, markers: markers, known: k)
}

private func n(_ p: String, _ mb: Int64, known k: KnownFolder? = nil, kind: MapKind = .folder,
               cleanable: Int64 = 0, _ kids: [MapNode] = []) -> MapNode {
    MapNode(path: p, name: (p as NSString).lastPathComponent, kind: kind, bytes: mb * 1_000_000,
            cleanable: cleanable * 1_000_000, children: kids, known: k)
}

@Test func decodesKnownFoldersFromTheEngine() throws {
    let c = try FolderClues.decode(Data(#"""
    {"path":"/h/.cache/uv/x","name":"x","bytes":1,"files":1,"folders":0,"newest_days":null,"types":[],"biggest":[],
     "owner":null,"markers":[],"known":{"name":"uv cache","owner":"uv","what":"Packages.","kind":"cache",
     "regrows":"yes","how":"uv cache clean","inside":true,"running":true}}
    """#.utf8))
    #expect(c.known == KnownFolder(name: "uv cache", owner: "uv", what: "Packages.", kind: .cache, regrows: .yes,
                                   how: "uv cache clean", inside: true, running: true))
    let plain = try FolderClues.decode(Data(#"""
    {"path":"/h/x","name":"x","bytes":1,"files":1,"folders":0,"newest_days":null,"types":[],"biggest":[],"owner":null,"markers":[]}
    """#.utf8))
    #expect(plain.known == nil)
    let map = try DiskMap.decode(Data(#"""
    {"total_bytes":null,"used_bytes":null,"free_bytes":null,"mapped_bytes":1,"cleanable_bytes":0,"elapsed_ms":1,"roots":[
     {"path":"/private/var/vm","name":"vm","kind":"folder","bytes":1,"cleanable":0,"children":[],
      "known":{"name":"Swap","owner":"macOS","what":"Swap.","kind":"system","regrows":"yes"}}]}
    """#.utf8))
    #expect(map.roots[0].known?.kind == .system)
}

@Test func roomyAnswersKnownFoldersItself() throws {
    let a = try #require(AdvisorPrompt.known(clues("/h/.cache/uv", known: known("uv cache", .cache, .yes, how: "uv cache clean")), home: "/h"))
    #expect(a.fromRoomy)
    #expect(a.verdict == .review)
    #expect(a.summary == "uv cache explained.")
    #expect(a.how == "uv cache clean")
    let inside = try #require(AdvisorPrompt.known(clues("/h/.cache/uv/x", known: known("uv cache", .cache, .yes, inside: true)), home: "/h"))
    #expect(inside.summary.hasPrefix("It's part of uv cache (uv). "))
    #expect(AdvisorPrompt.known(clues("/h/x", known: nil), home: "/h") == nil)
}

@Test func knownFoldersKeepRoomysLimits() throws {
    let running = try #require(AdvisorPrompt.known(clues("/h/vm", known: known("Claude's VM", .cache, .yes, owner: "Claude", running: true)), home: "/h"))
    #expect(running.verdict == .keep)
    #expect(running.override == "Claude is running; quit it first.")
    let system = try #require(AdvisorPrompt.known(clues("/private/var/vm", known: known("Swap", .system, .yes, owner: "macOS")), home: "/h"))
    #expect(system.verdict == .keep)
    let mine = try #require(AdvisorPrompt.known(clues("/h/Documents/app/node_modules", known: known("node_modules", .buildOutput, .yes)), home: "/h"))
    #expect(mine.verdict == .keep, "your own folders stay yours")
    let models = try #require(AdvisorPrompt.known(clues("/h/.ollama/models", known: known("Ollama models", .aiModels, .no)), home: "/h"))
    #expect(models.verdict == .keep, "models you pulled yourself don't come back")
}

@Test func dataOfARemovedAppIsALeftover() throws {
    let general = known("An app's data", .appData, .no, owner: "An app")
    let gone = FolderOwner(name: "OldApp", kind: "app", installed: false, running: false)
    let a = try #require(AdvisorPrompt.known(clues("/h/Library/Application Support/OldApp", known: general, owner: gone), home: "/h"))
    #expect(a.kind == .leftover)
    #expect(a.verdict == .review)
    let there = FolderOwner(name: "NewApp", kind: "app", installed: true, running: false)
    let b = try #require(AdvisorPrompt.known(clues("/h/Library/Application Support/NewApp", known: general, owner: there), home: "/h"))
    #expect(b.verdict == .keep)
}

private let cache = known("Tool caches", .cache, .yes, owner: "Command-line tools")
private let map = DiskMap(totalBytes: nil, usedBytes: nil, freeBytes: nil, mappedBytes: 1, cleanableBytes: 0, elapsedMs: 1, roots: [
    n("/", 10_000, [
        n("/h", 9_000, [
            n("/h/.cache", 3_000, known: cache, [
                n("/h/.cache/uv", 2_000, known: known("uv cache", .cache, .yes), [n("/h/.cache/uv/archive-v0", 1_900, known: known("uv part", .cache, .yes))]),
                n("/h/.cache/huggingface", 600, known: known("Hugging Face models", .aiModels, .yes)),
                n("/h/.cache/tiny", 10, known: known("tiny", .cache, .yes)),
            ]),
            n("/h/.npm", 800, known: known("npm", .cache, .yes), cleanable: 700),
            n("/h/Documents", 4_000, known: known("Your files", .userFiles, .no), kind: .personal,
              [n("/h/Documents/app/node_modules", 900, known: known("node_modules", .buildOutput, .yes))]),
            n("/h/.ollama", 500, known: known("Ollama models", .aiModels, .no)),
            n("/h/Library/Logs", 300, known: known("Your logs", .logs, .yes)),
        ]),
        n("/private/var/vm", 1_000, known: known("Swap", .system, .yes)),
    ]),
])

@Test func quickScanPicksTheMostSpecificKnownFolders() {
    let picked = AIScanPrompt.knownCandidates(map, home: "/h").map(\.path)
    #expect(picked == ["/h/.cache/uv", "/h/.cache/huggingface", "/h/Library/Logs"],
            "inner known folders over the broad cache folder; not tiny ones, ones Roomy already cleans, your files, kept kinds or macOS")
}

@Test func outlineNamesKnownFolders() {
    let o = AIScanPrompt.outline(map, home: "/h", includePersonal: false, apps: [])
    #expect(o.contains("~/.cache/uv 2.0 GB — uv cache"))
    #expect(!o.contains("archive-v0"), "Roomy already knows what's inside a known cache")
    #expect(o.contains("~/.cache 3.0 GB — Tool caches"))
}

@MainActor @Test func explainUsesRoomysListWithoutAskingAnAI() async throws {
    let advisor = FakeAdvisor()
    let engine = FakeEngine(scans: [.success(scanResult([]))])
    engine.clues = clues("/h/.cache/uv", known: known("uv cache", .cache, .yes))
    let store = CleanerStore(engine: engine, defaults: freshDefaults(), advisors: [advisor], userRules: tempRules())
    await store.explain("/h/.cache/uv")
    let advice = try #require(store.advice(for: "/h/.cache/uv"))
    #expect(advice.fromRoomy)
    #expect(advisor.calls == 0)
    store.advisorID = "other"
    #expect(store.advice(for: "/h/.cache/uv") != nil, "switching AI keeps Roomy's own answer")
}

@MainActor @Test func quickScanWorksWithoutAnyAI() async throws {
    let engine = FakeEngine(scans: [.success(scanResult([]))])
    engine.mapResult = .success(map)
    engine.cluesByPath = [
        "/h/.cache/uv": clues("/h/.cache/uv", known: known("uv cache", .cache, .yes)),
        "/h/.cache/huggingface": clues("/h/.cache/huggingface", known: known("Hugging Face models", .aiModels, .yes)),
        "/h/Library/Logs": clues("/h/Library/Logs", known: known("Your logs", .logs, .yes), markers: ["It is a git repository."]),
    ]
    let rules = tempRules()
    let store = CleanerStore(engine: engine, defaults: freshDefaults(), advisors: [FakeAdvisor(status: .notInstalled)], userRules: rules)
    await store.runQuickScan()
    #expect(store.aiScanState == .ready)
    let scan = try #require(store.aiScan)
    #expect(scan.advisor == "Roomy")
    #expect(scan.suggestions.map(\.path) == ["/h/.cache/uv", "/h/.cache/huggingface", "/h/Library/Logs"])
    #expect(scan.suggestions.map(\.name) == ["uv cache", "Hugging Face models", "Your logs"])
    #expect(store.aiSelected == ["/h/.cache/uv", "/h/.cache/huggingface"], "the git repository stays unticked")
    await store.addAISuggestions()
    #expect(rules.contains("/h/.cache/uv"))
}

@MainActor @Test func aiScanAddsWhatRoomyKnows() async throws {
    let advisor = FakeAdvisor()
    advisor.scanReply = Data(#"""
    {"overview":"Caches.","suggestions":[
      {"path":"/h/.cache/uv","what":"AI's words.","kind":"logs","regrows":"no"}]}
    """#.utf8)
    let engine = FakeEngine(scans: [.success(scanResult([]))])
    engine.mapResult = .success(map)
    engine.cluesByPath = [
        "/h/.cache/uv": clues("/h/.cache/uv", known: known("uv cache", .cache, .yes)),
        "/h/.cache/huggingface": clues("/h/.cache/huggingface", known: known("Hugging Face models", .aiModels, .yes)),
        "/h/Library/Logs": clues("/h/Library/Logs", known: known("Your logs", .logs, .yes)),
    ]
    let store = CleanerStore(engine: engine, defaults: freshDefaults(), advisors: [advisor], userRules: tempRules())
    await store.loadMap()
    await store.runAIScan()
    let scan = try #require(store.aiScan)
    #expect(scan.suggestions.map(\.path) == ["/h/.cache/uv", "/h/.cache/huggingface", "/h/Library/Logs"])
    #expect(scan.suggestions[0].advice.kind == .cache, "for a folder Roomy knows, its own label wins")
    #expect(scan.suggestions.allSatisfy { $0.advice.fromRoomy })
}
