import AppKit
import Foundation
import Observation

// MARK: - Engine output (`uninstall --json`, `leftovers --json`)

struct AppFile: Decodable, Sendable, Equatable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
    /// "Support files", "Caches", "Settings"…
    let what: String
    /// In /Library: removing it needs an administrator.
    let admin: Bool
}

struct UninstallPlan: Decodable, Sendable, Equatable {
    let app: String
    let name: String
    let bundleId: String?
    let appBytes: Int64
    let running: Bool
    let items: [AppFile]

    var totalBytes: Int64 { appBytes + items.reduce(0) { $0 + $1.bytes } }
    static func decode(_ data: Data) throws -> UninstallPlan { try engineDecoder().decode(UninstallPlan.self, from: data) }
}

struct Orphan: Decodable, Sendable, Equatable, Identifiable {
    var id: String { bundleId }
    let bundleId: String
    let items: [AppFile]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    static func decodeList(_ data: Data) throws -> [Orphan] { try engineDecoder().decode([Orphan].self, from: data) }
}

struct RemovedFile: Decodable, Sendable, Equatable {
    let path: String
    let trashed: String?
    let error: String?
    static func decodeList(_ data: Data) throws -> [RemovedFile] { try engineDecoder().decode([RemovedFile].self, from: data) }
}

/// Something a package manager installed (`packages --json`).
struct Package: Decodable, Sendable, Equatable, Identifiable {
    var id: String { manager + "/" + name }
    let manager: String
    let name: String
    let version: String?
    let description: String?
    let path: String
    let bytes: Int64
    let requested: Bool
    let neededBy: [String]
    let lastUsedDays: Int64?

    var managerTitle: String {
        switch manager {
        case "brew": "Homebrew"
        case "cask": "Homebrew app"
        case "npm": "npm"
        case "uv": "uv tool"
        case "pipx": "pipx"
        default: manager
        }
    }
    /// The command that removes it, as Roomy will run it.
    var command: String {
        switch manager {
        case "brew": "brew uninstall \(name)"
        case "cask": "brew uninstall --cask \(name)"
        case "npm": "npm uninstall -g \(name)"
        case "uv": "uv tool uninstall \(name)"
        default: "pipx uninstall \(name)"
        }
    }
}

struct PackageList: Decodable, Sendable, Equatable {
    let packages: [Package]
    let autoremove: [String]
    static func decode(_ data: Data) throws -> PackageList { try engineDecoder().decode(PackageList.self, from: data) }
}

struct CommandOutcome: Decodable, Sendable, Equatable {
    let command: String
    let ok: Bool
    let error: String?
    static func decode(_ data: Data) throws -> CommandOutcome { try engineDecoder().decode(CommandOutcome.self, from: data) }
}

