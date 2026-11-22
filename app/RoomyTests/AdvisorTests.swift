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

@Test func roomyDecidesFromWhatTheModelSaw() {
    func decide(_ k: FolderKind, _ r: Regrows) -> AdviceVerdict { AdvisorPrompt.decide(kind: k, regrows: r).verdict }
    #expect(decide(.cache, .yes) == .review)
    #expect(decide(.aiModels, .yes) == .review)
    #expect(decide(.buildOutput, .yes) == .review)
    #expect(decide(.leftover, .no) == .review, "a removed app's data")
    #expect(decide(.installers, .no) == .review, "an installer isn't needed after installing")
    #expect(decide(.logs, .unsure) == .review)
    #expect(decide(.cache, .unsure) == .keep, "if it may not come back, leave it")
    #expect(decide(.userFiles, .yes) == .keep)
    #expect(decide(.appData, .yes) == .keep)
    #expect(decide(.toolchain, .yes) == .keep)
    #expect(decide(.unknown, .yes) == .keep)
    #expect(AdvisorPrompt.decide(kind: .cache, regrows: .yes).why == "It's a cache that comes back by itself when it's needed.")
}

@Test func adviceIsDecidedThenGuarded() {
    let a = AdvisorPrompt.advice(summary: "Gemini's chats.", kind: .cache, regrows: .yes, clues: sampleClues(running: true))
    #expect(a.summary == "Gemini's chats.")
    #expect(a.verdict == .keep, "a running owner keeps it")
    #expect(a.override != nil)
}

@Test func leftoverNeedsAMissingOwner() {
    var c = sampleClues(path: "/h/Library/Developer/CoreSimulator/Devices/X/data")
    c = FolderClues(path: c.path, name: "data", bytes: c.bytes, files: c.files, folders: c.folders, newestDays: 4,
                    types: c.types, biggest: c.biggest, owner: nil, markers: [])
    let a = AdvisorPrompt.advice(summary: "s", kind: .leftover, regrows: .yes, clues: c)
    #expect(a.verdict == .keep, "nothing shows its app is gone")
    #expect(AdvisorPrompt.advice(summary: "s", kind: .leftover, regrows: .no, clues: sampleClues(installed: false)).verdict == .review)
}

@Test func yourFoldersStay() {
    for p in ["/h/Documents/code/x/out", "/h/Desktop/a", "/h/Movies/b", "/h/Pictures/c", "/h/Music/d"] {
        let c = sampleClues(path: p)
        #expect(AdvisorPrompt.guarded(FolderAdvice(summary: "s", kind: .cache, regrows: .yes, verdict: .review, why: "w"), c, home: "/h").verdict == .keep, "\(p)")
    }
    let dl = sampleClues(path: "/h/Downloads/old-installers")
    #expect(AdvisorPrompt.guarded(FolderAdvice(summary: "s", kind: .installers, regrows: .no, verdict: .review, why: "w"), dl, home: "/h").verdict == .review)
}

@Test func databasesStay() {
    let base = sampleClues()
    let c = FolderClues(path: base.path, name: base.name, bytes: base.bytes, files: base.files, folders: base.folders,
                        newestDays: 5, types: base.types, biggest: base.biggest, owner: nil,
                        markers: ["42% of it is databases, which usually hold the app's own data (messages, settings, history)."])
    let a = AdvisorPrompt.advice(summary: "s", kind: .cache, regrows: .yes, clues: c)
    #expect(a.verdict == .keep)
    #expect(a.override == "It has databases, which usually hold an app's own data.")
}
