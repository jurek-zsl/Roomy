import Foundation
import Testing

private let clues = sampleClues()

@Test func roomyOverridesRiskyVerdicts() {
    let review = FolderAdvice(summary: "s", kind: .userFiles, regrows: .no, verdict: .review, why: "w")
    let mine = AdvisorPrompt.guarded(review, clues)
    #expect(mine.verdict == .keep)
    #expect(mine.override == "Roomy never suggests removing your own files.")

    var data = review
    data.kind = .appData
    #expect(AdvisorPrompt.guarded(data, sampleClues(installed: true)).verdict == .keep, "installed app keeps its data")
    #expect(AdvisorPrompt.guarded(data, sampleClues(installed: false)).verdict == .review, "a removed app's data may go")

    var cache = review
    cache.kind = .cache
    #expect(AdvisorPrompt.guarded(cache, clues).verdict == .review)
    #expect(AdvisorPrompt.guarded(cache, clues).override == nil)
}

@Test func factsAreShortPlainLines() {
    let f = AdvisorPrompt.facts(clues, home: "/h")
    #expect(f.contains("Folder: ~/Library/Application Support/OldApp"))
    #expect(f.contains("Last change inside: 200 days ago"))
    #expect(f.contains("Named after the app \"OldApp\", which is NOT installed on this Mac"))
    #expect(f.contains("File types: .bin 2 kB") || f.contains("File types: .bin"))
    #expect(f.contains("It has cache or temp folders inside: Cache."))
}

@Test func userRulePatternsMatchOneFolder() {
    #expect(UserRules.pattern("/h/Library/Application Support/X", home: "/h") == "~/Library/Application Support/X")
    #expect(UserRules.pattern("/h/a [b] *c?", home: "/h") == "~/a [[]b[]] [*]c[?]")
    #expect(UserRules.pattern("/opt/x", home: "/h") == "/opt/x")
    #expect(UserRules.tomlString("say \"hi\" \\ now") == #""say \"hi\" \\ now""#)
    #expect(UserRules.id(for: "/a") == UserRules.id(for: "/a"))
    #expect(UserRules.id(for: "/a") != UserRules.id(for: "/b"))
}

@Test func userRulesAddAndRemove() throws {
    let rules = tempRules()
    #expect(rules.count() == 0)
    try rules.add(path: "/h/one", name: "One", explain: "first")
    try rules.add(path: "/h/two", name: "Two", explain: "second")
    try rules.add(path: "/h/one", name: "One", explain: "again")
    #expect(rules.count() == 2, "adding twice keeps one rule")
    try rules.remove("/h/one")
    #expect(!rules.contains("/h/one"))
    #expect(rules.contains("/h/two"))
    #expect(rules.count() == 1)
}
