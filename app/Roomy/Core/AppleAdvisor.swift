import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Explains folders with Apple's on-device model (Apple Intelligence).
/// Nothing leaves the Mac, there's nothing to download or pay for, and on
/// Macs without it Roomy still shows its own facts.
struct AppleAdvisor: FolderAdvisor {
    let name = "Apple Intelligence"

    func status() -> AdvisorStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .notSupported
            }
        }
        #endif
        return .notSupported
    }

    func advise(_ clues: FolderClues) async throws -> FolderAdvice {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: AdvisorPrompt.instructions)
            let reply = try await session.respond(
                to: AdvisorPrompt.facts(clues),
                generating: GeneratedAdvice.self,
                options: GenerationOptions(temperature: 0.1))
            let g = reply.content
            return AdvisorPrompt.advice(summary: g.summary, kind: g.kind.kind, regrows: g.regrows.value, clues: clues)
        }
        #endif
        throw EngineError.failed("Apple Intelligence isn't available on this Mac.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedAdvice {
    @Guide(description: "One or two plain sentences: whose folder it is and what the biggest items are.")
    var summary: String
    @Guide(description: "The kind of content. leftover = data of an app or tool that is not installed anymore.")
    var kind: GeneratedKind
    @Guide(description: "If it is removed, will the app or tool download or rebuild it by itself?")
    var regrows: GeneratedRegrows
}

@available(macOS 26.0, *)
@Generable
enum GeneratedKind {
    case cache, appData, userFiles, buildOutput, aiModels, toolchain, installers, logs, leftover, unknown

    var kind: FolderKind {
        switch self {
        case .cache: .cache
        case .appData: .appData
        case .userFiles: .userFiles
        case .buildOutput: .buildOutput
        case .aiModels: .aiModels
        case .toolchain: .toolchain
        case .installers: .installers
        case .logs: .logs
        case .leftover: .leftover
        case .unknown: .unknown
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum GeneratedRegrows {
    case yes, no, unsure

    var value: Regrows {
        switch self {
        case .yes: .yes
        case .no: .no
        case .unsure: .unsure
        }
    }
}

#endif
