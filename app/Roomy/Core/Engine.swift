import Foundation

/// What the store needs from the engine. The real one runs the bundled
/// `roomy-engine` program; tests use a scripted one.
protocol CleanEngine: Sendable {
    func scan() async throws -> ScanResult
    /// Where the disk space goes (`map --json`). Read-only; takes up to a minute.
    func map() async throws -> DiskMap
    /// Clues about one folder (`inspect --json`). Read-only.
    func inspect(path: String) async throws -> FolderClues
    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error>
    /// What uninstalling an app would remove. Read-only.
    func uninstallPlan(app: String) async throws -> UninstallPlan
    /// Move the app and/or its files to the Trash.
    func uninstall(app: String, paths: [String]) async throws -> [RemovedFile]
    /// Files of apps that aren't installed. Read-only.
    func leftovers() async throws -> [Orphan]
    func removeLeftovers(paths: [String]) async throws -> [RemovedFile]
    /// Homebrew packages and global tools. Read-only.
    func packages() async throws -> PackageList
    func removePackage(manager: String, name: String) async throws -> CommandOutcome
    func brewAutoremove() async throws -> CommandOutcome
}

extension CleanEngine {
    func uninstallPlan(app: String) async throws -> UninstallPlan { throw EngineError.failed("not supported") }
    func uninstall(app: String, paths: [String]) async throws -> [RemovedFile] { throw EngineError.failed("not supported") }
    func leftovers() async throws -> [Orphan] { [] }
    func removeLeftovers(paths: [String]) async throws -> [RemovedFile] { [] }
    func packages() async throws -> PackageList { PackageList(packages: [], autoremove: []) }
    func removePackage(manager: String, name: String) async throws -> CommandOutcome { throw EngineError.failed("not supported") }
    func brewAutoremove() async throws -> CommandOutcome { throw EngineError.failed("not supported") }
}

/// Runs the Rust engine as a program and reads its JSON. Arguments go to it
/// directly (no shell), so paths with spaces or quotes are safe.
struct Engine: CleanEngine {
    let binary: URL
    /// Your accepted Review rules, added to the built-in ones when the file exists.
    var rulesFile: URL?

    private var extraRules: [String] {
        guard let f = rulesFile, FileManager.default.fileExists(atPath: f.path) else { return [] }
        return ["--rules", f.path]
    }

    /// The engine inside the app, or `ROOMY_ENGINE` if set.
    static func bundled() -> Engine {
        if let p = ProcessInfo.processInfo.environment["ROOMY_ENGINE"], !p.isEmpty {
            return Engine(binary: URL(fileURLWithPath: p), rulesFile: UserRules.standard.file)
        }
        let url = Bundle.main.url(forAuxiliaryExecutable: "roomy-engine")
            ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/roomy-engine")
        return Engine(binary: url, rulesFile: UserRules.standard.file)
    }

    func scan() async throws -> ScanResult {
        try await Engine.json(binary, ["scan", "--json"] + extraRules, ScanResult.decode)
    }

    func map() async throws -> DiskMap {
        try await Engine.json(binary, ["map", "--json"] + extraRules, DiskMap.decode)
    }

    func inspect(path: String) async throws -> FolderClues {
        try await Engine.json(binary, ["inspect", "--json", path], FolderClues.decode)
    }

    func uninstallPlan(app: String) async throws -> UninstallPlan {
        try await Engine.json(binary, ["uninstall", "--json", app], UninstallPlan.decode)
    }

    func uninstall(app: String, paths: [String]) async throws -> [RemovedFile] {
        try await Engine.json(binary, ["uninstall", "--json", "--remove", app, "--"] + paths, RemovedFile.decodeList)
    }

    func leftovers() async throws -> [Orphan] {
        try await Engine.json(binary, ["leftovers", "--json"], Orphan.decodeList)
    }

    func removeLeftovers(paths: [String]) async throws -> [RemovedFile] {
        try await Engine.json(binary, ["leftovers", "--json", "--remove", "--"] + paths, RemovedFile.decodeList)
    }

