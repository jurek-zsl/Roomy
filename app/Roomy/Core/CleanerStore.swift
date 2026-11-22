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
    }

    /// Ticks the user changed, by path. A choice counts only while the item
    /// stays in the section it was made in.
    private var choices: [String: Choice] = [:]
    @ObservationIgnored private let engine: any CleanEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var freeTask: Task<Void, Never>?
    @ObservationIgnored private let notify: @Sendable (String) -> Void

    init(engine: any CleanEngine, defaults: UserDefaults = .standard, notify: @escaping @Sendable (String) -> Void = { _ in }) {
        self.engine = engine
        self.defaults = defaults
        self.notify = notify
        trashInstead = defaults.bool(forKey: Keys.trash)
        hasSeenIntro = defaults.bool(forKey: Keys.intro)
        lowSpaceAlerts = defaults.bool(forKey: Keys.lowSpace)
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
