import Foundation
import Testing

/// Scripted engine: hands out queued scan results and clean events.
final class FakeEngine: CleanEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var scans: [Result<ScanResult, EngineError>]
    private var events: [CleanEvent]
    private var streamError: EngineError?
    private var scanDelay: Duration
    var mapResult: Result<DiskMap, EngineError> = .failure(.failed("no map"))
    private(set) var mapCount = 0
    private(set) var scanCount = 0
    private(set) var cleanCalls: [(paths: [String], trash: Bool)] = []

    init(scans: [Result<ScanResult, EngineError>], events: [CleanEvent] = [], streamError: EngineError? = nil, scanDelay: Duration = .zero) {
        self.scans = scans
        self.events = events
        self.streamError = streamError
        self.scanDelay = scanDelay
    }

    func scan() async throws -> ScanResult {
        let next: Result<ScanResult, EngineError> = lock.withLock {
            scanCount += 1
            return scans.count > 1 ? scans.removeFirst() : scans[0]
        }
        if scanDelay > .zero { try await Task.sleep(for: scanDelay) }
        return try next.get()
    }

    var clues: FolderClues = sampleClues()
    var cluesByPath: [String: FolderClues] = [:]
    func inspect(path: String) async throws -> FolderClues { cluesByPath[path] ?? clues }

    func map() async throws -> DiskMap {
        let r = lock.withLock { mapCount += 1; return mapResult }
        return try r.get()
    }

    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error> {
        let (evs, err) = lock.withLock {
            cleanCalls.append((paths, trash))
            return (events, streamError)
        }
        return AsyncThrowingStream { c in
            for e in evs { c.yield(e) }
            c.finish(throwing: err)
        }
    }
}

func finding(_ path: String, _ section: Section, bytes: Int64 = 100, name: String = "Thing") -> Finding {
    Finding(
        rule: "r", name: name, category: "c",
        risk: section == .review ? .review : .safe,
        status: section == .blocked ? .blocked : .ready,
        section: section, reason: section == .blocked ? "it's in use" : nil,
        path: path, bytesOnDisk: bytes, bytesFreed: bytes, files: 1,
        clean: nil, explain: "e", method: .delete)
}

func scanResult(_ f: [Finding], free: Int64 = 1_000) -> ScanResult {
    ScanResult(freeBytes: free, elapsedMs: 1, findings: f)
}

func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
    d.set(true, forKey: "seenIntro")
    return d
}

private let a = finding("/h/a", .safeNow, bytes: 300)
private let b = finding("/h/b", .review, bytes: 200)
private let c = finding("/h/c", .blocked, bytes: 50)

@MainActor @Test func defaultTicks() async {
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a, b, c]))]), defaults: freshDefaults())
    await store.scan()
    #expect(store.isSelected(a))
    #expect(!store.isSelected(b))
    #expect(!store.isSelected(c))
}

@MainActor @Test func blockedCannotBeTicked() async {
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a, b, c]))]), defaults: freshDefaults())
    await store.scan()
    store.toggle(c)
    store.setAll(.blocked, true)
    #expect(!store.isSelected(c))
    #expect(store.selectedItems.map(\.path) == ["/h/a"])
}

@MainActor @Test func choicesSurviveRescanInSameSection() async {
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a, b, c]))]), defaults: freshDefaults())
    await store.scan()
    store.toggle(a)
    store.toggle(b)
    await store.scan()
    #expect(!store.isSelected(a))
    #expect(store.isSelected(b))
}

@MainActor @Test func choiceResetsWhenSectionChanges() async {
    let aReview = finding("/h/a", .review, bytes: 300)
    let engine = FakeEngine(scans: [.success(scanResult([a])), .success(scanResult([aReview])), .success(scanResult([a]))])
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.scan()
    store.toggle(a)  // off while safe
    await store.scan()  // now in review: default off
    #expect(!store.isSelected(aReview))
    await store.scan()  // back in safe: the old choice is gone, default on
    #expect(store.isSelected(a))
}