/// An app on this Mac, for the list.
struct InstalledApp: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bundleId: String?
    var bytes: Int64?

    /// Apple's own apps can't (and shouldn't) be removed.
    var isApple: Bool { bundleId?.hasPrefix("com.apple.") == true }

    /// Apps in /Applications and ~/Applications, one level of folders deep.
    static func scan(home: String = NSHomeDirectory()) -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        func add(_ dir: String, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    let id = Bundle(path: path)?.bundleIdentifier
                    out.append(InstalledApp(path: path, name: String(name.dropLast(4)), bundleId: id))
                } else if depth < 1, (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    add(path, depth: depth + 1)
                }
            }
        }
        add("/Applications", depth: 0)
        add(home + "/Applications", depth: 0)
        return out.filter { !$0.isApple }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Space on disk, adding up every file inside.
    static func size(_ path: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - State

/// Uninstalling apps with everything they left, and leftovers of apps
/// already gone. Everything goes to the Trash; Apple's apps are left out.
@MainActor @Observable
final class Uninstaller {
    enum Load: Equatable { case idle, loading, ready, failed(String) }

    private let engine: any CleanEngine
    private let listApps: @Sendable () -> [InstalledApp]

    private(set) var apps: [InstalledApp] = []
    var selectedApp: InstalledApp.ID?
    private(set) var plan: UninstallPlan?
    private(set) var planState: Load = .idle
    /// Files of the selected app to remove; the app itself is `removeApp`.
    var chosen: Set<String> = []
    var removeApp = true
    private(set) var packages: PackageList?
    private(set) var packageState: Load = .idle
    /// The package being removed right now.
    private(set) var removing: Package.ID?
    private(set) var orphans: [Orphan] = []
    private(set) var orphanState: Load = .idle
    var chosenOrphans: Set<String> = []
    private(set) var working = false
    /// What the last removal did, in words.
    private(set) var report: String?
    private(set) var skipped: [RemovedFile] = []

    init(engine: any CleanEngine, listApps: @escaping @Sendable () -> [InstalledApp] = { InstalledApp.scan() }) {
        self.engine = engine
        self.listApps = listApps
    }

    func loadApps() async {
        let list = listApps
        apps = await Task.detached { list() }.value
        // Sizes come in one by one in the background.
        for app in apps where app.bytes == nil {
            let path = app.path
            let bytes = await Task.detached(priority: .utility) { InstalledApp.size(path) }.value
            if let i = apps.firstIndex(where: { $0.path == path }) { apps[i].bytes = bytes }
        }
    }

    func select(_ id: InstalledApp.ID?) async {
        selectedApp = id
        report = nil
        skipped = []
        plan = nil
        guard let id else { planState = .idle; return }
        planState = .loading
        do {
            let p = try await engine.uninstallPlan(app: id)
            guard selectedApp == id else { return }
            plan = p
            chosen = Set(p.items.filter { !$0.admin }.map(\.path))
            removeApp = true
            planState = .ready
        } catch {
            planState = .failed(error.localizedDescription)
        }
    }

    var chosenBytes: Int64 {
        guard let plan else { return 0 }
        return (removeApp ? plan.appBytes : 0) + plan.items.filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    /// Move the app and the ticked files to the Trash.
    func uninstall() async {
        guard let plan, !plan.running, !working else { return }
        let paths = (removeApp ? [plan.app] : []) + plan.items.filter { chosen.contains($0.path) && !$0.admin }.map(\.path)
        guard !paths.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let done = try await engine.uninstall(app: plan.app, paths: paths)
            finish(done, what: removeApp ? plan.name : "\(plan.name)'s files")
            if removeApp, done.contains(where: { $0.path == plan.app && $0.error == nil }) {
                apps.removeAll { $0.path == plan.app }
                selectedApp = nil
                self.plan = nil
                planState = .idle
            } else {
                await select(plan.app)
            }
        } catch {
            report = "Couldn't uninstall: \(error.localizedDescription)"
        }
    }

    func loadPackages() async {
        packageState = .loading
        do {
            packages = try await engine.packages()
            packageState = .ready
        } catch {
            packageState = .failed(error.localizedDescription)
        }
    }

    /// Remove one package with its manager's own uninstall command.
    func remove(_ p: Package) async {
        guard removing == nil, p.neededBy.isEmpty else { return }
        removing = p.id
        defer { removing = nil }
        do {
            let r = try await engine.removePackage(manager: p.manager, name: p.name)
            report = r.ok ? "Removed \(p.name) with \(r.command)." : "\(r.command) didn't work: \(r.error ?? "unknown error")"
            if r.ok { await loadPackages() }
        } catch {
            report = "Couldn't remove \(p.name): \(error.localizedDescription)"
        }
    }

    /// `brew autoremove`: dependencies nothing needs anymore.
    func autoremove() async {
        guard removing == nil else { return }
        removing = "autoremove"
        defer { removing = nil }
        do {
            let r = try await engine.brewAutoremove()
            report = r.ok ? "Removed \(packages?.autoremove.count ?? 0) dependencies nothing needed." : "brew autoremove didn't work: \(r.error ?? "unknown error")"
            await loadPackages()
        } catch {
            report = "brew autoremove didn't work: \(error.localizedDescription)"
        }
    }

    func loadOrphans() async {
        orphanState = .loading
        do {
            orphans = try await engine.leftovers()
            chosenOrphans = []
            orphanState = .ready
        } catch {
            orphanState = .failed(error.localizedDescription)
        }
    }

    func removeOrphans() async {
        let paths = orphans.filter { chosenOrphans.contains($0.id) }.flatMap(\.items).map(\.path)
        guard !paths.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            finish(try await engine.removeLeftovers(paths: paths), what: "the leftovers")
            await loadOrphans()
        } catch {
            report = "Couldn't remove them: \(error.localizedDescription)"
        }
    }

    private func finish(_ done: [RemovedFile], what: String) {
        let moved = done.filter { $0.error == nil }.count
        skipped = done.filter { $0.error != nil }
        report = moved == 0 ? "Nothing was moved." : "Moved \(what) to the Trash (\(moved) item\(moved == 1 ? "" : "s")). Empty the Trash to get the space back."
    }

    /// Ask the app to quit, the normal way (it can ask to save first).
    func quit(_ plan: UninstallPlan) {
        guard let id = plan.bundleId else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }
}