    func packages() async throws -> PackageList {
        try await Engine.json(binary, ["packages", "--json"], PackageList.decode)
    }

    func removePackage(manager: String, name: String) async throws -> CommandOutcome {
        try await Engine.json(binary, ["packages", "--json", "--remove", manager, name], CommandOutcome.decode)
    }

    func brewAutoremove() async throws -> CommandOutcome {
        try await Engine.json(binary, ["packages", "--json", "--autoremove"], CommandOutcome.decode)
    }

    /// Run the engine once and decode what it prints. Blocking reads run on
    /// a dispatch thread, never on Swift's shared threads: many runs at once
    /// would starve them and hang.
    private static func json<T: Sendable>(_ binary: URL, _ args: [String], _ decode: @escaping @Sendable (Data) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(with: Result {
                    let run = try start(binary, args)
                    let stderr = collect(run.err)
                    let data = (try? run.out.readToEnd()) ?? Data()
                    run.process.waitUntilExit()
                    guard run.process.terminationStatus == 0 else { throw EngineError.failed(tail(stderr.wait())) }
                    do {
                        return try decode(data)
                    } catch {
                        throw EngineError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
                    }
                })
            }
        }
    }

    /// Streams `clean --json` events as they come. A line that isn't an event
    /// is remembered and reported at the end; reading goes on, so the engine
    /// never blocks on a full pipe in the middle of cleaning.
    func clean(paths: [String], trash: Bool) -> AsyncThrowingStream<CleanEvent, Error> {
        let binary = binary
        let args = ["clean", "--json"] + extraRules + (trash ? ["--trash"] : []) + ["--"] + paths
        return AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let run = try Engine.start(binary, args)
                    let stderr = Engine.collect(run.err)
                    var sawDone = false
                    var badLine: String?
                    var buffer = Data()
                    func handle(_ bytes: Data) {
                        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { return }
                        do {
                            let event = try CleanEvent.decode(line: line)
                            if case .done = event { sawDone = true }
                            continuation.yield(event)
                        } catch {
                            if badLine == nil { badLine = line }
                        }
                    }
                    while true {
                        let chunk = run.out.availableData  // empty at end of output
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            handle(Data(buffer[buffer.startIndex..<nl]))
                            buffer = Data(buffer[buffer.index(after: nl)...])
                        }
                    }
                    handle(buffer)
                    run.process.waitUntilExit()
                    let errText = stderr.wait()
                    if let badLine { throw EngineError.badOutput(badLine) }
                    if !sawDone {
                        let why = run.process.terminationStatus == 0 ? "it ended without finishing" : Engine.tail(errText)
                        throw EngineError.failed(why)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private struct Running {
        let process: Process
        let out: FileHandle
        let err: FileHandle
    }

    private static func start(_ binary: URL, _ args: [String]) throws -> Running {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw EngineError.missing }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        // Keep these pipe ends out of any other program started meanwhile;
        // a leaked write end means the output never ends.
        for h in [out.fileHandleForReading, out.fileHandleForWriting, err.fileHandleForReading, err.fileHandleForWriting] {
            _ = fcntl(h.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            throw EngineError.failed("couldn't start it: \(error.localizedDescription)")
        }
        // Only the engine writes; our copies of the write ends must close.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        return Running(process: p, out: out.fileHandleForReading, err: err.fileHandleForReading)
    }

    /// Reads stderr to the end on its own thread.
    private final class Collected: @unchecked Sendable {
        private var text = ""
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .utility).async {
                self.text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                self.done.signal()
            }
        }

        func wait() -> String {
            done.wait()
            return text
        }
    }

    private static func collect(_ handle: FileHandle) -> Collected {
        Collected(handle)
    }

    /// The last few lines the engine printed to stderr, for error messages.
    static func tail(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Scanning..." }
        return lines.isEmpty ? "it stopped with no message" : lines.suffix(3).joined(separator: " / ")
    }
}