@MainActor @Test func totalsAndSelectedBytes() async {
    let a2 = finding("/h/a2", .safeNow, bytes: 700)
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a, b, c, a2]))]), defaults: freshDefaults())
    await store.scan()
    #expect(store.total(.safeNow) == 1_000)
    #expect(store.total(.review) == 200)
    #expect(store.total(.blocked) == 50)
    #expect(store.items(.safeNow).map(\.path) == ["/h/a2", "/h/a"])
    #expect(store.selectedBytes == 1_000)
    store.toggle(b)
    #expect(store.selectedBytes == 1_200)
    store.setAll(.safeNow, false)
    #expect(store.selectedBytes == 200)
}

@MainActor @Test func secondOperationIsIgnored() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))], scanDelay: .milliseconds(50))
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    let t1 = Task { await store.scan() }
    let t2 = Task { await store.scan() }
    let t3 = Task { await store.cleanSafe() }
    await t1.value
    await t2.value
    await t3.value
    #expect(engine.scanCount == 1)
    #expect(engine.cleanCalls.isEmpty)
}

@MainActor @Test func scanFailureShowsError() async {
    let engine = FakeEngine(scans: [.failure(.missing), .success(scanResult([a]))])
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.scan()
    #expect(store.phase == .error(EngineError.missing.localizedDescription))
    await store.scan()
    #expect(store.phase == .idle)
    #expect(store.result?.findings.count == 1)
}

@MainActor @Test func cleanBuildsSummaryAndRescans() async {
    let events: [CleanEvent] = [
        .plan(items: 2, bytes: 500),
        .item(CleanItem(index: 1, path: "/h/a", rule: "r", name: "Thing A", bytes: 300, outcome: .cleaned(.delete, note: nil))),
        .item(CleanItem(index: 2, path: "/h/b", rule: "", name: "", bytes: 0, outcome: .skipped(reason: "the scan doesn't find it anymore"))),
        .done(CleanDone(cleaned: 1, skipped: 1, failed: 0, freeBefore: 100, freeAfter: 150, trashedBytes: 0)),
    ]
    let b2 = finding("/h/b", .review, bytes: 200, name: "Thing B")
    let engine = FakeEngine(scans: [.success(scanResult([a, b2]))], events: events)
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.scan()
    store.toggle(b2)
    await store.clean(store.selectedItems)
    #expect(engine.cleanCalls.first?.paths == ["/h/a", "/h/b"])
    #expect(engine.cleanCalls.first?.trash == false)
    #expect(engine.scanCount == 2)
    #expect(store.phase == .idle)
    let s = try! #require(store.summary)
    #expect(s.cleaned == 1)
    #expect(s.freed == 50)
    #expect(s.skipped == [SummaryLine(name: "Thing B", path: "/h/b", reason: "the scan doesn't find it anymore")])
    #expect(s.failed.isEmpty)
    #expect(s.error == nil)
}

@MainActor @Test func cleanPassesTrashSetting() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))], events: [])
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    store.trashInstead = true
    await store.scan()
    await store.cleanSafe()
    #expect(engine.cleanCalls.first?.trash == true)
    #expect(engine.cleanCalls.first?.paths == ["/h/a"])
}

@MainActor @Test func cleanStreamErrorStillRescans() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))], events: [.plan(items: 1, bytes: 300)], streamError: .badOutput("Scanning..."))
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.scan()
    await store.cleanSafe()
    #expect(engine.scanCount == 2)
    #expect(store.summary?.error == EngineError.badOutput("Scanning...").localizedDescription)
}

@MainActor @Test func staleScanWaitsForIntro() async {
    let d = freshDefaults()
    d.set(false, forKey: "seenIntro")
    let engine = FakeEngine(scans: [.success(scanResult([a]))])
    let store = CleanerStore(engine: engine, defaults: d)
    await store.scanIfStale(maxAge: 600)
    #expect(engine.scanCount == 0)
    store.hasSeenIntro = true
    await store.scanIfStale(maxAge: 600)
    await store.scanIfStale(maxAge: 600)
    #expect(engine.scanCount == 1)
}

