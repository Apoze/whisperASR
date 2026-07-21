import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseTranslationControlTests: XCTestCase {
    private struct Turn: Codable {
        let corpusID: String
        let turnID: Int
        let startSample: Int
        let endSample: Int
        let english: String
        let milliseconds: Double
        let attemptCount: Int
        let error: String?
    }

    private struct Corpus: Codable {
        let corpusID: String
        let manifestSHA256: String
        let annotationStatus: String
        let turnCount: Int
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let runID: String
        let gitCommit: String
        let sourceTreeSHA256: String
        let runtimeSHA256: String
        let worktreeDirty: Bool
        let networkDenied: Bool
        let generatedAt: String
        let translationPath: String
        let setupMilliseconds: Double
        let corpora: [Corpus]
        let turns: [Turn]
    }

    @MainActor
    func testHumanJapaneseToAppleFinalWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_L7C_TRANSLATION_CONTROL"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_l7c_replay.sh.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple highFidelity Translation requires macOS 26.4.")
        }
        guard let commit = environment["WHISPERASR_BENCHMARK_COMMIT"],
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw NSError(
                domain: "JapaneseTranslationControl",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing exact benchmark commit."]
            )
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let service = AppleTranslationService()
        let setupStarted = DispatchTime.now().uptimeNanoseconds
        try await service.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        try await service.warmup(highFidelity: true)
        let setupMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - setupStarted
        ) / 1_000_000
        defer { Task { await service.cancel() } }

        var corpora: [Corpus] = []
        var results: [Turn] = []
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let manifestURL = root.appendingPathComponent(
                "docs/japanese-live/corpora/\(corpusID)/manifest.json"
            )
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            corpora.append(Corpus(
                corpusID: corpusID,
                manifestSHA256: try JapaneseBenchmarkSupport.sha256(at: manifestURL),
                annotationStatus: manifest.annotations.status.rawValue,
                turnCount: manifest.annotations.turns.count
            ))
            for turn in manifest.annotations.turns {
                let started = DispatchTime.now().uptimeNanoseconds
                var english = ""
                var failure: String?
                var attempts = 0
                for attempt in 1...3 {
                    attempts = attempt
                    do {
                        english = try EnglishSubtitleValidator.requireEnglish(
                            try await service.translate(turn.japanese, highFidelity: true)
                        )
                        failure = nil
                        break
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                results.append(Turn(
                    corpusID: corpusID,
                    turnID: turn.id,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    english: english,
                    milliseconds: Double(
                        DispatchTime.now().uptimeNanoseconds - started
                    ) / 1_000_000,
                    attemptCount: attempts,
                    error: failure
                ))
            }
        }

        let report = Report(
            schemaVersion: 1,
            runID: environment["WHISPERASR_L7C_RUN_ID"] ?? "l7c-translation-control",
            gitCommit: commit,
            sourceTreeSHA256: environment["WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256"]
                ?? "unknown",
            runtimeSHA256: environment["WHISPERASR_BENCHMARK_RUNTIME_SHA256"]
                ?? "unknown",
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            networkDenied: environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            translationPath: "human Japanese reference -> Apple highFidelity English",
            setupMilliseconds: setupMilliseconds,
            corpora: corpora,
            turns: results
        )
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(report.runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: output.appendingPathComponent("human-translation-control.json"),
            options: .atomic
        )
        XCTAssertEqual(results.count, 470)
    }
}
