import Foundation
import Observation

struct SummaryLine: Equatable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let reason: String
}

/// What happened in the last clean.
struct CleanSummary: Equatable, Sendable {
    var cleaned = 0
    var skipped: [SummaryLine] = []
    var failed: [SummaryLine] = []
    var freeBefore: Int64?
    var freeAfter: Int64?
    var trashedBytes: Int64 = 0
    /// Set when the engine stopped or sent something unexpected.
    var error: String?

    var freed: Int64? {
        guard let b = freeBefore, let a = freeAfter else { return nil }
        return max(0, a - b)
    }
}

/// Everything the window and the menu bar show. One scan or clean at a time.
@MainActor @Observable
final class CleanerStore {
    enum Phase: Equatable {
        case idle
        case scanning
        case cleaning(done: Int, total: Int, current: String)
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var result: ScanResult?
    private(set) var lastScan: Date?
    private(set) var freeBytes: Int64?
    private(set) var totalBytes: Int64?
    var summary: CleanSummary?

    enum MapState: Equatable {
        case none
        case loading
        case ready
        case failed(String)
    }

    private(set) var mapState: MapState = .none
    private(set) var diskMap: DiskMap?
    private(set) var mapDate: Date?
    /// Something was cleaned since the map was made.
    private(set) var mapIsStale = false

    enum Insight: Equatable {
        case loading
        /// Roomy's facts, and the AI's reading of them when it's available.
        case ready(FolderClues, FolderAdvice?)
        case failed(String)
    }

    /// Explanations of folders, by path. Kept until the app quits.
    private(set) var insights: [String: Insight] = [:]
    /// Folders you agreed to review (as rules), by path.
    private(set) var accepted: Set<String> = []
    /// The AI tools Roomy can ask (Claude, Codex, Gemini).
    private(set) var advisors: [any FolderAdvisor]
    /// Which one explains folders; remembered.
    var advisorID: String {
        didSet {
            defaults.set(advisorID, forKey: Keys.advisor)
            adviceError = nil
            for (path, insight) in insights {
                // Roomy's own answers don't depend on which AI is picked.
                if case .ready(let clues, let a?) = insight, !a.fromRoomy { insights[path] = .ready(clues, nil) }
            }
        }
    }
    var advisor: any FolderAdvisor { advisors.first { $0.id == advisorID } ?? advisors[0] }

    /// Look for the tools again, after one was installed.
    func reloadAdvisors() {
        guard advisors.allSatisfy({ $0 is CLIAdvisor }) else { return }
        advisors = CLIAdvisor.all
    }
    enum AIScanState: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    private(set) var aiScanState: AIScanState = .idle
    private(set) var aiScan: AIScanResult?
    /// Suggestions ticked to add to Review.
    var aiSelected: Set<String> = []
    /// Send the contents of Documents, Desktop and media folders too.
    var aiScanIncludesPersonal: Bool {
        didSet { defaults.set(aiScanIncludesPersonal, forKey: Keys.aiPersonal) }
    }

    /// Folders waiting for an answer from the advisor.
    private(set) var asking: Set<String> = []
    @ObservationIgnored let userRules: UserRules

    /// Notify when free space drops under `lowSpaceThreshold` (once a day at most).
    var lowSpaceAlerts: Bool {
        didSet { defaults.set(lowSpaceAlerts, forKey: Keys.lowSpace) }
    }
    let lowSpaceThreshold: Int64 = 10_000_000_000

    /// Move everything to the Trash instead of deleting.
    var trashInstead: Bool {
        didSet { defaults.set(trashInstead, forKey: Keys.trash) }
    }

    /// The intro explains folder-access prompts; no scan starts on its own before it.
    var hasSeenIntro: Bool {
        didSet { defaults.set(hasSeenIntro, forKey: Keys.intro) }
    }

    private struct Choice: Equatable {
        let section: Section
        let on: Bool
    }

    private enum Keys {
        static let trash = "trashInstead"
        static let intro = "seenIntro"
        static let lowSpace = "lowSpaceAlerts"
        static let lastAlert = "lastLowSpaceAlert"
        static let advisor = "advisor"
        static let aiPersonal = "aiScanIncludesPersonal"
    }

