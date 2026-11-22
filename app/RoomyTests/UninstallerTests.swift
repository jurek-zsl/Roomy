import Foundation
import Testing

private final class AppEngine: CleanEngine, @unchecked Sendable {
    var plan: UninstallPlan
    var orphanList: [Orphan] = []
    private(set) var removed: [[String]] = []
    init(plan: UninstallPlan) { self.plan = plan }
    func scan() async throws -> ScanResult { throw EngineError.missing }
    func map() async throws -> DiskMap { throw EngineError.missing }
    func inspect(path: String) async throws -> FolderClues { throw EngineError.missing }
    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func uninstallPlan(app: String) async throws -> UninstallPlan { plan }
    func uninstall(app: String, paths: [String]) async throws -> [RemovedFile] {
        removed.append(paths)
        return paths.map { RemovedFile(path: $0, trashed: "/T/x", error: nil) }
    }
    func leftovers() async throws -> [Orphan] { orphanList }
    func removeLeftovers(paths: [String]) async throws -> [RemovedFile] {
        removed.append(paths)
        orphanList = []
        return paths.map { RemovedFile(path: $0, trashed: "/T/x", error: nil) }
    }
}

private let slack = "/Applications/Slack.app"
private func plan(running: Bool = false) -> UninstallPlan {
    UninstallPlan(app: slack, name: "Slack", bundleId: "com.tinyspeck.slackmacgap", appBytes: 500, running: running, items: [
        AppFile(path: "/h/Library/Caches/com.tinyspeck.slackmacgap", bytes: 300, what: "Caches", admin: false),
        AppFile(path: "/h/Library/Application Support/Slack", bytes: 200, what: "Support files", admin: false),
        AppFile(path: "/Library/LaunchDaemons/com.tinyspeck.helper.plist", bytes: 1, what: "Background service", admin: true),
    ])
}

@Test func decodesTheEnginesUninstallPlan() throws {
    let p = try UninstallPlan.decode(Data(#"""
    {"app":"/Applications/Slack.app","name":"Slack","bundle_id":"com.tinyspeck.slackmacgap","app_bytes":5,"running":false,
     "items":[{"path":"/h/x","bytes":3,"what":"Caches","admin":false}]}
    """#.utf8))
    #expect(p.totalBytes == 8)
    #expect(p.items.first?.what == "Caches")
    let o = try Orphan.decodeList(Data(#"[{"bundle_id":"com.gone.app","items":[{"path":"/h/y","bytes":4,"what":"Settings","admin":false}]}]"#.utf8))
    #expect(o.first?.bytes == 4)
}

@MainActor @Test func uninstallTakesTheAppAndTickedFilesNotAdminOnes() async {
    let engine = AppEngine(plan: plan())
    let u = Uninstaller(engine: engine, listApps: { [InstalledApp(path: slack, name: "Slack", bundleId: "com.tinyspeck.slackmacgap", bytes: 500)] })
    await u.loadApps()
    await u.select(slack)
    #expect(u.chosen == ["/h/Library/Caches/com.tinyspeck.slackmacgap", "/h/Library/Application Support/Slack"], "admin files start unticked")
    #expect(u.chosenBytes == 1_000)
    u.chosen.remove("/h/Library/Application Support/Slack")
    await u.uninstall()
    #expect(engine.removed == [[slack, "/h/Library/Caches/com.tinyspeck.slackmacgap"]])
    #expect(u.apps.isEmpty, "the app is gone from the list")
    #expect(u.report?.hasPrefix("Moved Slack to the Trash") == true)
}

@MainActor @Test func aRunningAppIsntUninstalled() async {
    let engine = AppEngine(plan: plan(running: true))
    let u = Uninstaller(engine: engine, listApps: { [] })
    await u.select(slack)
    await u.uninstall()
    #expect(engine.removed.isEmpty)
}

@MainActor @Test func leftoversOfRemovedApps() async {
    let engine = AppEngine(plan: plan())
    engine.orphanList = [Orphan(bundleId: "com.gone.app", items: [AppFile(path: "/h/Library/Caches/com.gone.app", bytes: 9, what: "Caches", admin: false)])]
    let u = Uninstaller(engine: engine, listApps: { [] })
    await u.loadOrphans()
    #expect(u.orphans.count == 1)
    u.chosenOrphans = ["com.gone.app"]
    await u.removeOrphans()
    #expect(engine.removed == [["/h/Library/Caches/com.gone.app"]])
    #expect(u.orphans.isEmpty)
}
