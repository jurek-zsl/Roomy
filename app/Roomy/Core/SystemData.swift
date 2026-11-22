import Foundation

/// What hides in "System Data": Time Machine's local snapshots, purgeable
/// space, and whether Time Machine backs up at all. All read-only; removing
/// snapshots goes through macOS's own password prompt.
enum SystemData {
    /// Dates from `tmutil listlocalsnapshotdates /` (2026-11-22-101530).
    static func snapshotDates(_ output: String) -> [Date] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return output.split(separator: "\n").compactMap { f.date(from: $0.trimmingCharacters(in: .whitespaces)) }.sorted()
    }

    /// Time Machine's backup disk from `tmutil destinationinfo`, if one is set up.
    static func destination(_ output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("Name") }
            .map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
    }

    /// Space macOS can free by itself when it needs it (caches, snapshots,
    /// iCloud files that are also in the cloud).
    static func purgeable(important: Int64?, available: Int64?) -> Int64? {
        guard let important, let available else { return nil }
        return max(0, important - available)
    }

    struct Facts: Equatable, Sendable {
        var snapshots: [Date] = []
        var backupDisk: String?
        var purgeable: Int64?
        var swap: Int64?
    }

    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func gather() -> Facts {
        var f = Facts()
        f.snapshots = snapshotDates(run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"]))
        f.backupDisk = destination(run("/usr/bin/tmutil", ["destinationinfo"]))
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        f.purgeable = purgeable(important: v?.volumeAvailableCapacityForImportantUsage, available: v?.volumeAvailableCapacity.map(Int64.init))
        let vm = (try? FileManager.default.contentsOfDirectory(atPath: "/private/var/vm")) ?? []
        f.swap = vm.reduce(Int64(0)) { sum, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: "/private/var/vm/" + name)[.size] as? Int64) ?? 0
            return sum + (size ?? 0)
        }
        return f
    }

    /// Delete every local snapshot. macOS asks for an administrator's password itself.
    static func deleteSnapshots() -> String? {
        let script = "do shell script \"/usr/bin/tmutil deletelocalsnapshots /\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        guard (try? p.run()) != nil else { return "Couldn't ask macOS." }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.contains("-128") ? "Cancelled." : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