@Test func storageSegmentsAddUp() {
    let s = StorageBreakdown(total: 250, free: 60, safe: 20, review: 10)
    #expect(s.used == 160)
    #expect(s.used + s.safe + s.review + s.free == s.total)
    // Engine numbers a bit off from the disk's: never negative.
    let odd = StorageBreakdown(total: 100, free: 90, safe: 20, review: 5)
    #expect(odd.used == 0)
}

final class Bell: @unchecked Sendable {
    var rung: [String] = []
}

@MainActor @Test func lowSpaceAlertsOncePerDay() {
    let d = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
    let bell = Bell()
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([]))]), defaults: d, notify: { bell.rung.append($0) })
    let now = Date()
    store.checkLowSpace(free: 5_000_000_000, now: now)
    #expect(bell.rung.isEmpty, "off by default")
    store.lowSpaceAlerts = true
    store.checkLowSpace(free: 50_000_000_000, now: now)
    #expect(bell.rung.isEmpty, "plenty of space")
    store.checkLowSpace(free: 5_000_000_000, now: now)
    store.checkLowSpace(free: 4_000_000_000, now: now.addingTimeInterval(3600))
    #expect(bell.rung.count == 1)
    store.checkLowSpace(free: 4_000_000_000, now: now.addingTimeInterval(25 * 3600))
    #expect(bell.rung.count == 2)
    #expect(bell.rung[0].contains("5.0 GB"))
}


func diskMap(cleanable: Int64 = 40) -> DiskMap {
    let child = MapNode(path: "/h/code", name: "code", kind: .folder, bytes: 600, cleanable: cleanable, children: [])
    let home = MapNode(path: "/h", name: "/h", kind: .folder, bytes: 1_000, cleanable: cleanable, children: [child])
    return DiskMap(totalBytes: 5_000, usedBytes: 3_000, freeBytes: 2_000, mappedBytes: 1_000,
                   cleanableBytes: cleanable, elapsedMs: 5, roots: [home])
}

@MainActor @Test func mapLoadsAndExplainsTheRest() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))])
    engine.mapResult = .success(diskMap())
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    #expect(store.mapState == .none)
    await store.loadMap()
    #expect(store.mapState == .ready)
    #expect(store.diskMap?.roots.first?.children.first?.name == "code")
    #expect(store.diskMap?.systemBytes == 2_000, "used minus what the map found")
    #expect(store.diskMap?.unexplained(min: 100).map(\.path) == ["/h/code"])
}

@MainActor @Test func mapErrorIsShown() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))])
    engine.mapResult = .failure(.failed("no access"))
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.loadMap()
    #expect(store.mapState == .failed("The engine stopped: no access"))
}

@MainActor @Test func mapIsOutOfDateAfterAClean() async {
    let engine = FakeEngine(scans: [.success(scanResult([a]))],
                            events: [.plan(items: 1, bytes: 300),
                                     .done(CleanDone(cleaned: 1, skipped: 0, failed: 0, freeBefore: 1, freeAfter: 301, trashedBytes: 0))])
    engine.mapResult = .success(diskMap())
    let store = CleanerStore(engine: engine, defaults: freshDefaults())
    await store.scan()
    await store.loadMap()
    #expect(!store.mapIsStale)
    await store.clean([a])
    #expect(store.mapIsStale)
}

@MainActor @Test func trashSettingKeepsToolOnlyItems() async {
    var gc = finding("/h/app/.git", .safeNow)
    gc.trashMethod = .command("git -C /h/app gc --quiet")
    let plain = finding("/h/x", .safeNow)
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([gc, plain]))]), defaults: freshDefaults())
    store.trashInstead = true
    #expect(store.method(for: gc) == .command("git -C /h/app gc --quiet"))
    #expect(store.method(for: plain) == .trash)
}


