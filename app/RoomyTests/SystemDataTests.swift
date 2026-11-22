import Foundation
import Testing

@Test func readsTimeMachineOutput() {
    let dates = SystemData.snapshotDates("Snapshot dates for disk /:\n2026-11-22-101530\n2026-11-21-091500\n")
    #expect(dates.count == 2)
    #expect(dates[0] < dates[1], "oldest first")
    #expect(SystemData.snapshotDates("Snapshot dates for disk /:\n").isEmpty)
    #expect(SystemData.destination("tmutil: No destinations configured.") == nil)
    #expect(SystemData.destination("====\nName          : Backup Disk\nKind          : Local\n") == "Backup Disk")
    #expect(SystemData.purgeable(important: 50, available: 30) == 20)
    #expect(SystemData.purgeable(important: 10, available: 30) == 0)
    #expect(SystemData.purgeable(important: nil, available: 30) == nil)
}