    /// Ticks the user changed, by path. A choice counts only while the item
    /// stays in the section it was made in.
    private var choices: [String: Choice] = [:]
    @ObservationIgnored private let engine: any CleanEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var freeTask: Task<Void, Never>?
    @ObservationIgnored private let notify: @Sendable (String) -> Void

    init(engine: any CleanEngine, defaults: UserDefaults = .standard, notify: @escaping @Sendable (String) -> Void = { _ in },
         advisors: [any FolderAdvisor] = CLIAdvisor.all, userRules: UserRules = .standard) {
        self.engine = engine
        self.advisors = advisors
        advisorID = defaults.string(forKey: Keys.advisor)
            ?? (advisors.first { $0.status() == .ready } ?? advisors[0]).id
        self.userRules = userRules
        self.defaults = defaults
        self.notify = notify
        trashInstead = defaults.bool(forKey: Keys.trash)
        hasSeenIntro = defaults.bool(forKey: Keys.intro)
        lowSpaceAlerts = defaults.bool(forKey: Keys.lowSpace)
        aiScanIncludesPersonal = defaults.bool(forKey: Keys.aiPersonal)
    }

    var storage: StorageBreakdown? {
        guard let disk = totalBytes, let free = freeBytes else { return nil }
        return StorageBreakdown(total: disk, free: free, safe: total(.safeNow), review: total(.review))
    }

    func checkLowSpace(free: Int64, now: Date = .now) {
        guard lowSpaceAlerts, free < lowSpaceThreshold else { return }
        if let last = defaults.object(forKey: Keys.lastAlert) as? Date, now.timeIntervalSince(last) < 86_400 { return }
        defaults.set(now, forKey: Keys.lastAlert)
        let safe = total(.safeNow)
        let extra = safe > 0 ? " Roomy can free \(formatBytes(safe)) safely." : " Open Roomy to see what can go."
        notify("Only \(formatBytes(free)) free on this Mac.\(extra)")
    }

    var isWorking: Bool {
        switch phase {
        case .scanning, .cleaning: true
        case .idle, .error: false
        }
    }

    // MARK: - What's found

    /// Biggest first.
    func items(_ section: Section) -> [Finding] {
        (result?.findings ?? []).filter { $0.section == section }.sorted { $0.bytesFreed > $1.bytesFreed }
    }

    func total(_ section: Section) -> Int64 {
        items(section).reduce(0) { $0 + $1.bytesFreed }
    }

    func isSelected(_ f: Finding) -> Bool {
        guard f.section != .blocked else { return false }
        if let c = choices[f.path], c.section == f.section { return c.on }
        return f.section == .safeNow
    }

    var selectedItems: [Finding] {
        (result?.findings ?? []).filter(isSelected).sorted { $0.bytesFreed > $1.bytesFreed }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytesFreed }
    }

    func toggle(_ f: Finding) {
        guard f.section != .blocked else { return }
        choices[f.path] = Choice(section: f.section, on: !isSelected(f))
    }

    func setAll(_ section: Section, _ on: Bool) {
        guard section != .blocked else { return }
        for f in items(section) { choices[f.path] = Choice(section: section, on: on) }
    }

    // MARK: - Actions