func sampleClues(path: String = "/h/Library/Application Support/OldApp", installed: Bool = false, running: Bool = false) -> FolderClues {
    FolderClues(path: path, name: "OldApp", bytes: 2_000, files: 3, folders: 1, newestDays: 200,
                types: [TypeShare(ext: "bin", bytes: 1_900, files: 2)],
                biggest: [FolderItem(name: "Cache", bytes: 1_900, folder: true)],
                owner: FolderOwner(name: "OldApp", kind: "app", installed: installed, running: running),
                markers: ["It has cache or temp folders inside: Cache."])
}

final class FakeAdvisor: FolderAdvisor, @unchecked Sendable {
    let name = "Fake AI"
    var id = "fake"
    var offMac = false
    var sendsOffMac: Bool { offMac }
    var current: AdvisorStatus
    var advice: FolderAdvice
    private(set) var calls = 0
    init(status: AdvisorStatus = .ready, advice: FolderAdvice = FolderAdvice(
        summary: "Leftover cache of OldApp.", kind: .leftover, regrows: .no, verdict: .review, why: "OldApp isn't installed.")) {
        current = status
        self.advice = advice
    }
    func status() -> AdvisorStatus { current }
    var scanReply: Data?
    func request(system: String, prompt: String, schema: String, timeout: TimeInterval) async throws -> Data {
        guard let scanReply else { throw EngineError.failed("no reply") }
        return scanReply
    }
    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        calls += 1
        return AdvisorPrompt.guarded(advice, clues)
    }
}

func tempRules() -> UserRules {
    UserRules(file: FileManager.default.temporaryDirectory.appending(path: "roomy-\(UUID().uuidString)/rules.toml"), home: "/h")
}

@MainActor @Test func explainShowsCluesAndAdvice() async {
    let advisor = FakeAdvisor()
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a]))]), defaults: freshDefaults(),
                             advisors: [advisor], userRules: tempRules())
    let path = "/h/Library/Application Support/OldApp"
    await store.explain(path)
    guard case .ready(let clues, let advice) = store.insights[path] else { Issue.record("no insight"); return }
    #expect(clues.owner?.name == "OldApp")
    #expect(advice?.verdict == .review)
    #expect(advisor.calls == 1)
    await store.explain(path)
    #expect(advisor.calls == 1, "answers are kept, not asked again")
}

@MainActor @Test func explainWithoutAnAIStillShowsClues() async {
    let advisor = FakeAdvisor(status: .notInstalled)
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a]))]), defaults: freshDefaults(),
                             advisors: [advisor], userRules: tempRules())
    await store.explain("/h/x")
    guard case .ready(let clues, let advice) = store.insights["/h/x"] else { Issue.record("no insight"); return }
    #expect(clues.name == "OldApp")
    #expect(advice == nil)
    #expect(advisor.calls == 0)
    #expect(store.advisorStatus == .notInstalled)
}

@MainActor @Test func acceptingAddsAReviewRuleAndRescans() async throws {
    let engine = FakeEngine(scans: [.success(scanResult([a]))])
    engine.mapResult = .success(diskMap())
    let rules = tempRules()
    let store = CleanerStore(engine: engine, defaults: freshDefaults(), advisors: [FakeAdvisor()], userRules: rules)
    await store.loadMap()
    let path = "/h/Library/Application Support/OldApp"
    await store.explain(path)
    let before = engine.scanCount
    await store.acceptSuggestion(path)
    #expect(rules.contains(path))
    #expect(store.isAccepted(path))
    #expect(engine.scanCount == before + 1)
    #expect(store.mapIsStale)
    let text = try String(contentsOf: rules.file, encoding: .utf8)
    #expect(text.contains("risk = \"review\""))
    #expect(text.contains("Apple Intelligence") == false, "named after the advisor in use")
    #expect(text.contains("Fake AI"))
    await store.removeSuggestion(path)
    #expect(!rules.contains(path))
}

