import Foundation
import Testing

/// A shell script standing in for the engine, so the real process code runs.
private func script(_ body: String) throws -> Engine {
    let dir = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "roomy-engine")
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return Engine(binary: url)
}

@Test func scanRunsTheEngine() async throws {
    let e = try script(#"""
    [ "$1 $2" = "scan --json" ] || exit 9
    echo 'Scanning...' >&2
    echo '{"free_bytes":5,"elapsed_ms":1,"findings":[]}'
    """#)
    let r = try await e.scan()
    #expect(r.freeBytes == 5)
}

@Test func missingEngineIsReported() async {
    let e = Engine(binary: URL(fileURLWithPath: "/nonexistent/roomy-engine"))
    await #expect(throws: EngineError.missing) { try await e.scan() }
}

@Test func failingEngineShowsItsMessage() async throws {
    let e = try script("echo 'error: built-in rules: bad' >&2\nexit 1\n")
    await #expect(throws: EngineError.failed("error: built-in rules: bad")) { try await e.scan() }
}

@Test func cleanPassesPathsAsArguments() async throws {
    let e = try script(#"""
    [ "$1" = "clean" ] && [ "$2" = "--json" ] && [ "$3" = "--trash" ] && [ "$4" = "--" ] && [ "$5" = "/h/My Code/it's" ] || exit 9
    echo '{"event":"plan","items":1,"bytes":3}'
    echo '{"event":"done","cleaned":0,"skipped":0,"failed":0,"free_before":null,"free_after":null,"trashed_bytes":0}'
    """#)
    var got: [CleanEvent] = []
    for try await ev in e.clean(paths: ["/h/My Code/it's"], trash: true) { got.append(ev) }
    #expect(got.count == 2)
    #expect(got.first == .plan(items: 1, bytes: 3))
}

@Test func cleanKeepsReadingAfterABadLine() async throws {
    let e = try script(#"""
    echo '{"event":"plan","items":1,"bytes":3}'
    echo 'something odd'
    echo '{"event":"done","cleaned":1,"skipped":0,"failed":0,"free_before":1,"free_after":4,"trashed_bytes":0}'
    """#)
    var got: [CleanEvent] = []
    await #expect(throws: EngineError.badOutput("something odd")) {
        for try await ev in e.clean(paths: ["/h/a"], trash: false) { got.append(ev) }
    }
    #expect(got.count == 2, "events after the bad line still arrive")
}

@Test func cleanThatDiesEarlyIsAnError() async throws {
    let e = try script("echo 'boom' >&2\nexit 3\n")
    await #expect(throws: EngineError.failed("boom")) {
        for try await _ in e.clean(paths: ["/h/a"], trash: false) {}
    }
}

/// Many engine runs at once must all finish: reads may not block Swift's
/// shared threads, and pipe ends may not leak into other runs.
@Test(.timeLimit(.minutes(1))) func manyRunsAtOnceAllFinish() async throws {
    let e = try script(#"""
    sleep 0.2
    echo '{"event":"plan","items":0,"bytes":0}'
    echo 'note' >&2
    echo '{"event":"done","cleaned":0,"skipped":0,"failed":0,"free_before":null,"free_after":null,"trashed_bytes":0}'
    """#)
    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<30 {
            group.addTask {
                var n = 0
                for try await _ in e.clean(paths: ["/h/a"], trash: false) { n += 1 }
                return n
            }
        }
        for try await n in group { #expect(n == 2) }
    }
}
