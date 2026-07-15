import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseEnglishFullBakeoffTests: XCTestCase {
    private enum CandidateID: String, Codable, CaseIterable, Hashable {
        case humanApple = "human-japanese-apple-high-fidelity"
        case turboApple = "whisper-large-v3-turbo-apple-high-fidelity"
        case voxtralApple = "voxtral-q4-continuous-960ms-apple-high-fidelity"
        case qwenApple = "qwen3-asr-1.7b-mlx-8bit-apple-high-fidelity"
        case cohereApple = "cohere-transcribe-03-2026-mlx-8bit-apple-high-fidelity"
        case whisperLargeV3Direct = "whisper-large-v3-direct-ja-en"
    }

    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            let sha256: String
            let sampleCount: Int
        }

        struct Annotations: Decodable {
            let turns: [Turn]
        }

        struct Turn: Decodable {
            let id: Int
            let startSample: Int
            let endSample: Int
            let japanese: String
            let confidence: String
        }

        let corpusID: String
        let fixture: Fixture
        let annotations: Annotations
    }

    private struct ASRBakeoffReport: Decodable {
        struct Engine: Decodable {
            let engine: String
            let status: String
            let maximumResidentBytes: UInt64
            let turns: [Turn]
        }

        struct Turn: Decodable {
            let turnID: Int
            let referenceJapanese: String
            let hypothesisJapanese: String
            let asrMilliseconds: Double
            let appleEnglish: String?
            let appleHighFidelityMilliseconds: Double?
            let validEnglish: Bool?
            let residentBytes: UInt64
            let asrError: String?
            let translationError: String?
        }

        let corpusID: String
        let corpusSHA256: String
        let scope: String
        let selectedTurnIDs: [Int]
        let boundaryMode: String
        let appleHighFidelityEnabled: Bool
        let engines: [Engine]
    }

    private struct CandidateOutput: Codable {
        let id: CandidateID
        let japaneseInput: String?
        let english: String
        let validEnglish: Bool
        let asrMilliseconds: Double?
        let appleHighFidelityMilliseconds: Double?
        let endToEndMilliseconds: Double
        let residentBytes: UInt64
        let error: String?
    }

    private struct TurnOutput: Codable {
        let turnID: Int
        let confidence: String
        let startSample: Int
        let endSample: Int
        let referenceJapanese: String
        let candidates: [CandidateOutput]
    }

    private struct CandidateSummary: Codable {
        let id: CandidateID
        let turnCount: Int
        let validEnglishCount: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let worstMilliseconds: Double?
        let maximumResidentBytes: UInt64
    }

    private struct CandidateAvailability: Codable {
        let id: CandidateID
        let status: String
        let note: String
    }

    private struct FullReport: Codable {
        let schemaVersion: Int
        let corpusID: String
        let corpusSHA256: String
        let generatedAt: String
        let boundaryMode: String
        let note: String
        let appleEnrichmentStatus: String
        let candidateAvailability: [CandidateAvailability]
        let turns: [TurnOutput]
        let summaries: [CandidateSummary]
    }

    private struct BlindCandidate: Codable {
        let alias: String
        let english: String
        let fidelityScore1To5: Int?
        let subtitleNaturalnessScore1To5: Int?
        let criticalError: String?
        let preferred: Bool?
    }

    private struct BlindTurn: Codable {
        let turnID: Int
        let confidence: String
        let referenceJapanese: String
        let candidates: [BlindCandidate]
    }

    private struct BlindReport: Codable {
        let schemaVersion: Int
        let corpusID: String
        let note: String
        let turns: [BlindTurn]
    }

    private static let sourceEngines: [(String, CandidateID)] = [
        ("whisper-large-v3-turbo", .turboApple),
        ("voxtral-q4-continuous-960ms", .voxtralApple),
        ("qwen3-asr-1.7b-mlx-8bit", .qwenApple),
        ("cohere-transcribe-03-2026-mlx-8bit", .cohereApple),
    ]

    @MainActor
    func testFullEnglishBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_JAPANESE_ENGLISH_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_english_bakeoff.sh after the full ASR bakeoff.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let corpus = URL(fileURLWithPath: environment["WHISPERASR_JAPANESE_BAKEOFF_CORPUS"]
            ?? root.appendingPathComponent(".build/benchmarks/corpora/easy-japanese-1").path)
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: corpus.appendingPathComponent("manifest.json"))
        )
        let asrReportURL = URL(fileURLWithPath: environment["WHISPERASR_JAPANESE_ASR_APPLE_REPORT"]
            ?? root.appendingPathComponent(
                ".build/benchmarks/easy-japanese-1-asr-bakeoff-full-full.json"
            ).path)
        let asrReport = try JSONDecoder().decode(
            ASRBakeoffReport.self,
            from: Data(contentsOf: asrReportURL)
        )
        try validate(asrReport: asrReport, manifest: manifest)

        let audio = try await AudioLoader.loadSamples(
            url: corpus.appendingPathComponent("audio-16k-mono.wav")
        )
        guard audio.count == manifest.fixture.sampleCount else {
            throw inputError("Corpus sample count no longer matches its manifest.")
        }

        var humanApple: [Int: CandidateOutput] = [:]
        var appleEnrichmentStatus = asrReport.appleHighFidelityEnabled
            ? "source-report-complete; human ceiling pending"
            : "not-run: Apple Translation unavailable under the ASR XCTest run"
        if asrReport.appleHighFidelityEnabled, #available(macOS 26.4, *) {
            let apple = AppleTranslationService()
            do {
                try await apple.configure(sourceLocale: "ja", mode: .highFidelityOnly)
                try await apple.warmup(highFidelity: true)
                for turn in manifest.annotations.turns {
                    let started = DispatchTime.now().uptimeNanoseconds
                    do {
                        let english = try EnglishSubtitleValidator.requireEnglish(
                            try await translateWithRetry(turn.japanese, service: apple)
                        )
                        let elapsed = milliseconds(since: started)
                        humanApple[turn.id] = CandidateOutput(
                            id: .humanApple,
                            japaneseInput: turn.japanese,
                            english: english,
                            validEnglish: true,
                            asrMilliseconds: nil,
                            appleHighFidelityMilliseconds: elapsed,
                            endToEndMilliseconds: elapsed,
                            residentBytes: physicalFootprint(),
                            error: nil
                        )
                    } catch {
                        humanApple[turn.id] = failedCandidate(
                            id: .humanApple,
                            japanese: turn.japanese,
                            elapsed: milliseconds(since: started),
                            error: error
                        )
                    }
                }
                appleEnrichmentStatus = humanApple.values.allSatisfy(\.validEnglish)
                    ? "complete"
                    : "partial: one or more human-Japanese Apple translations failed"
            } catch {
                appleEnrichmentStatus = "unavailable: \(error.localizedDescription)"
            }
            await apple.cancel()
        } else if asrReport.appleHighFidelityEnabled {
            appleEnrichmentStatus = "unavailable: requires macOS 26.4 or later"
        }

        let whisperModel = try XCTUnwrap(ModelCatalog.model(id: "large-v3"))
        let whisperPath = ModelCatalog.path(for: whisperModel).path
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            throw inputError("Whisper Large v3 is not downloaded at \(whisperPath).")
        }
        let whisper = TranscriptionService()
        try await whisper.preloadModel(
            modelPath: whisperPath,
            requireEnglishTranslation: true
        )
        var direct: [Int: CandidateOutput] = [:]
        for turn in manifest.annotations.turns {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try await whisper.transcribeChunk(
                    samples: Array(audio[turn.startSample..<turn.endSample]),
                    language: "ja",
                    translate: true,
                    modelPath: whisperPath
                )
                let english = try EnglishSubtitleValidator.requireEnglish(result.text)
                let elapsed = milliseconds(since: started)
                direct[turn.id] = CandidateOutput(
                    id: .whisperLargeV3Direct,
                    japaneseInput: nil,
                    english: english,
                    validEnglish: true,
                    asrMilliseconds: elapsed,
                    appleHighFidelityMilliseconds: nil,
                    endToEndMilliseconds: elapsed,
                    residentBytes: physicalFootprint(),
                    error: nil
                )
            } catch {
                direct[turn.id] = failedCandidate(
                    id: .whisperLargeV3Direct,
                    japanese: nil,
                    elapsed: milliseconds(since: started),
                    error: error
                )
            }
            print("[JapaneseEnglishBakeoff] direct turn=\(turn.id)/\(manifest.annotations.turns.count)")
        }
        await whisper.unloadModel()

        let outputs = try manifest.annotations.turns.map { turn in
            var candidates: [CandidateOutput] = []
            if let human = humanApple[turn.id] { candidates.append(human) }
            if asrReport.appleHighFidelityEnabled {
                for (engineID, candidateID) in Self.sourceEngines {
                    let engine = try required(
                        asrReport.engines.first(where: { $0.engine == engineID }),
                        "Missing engine \(engineID)."
                    )
                    let source = try required(
                        engine.turns.first(where: { $0.turnID == turn.id }),
                        "Missing \(engineID) turn \(turn.id)."
                    )
                    candidates.append(sourceCandidate(source, id: candidateID))
                }
            }
            candidates.append(try required(direct[turn.id], "Missing direct turn \(turn.id)."))
            return TurnOutput(
                turnID: turn.id,
                confidence: turn.confidence,
                startSample: turn.startSample,
                endSample: turn.endSample,
                referenceJapanese: turn.japanese,
                candidates: candidates
            )
        }
        let humanStatus = humanApple.count == manifest.annotations.turns.count
            && humanApple.values.allSatisfy(\.validEnglish)
            ? "complete" : (humanApple.isEmpty ? "unavailable" : "partial")
        let directComplete = direct.count == manifest.annotations.turns.count
            && direct.values.allSatisfy(\.validEnglish)
        let availability = CandidateID.allCases.map { id -> CandidateAvailability in
            switch id {
            case .humanApple:
                return CandidateAvailability(id: id, status: humanStatus, note: appleEnrichmentStatus)
            case .turboApple, .voxtralApple, .qwenApple, .cohereApple:
                return CandidateAvailability(
                    id: id,
                    status: asrReport.appleHighFidelityEnabled ? "complete" : "unavailable",
                    note: asrReport.appleHighFidelityEnabled
                        ? "Loaded from the complete ASR+Apple report."
                        : "ASR was measured, but Apple Translation was unavailable under XCTest."
                )
            case .whisperLargeV3Direct:
                return CandidateAvailability(
                    id: id,
                    status: directComplete ? "complete" : "partial",
                    note: "Measured in this run."
                )
            }
        }
        let completeIDs = Set(availability.filter { $0.status == "complete" }.map(\.id))
        let full = FullReport(
            schemaVersion: 1,
            corpusID: manifest.corpusID,
            corpusSHA256: manifest.fixture.sha256,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            boundaryMode: "human-reference-turns",
            note: "No human English reference exists. Scores must be human blind judgments; human Japanese→Apple is a comparative ceiling, not ground truth.",
            appleEnrichmentStatus: appleEnrichmentStatus,
            candidateAvailability: availability,
            turns: outputs,
            summaries: CandidateID.allCases.map { summary(for: $0, turns: outputs) }
        )
        let blind = blindArtifacts(
            corpusID: manifest.corpusID,
            turns: outputs,
            completeCandidateIDs: completeIDs,
            appleEnrichmentStatus: appleEnrichmentStatus
        )
        try write(full: full, blind: blind.report, key: blind.key, root: root)

        let invalid = direct.values.filter { !$0.validEnglish }
        XCTAssertTrue(
            invalid.isEmpty,
            invalid.map { "\($0.id.rawValue): \($0.error ?? "invalid English")" }
                .joined(separator: "\n")
        )
        let directP95 = try XCTUnwrap(
            full.summaries.first(where: { $0.id == .whisperLargeV3Direct })?.p95Milliseconds
        )
        XCTAssertLessThanOrEqual(directP95, 2_500)
        XCTAssertTrue(outputs.flatMap(\.candidates).allSatisfy { $0.residentBytes < 10 * 1_024 * 1_024 * 1_024 })
    }

    func testBlindArtifactsRotateAllSixCandidates() {
        let candidates = CandidateID.allCases.map {
            CandidateOutput(
                id: $0,
                japaneseInput: nil,
                english: $0.rawValue,
                validEnglish: true,
                asrMilliseconds: nil,
                appleHighFidelityMilliseconds: nil,
                endToEndMilliseconds: 1,
                residentBytes: 1,
                error: nil
            )
        }
        let turns = (1...2).map {
            TurnOutput(
                turnID: $0,
                confidence: "high",
                startSample: 0,
                endSample: 1,
                referenceJapanese: "日本語",
                candidates: candidates
            )
        }
        let artifacts = blindArtifacts(
            corpusID: "fixture",
            turns: turns,
            completeCandidateIDs: Set(CandidateID.allCases),
            appleEnrichmentStatus: "complete"
        )
        XCTAssertEqual(artifacts.report.turns.count, 2)
        XCTAssertTrue(artifacts.report.turns.allSatisfy { $0.candidates.count == 6 })
        XCTAssertEqual(artifacts.key.count, 12)
        XCTAssertNotEqual(
            artifacts.key["1:A"],
            artifacts.key["2:A"],
            "Aliases must rotate between turns."
        )
    }

    @available(macOS 26.4, *)
    @MainActor
    private func translateWithRetry(
        _ japanese: String,
        service: AppleTranslationService
    ) async throws -> String {
        var lastError: Error?
        for _ in 0..<3 {
            do { return try await service.translate(japanese, highFidelity: true) }
            catch { lastError = error }
        }
        throw lastError ?? LocalPrototypeError.invalidResponse
    }

    private func validate(asrReport: ASRBakeoffReport, manifest: Manifest) throws {
        let expectedIDs = manifest.annotations.turns.map(\.id)
        guard asrReport.corpusID == manifest.corpusID,
              asrReport.corpusSHA256 == manifest.fixture.sha256,
              asrReport.scope == "full",
              asrReport.boundaryMode == "human-reference-turns",
              asrReport.selectedTurnIDs == expectedIDs else {
            throw inputError("ASR report is not the complete 59-turn human-boundary run.")
        }
        for (engineID, _) in Self.sourceEngines {
            guard let engine = asrReport.engines.first(where: { $0.engine == engineID }),
                  engine.status == "complete",
                  engine.turns.count == expectedIDs.count,
                  engine.turns.map(\.turnID) == expectedIDs,
                  engine.turns.allSatisfy({ $0.asrError == nil }) else {
                throw inputError("ASR report is incomplete for \(engineID).")
            }
            if asrReport.appleHighFidelityEnabled,
               !engine.turns.allSatisfy({
                   $0.validEnglish == true
                       && $0.appleEnglish?.isEmpty == false
                       && $0.translationError == nil
               }) {
                throw inputError("ASR+Apple report is incomplete for \(engineID).")
            }
        }
    }

    private func sourceCandidate(
        _ turn: ASRBakeoffReport.Turn,
        id: CandidateID
    ) -> CandidateOutput {
        let english = turn.appleEnglish ?? ""
        let valid = turn.validEnglish == true
            && EnglishSubtitleValidator.normalizedEnglish(english) != nil
        return CandidateOutput(
            id: id,
            japaneseInput: turn.hypothesisJapanese,
            english: english,
            validEnglish: valid,
            asrMilliseconds: turn.asrMilliseconds,
            appleHighFidelityMilliseconds: turn.appleHighFidelityMilliseconds,
            endToEndMilliseconds: turn.asrMilliseconds + (turn.appleHighFidelityMilliseconds ?? 0),
            residentBytes: turn.residentBytes,
            error: turn.asrError ?? turn.translationError
        )
    }

    private func failedCandidate(
        id: CandidateID,
        japanese: String?,
        elapsed: Double,
        error: Error
    ) -> CandidateOutput {
        CandidateOutput(
            id: id,
            japaneseInput: japanese,
            english: "",
            validEnglish: false,
            asrMilliseconds: id == .whisperLargeV3Direct ? elapsed : nil,
            appleHighFidelityMilliseconds: id == .humanApple ? elapsed : nil,
            endToEndMilliseconds: elapsed,
            residentBytes: physicalFootprint(),
            error: error.localizedDescription
        )
    }

    private func summary(for id: CandidateID, turns: [TurnOutput]) -> CandidateSummary {
        let outputs = turns.flatMap(\.candidates).filter { $0.id == id }
        let timings = outputs.filter(\.validEnglish).map(\.endToEndMilliseconds).sorted()
        return CandidateSummary(
            id: id,
            turnCount: outputs.count,
            validEnglishCount: outputs.filter(\.validEnglish).count,
            p50Milliseconds: percentile(timings, 0.50),
            p95Milliseconds: percentile(timings, 0.95),
            worstMilliseconds: timings.last,
            maximumResidentBytes: outputs.map(\.residentBytes).max() ?? 0
        )
    }

    private func blindArtifacts(
        corpusID: String,
        turns: [TurnOutput],
        completeCandidateIDs: Set<CandidateID>,
        appleEnrichmentStatus: String
    ) -> (report: BlindReport, key: [String: String]) {
        var key: [String: String] = [:]
        let blindTurns = turns.map { turn in
            let available = turn.candidates.filter { completeCandidateIDs.contains($0.id) }
            let ordered = available.indices.map { aliasIndex -> BlindCandidate in
                let candidate = available[(aliasIndex + turn.turnID) % available.count]
                let alias = String(UnicodeScalar(65 + aliasIndex)!)
                key["\(turn.turnID):\(alias)"] = candidate.id.rawValue
                return BlindCandidate(
                    alias: alias,
                    english: candidate.english,
                    fidelityScore1To5: nil,
                    subtitleNaturalnessScore1To5: nil,
                    criticalError: nil,
                    preferred: nil
                )
            }
            return BlindTurn(
                turnID: turn.turnID,
                confidence: turn.confidence,
                referenceJapanese: turn.referenceJapanese,
                candidates: ordered
            )
        }
        return (
            BlindReport(
                schemaVersion: 1,
                corpusID: corpusID,
                note: "No human English reference exists. Judge only available candidates; do not treat any candidate as ground truth. Apple enrichment: \(appleEnrichmentStatus).",
                turns: blindTurns
            ),
            key
        )
    }

    private func write(
        full: FullReport,
        blind: BlindReport,
        key: [String: String],
        root: URL
    ) throws {
        let directory = root.appendingPathComponent(".build/benchmarks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, data) in [
            ("easy-japanese-1-english-bakeoff-full.json", try encoder.encode(full)),
            ("easy-japanese-1-english-bakeoff-blind.json", try encoder.encode(blind)),
            ("easy-japanese-1-english-bakeoff-key.json", try encoder.encode(key)),
        ] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            print("[JapaneseEnglishBakeoff] wrote \(url.path)")
        }
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))]
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw inputError(message) }
        return value
    }

    private func inputError(_ message: String) -> NSError {
        NSError(
            domain: "JapaneseEnglishFullBakeoff",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