@MainActor @Test func offMacAdvisorWaitsUntilYouAsk() async {
    let advisor = FakeAdvisor()
    advisor.offMac = true
    let store = CleanerStore(engine: FakeEngine(scans: [.success(scanResult([a]))]), defaults: freshDefaults(),
                             advisors: [advisor], userRules: tempRules())
    let path = "/h/Library/Application Support/OldApp"
    await store.explain(path)
    guard case .ready(_, nil) = store.insights[path] else { Issue.record("should show facts only"); return }
    #expect(advisor.calls == 0, "nothing leaves the Mac by itself")
    #expect(store.outgoing(path)?.contains("Folder: ") == true, "you see what would be sent")
    await store.ask(path)
    #expect(advisor.calls == 1)
    guard case .ready(_, let advice?) = store.insights[path] else { Issue.record("no advice"); return }
    #expect(advice.verdict == .review)
}

@MainActor @Test func choosingAnotherAdvisorIsRemembered() async {
    let d = freshDefaults()
    let local = FakeAdvisor()
    let cloud = FakeAdvisor()
    cloud.id = "cloud"
    let store = CleanerStore(engine: FakeEngine(scans: []), defaults: d, advisors: [local, cloud], userRules: tempRules())
    #expect(store.advisor.id == local.id)
    store.advisorID = "cloud"
    #expect(store.advisor.id == "cloud")
    let again = CleanerStore(engine: FakeEngine(scans: []), defaults: d, advisors: [local, cloud], userRules: tempRules())
    #expect(again.advisor.id == "cloud")
}

@Test func wholeDiskMapShowsTheTopFolders() throws {
    func n(_ p: String, _ b: Int64, _ kids: [MapNode] = []) -> MapNode {
        MapNode(path: p, name: (p as NSString).lastPathComponent, kind: .folder, bytes: b, cleanable: 0, children: kids)
    }
    let vm = n("/private/var/vm", 2_000)
    let cache = n("/Users/me/.cache/x", 3_000)
    let root = MapNode(path: "/", name: "/", kind: .folder, bytes: 9_000, cleanable: 0,
                       children: [n("/Users", 5_000, [n("/Users/me", 5_000, [cache])]), n("/private", 2_000, [n("/private/var", 2_000, [vm])])])
    let map = DiskMap(totalBytes: 10_000, usedBytes: 9_500, freeBytes: 500, mappedBytes: 9_000, cleanableBytes: 0, elapsedMs: 1, roots: [root])
    #expect(map.places.map(\.path) == ["/Users", "/private"])
    #expect(map.unexplained(min: 1_000).map(\.path) == ["/Users/me/.cache/x"], "macOS swap isn't worth a look")
}

@MainActor @Test func aiScanChecksEverySuggestion() async throws {
    let advisor = FakeAdvisor()
    advisor.scanReply = Data(#"""
    {"overview":"Most space is in caches.","suggestions":[
      {"path":"/h/Library/Application Support/OldApp","what":"OldApp's cache.","kind":"cache","regrows":"yes"}]}
    """#.utf8)
    let engine = FakeEngine(scans: [.success(scanResult([a])), .success(scanResult([a]))])
    engine.mapResult = .success(DiskMap(totalBytes: 10, usedBytes: 9, freeBytes: 1, mappedBytes: 9, cleanableBytes: 0, elapsedMs: 1, roots: [
        MapNode(path: "/h", name: "/h", kind: .folder, bytes: 9, cleanable: 0, children: [
            MapNode(path: "/h/Library/Application Support/OldApp", name: "OldApp", kind: .folder, bytes: 9, cleanable: 0, children: [])])]))
    let rules = tempRules()
    let store = CleanerStore(engine: engine, defaults: freshDefaults(), advisors: [advisor], userRules: rules)
    #expect(store.aiScanPreview == nil, "no map yet")
    await store.runAIScan()
    #expect(store.aiScanState == .ready)
    let s = try #require(store.aiScan?.suggestions.first)
    #expect(s.advice.verdict == .review)
    #expect(store.aiScan?.overview == "Most space is in caches.")
    #expect(store.aiSelected == [s.path], "what Roomy agrees with starts ticked")
    await store.addAISuggestions()
    #expect(rules.contains(s.path))
    #expect(store.isAccepted(s.path))
}
