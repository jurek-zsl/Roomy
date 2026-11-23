import Foundation
import Observation
import ServiceManagement

/// One automatic cleaning run, as the engine noted it.
struct AutoRun: Equatable, Sendable {
    var at: Date
    var freed: Int64
    var cleaned: Int
    var skipped: Int
}

/// The history the engine writes after each `clean --auto`, one JSON line per run.
enum AutoCleanHistory {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Roomy/auto-clean.jsonl")
    }

    static func parse(_ text: String) -> [AutoRun] {
        text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = (o["at"] as? NSNumber)?.doubleValue else { return nil }
            return AutoRun(at: Date(timeIntervalSince1970: at),
                           freed: (o["freed"] as? NSNumber)?.int64Value ?? 0,
                           cleaned: (o["cleaned"] as? NSNumber)?.intValue ?? 0,
                           skipped: (o["skipped"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Bytes freed by runs since a date.
    static func freed(_ runs: [AutoRun], since: Date) -> Int64 {
        runs.filter { $0.at >= since }.reduce(0) { $0 + $1.freed }
    }
}

/// Automatic cleaning: a background agent (inside Roomy.app) that runs the
/// engine's `clean --auto --if-due` every few hours, whether Roomy is open
/// or not. It only removes caches and logs marked for it, of closed apps.
@MainActor @Observable
final class AutoClean {
    enum State: Equatable {
        case off, on, needsApproval
        case failed(String)
    }

    static let daysKey = "autoCleanDays"
    static let choices = [1, 7, 30]

    private(set) var state: State = .off
    private(set) var runs: [AutoRun] = []
    var everyDays: Int {
        didSet { defaults.set(everyDays, forKey: Self.daysKey) }
    }

    private let defaults: UserDefaults
    private let service = SMAppService.agent(plistName: "dev.roomy.autoclean.plist")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.daysKey)
        everyDays = Self.choices.contains(saved) ? saved : 7
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        default: if case .failed = state {} else { state = .off }
        }
        runs = AutoCleanHistory.parse((try? String(contentsOf: AutoCleanHistory.url, encoding: .utf8)) ?? "")
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                defaults.set(everyDays, forKey: Self.daysKey)
                try service.register()
            } else {
                try service.unregister()
            }
            state = .off
        } catch {
            state = .failed(on ? "Couldn't turn it on: \(error.localizedDescription) Moving Roomy to Applications may help."
                               : "Couldn't turn it off: \(error.localizedDescription)")
        }
        let failed = state
        refresh()
        if case .failed = failed, state == .off { state = failed }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
