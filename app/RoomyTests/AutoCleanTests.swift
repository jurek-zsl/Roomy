import Foundation
import Testing

@Test func readsTheAutomaticCleaningHistory() {
    let text = """
    {"at":1795000000,"freed":1200000000,"cleaned":40,"skipped":3,"failed":0}
    not json
    {"at":1795600000,"freed":300000000,"cleaned":12,"skipped":0,"failed":0}

    """
    let runs = AutoCleanHistory.parse(text)
    #expect(runs.count == 2)
    #expect(runs[0] == AutoRun(at: Date(timeIntervalSince1970: 1_795_000_000), freed: 1_200_000_000, cleaned: 40, skipped: 3))
    #expect(AutoCleanHistory.freed(runs, since: Date(timeIntervalSince1970: 1_795_100_000)) == 300_000_000)
    #expect(AutoCleanHistory.parse("").isEmpty)
}

@MainActor @Test func remembersHowOften() {
    let d = freshDefaults()
    #expect(AutoClean(defaults: d).everyDays == 7, "weekly unless set")
    d.set(30, forKey: AutoClean.daysKey)
    #expect(AutoClean(defaults: d).everyDays == 30)
    d.set(5, forKey: AutoClean.daysKey)
    #expect(AutoClean(defaults: d).everyDays == 7, "only the offered choices")
}
