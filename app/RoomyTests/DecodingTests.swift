import Foundation
import Testing

// Copied from real `roomy scan --json` output, paths shortened.
private let scanJSON = """
{
  "free_bytes": 61800000000,
  "elapsed_ms": 996,
  "findings": [
    {"rule": "pnpm-store", "category": "package-cache", "risk": "safe", "status": "ready", "reason": null,
     "path": "/Users/me/Library/pnpm/store", "bytes_on_disk": 958000000, "bytes_freed": 820260864, "files": 1200,
     "clean": "pnpm store prune", "explain": "pnpm's package store.", "name": "pnpm packages",
     "section": "safe-now", "method": {"kind": "command", "command": "pnpm store prune"}},
    {"rule": "claude-code-old-version", "category": "old-version", "risk": "review", "status": "ready", "reason": null,
     "path": "/Users/me/.local/share/claude/versions/2.1.328", "bytes_on_disk": 354631680, "bytes_freed": 354631680, "files": 3,
     "clean": "rm -rf /Users/me/.local/share/claude/versions/2.1.328", "explain": "An older Claude Code version.",
     "name": "Old Claude Code version", "section": "review", "method": {"kind": "trash"}},
    {"rule": "uv-cache", "category": "package-cache", "risk": "safe", "status": "blocked",
     "reason": "another program is using it (lock held)", "path": "/Users/me/.cache/uv", "bytes_on_disk": 3100000000,
     "bytes_freed": 456478720, "files": 9000, "clean": "uv cache clean", "explain": "uv's cache.", "name": "uv Python cache",
     "section": "blocked", "method": {"kind": "command", "command": "uv cache clean"}}
  ]
}
"""

@Test func decodesScanDocument() throws {
    let r = try ScanResult.decode(Data(scanJSON.utf8))
    #expect(r.freeBytes == 61_800_000_000)
    #expect(r.elapsedMs == 996)
    #expect(r.findings.count == 3)
    let pnpm = r.findings[0]
    #expect(pnpm.id == "/Users/me/Library/pnpm/store")
    #expect(pnpm.section == .safeNow)
    #expect(pnpm.risk == .safe)
    #expect(pnpm.method == .command("pnpm store prune"))
    #expect(pnpm.bytesFreed == 820_260_864)
    #expect(pnpm.bytesOnDisk == 958_000_000)
    #expect(pnpm.name == "pnpm packages")
    #expect(r.findings[1].method == .trash)
    #expect(r.findings[1].risk == .review)
    #expect(r.findings[2].section == .blocked)
    #expect(r.findings[2].status == .blocked)
    #expect(r.findings[2].reason == "another program is using it (lock held)")
}

@Test func decodesEveryEvent() throws {
    #expect(try CleanEvent.decode(line: #"{"event":"plan","items":2,"bytes":5}"#) == .plan(items: 2, bytes: 5))

    let cleaned = try CleanEvent.decode(line: #"{"event":"item","index":1,"path":"/h/a","rule":"r","name":"R","bytes":7,"outcome":{"result":"cleaned","method":{"kind":"delete"},"note":null}}"#)
    #expect(cleaned == .item(CleanItem(index: 1, path: "/h/a", rule: "r", name: "R", bytes: 7, outcome: .cleaned(.delete, note: nil))))

    let skipped = try CleanEvent.decode(line: #"{"event":"item","index":2,"path":"/h/b","rule":"","name":"","bytes":0,"outcome":{"result":"skipped","reason":"the scan doesn't find it anymore"}}"#)
    #expect(skipped == .item(CleanItem(index: 2, path: "/h/b", rule: "", name: "", bytes: 0, outcome: .skipped(reason: "the scan doesn't find it anymore"))))

    let failed = try CleanEvent.decode(line: #"{"event":"item","index":3,"path":"/h/c","rule":"r","name":"R","bytes":1,"outcome":{"result":"failed","method":{"kind":"command","command":"brew cleanup"},"error":"ended with code 1"}}"#)
    #expect(failed == .item(CleanItem(index: 3, path: "/h/c", rule: "r", name: "R", bytes: 1, outcome: .failed(.command("brew cleanup"), error: "ended with code 1"))))

    let done = try CleanEvent.decode(line: #"{"event":"done","cleaned":1,"skipped":1,"failed":1,"free_before":10,"free_after":null,"trashed_bytes":4}"#)
    #expect(done == .done(CleanDone(cleaned: 1, skipped: 1, failed: 1, freeBefore: 10, freeAfter: nil, trashedBytes: 4)))

    #expect(try CleanEvent.decode(line: #"{"event":"error","message":"bad rules"}"#) == .error("bad rules"))
}

@Test func garbageLineIsAnError() {
    #expect(throws: (any Error).self) { try CleanEvent.decode(line: "Scanning...") }
    #expect(throws: (any Error).self) { try CleanEvent.decode(line: #"{"event":"party"}"#) }
}


@Test func decodesDetailAndTrashMethod() throws {
    let json = #"""
    {"free_bytes": 1, "elapsed_ms": 2, "findings": [{
      "rule": "simulator-runtime", "name": "iOS 27.2 Simulator runtime", "category": "xcode", "risk": "review",
      "status": "ready", "section": "review", "reason": null, "path": "/System/Library/AssetsV2/x",
      "bytes_on_disk": 8000, "bytes_freed": 8000, "files": 0, "clean": "xcrun simctl runtime delete A",
      "explain": "e", "detail": "iOS 27.2: unused.", "label": "iOS 27.2 Simulator runtime",
      "method": {"kind": "command", "command": "xcrun simctl runtime delete A"},
      "trash_method": {"kind": "command", "command": "xcrun simctl runtime delete A"}}]}
    """#
    let f = try ScanResult.decode(Data(json.utf8)).findings[0]
    #expect(f.detail == "iOS 27.2: unused.")
    #expect(f.trashMethod == .command("xcrun simctl runtime delete A"))
}

@Test func decodesDiskMap() throws {
    let json = #"""
    {"total_bytes": 245000000000, "used_bytes": 180700000000, "free_bytes": 64300000000,
     "mapped_bytes": 112000000000, "cleanable_bytes": 3000000000, "elapsed_ms": 13984,
     "roots": [{"path": "/Users/me", "name": "/Users/me", "kind": "folder", "bytes": 61400000000, "cleanable": 3000000000,
                "children": [{"path": "/Users/me/Pictures/Photos Library.photoslibrary", "name": "Photos Library.photoslibrary",
                              "kind": "personal", "bytes": 9000000000, "cleanable": 0, "children": []},
                             {"path": "/Users/me", "name": "Smaller items", "kind": "other", "bytes": 1000, "cleanable": 0, "children": []}]}]}
    """#
    let m = try DiskMap.decode(Data(json.utf8))
    #expect(m.usedBytes == 180_700_000_000)
    #expect(m.roots[0].children[0].kind == .personal)
    #expect(m.roots[0].children[1].kind == .other)
    #expect(m.roots[0].children[0].id != m.roots[0].id, "a grouped row has its own id")
}