    func scan() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await performScan()
    }

    func scanIfStale(maxAge: TimeInterval) async {
        guard hasSeenIntro else { return }
        if let lastScan, Date.now.timeIntervalSince(lastScan) < maxAge { return }
        await scan()
    }

    /// Clean these items, then scan again: cleaning one thing can make
    /// another freeable (deleting node_modules frees the pnpm store).
    func clean(_ items: [Finding]) async {
        let items = items.filter { $0.section != .blocked }
        guard !busy, !items.isEmpty else { return }
        busy = true
        defer { busy = false }
        summary = nil
        let names = Dictionary(items.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
        var s = CleanSummary()
        var total = items.count
        phase = .cleaning(done: 0, total: total, current: "")
        do {
            for try await event in engine.clean(paths: items.map(\.path), trash: trashInstead) {
                switch event {
                case .plan(let n, _):
                    total = n
                    phase = .cleaning(done: 0, total: n, current: "")
                case .item(let it):
                    let name = !it.name.isEmpty ? it.name : names[it.path] ?? URL(fileURLWithPath: it.path).lastPathComponent
                    switch it.outcome {
                    case .cleaned: s.cleaned += 1
                    case .skipped(let reason): s.skipped.append(SummaryLine(name: name, path: it.path, reason: reason))
                    case .failed(_, let error): s.failed.append(SummaryLine(name: name, path: it.path, reason: error))
                    }
                    phase = .cleaning(done: it.index, total: total, current: it.path)
                case .done(let d):
                    s.cleaned = d.cleaned
                    s.freeBefore = d.freeBefore
                    s.freeAfter = d.freeAfter
                    s.trashedBytes = d.trashedBytes
                case .error(let message):
                    s.error = message
                }
            }
        } catch {
            s.error = error.localizedDescription
        }
        summary = s
        if diskMap != nil { mapIsStale = true }
        await performScan()
    }

    var advisorStatus: AdvisorStatus { advisor.status() }

    func isAccepted(_ path: String) -> Bool {
        accepted.contains(path) || userRules.contains(path)
    }

    /// Gather the facts about a folder, then ask the on-device AI what it is.
    /// An advisor that sends facts off the Mac waits for `ask`.
    func explain(_ path: String) async {
        if case .ready(_, let advice) = insights[path], advice != nil || !autoAsk { return }
        if insights[path] == .loading { return }
        insights[path] = .loading
        do {
            let clues = try await engine.inspect(path: path)
            // A folder on Roomy's list is answered at once, offline.
            if let known = AdvisorPrompt.known(clues, home: userRules.home) {
                insights[path] = .ready(clues, known)
                return
            }
            insights[path] = .ready(clues, nil)
            if autoAsk { await ask(path) }
        } catch {
            insights[path] = .failed(error.localizedDescription)
        }
    }

    private var autoAsk: Bool { advisor.status() == .ready && !advisor.sendsOffMac }

    func advice(for path: String) -> FolderAdvice? {
        if case .ready(_, let advice?) = insights[path] { return advice }
        return nil
    }

    /// Exactly what the advisor gets for this folder.
    func outgoing(_ path: String) -> String? {
        guard case .ready(let clues, _) = insights[path] else { return nil }
        return AdvisorPrompt.facts(clues)
    }

    /// Ask the advisor about a folder whose facts are in.
    func ask(_ path: String) async {
        guard case .ready(let clues, nil) = insights[path], advisor.status() == .ready, !asking.contains(path) else { return }
        let advisor = advisor
        asking.insert(path)
        adviceError = nil
        defer { asking.remove(path) }
        do {
            let advice = try await advisor.advise(clues)
            if advisor.id == advisorID { insights[path] = .ready(clues, advice) }
        } catch {
            adviceError = error.localizedDescription
        }
    }

    /// Set when the AI failed after the facts came in.
    var adviceError: String?

    /// You agree: list this folder under Review first from now on. It is
    /// cleaned like any rule (checked, confirmed, to the Trash).
    func acceptSuggestion(_ path: String) async {
        guard case .ready(let clues, let advice?) = insights[path] else { return }
        let name: String
        if let k = clues.known, !k.isGeneral, k.inside != true {
            name = k.name
        } else {
            name = clues.owner.map { "\($0.name) \(advice.kind.title.lowercased())" } ?? clues.name
        }
        let by = advice.fromRoomy ? "From Roomy's list of known folders"
            : "Suggested by \(advisor.name)\(advisor.sendsOffMac ? "" : " on this Mac")"
        let explain = "\(advice.summary) \(advice.why) (\(by); you agreed to review it.)"
        do {
            try userRules.add(path: path, name: name, explain: explain)
            accepted.insert(path)
            if diskMap != nil { mapIsStale = true }
            await scan()
        } catch {
            adviceError = "Couldn't save the rule: \(error.localizedDescription)"
        }
    }

    func removeSuggestion(_ path: String) async {
        try? userRules.remove(path)
        accepted.remove(path)
        if diskMap != nil { mapIsStale = true }
        await scan()
    }

    // MARK: AI scan

    /// Exactly what the AI scan sends, once there's a map.
    var aiScanPreview: String? {
        guard let map = diskMap else { return nil }
        return AIScanPrompt.outline(map, home: userRules.home, includePersonal: aiScanIncludesPersonal,
                                    apps: AIScanPrompt.installedApps(home: userRules.home))
    }

    /// Map the disk if needed, let the AI read all of it in one request,
    /// then check each folder it names the same way as "What is this?".
    /// Ask the AI about a folder Roomy already knows, for more detail. If
    /// that fails, Roomy's own answer comes back.
    func askAI(_ path: String) async {
        guard case .ready(let clues, let known?) = insights[path], known.fromRoomy else { return }
        insights[path] = .ready(clues, nil)
        await ask(path)
        if case .ready(_, nil) = insights[path], adviceError != nil { insights[path] = .ready(clues, known) }
    }

    /// Roomy's own list of known folders, checked against the map: instant,
    /// offline, no AI needed.
    func runQuickScan() async {
        if case .working = aiScanState { return }
        aiScanState = .working("Mapping the disk…")
        if diskMap == nil { await loadMap() }
        guard let map = diskMap else {
            aiScanState = .failed("Roomy couldn't map the disk.")
            return
        }
        aiScanState = .working("Checking the folders Roomy knows…")
        let found = await knownSuggestions(map, besides: [])
        let review = found.filter { $0.advice.verdict == .review }
        let overview = review.isEmpty
            ? "Roomy's list of known folders found nothing more worth removing beyond what Clean already finds."
            : "Roomy recognized \(review.count) folder\(review.count == 1 ? "" : "s") worth a look, about \(formatBytes(review.reduce(0) { $0 + $1.bytes })) in all, from its own list of known folders. Nothing was sent anywhere."
        aiScan = AIScanResult(overview: overview, suggestions: found, advisor: "Roomy", date: .now)
        aiSelected = Set(review.filter { !isAccepted($0.path) }.map(\.path))
        aiScanState = .ready
    }

    /// The known folders worth a look, checked one by one like an AI's
    /// suggestions, leaving out any that overlap `besides`.
    private func knownSuggestions(_ map: DiskMap, besides: [String]) async -> [AISuggestion] {
        let overlaps = { (p: String) in besides.contains { $0 == p || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") } }
        let nodes = AIScanPrompt.knownCandidates(map, home: userRules.home).filter { !overlaps($0.path) }
        let engine = engine
        let clues = await withTaskGroup(of: (String, FolderClues?).self) { group in
            for n in nodes { group.addTask { (n.path, try? await engine.inspect(path: n.path)) } }
            var out: [String: FolderClues] = [:]
            for await (path, c) in group { out[path] = c }
            return out
        }
        return nodes.compactMap { n in
            guard let c = clues[n.path], let advice = AdvisorPrompt.known(c, home: userRules.home) else { return nil }
            return AISuggestion(path: n.path, name: suggestionName(n, c.known), bytes: n.bytes, advice: advice)
        }
    }

    private func suggestionName(_ n: MapNode, _ known: KnownFolder?) -> String {
        if let known, !known.isGeneral, known.inside != true { return known.name }
        return n.kind == .bundle ? (n.name as NSString).deletingPathExtension : n.name
    }

    func runAIScan() async {
        if case .working = aiScanState { return }
        aiScanState = .working("Mapping the disk…")
        // Use the map whose text you were shown; map only if there is none yet.
        if diskMap == nil { await loadMap() }
        guard diskMap != nil, let prompt = aiScanPreview, let map = diskMap else {
            aiScanState = .failed("Roomy couldn't map the disk, so there's nothing to send.")
            return
        }
        let advisor = advisor
        aiScanState = .working("\(advisor.name) is reading the map…")
        do {
            let data = try await advisor.request(system: AIScanPrompt.instructions, prompt: prompt,
                                                 schema: AIScanPrompt.schema, timeout: 600)
            let reply = try JSONDecoder().decode(AIScanReply.self, from: data)
            aiScanState = .working("Checking each folder…")
            var found: [AISuggestion] = []
            for (node, item) in AIScanPrompt.validate(reply, map: map, home: userRules.home) {
                let advice: FolderAdvice
                let clues = try? await engine.inspect(path: node.path)
                if let clues, let known = AdvisorPrompt.known(clues, home: userRules.home), clues.known?.isGeneral == false {
                    // Roomy knows this folder by name: its own label wins.
                    advice = known
                } else if let clues {
                    advice = AdvisorPrompt.advice(summary: item.what, kind: item.kind, regrows: item.regrows,
                                                  clues: clues, home: userRules.home)
                } else {
                    advice = FolderAdvice(summary: item.what, kind: item.kind, regrows: item.regrows, verdict: .keep,
                                          why: "Roomy couldn't look inside it, so it stays.", override: nil)
                }
                found.append(AISuggestion(path: node.path, name: suggestionName(node, clues?.known), bytes: node.bytes, advice: advice))
            }
            aiScanState = .working("Adding the folders Roomy knows…")
            found += await knownSuggestions(map, besides: found.map(\.path))
            found.sort { $0.bytes > $1.bytes }
            aiScan = AIScanResult(overview: reply.overview, suggestions: found, advisor: advisor.name, date: .now)
            aiSelected = Set(found.filter { $0.advice.verdict == .review && !isAccepted($0.path) }.map(\.path))
            aiScanState = .ready
        } catch {
            aiScanState = .failed(error.localizedDescription)
        }
    }

    /// Add the ticked suggestions as rules: they show up under Review first
    /// and go through every check, your confirmation and the Trash.
    func addAISuggestions() async {
        guard let result = aiScan else { return }
        let picked = result.suggestions.filter { aiSelected.contains($0.path) }
        guard !picked.isEmpty else { return }
        do {
            for s in picked {
                let by = s.advice.fromRoomy ? "From Roomy's list of known folders" : "Suggested by \(result.advisor) in an AI scan"
                let explain = "\(s.advice.summary) \(s.advice.why) (\(by); you agreed to review it.)"
                try userRules.add(path: s.path, name: s.name, explain: explain)
                accepted.insert(s.path)
            }
        } catch {
            aiScanState = .failed("Couldn't save the rules: \(error.localizedDescription)")
        }
        aiSelected = []
        if diskMap != nil { mapIsStale = true }
        await scan()
    }

    /// Map where the disk space goes. Read-only, so it may run next to a scan.
    func loadMap() async {
        guard mapState != .loading else { return }
        mapState = .loading
        do {
            diskMap = try await engine.map()
            mapDate = .now
            mapIsStale = false
            mapState = .ready
        } catch {
            mapState = .failed(error.localizedDescription)
        }
    }

    /// Everything in "Safe now" from the last scan (the menu bar button).
    func cleanSafe() async {
        await clean(items(.safeNow))
    }

    func refreshFree() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        if let total = values?.volumeTotalCapacity { totalBytes = Int64(total) }
        if let free = values?.volumeAvailableCapacity {
            freeBytes = Int64(free)
            checkLowSpace(free: Int64(free))
        }
    }

    /// Free space every minute, for the menu bar. Started by the app, not
    /// `init`, so tests don't run timers.
    func startFreeSpaceUpdates() {
        guard freeTask == nil else { return }
        freeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFree()
                // Keep "safe to clean" fresh for the menu bar: rescan every 6 hours.
                await self?.scanIfStale(maxAge: 6 * 3600)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func performScan() async {
        phase = .scanning
        do {
            apply(try await engine.scan())
            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func apply(_ r: ScanResult) {
        let sections = Dictionary(r.findings.map { ($0.path, $0.section) }, uniquingKeysWith: { first, _ in first })
        choices = choices.filter { sections[$0.key] == $0.value.section }
        result = r
        lastScan = .now
        if let free = r.freeBytes { freeBytes = free }
    }
}

extension CleanerStore {
    /// What Clean will really do with this item, with the Trash setting applied.
    func method(for f: Finding) -> Method {
        trashInstead ? (f.trashMethod ?? .trash) : f.method
    }
}
