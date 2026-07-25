import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseTranslationControlTests: XCTestCase {
    private struct NativeReport: Decodable {
        struct Session: Decodable {
            struct Fragment: Decodable {
                let startSample: Int
                let endSample: Int
                let text: String
            }

            let recipeID: String
            let corpusID: String
            let fragments: [Fragment]
        }

        let sessions: [Session]
    }

    private struct DiagnosticItem: Codable {
        let level: String
        let corpusID: String
        let unitID: Int
        let startSample: Int
        let endSample: Int
        let sourceJapanese: String
        let referenceEnglish: String?
        let english: String
        let milliseconds: Double
        let attemptCount: Int
        let error: String?
    }

    private struct DiagnosticReport: Codable {
        let schemaVersion: Int
        let runID: String
        let gitCommit: String
        let sourceTreeSHA256: String
        let nativeReportSHA256: String
        let worktreeDirty: Bool
        let networkDenied: Bool
        let generatedAt: String
        let alignment: String
        let items: [DiagnosticItem]
    }

    private struct TimedText {
        let startSample: Int
        let endSample: Int
        let text: String
    }

    private struct TargetRange {
        let startSample: Int
        let endSample: Int
    }

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

    func testTemporalTextDistributionDoesNotDuplicateCharacters() {
        let distributed = distribute(
            [TimedText(startSample: 0, endSample: 120, text: "abcdefghijkl")],
            into: [
                TargetRange(startSample: 0, endSample: 40),
                TargetRange(startSample: 60, endSample: 100),
            ]
        )

        XCTAssertEqual(distributed.joined(), "abcdefghijkl")
        XCTAssertFalse(distributed[0].isEmpty)
        XCTAssertTrue(distributed[1].hasSuffix("l"))
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
                let translated = await translate(turn.japanese, with: service)
                results.append(Turn(
                    corpusID: corpusID,
                    turnID: turn.id,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    english: translated.english,
                    milliseconds: translated.milliseconds,
                    attemptCount: translated.attemptCount,
                    error: translated.error
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

    @MainActor
    func testVoxtralFourLevelAppleDiagnosticWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_L8A_VOXTRAL_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set WHISPERASR_L8A_VOXTRAL_DIAGNOSTIC=1.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple highFidelity Translation requires macOS 26.4.")
        }
        guard let reportPath = environment["WHISPERASR_L8A_NATIVE_REPORT"],
              let commit = environment["WHISPERASR_BENCHMARK_COMMIT"],
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw NSError(
                domain: "JapaneseTranslationControl",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing native report or exact commit."]
            )
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reportURL = URL(fileURLWithPath: reportPath)
        let native = try JSONDecoder().decode(
            NativeReport.self,
            from: Data(contentsOf: reportURL)
        )
        let sessions = native.sessions.filter {
            $0.recipeID == "voxtral-q4-continuous-960ms"
        }
        XCTAssertEqual(Set(sessions.map(\.corpusID)), ["qudu2fx3ncc", "md62mmdz0m"])

        let service = AppleTranslationService()
        try await service.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        try await service.warmup(highFidelity: true)
        defer { Task { await service.cancel() } }

        var items: [DiagnosticItem] = []
        var expectedItemCount = 0
        for session in sessions.sorted(by: { $0.corpusID < $1.corpusID }) {
            let manifestURL = root.appendingPathComponent(
                "docs/japanese-live/corpora/\(session.corpusID)/manifest.json"
            )
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            let turns = manifest.annotations.turns.sorted {
                ($0.startSample, $0.id) < ($1.startSample, $1.id)
            }
            let fragments = session.fragments.sorted {
                ($0.startSample, $0.endSample) < ($1.startSample, $1.endSample)
            }
            expectedItemCount += 2 * (turns.count + fragments.count)

            let humanRanges = turns.map {
                TargetRange(startSample: $0.startSample, endSample: $0.endSample)
            }
            let productRanges = fragments.map {
                TargetRange(startSample: $0.startSample, endSample: $0.endSample)
            }
            let voxtralByHumanTurn = distribute(
                fragments.map {
                    TimedText(
                        startSample: $0.startSample,
                        endSample: $0.endSample,
                        text: $0.text
                    )
                },
                into: humanRanges
            )
            let humanByProductFragment = distribute(
                turns.map {
                    TimedText(
                        startSample: $0.startSample,
                        endSample: $0.endSample,
                        text: $0.japanese
                    )
                },
                into: productRanges
            )

            for (index, turn) in turns.enumerated() {
                items.append(await diagnosticItem(
                    level: "human-japanese-human-boundaries",
                    corpusID: session.corpusID,
                    unitID: turn.id,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    source: turn.japanese,
                    referenceEnglish: turn.english,
                    service: service
                ))
                items.append(await diagnosticItem(
                    level: "voxtral-japanese-human-boundaries",
                    corpusID: session.corpusID,
                    unitID: turn.id,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    source: voxtralByHumanTurn[index],
                    referenceEnglish: turn.english,
                    service: service
                ))
            }
            for (index, fragment) in fragments.enumerated() {
                items.append(await diagnosticItem(
                    level: "human-japanese-product-boundaries",
                    corpusID: session.corpusID,
                    unitID: index + 1,
                    startSample: fragment.startSample,
                    endSample: fragment.endSample,
                    source: humanByProductFragment[index],
                    referenceEnglish: nil,
                    service: service
                ))
                items.append(await diagnosticItem(
                    level: "voxtral-japanese-product-boundaries",
                    corpusID: session.corpusID,
                    unitID: index + 1,
                    startSample: fragment.startSample,
                    endSample: fragment.endSample,
                    source: fragment.text,
                    referenceEnglish: nil,
                    service: service
                ))
            }
        }

        let report = DiagnosticReport(
            schemaVersion: 1,
            runID: environment["WHISPERASR_L8A_RUN_ID"] ?? "l8a-voxtral-diagnostic",
            gitCommit: commit,
            sourceTreeSHA256: environment["WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256"]
                ?? "unknown",
            nativeReportSHA256: try JapaneseBenchmarkSupport.sha256(at: reportURL),
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            networkDenied: environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            alignment: (
                "post-ASR lossless temporal character distribution to the nearest target "
                + "sample range; diagnostic approximation only"
            ),
            items: items
        )
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(report.runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: output.appendingPathComponent("voxtral-four-level-apple.json"),
            options: .atomic
        )
        XCTAssertEqual(items.count, expectedItemCount)
    }

    @available(macOS 26.4, *)
    private func diagnosticItem(
        level: String,
        corpusID: String,
        unitID: Int,
        startSample: Int,
        endSample: Int,
        source: String,
        referenceEnglish: String?,
        service: AppleTranslationService
    ) async -> DiagnosticItem {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return DiagnosticItem(
                level: level,
                corpusID: corpusID,
                unitID: unitID,
                startSample: startSample,
                endSample: endSample,
                sourceJapanese: "",
                referenceEnglish: referenceEnglish,
                english: "",
                milliseconds: 0,
                attemptCount: 0,
                error: "empty-aligned-source"
            )
        }
        let translated = await translate(normalized, with: service)
        return DiagnosticItem(
            level: level,
            corpusID: corpusID,
            unitID: unitID,
            startSample: startSample,
            endSample: endSample,
            sourceJapanese: normalized,
            referenceEnglish: referenceEnglish,
            english: translated.english,
            milliseconds: translated.milliseconds,
            attemptCount: translated.attemptCount,
            error: translated.error
        )
    }

    @available(macOS 26.4, *)
    private func translate(
        _ source: String,
        with service: AppleTranslationService
    ) async -> (english: String, milliseconds: Double, attemptCount: Int, error: String?) {
        let started = DispatchTime.now().uptimeNanoseconds
        var english = ""
        var failure: String?
        var attempts = 0
        for attempt in 1...3 {
            attempts = attempt
            do {
                english = try EnglishSubtitleValidator.requireEnglish(
                    try await service.translate(source, highFidelity: true)
                )
                failure = nil
                break
            } catch {
                failure = error.localizedDescription
            }
        }
        return (
            english,
            Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            attempts,
            failure
        )
    }

    private func distribute(
        _ sources: [TimedText],
        into targets: [TargetRange]
    ) -> [String] {
        var output = Array(repeating: [Character](), count: targets.count)
        for source in sources where source.endSample > source.startSample {
            let characters = Array(source.text.precomposedStringWithCanonicalMapping)
            guard !characters.isEmpty else { continue }
            let duration = source.endSample - source.startSample
            for (index, character) in characters.enumerated() {
                let midpoint = source.startSample
                    + duration * (2 * index + 1) / (2 * characters.count)
                guard let target = targets.indices.min(by: {
                    distance(from: midpoint, to: targets[$0])
                        < distance(from: midpoint, to: targets[$1])
                }) else { continue }
                output[target].append(character)
            }
        }
        return output.map { String($0) }
    }

    private func distance(from sample: Int, to range: TargetRange) -> Int {
        if sample < range.startSample { return range.startSample - sample }
        if sample >= range.endSample { return sample - range.endSample + 1 }
        return 0
    }
}
