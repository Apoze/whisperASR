import CryptoKit
import FluidAudio
import Foundation
import XCTest
@testable import WhisperASRApp

enum JapaneseBenchmarkCSV {
    enum ParseError: Error, LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let message): message
            }
        }
    }

    static func records(
        data: Data,
        expectedHeader: [String]
    ) throws -> [[String: String]] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParseError.malformed("CSV is not valid UTF-8.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try rows(text)
        guard let header = rows.first, header == expectedHeader else {
            throw ParseError.malformed("Unexpected CSV header: \(rows.first ?? []).")
        }
        return try rows.dropFirst().enumerated().compactMap { index, row in
            if row.count == 1, row[0].isEmpty { return nil }
            guard row.count == header.count else {
                throw ParseError.malformed(
                    "CSV row \(index + 2) has \(row.count) fields; expected \(header.count)."
                )
            }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }

    static func sampleIndex(timecode: String, sampleRate: Int = 16_000) throws -> Int {
        let clock = timecode.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3,
              clock[0].count == 2,
              clock[1].count == 2 else {
            throw ParseError.malformed("Invalid timecode: \(timecode).")
        }
        let seconds = clock[2].split(separator: ".", omittingEmptySubsequences: false)
        guard seconds.count == 2,
              seconds[0].count == 2,
              seconds[1].count == 3,
              let hours = Int(clock[0]),
              let minutes = Int(clock[1]),
              let wholeSeconds = Int(seconds[0]),
              let milliseconds = Int(seconds[1]),
              (0..<60).contains(minutes),
              (0..<60).contains(wholeSeconds),
              (0..<1_000).contains(milliseconds),
              sampleRate.isMultiple(of: 1_000) else {
            throw ParseError.malformed("Invalid timecode: \(timecode).")
        }
        let totalMilliseconds = (((hours * 60) + minutes) * 60 + wholeSeconds) * 1_000
            + milliseconds
        return totalMilliseconds * sampleRate / 1_000
    }

    private static func rows(_ text: String) throws -> [[String]] {
        let characters = Array(text)
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var afterQuote = false
        var index = 0

        func finishField() {
            row.append(field)
            field = ""
            afterQuote = false
        }

        func finishRow() {
            finishField()
            result.append(row)
            row = []
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        afterQuote = true
                    }
                } else {
                    field.append(character)
                }
            } else if afterQuote {
                switch character {
                case ",": finishField()
                case "\n", "\r\n": finishRow()
                case "\r":
                    finishRow()
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default:
                    throw ParseError.malformed(
                        "Unexpected character '\(character)' after a quoted field at offset \(index)."
                    )
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty else {
                        throw ParseError.malformed("Quote inside an unquoted field.")
                    }
                    inQuotes = true
                case ",": finishField()
                case "\n", "\r\n": finishRow()
                case "\r":
                    finishRow()
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default: field.append(character)
                }
            }
            index += 1
        }

        guard !inQuotes else {
            throw ParseError.malformed("Unterminated quoted field.")
        }
        if afterQuote || !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return result
    }
}

private typealias JapaneseBenchmarkManifest = JapaneseBenchmarkSupport.Manifest

private enum JapaneseBakeoffEngine: String, Codable, CaseIterable {
    case whisperTurbo = "whisper-large-v3-turbo"
    case voxtralContinuous = "voxtral-q4-continuous-960ms"
    case nemotron1120 = "nemotron-multilingual-coreml-1120ms"
    case nemotron560 = "nemotron-multilingual-coreml-560ms"
}

private struct JapaneseBakeoffModelProvenance: Codable {
    let modelID: String
    let revision: String
    let revisionEnforced: Bool
    let artifactSHA256: String?
    let expectedArtifactSHA256: String
    let artifactSHA256Verified: Bool
    let license: String
    let runtime: String
    let runtimeRevision: String
}

private struct JapaneseBakeoffTurnReport: Codable {
    let turnID: Int
    let confidence: JapaneseBenchmarkManifest.Turn.Confidence
    let overlap: Bool
    let speaker: String
    let startSample: Int
    let endSample: Int
    let referenceJapanese: String
    let hypothesisJapanese: String
    let criticalTerms: [JapaneseBenchmarkManifest.Turn.CriticalTerm]
    let inputSampleCount: Int
    let fedSampleCount: Int
    let asrMilliseconds: Double
    let appleEnglish: String?
    let appleHighFidelityMilliseconds: Double?
    let validEnglish: Bool?
    let residentBytes: UInt64
    let asrError: String?
    let translationError: String?
}

private struct JapaneseBakeoffCERReport: Codable, Equatable {
    let turnCount: Int
    let editDistance: Int
    let substitutionCount: Int
    let deletionCount: Int
    let insertionCount: Int
    let referenceCharacterCount: Int
    let hypothesisCharacterCount: Int
    let omissionCount: Int
    let rate: Double?
}

private struct JapaneseBakeoffEngineReport: Codable {
    let engine: JapaneseBakeoffEngine
    let model: JapaneseBakeoffModelProvenance
    let status: String
    let setupError: String?
    let primaryHighConfidenceCER: JapaneseBakeoffCERReport
    let diagnosticMediumConfidenceCER: JapaneseBakeoffCERReport
    let exploratoryUnverifiedCER: JapaneseBakeoffCERReport
    let criticalDiagnostics: JapaneseBakeoffCriticalDiagnostics
    let expectedPCMSamples: Int
    let fedPCMSamples: Int
    let pcmInputCoverageComplete: Bool
    let pcmConsumptionStatus: String
    let lastReferenceTurnHasHypothesis: Bool
    let asrP50Milliseconds: Double?
    let asrP95Milliseconds: Double?
    let asrWorstMilliseconds: Double?
    let appleHighFidelityP50Milliseconds: Double?
    let appleHighFidelityP95Milliseconds: Double?
    let appleHighFidelityWorstMilliseconds: Double?
    let maximumObservedResidentBytes: UInt64
    let turns: [JapaneseBakeoffTurnReport]
}

private struct JapaneseBakeoffCriticalDiagnostics: Codable {
    struct MissingTerm: Codable {
        let turnID: Int
        let category: JapaneseBenchmarkManifest.Turn.CriticalTerm.Category
        let japanese: String
    }

    let annotatedTermCount: Int
    let missingAnnotatedTermCount: Int
    let missingTerms: [MissingTerm]
    let scoringStatus: String
    let note: String
}

private struct JapaneseBakeoffConfiguration: Codable {
    let language: String
    let sampleRate: Int
    let executionMode: String
    let engineOrder: [JapaneseBakeoffEngine]
    let fluidAudioVersion: String
    let fluidAudioRevision: String
}

private struct JapaneseBakeoffBootstrapInterval: Codable, Equatable {
    let observedRelativeImprovement: Double?
    let lower95: Double?
    let upper95: Double?
    let resamples: Int
}

private struct JapaneseBakeoffComparison: Codable {
    let baseline: JapaneseBakeoffEngine
    let candidate: JapaneseBakeoffEngine
    let pairedCERBootstrap: JapaneseBakeoffBootstrapInterval
    let qualityPathPasses: Bool
    let previewPathStatus: String
    let blockingReasons: [String]
}

private struct JapanesePairedCERObservation {
    let baselineErrors: Int
    let candidateErrors: Int
    let referenceCharacters: Int
}

private struct JapaneseBakeoffFullReport: Codable {
    let schemaVersion: Int
    let runID: String
    let gitCommit: String
    let worktreeDirty: Bool
    let modelHubOfflineMode: Bool
    let corpusID: String
    let corpusPurpose: String
    let manifestSHA256: String
    let audioSHA256: String
    let humanEnglishReferenceSHA256: String?
    let humanEnglishReferenceTurnCount: Int
    let humanEnglishReferenceStatus: String
    let corpusAnnotationStatus: String
    let promotionEligibleReference: Bool
    let generatedAt: String
    let scope: String
    let selectedTurnIDs: [Int]
    let boundaryMode: String
    let productionBoundaryStatus: String
    let productionBoundaryNote: String
    let appleHighFidelityEnabled: Bool
    let voxtralConfiguration: VoxtralContinuousConfiguration
    let configuration: JapaneseBakeoffConfiguration
    let engines: [JapaneseBakeoffEngineReport]
    let comparisons: [JapaneseBakeoffComparison]
    let promotionDecision: String
}

private struct JapaneseASRResult {
    let text: String
    let fedSampleCount: Int
}

private struct JapaneseBakeoffBlindCandidate: Codable {
    let alias: String
    let japanese: String
    let english: String?
}

private struct JapaneseBakeoffBlindItem: Codable {
    let turnID: Int
    let confidence: JapaneseBenchmarkManifest.Turn.Confidence
    let referenceJapanese: String
    let candidates: [JapaneseBakeoffBlindCandidate]
}

private struct JapaneseBakeoffBlindReport: Codable {
    let schemaVersion: Int
    let corpusID: String
    let scope: String
    let note: String
    let items: [JapaneseBakeoffBlindItem]
}

private typealias JapaneseBakeoffTranslation = @Sendable (String) async throws -> String

final class JapaneseModelBakeoffTests: XCTestCase {
    private static let fluidAudioVersion = "0.15.5"
    private static let fluidAudioRevision = "19600a485baa4998812e4654b70d2bab8f2c9949"
    private static let nemotronModelID =
        "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    private static let nemotronRevision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let whisperTurboSHA256 =
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    private static let easyJapaneseEnglishArchiveSHA256 =
        "721be7072dd9eca908a17099c077115e37b73851d8dcedce3c102ba23dbdc12f"
    private static let easyJapaneseEnglishTurnsSHA256 =
        "3efda22bbd72c109d1ba57b646bea68d76141060a5607ccaafcd397f3d0eeecb"
    private static let baselineResidentBytes: UInt64 = 4_185_313_288
    private static let turnsHeader = [
        "tour", "debut_switch", "fin", "locuteur", "description_locuteur",
        "japonais", "confiance", "note",
    ]
    private static let detailedHeader = [
        "index", "debut", "fin", "locuteur", "description_locuteur",
        "changement_de_locuteur", "japonais", "confiance", "note",
    ]
    private static let englishTurnsHeader = [
        "turn", "speaker_switch_start", "end", "speaker", "speaker_description",
        "english", "japanese_source", "confidence", "note",
    ]

    func testCSVTimecodeAndCERPrimitives() throws {
        let data = Data("\u{FEFF}id,text,note\r\n1,\"a,b\",\"say \"\"hi\"\"\"\r\n".utf8)
        let records = try JapaneseBenchmarkCSV.records(
            data: data,
            expectedHeader: ["id", "text", "note"]
        )
        XCTAssertEqual(records, [["id": "1", "text": "a,b", "note": "say \"hi\""]])
        XCTAssertEqual(
            try JapaneseBenchmarkCSV.sampleIndex(timecode: "00:04:32.100"),
            4_353_600
        )

        XCTAssertEqual(String(JapaneseCER.normalized(" ＡＢＣ、１２３。 みな ")), "abc123みな")
        XCTAssertEqual(String(JapaneseCER.normalized("［実況不明瞭］ガード（笑）")), "ガード")
        let score = JapaneseCER.score([
            (reference: "日本語", hypothesis: "日本後"),
            (reference: "はい", hypothesis: ""),
        ])
        XCTAssertEqual(score.editDistance, 3)
        XCTAssertEqual(score.substitutionCount, 1)
        XCTAssertEqual(score.deletionCount, 2)
        XCTAssertEqual(score.insertionCount, 0)
        XCTAssertEqual(score.referenceCharacterCount, 5)
        XCTAssertEqual(score.omissionCount, 1)
        XCTAssertEqual(score.rate, 0.6)
    }

    func testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns() {
        let reports = [
            JapaneseBakeoffTurnReport(
                turnID: 1,
                confidence: .high,
                overlap: false,
                speaker: "A",
                startSample: 0,
                endSample: 16_000,
                referenceJapanese: "日本語",
                hypothesisJapanese: "日本後",
                criticalTerms: [
                    JapaneseBenchmarkManifest.Turn.CriticalTerm(
                        category: .name,
                        japanese: "語",
                        expectedEnglish: nil
                    )
                ],
                inputSampleCount: 16_000,
                fedSampleCount: 16_000,
                asrMilliseconds: 10,
                appleEnglish: nil,
                appleHighFidelityMilliseconds: nil,
                validEnglish: nil,
                residentBytes: 1,
                asrError: nil,
                translationError: nil
            ),
            JapaneseBakeoffTurnReport(
                turnID: 2,
                confidence: .medium,
                overlap: false,
                speaker: "B",
                startSample: 16_000,
                endSample: 32_000,
                referenceJapanese: "はい",
                hypothesisJapanese: "",
                criticalTerms: [],
                inputSampleCount: 16_000,
                fedSampleCount: 16_000,
                asrMilliseconds: 20,
                appleEnglish: nil,
                appleHighFidelityMilliseconds: nil,
                validEnglish: nil,
                residentBytes: 2,
                asrError: nil,
                translationError: nil
            ),
            JapaneseBakeoffTurnReport(
                turnID: 3,
                confidence: .high,
                overlap: true,
                speaker: "A+B",
                startSample: 24_000,
                endSample: 40_000,
                referenceJapanese: "重複",
                hypothesisJapanese: "",
                criticalTerms: [],
                inputSampleCount: 16_000,
                fedSampleCount: 16_000,
                asrMilliseconds: 30,
                appleEnglish: nil,
                appleHighFidelityMilliseconds: nil,
                validEnglish: nil,
                residentBytes: 3,
                asrError: nil,
                translationError: nil
            ),
        ]

        let high = cerReport(reports, confidence: .high)
        let medium = cerReport(reports, confidence: .medium)
        XCTAssertEqual(high.turnCount, 1)
        XCTAssertEqual(high.editDistance, 1)
        XCTAssertEqual(high.deletionCount, 0)
        XCTAssertEqual(high.omissionCount, 0)
        XCTAssertEqual(medium.turnCount, 1)
        XCTAssertEqual(medium.editDistance, 2)
        XCTAssertEqual(medium.omissionCount, 1)
        let critical = criticalDiagnostics(reports)
        XCTAssertEqual(critical.annotatedTermCount, 1)
        XCTAssertEqual(critical.missingAnnotatedTermCount, 1)
        XCTAssertEqual(critical.missingTerms.first?.japanese, "語")

        let artifacts = blindArtifacts(
            corpusID: "fixture",
            scope: "unit",
            seed: "unit-secret",
            reports: JapaneseBakeoffEngine.allCases.map { engine in
                JapaneseBakeoffEngineReport(
                    engine: engine,
                    model: fixtureProvenance(engine),
                    status: "execution-complete",
                    setupError: nil,
                    primaryHighConfidenceCER: high,
                    diagnosticMediumConfidenceCER: medium,
                    exploratoryUnverifiedCER: cerReport(reports, confidence: .unverified),
                    criticalDiagnostics: criticalDiagnostics(reports),
                    expectedPCMSamples: 48_000,
                    fedPCMSamples: 48_000,
                    pcmInputCoverageComplete: true,
                    pcmConsumptionStatus: "not-exposed-by-benchmark-api",
                    lastReferenceTurnHasHypothesis: false,
                    asrP50Milliseconds: 10,
                    asrP95Milliseconds: 30,
                    asrWorstMilliseconds: 30,
                    appleHighFidelityP50Milliseconds: nil,
                    appleHighFidelityP95Milliseconds: nil,
                    appleHighFidelityWorstMilliseconds: nil,
                    maximumObservedResidentBytes: 3,
                    turns: reports
                )
            }
        )
        XCTAssertEqual(artifacts.report.items.count, 3)
        XCTAssertEqual(Set(artifacts.report.items[0].candidates.map(\.alias)), Set(["A", "B", "C", "D"]))
        XCTAssertEqual(artifacts.key.count, 12)
    }

    func testBakeoffModelArtifactsArePinned() throws {
        let turbo = try XCTUnwrap(ModelCatalog.model(id: "large-v3-turbo"))
        XCTAssertEqual(turbo.sha256, Self.whisperTurboSHA256)
        XCTAssertTrue(turbo.url.path.contains(Self.whisperRevision))
    }

    func testPairedBootstrapUsesTheSameTurns() {
        let observations = (0..<8).map { _ in
            JapanesePairedCERObservation(
                baselineErrors: 2,
                candidateErrors: 1,
                referenceCharacters: 4
            )
        }
        let interval = pairedBootstrap(
            observations,
            resamples: 1_000,
            seed: 7
        )
        XCTAssertEqual(interval.observedRelativeImprovement, 0.5)
        XCTAssertEqual(interval.lower95, 0.5)
        XCTAssertEqual(interval.upper95, 0.5)
    }

    func testPreparePinnedNemotronModelsWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_PREPARE_NEMOTRON"] == "1" else {
            throw XCTSkip("Set WHISPERASR_PREPARE_NEMOTRON=1 for the initial pinned model download.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelRoot = nemotronModelRoot(root: root, environment: environment)
        for chunkMilliseconds in [1_120, 560] {
            let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "ja-JP",
                chunkMs: chunkMilliseconds,
                to: modelRoot
            )
            let hash = try artifactSHA256(at: directory)
            let engine: JapaneseBakeoffEngine = chunkMilliseconds == 1_120
                ? .nemotron1120 : .nemotron560
            XCTAssertEqual(
                hash,
                Self.expectedArtifactSHA256(for: engine),
                "Nemotron main no longer matches the pinned \(Self.nemotronRevision) artifact."
            )
            print(
                "[JapaneseBakeoff] Nemotron \(chunkMilliseconds)ms "
                + "revision=\(Self.nemotronRevision) sha256=\(hash)"
            )
        }
    }

    /// Run with `Scripts/run_japanese_bakeoff.sh [smoke|full]`.
    ///
    /// Every engine receives the exact same annotated human turn ranges. The
    /// production clause planner is deliberately not approximated here: its
    /// long-lived state lives in AppState and is measured by the existing live
    /// replay benchmarks instead.
    @MainActor
    func testJapaneseASRBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_JAPANESE_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_bakeoff.sh to compare local Japanese ASR models.")
        }
        guard let gitCommit = environment["WHISPERASR_BENCHMARK_COMMIT"],
              gitCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            XCTFail("WHISPERASR_BENCHMARK_COMMIT must contain the exact 40-character Git commit.")
            return
        }
        ModelHub.offlineMode = environment["WHISPERASR_OFFLINE"] == "1"
        defer { ModelHub.offlineMode = false }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = URL(
            fileURLWithPath: environment["WHISPERASR_JAPANESE_BENCHMARK_MANIFEST"]
                ?? root.appendingPathComponent(
                    "docs/japanese-live/corpora/easy-japanese-1/manifest.json"
                ).path
        ).standardizedFileURL
        let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
        let manifestSHA256 = try JapaneseBenchmarkSupport.sha256(at: manifestURL)
        let wavURL = try JapaneseBenchmarkSupport.fixtureURL(
            for: manifest,
            workspaceRoot: root
        )
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: wavURL), manifest.fixture.sha256)
        let samples = try await AudioLoader.loadSamples(url: wavURL)
        XCTAssertEqual(samples.count, manifest.fixture.sampleCount)
        XCTAssertEqual(manifest.fixture.sampleRate, 16_000)
        let englishReference = try validateHumanEnglishReference(
            environment: environment,
            manifest: manifest
        )

        let scope = environment["WHISPERASR_JAPANESE_BAKEOFF_SCOPE"] ?? "full"
        let selectedIDs = selectedTurnIDs(
            environment: environment,
            scope: scope,
            turns: manifest.annotations.turns
        )
        let selectedTurns = manifest.annotations.turns.filter { selectedIDs.contains($0.id) }
        guard !selectedTurns.isEmpty, selectedTurns.count == selectedIDs.count else {
            XCTFail("The selected corpus has no complete set of scorable turns.")
            return
        }
        XCTAssertTrue(selectedTurns.allSatisfy { $0.endSample <= samples.count })

        let translation = try await optionalAppleTranslation(environment: environment)
        let modelManager = LocalEnglishModelManager()
        let whisper = TranscriptionService()
        let voxtralConfiguration = try requestedVoxtralConfiguration(environment: environment)
        await modelManager.selectContinuousVoxtralConfiguration(voxtralConfiguration)
        let requestedEngines = try selectedEngines(environment: environment, scope: scope)
        let runID = try benchmarkRunID(environment: environment)

        var engineReports: [JapaneseBakeoffEngineReport] = []
        for engine in requestedEngines {
            print("[JapaneseBakeoff] preparing \(engine.rawValue)")
            let report = await runEngine(
                engine,
                turns: selectedTurns,
                samples: samples,
                modelManager: modelManager,
                whisper: whisper,
                translation: translation,
                root: root,
                environment: environment
            )
            engineReports.append(report)
            print(
                "[JapaneseBakeoff] \(engine.rawValue) "
                    + "high-CER=\(format(report.primaryHighConfidenceCER.rate)) "
                    + "medium-CER=\(format(report.diagnosticMediumConfidenceCER.rate)) "
                    + "status=\(report.status)"
            )
        }
        await modelManager.shutdown()
        await whisper.unloadModel()
        let comparisons = bakeoffComparisons(
            reports: engineReports,
            manifest: manifest
        )

        let report = JapaneseBakeoffFullReport(
            schemaVersion: 3,
            runID: runID,
            gitCommit: gitCommit,
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            modelHubOfflineMode: environment["WHISPERASR_OFFLINE"] == "1",
            corpusID: manifest.corpusID,
            corpusPurpose: manifest.purpose.rawValue,
            manifestSHA256: manifestSHA256,
            audioSHA256: manifest.fixture.sha256,
            humanEnglishReferenceSHA256: englishReference.sha256,
            humanEnglishReferenceTurnCount: englishReference.turnCount,
            humanEnglishReferenceStatus: englishReference.status,
            corpusAnnotationStatus: manifest.annotations.status.rawValue,
            promotionEligibleReference: manifest.annotations.status == .complete,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            scope: scope,
            selectedTurnIDs: selectedTurns.map(\.id),
            boundaryMode: manifest.annotations.status == .complete
                ? "human-reference-turns"
                : "exploratory-unverified-turns",
            productionBoundaryStatus: "not-reproduced",
            productionBoundaryNote: "Production boundaries depend on AppState's continuous VoxtralClausePlanner, VAD, preview scheduler and optional diarization state. Recreating them turn-by-turn here would be a false simulation; use the existing real-time replay reports for that pass.",
            appleHighFidelityEnabled: translation != nil,
            voxtralConfiguration: voxtralConfiguration,
            configuration: JapaneseBakeoffConfiguration(
                language: "ja-JP",
                sampleRate: 16_000,
                executionMode: "sequential-offline-human-turns",
                engineOrder: requestedEngines,
                fluidAudioVersion: Self.fluidAudioVersion,
                fluidAudioRevision: Self.fluidAudioRevision
            ),
            engines: engineReports,
            comparisons: comparisons,
            promotionDecision: promotionDecision(manifest: manifest)
        )
        let artifacts = blindArtifacts(
            corpusID: manifest.corpusID,
            scope: scope,
            seed: UUID().uuidString,
            reports: engineReports
        )
        try writeBakeoffArtifacts(
            report: report,
            blind: artifacts.report,
            key: artifacts.key,
            corpusID: manifest.corpusID,
            scope: scope,
            runID: runID,
            root: root
        )

        let failures = engineReports.flatMap { engine -> [String] in
            var result: [String] = []
            if engine.status != "execution-complete" {
                result.append("\(engine.engine.rawValue): \(engine.setupError ?? engine.status)")
            }
            result += engine.turns.compactMap { turn in
                turn.asrError.map { "\(engine.engine.rawValue) turn \(turn.turnID): \($0)" }
            }
            return result
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPrepareEasyJapaneseCorpusWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_PREPARE_JAPANESE_CORPUS"] == "1",
              let videoPath = environment["WHISPERASR_JAPANESE_CORPUS_VIDEO"],
              let archivePath = environment["WHISPERASR_JAPANESE_CORPUS_TRANSCRIPT_ARCHIVE"],
              let outputPath = environment["WHISPERASR_JAPANESE_CORPUS_OUTPUT"] else {
            throw XCTSkip("Run Scripts/prepare_japanese_bakeoff.sh to prepare the local corpus.")
        }

        let videoURL = URL(fileURLWithPath: videoPath).standardizedFileURL
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let turnsURL = outputURL.appendingPathComponent("turns.csv")
        let detailedURL = outputURL.appendingPathComponent("detailed.csv")
        let speakersURL = outputURL.appendingPathComponent("speakers.srt")
        let wavURL = outputURL.appendingPathComponent("audio-16k-mono.wav")

        let videoSHA = try JapaneseBenchmarkSupport.sha256(at: videoURL)
        let archiveSHA = try JapaneseBenchmarkSupport.sha256(at: archiveURL)
        XCTAssertEqual(
            videoSHA,
            "6b6fee800edaf8fe5ffea029f673b37e04b648cd24aaa779c1c53dc9446b2667"
        )
        XCTAssertEqual(
            archiveSHA,
            "1da9a9d3d2d41455eef067cee3a57d8c0ea7aca9c0a33291347e492a1ae238c1"
        )

        let turnsData = try Data(contentsOf: turnsURL)
        let detailedData = try Data(contentsOf: detailedURL)
        let speakersData = try Data(contentsOf: speakersURL)
        XCTAssertEqual(
            digest(turnsData),
            "d9a81899c6bb0e424161f732f53761cabcac41d14fed144e885cec2a0835e25d"
        )
        XCTAssertEqual(
            digest(detailedData),
            "c67ae24564eed86e750de000122677404ba7641ad8f4f2400b238e644f3f7fd4"
        )
        XCTAssertEqual(
            digest(speakersData),
            "d87a98fdbbf99151b8ad2533f27abf53d9001bdc6506a718328ba11f89313dbf"
        )

        let turnRecords = try JapaneseBenchmarkCSV.records(
            data: turnsData,
            expectedHeader: Self.turnsHeader
        )
        let turns = try turnRecords.enumerated().map { index, record in
            try referenceTurn(record, expectedID: index + 1)
        }
        guard zip(turns, turns.dropFirst()).allSatisfy({ previous, next in
            next.startSample >= previous.endSample
        }) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Reference turns overlap or are out of order."
            )
        }
        let detailedRecords = try JapaneseBenchmarkCSV.records(
            data: detailedData,
            expectedHeader: Self.detailedHeader
        )
        try validateDetailedRecords(detailedRecords)

        let speakers = try XCTUnwrap(String(data: speakersData, encoding: .utf8))
        XCTAssertEqual(speakers.components(separatedBy: " --> ").count - 1, 102)

        let samples = try await AudioLoader.loadSamples(url: videoURL)
        XCTAssertGreaterThan(samples.count, 4_353_600)
        XCTAssertTrue(turns.allSatisfy { $0.endSample <= samples.count })

        let wavData = PCM16WAV.data(samples: samples)
        try wavData.write(to: wavURL, options: .atomic)

        let highCount = turns.filter { $0.confidence == .high }.count
        let mediumCount = turns.filter { $0.confidence == .medium }.count
        let speakerCount = Set(turns.map(\.speaker)).count
        let speakerChanges = zip(turns, turns.dropFirst()).filter { $0.speaker != $1.speaker }.count
        let annotatedSamples = turns.reduce(0) { $0 + $1.endSample - $1.startSample }
        XCTAssertEqual(turns.count, 59)
        XCTAssertEqual(highCount, 46)
        XCTAssertEqual(mediumCount, 13)
        XCTAssertEqual(speakerCount, 15)
        XCTAssertEqual(speakerChanges, 57)
        XCTAssertEqual(annotatedSamples, 4_111_760)

        XCTAssertEqual(
            digest(wavData),
            "64ee5d98f5db01497d6b13354a17d4d0ba43776ae31699d7c73bb8b0c019c07c"
        )
    }

    private func selectedTurnIDs(
        environment: [String: String],
        scope: String,
        turns: [JapaneseBenchmarkManifest.Turn]
    ) -> Set<Int> {
        if let raw = environment["WHISPERASR_JAPANESE_BAKEOFF_TURN_IDS"] {
            return Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        return scope == "smoke"
            ? Set(turns.prefix(4).map(\.id))
            : Set(turns.map(\.id))
    }

    private func validateHumanEnglishReference(
        environment: [String: String],
        manifest: JapaneseBenchmarkManifest
    ) throws -> (sha256: String?, turnCount: Int, status: String) {
        guard let path = environment["WHISPERASR_JAPANESE_ENGLISH_TURNS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return (nil, 0, "not-provided-for-this-corpus")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let data = try Data(contentsOf: url)
        let sha256 = digest(data)
        let records = try JapaneseBenchmarkCSV.records(
            data: data,
            expectedHeader: Self.englishTurnsHeader
        )
        guard records.count == manifest.annotations.turns.count else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The human English reference must cover every Japanese turn."
            )
        }
        let turns = Dictionary(uniqueKeysWithValues: manifest.annotations.turns.map { ($0.id, $0) })
        let recordIDs = records.compactMap { $0["turn"].flatMap(Int.init) }
        guard recordIDs.count == records.count,
              Set(recordIDs).count == records.count,
              Set(recordIDs) == Set(turns.keys) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The human English reference must contain each turn exactly once."
            )
        }
        for record in records {
            guard let rawID = record["turn"], let id = Int(rawID),
                  let turn = turns[id],
                  let english = record["english"],
                  !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record["speaker"] == turn.speaker,
                  record["japanese_source"] == turn.japanese,
                  record["confidence"] == turn.confidence.rawValue,
                  let start = record["speaker_switch_start"],
                  let end = record["end"],
                  try JapaneseBenchmarkCSV.sampleIndex(timecode: start) == turn.startSample,
                  try JapaneseBenchmarkCSV.sampleIndex(timecode: end) == turn.endSample else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The human English reference is not aligned with the Japanese manifest."
                )
            }
        }
        if manifest.corpusID == "easy-japanese-1" {
            guard sha256 == Self.easyJapaneseEnglishTurnsSHA256,
                  manifest.source.references.contains(where: {
                      $0.label == "english-transcript-archive"
                          && $0.sha256 == Self.easyJapaneseEnglishArchiveSHA256
                  }) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The Easy Japanese English reference does not match its pinned source."
                )
            }
        }
        return (sha256, records.count, "verified-reference-not-scored-by-asr-bakeoff")
    }

    private func requestedVoxtralConfiguration(
        environment: [String: String]
    ) throws -> VoxtralContinuousConfiguration {
        let model = environment["WHISPERASR_VOXTRAL_HELPER_VARIANT"]
            .flatMap(VoxtralModelVariant.init(rawValue:)) ?? .q4
        let delay = environment["WHISPERASR_VOXTRAL_HELPER_DELAY_MS"]
            .flatMap(Int.init)
            .flatMap(VoxtralTranscriptionDelay.init(rawValue:)) ?? .milliseconds960
        let requested = VoxtralContinuousConfiguration(model: model, delay: delay)
        guard requested == .default else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "L3 fixes Voxtral to Q4/960; remove experimental Voxtral overrides."
            )
        }
        return .default
    }

    private func selectedEngines(
        environment: [String: String],
        scope: String
    ) throws -> [JapaneseBakeoffEngine] {
        guard let raw = environment["WHISPERASR_JAPANESE_BAKEOFF_ENGINES"] else {
            return JapaneseBakeoffEngine.allCases
        }
        let identifiers = raw.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The ASR engine list must not be empty."
            )
        }
        let engines = try identifiers.map { identifier in
            guard let engine = JapaneseBakeoffEngine(rawValue: identifier) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Unknown ASR bakeoff engine: \(identifier)."
                )
            }
            return engine
        }
        guard Set(engines).count == engines.count else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The ASR engine list must not contain duplicates."
            )
        }
        let canonicalOrder = JapaneseBakeoffEngine.allCases.filter { engines.contains($0) }
        guard engines == canonicalOrder else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "ASR engines must follow the fixed L3 order."
            )
        }
        if scope == "full", engines != JapaneseBakeoffEngine.allCases {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "A full L3 proof must execute all four ASR engines."
            )
        }
        return engines
    }

    @MainActor
    private func optionalAppleTranslation(
        environment: [String: String]
    ) async throws -> JapaneseBakeoffTranslation? {
        guard environment["WHISPERASR_JAPANESE_BAKEOFF_APPLE"] == "1" else { return nil }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple high-fidelity comparison requires macOS 26.4 or later.")
        }
        let service = AppleTranslationService()
        try await service.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        return { text in
            try await service.translate(text, highFidelity: true)
        }
    }

    @MainActor
    private func runEngine(
        _ engine: JapaneseBakeoffEngine,
        turns: [JapaneseBenchmarkManifest.Turn],
        samples: [Float],
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        translation: JapaneseBakeoffTranslation?,
        root: URL,
        environment: [String: String]
    ) async -> JapaneseBakeoffEngineReport {
        var turnReports: [JapaneseBakeoffTurnReport] = []
        var setupError: String?
        var nemotron: StreamingNemotronMultilingualAsrManager?
        var provenance = unresolvedProvenance(engine)

        do {
            await modelManager.unload()
            await whisper.unloadModel()
            provenance = try modelProvenance(
                engine,
                root: root,
                environment: environment
            )
            guard provenance.artifactSHA256Verified else {
                throw NSError(
                    domain: "JapaneseModelBakeoff",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Model artifact SHA-256 does not match the pinned value."
                    ]
                )
            }
            switch engine {
            case .whisperTurbo:
                guard let turbo = ModelCatalog.model(id: "large-v3-turbo"),
                      ModelManager.shared.isDownloaded(turbo) else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Whisper Large v3 Turbo is not downloaded."]
                    )
                }
                try await whisper.preloadModel(
                    modelPath: ModelCatalog.path(for: turbo).path,
                    requireEnglishTranslation: false
                )
            case .voxtralContinuous:
                try await modelManager.prepare(.voxtralApple)
            case .nemotron1120, .nemotron560:
                let manager = StreamingNemotronMultilingualAsrManager()
                let directory = nemotronModelDirectory(
                    engine: engine,
                    root: root,
                    environment: environment
                )
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Pinned Nemotron model is missing at \(directory.path)."
                        ]
                    )
                }
                try await manager.loadModels(from: directory)
                await manager.setLanguage("ja-JP")
                nemotron = manager
            }
        } catch {
            setupError = error.localizedDescription
        }

        if setupError == nil {
            for (index, turn) in turns.enumerated() {
                let audio = Array(samples[turn.startSample..<turn.endSample])
                let asrStarted = DispatchTime.now().uptimeNanoseconds
                var asrResult = JapaneseASRResult(
                    text: "",
                    fedSampleCount: 0
                )
                var asrError: String?
                do {
                    asrResult = try await transcribe(
                        engine,
                        audio: audio,
                        absoluteStartSample: turn.startSample,
                        modelManager: modelManager,
                        whisper: whisper,
                        nemotron: nemotron
                    )
                } catch {
                    asrError = error.localizedDescription
                }
                let asrFinished = DispatchTime.now().uptimeNanoseconds
                let hypothesis = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

                var english: String?
                var translationMilliseconds: Double?
                var validEnglish: Bool?
                var translationError: String?
                if let translation, asrError == nil, !hypothesis.isEmpty {
                    let translationStarted = DispatchTime.now().uptimeNanoseconds
                    do {
                        let candidate = try await translation(hypothesis)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let valid = !candidate.isEmpty
                            && !EnglishSubtitleValidator.containsSourceScript(candidate)
                        english = candidate
                        validEnglish = valid
                        if !valid {
                            translationError = "Apple highFidelity returned empty or source-script text."
                        }
                    } catch {
                        translationError = error.localizedDescription
                        validEnglish = false
                    }
                    translationMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - translationStarted
                    ) / 1_000_000
                }

                let helperBytes = engine == .voxtralContinuous
                    ? await modelManager.continuousVoxtralProgress().helperRSSBytes ?? 0
                    : 0
                turnReports.append(JapaneseBakeoffTurnReport(
                    turnID: turn.id,
                    confidence: turn.confidence,
                    overlap: turn.overlap ?? false,
                    speaker: turn.speaker,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    referenceJapanese: turn.japanese,
                    hypothesisJapanese: hypothesis,
                    criticalTerms: turn.criticalTerms,
                    inputSampleCount: audio.count,
                    fedSampleCount: asrResult.fedSampleCount,
                    asrMilliseconds: Double(asrFinished - asrStarted) / 1_000_000,
                    appleEnglish: english,
                    appleHighFidelityMilliseconds: translationMilliseconds,
                    validEnglish: validEnglish,
                    residentBytes: modelManager.currentMemoryBytes() + helperBytes,
                    asrError: asrError,
                    translationError: translationError
                ))
                print(
                    "[JapaneseBakeoff] \(engine.rawValue) "
                        + "turn=\(turn.id) progress=\(index + 1)/\(turns.count)"
                )
            }
        }

        if let nemotron { await nemotron.cleanup() }
        await whisper.unloadModel()
        await modelManager.unload()
        return engineReport(
            engine: engine,
            model: provenance,
            setupError: setupError,
            turns: turnReports,
            expectedTurnCount: turns.count
        )
    }

    @MainActor
    private func transcribe(
        _ engine: JapaneseBakeoffEngine,
        audio: [Float],
        absoluteStartSample: Int,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        nemotron: StreamingNemotronMultilingualAsrManager?
    ) async throws -> JapaneseASRResult {
        switch engine {
        case .whisperTurbo:
            guard let turbo = ModelCatalog.model(id: "large-v3-turbo") else {
                throw NSError(
                    domain: "JapaneseModelBakeoff",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Whisper Turbo is absent from ModelCatalog."]
                )
            }
            let text = try await whisper.transcribeChunk(
                samples: audio,
                language: "ja",
                translate: false,
                modelPath: ModelCatalog.path(for: turbo).path
            )
            return JapaneseASRResult(
                text: text.text,
                fedSampleCount: audio.count
            )
        case .voxtralContinuous:
            let events = try await modelManager.startContinuousVoxtral()
            let collector = Task {
                var failures: [String] = []
                for await event in events {
                    if case .failed(let message) = event { failures.append(message) }
                }
                return failures
            }
            let blockSamples = VoxtralHelperManifest.sampleRate
                * VoxtralHelperManifest.transportBlockMilliseconds / 1_000
            do {
                for localStart in stride(from: 0, to: audio.count, by: blockSamples) {
                    let localEnd = min(audio.count, localStart + blockSamples)
                    let absoluteRange = (absoluteStartSample + localStart)..<(absoluteStartSample + localEnd)
                    try await modelManager.feedContinuousVoxtral(
                        samples: Array(audio[localStart..<localEnd]),
                        range: absoluteRange
                    )
                }
                let transcript = try await modelManager.finishContinuousVoxtral()
                let failures = await collector.value
                guard failures.isEmpty else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
                    )
                }
                return JapaneseASRResult(
                    text: transcript,
                    fedSampleCount: audio.count
                )
            } catch {
                await modelManager.cancelContinuousVoxtral()
                collector.cancel()
                _ = await collector.result
                throw error
            }
        case .nemotron1120, .nemotron560:
            guard let nemotron else {
                throw NSError(
                    domain: "JapaneseModelBakeoff",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Nemotron manager was not prepared."]
                )
            }
            await nemotron.reset()
            let feedBlockSamples = 2_560
            for localStart in stride(from: 0, to: audio.count, by: feedBlockSamples) {
                let localEnd = min(audio.count, localStart + feedBlockSamples)
                _ = try await nemotron.process(samples: Array(audio[localStart..<localEnd]))
            }
            let final = try await nemotron.finish()
            return JapaneseASRResult(
                text: final,
                fedSampleCount: audio.count
            )
        }
    }

    private func engineReport(
        engine: JapaneseBakeoffEngine,
        model: JapaneseBakeoffModelProvenance,
        setupError: String?,
        turns: [JapaneseBakeoffTurnReport],
        expectedTurnCount: Int
    ) -> JapaneseBakeoffEngineReport {
        let asrFailures = turns.filter { $0.asrError != nil }.count
        let status: String
        if setupError != nil {
            status = "unavailable"
        } else if turns.count != expectedTurnCount || asrFailures > 0 {
            status = "partial"
        } else {
            status = "execution-complete"
        }
        let asr = turns.filter { $0.asrError == nil }.map(\.asrMilliseconds)
        let translations = turns.compactMap(\.appleHighFidelityMilliseconds)
        let expectedPCMSamples = turns.reduce(0) { $0 + $1.inputSampleCount }
        let fedPCMSamples = turns.reduce(0) { $0 + $1.fedSampleCount }
        return JapaneseBakeoffEngineReport(
            engine: engine,
            model: model,
            status: status,
            setupError: setupError,
            primaryHighConfidenceCER: cerReport(turns, confidence: .high),
            diagnosticMediumConfidenceCER: cerReport(turns, confidence: .medium),
            exploratoryUnverifiedCER: cerReport(turns, confidence: .unverified),
            criticalDiagnostics: criticalDiagnostics(turns),
            expectedPCMSamples: expectedPCMSamples,
            fedPCMSamples: fedPCMSamples,
            pcmInputCoverageComplete: expectedPCMSamples > 0
                && fedPCMSamples == expectedPCMSamples,
            pcmConsumptionStatus: "not-exposed-by-benchmark-api",
            lastReferenceTurnHasHypothesis:
                !(turns.last.map(\.hypothesisJapanese) ?? "").isEmpty,
            asrP50Milliseconds: percentile(asr, fraction: 0.50),
            asrP95Milliseconds: percentile(asr, fraction: 0.95),
            asrWorstMilliseconds: asr.max(),
            appleHighFidelityP50Milliseconds: percentile(translations, fraction: 0.50),
            appleHighFidelityP95Milliseconds: percentile(translations, fraction: 0.95),
            appleHighFidelityWorstMilliseconds: translations.max(),
            maximumObservedResidentBytes: turns.map(\.residentBytes).max() ?? 0,
            turns: turns
        )
    }

    private func cerReport(
        _ turns: [JapaneseBakeoffTurnReport],
        confidence: JapaneseBenchmarkManifest.Turn.Confidence
    ) -> JapaneseBakeoffCERReport {
        let selected = turns.filter { $0.confidence == confidence && !$0.overlap }
        let score = JapaneseCER.score(selected.map {
            (reference: $0.referenceJapanese, hypothesis: $0.hypothesisJapanese)
        })
        return JapaneseBakeoffCERReport(
            turnCount: selected.count,
            editDistance: score.editDistance,
            substitutionCount: score.substitutionCount,
            deletionCount: score.deletionCount,
            insertionCount: score.insertionCount,
            referenceCharacterCount: score.referenceCharacterCount,
            hypothesisCharacterCount: score.hypothesisCharacterCount,
            omissionCount: score.omissionCount,
            rate: score.rate
        )
    }

    private func criticalDiagnostics(
        _ turns: [JapaneseBakeoffTurnReport]
    ) -> JapaneseBakeoffCriticalDiagnostics {
        let scorableTurns = turns.filter { !$0.overlap }
        let annotatedTermCount = scorableTurns.reduce(0) { $0 + $1.criticalTerms.count }
        let missing: [JapaneseBakeoffCriticalDiagnostics.MissingTerm] = scorableTurns.flatMap { turn in
            let hypothesis = String(JapaneseCER.normalized(turn.hypothesisJapanese))
            return turn.criticalTerms.compactMap {
                term -> JapaneseBakeoffCriticalDiagnostics.MissingTerm? in
                let normalizedTerm = String(JapaneseCER.normalized(term.japanese))
                guard !hypothesis.contains(normalizedTerm) else { return nil }
                return JapaneseBakeoffCriticalDiagnostics.MissingTerm(
                    turnID: turn.turnID,
                    category: term.category,
                    japanese: term.japanese
                )
            }
        }
        return JapaneseBakeoffCriticalDiagnostics(
            annotatedTermCount: annotatedTermCount,
            missingAnnotatedTermCount: missing.count,
            missingTerms: missing,
            scoringStatus: annotatedTermCount == 0
                ? "unavailable-no-human-critical-term-annotations"
                : "scored-from-manifest-critical-terms",
            note: "Only manifest criticalTerms are admissible. Heuristic marker matching is intentionally excluded from promotion evidence."
        )
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(ceil(Double(sorted.count) * fraction)) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func pairedBootstrap(
        _ observations: [JapanesePairedCERObservation],
        resamples: Int = 10_000,
        seed: UInt64 = 0x4A41_5041_4E
    ) -> JapaneseBakeoffBootstrapInterval {
        func improvement(_ sample: [JapanesePairedCERObservation]) -> Double? {
            let baselineErrors = sample.reduce(0) { $0 + $1.baselineErrors }
            let candidateErrors = sample.reduce(0) { $0 + $1.candidateErrors }
            let referenceCharacters = sample.reduce(0) { $0 + $1.referenceCharacters }
            guard baselineErrors > 0, referenceCharacters > 0 else { return nil }
            let baselineRate = Double(baselineErrors) / Double(referenceCharacters)
            let candidateRate = Double(candidateErrors) / Double(referenceCharacters)
            return 1 - candidateRate / baselineRate
        }

        guard !observations.isEmpty, resamples > 0 else {
            return JapaneseBakeoffBootstrapInterval(
                observedRelativeImprovement: nil,
                lower95: nil,
                upper95: nil,
                resamples: resamples
            )
        }
        var state = seed
        var samples: [Double] = []
        samples.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var resample: [JapanesePairedCERObservation] = []
            resample.reserveCapacity(observations.count)
            for _ in observations.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let index = Int((state >> 32) % UInt64(observations.count))
                resample.append(observations[index])
            }
            if let value = improvement(resample) { samples.append(value) }
        }
        return JapaneseBakeoffBootstrapInterval(
            observedRelativeImprovement: improvement(observations),
            lower95: percentile(samples, fraction: 0.025),
            upper95: percentile(samples, fraction: 0.975),
            resamples: resamples
        )
    }

    private func bakeoffComparisons(
        reports: [JapaneseBakeoffEngineReport],
        manifest: JapaneseBenchmarkManifest
    ) -> [JapaneseBakeoffComparison] {
        guard let baseline = reports.first(where: { $0.engine == .whisperTurbo }) else {
            return []
        }
        let baselineTurns = Dictionary(uniqueKeysWithValues: baseline.turns.map { ($0.turnID, $0) })
        return reports.filter { $0.engine != .whisperTurbo }.map { candidate in
            let observations = candidate.turns.compactMap { turn -> JapanesePairedCERObservation? in
                guard turn.confidence == .high, !turn.overlap,
                      let baselineTurn = baselineTurns[turn.turnID] else { return nil }
                let baselineScore = JapaneseCER.score([(
                    reference: turn.referenceJapanese,
                    hypothesis: baselineTurn.hypothesisJapanese,
                )])
                let candidateScore = JapaneseCER.score([(
                    reference: turn.referenceJapanese,
                    hypothesis: turn.hypothesisJapanese,
                )])
                return JapanesePairedCERObservation(
                    baselineErrors: baselineScore.editDistance,
                    candidateErrors: candidateScore.editDistance,
                    referenceCharacters: candidateScore.referenceCharacterCount
                )
            }
            let bootstrap = pairedBootstrap(observations)
            let qualityPasses = bootstrap.lower95.map { $0 >= 0.10 } == true
            var blockers: [String] = []
            if manifest.annotations.status != .complete {
                blockers.append("corpus annotations are not complete")
            }
            if baseline.status != "execution-complete"
                || candidate.status != "execution-complete" {
                blockers.append("one or both ASR executions are incomplete")
            }
            if !baseline.model.artifactSHA256Verified
                || !candidate.model.artifactSHA256Verified {
                blockers.append("one or both model artifacts are not SHA-pinned")
            }
            if !baseline.pcmInputCoverageComplete || !candidate.pcmInputCoverageComplete {
                blockers.append("PCM input coverage is incomplete")
            }
            if !baseline.lastReferenceTurnHasHypothesis
                || !candidate.lastReferenceTurnHasHypothesis {
                blockers.append("the final annotated turn is absent")
            }
            let baselineMissingTerms = Set(baseline.criticalDiagnostics.missingTerms.map {
                "\($0.turnID)|\($0.category.rawValue)|\($0.japanese)"
            })
            let candidateMissingTerms = Set(candidate.criticalDiagnostics.missingTerms.map {
                "\($0.turnID)|\($0.category.rawValue)|\($0.japanese)"
            })
            if candidate.criticalDiagnostics.annotatedTermCount == 0 {
                blockers.append("critical terms are not human-annotated")
            } else if !candidateMissingTerms.subtracting(baselineMissingTerms).isEmpty {
                blockers.append("the candidate adds critical-term omissions")
            }
            if !qualityPasses {
                blockers.append("paired CER bootstrap does not clear the 10% quality gate")
            }
            if candidate.maximumObservedResidentBytes >= 10 * 1_024 * 1_024 * 1_024
                || Double(candidate.maximumObservedResidentBytes)
                    > Double(Self.baselineResidentBytes) * 1.20 {
                blockers.append("an observed post-turn RSS snapshot exceeds the L0 gate")
            }
            blockers.append("English preview, final stability and backlog need exact product replay")
            blockers.append("all independent holdouts must be evaluated together")
            return JapaneseBakeoffComparison(
                baseline: .whisperTurbo,
                candidate: candidate.engine,
                pairedCERBootstrap: bootstrap,
                qualityPathPasses: qualityPasses,
                previewPathStatus: "not-measured-by-offline-ASR-oracle",
                blockingReasons: blockers
            )
        }
    }

    private func promotionDecision(
        manifest: JapaneseBenchmarkManifest
    ) -> String {
        if manifest.annotations.status != .complete {
            return "blocked: corpus requires human validation"
        }
        return "blocked: exact product replay and all complete holdouts are still required"
    }

    private func benchmarkRunID(environment: [String: String]) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generated = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.lowercased()
        let runID = environment["WHISPERASR_BENCHMARK_RUN_ID"] ?? generated
        guard runID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
            options: .regularExpression
        ) != nil else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Invalid benchmark run ID.")
        }
        return runID
    }

    private func fixtureProvenance(
        _ engine: JapaneseBakeoffEngine
    ) -> JapaneseBakeoffModelProvenance {
        let base = unresolvedProvenance(engine)
        return JapaneseBakeoffModelProvenance(
            modelID: base.modelID,
            revision: base.revision,
            revisionEnforced: true,
            artifactSHA256: "fixture",
            expectedArtifactSHA256: "fixture",
            artifactSHA256Verified: true,
            license: base.license,
            runtime: base.runtime,
            runtimeRevision: base.runtimeRevision
        )
    }

    private func unresolvedProvenance(
        _ engine: JapaneseBakeoffEngine
    ) -> JapaneseBakeoffModelProvenance {
        switch engine {
        case .whisperTurbo:
            return JapaneseBakeoffModelProvenance(
                modelID: "ggerganov/whisper.cpp:ggml-large-v3-turbo.bin",
                revision: Self.whisperRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "MIT",
                runtime: "CWhisper.xcframework",
                runtimeRevision: "repository-binary"
            )
        case .voxtralContinuous:
            return JapaneseBakeoffModelProvenance(
                modelID: VoxtralModelVariant.q4.modelID,
                revision: VoxtralModelVariant.q4.modelRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "Apache-2.0",
                runtime: "mlx-audio \(VoxtralHelperManifest.mlxAudioVersion)",
                runtimeRevision: VoxtralHelperManifest.mlxAudioCommit
            )
        case .nemotron1120, .nemotron560:
            return JapaneseBakeoffModelProvenance(
                modelID: Self.nemotronModelID,
                revision: Self.nemotronRevision,
                revisionEnforced: false,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "OpenMDW-1.1",
                runtime: "FluidAudio \(Self.fluidAudioVersion)",
                runtimeRevision: Self.fluidAudioRevision
            )
        }
    }

    private func modelProvenance(
        _ engine: JapaneseBakeoffEngine,
        root: URL,
        environment: [String: String]
    ) throws -> JapaneseBakeoffModelProvenance {
        let base = unresolvedProvenance(engine)
        let artifact: URL
        switch engine {
        case .whisperTurbo:
            guard let turbo = ModelCatalog.model(id: "large-v3-turbo") else {
                throw JapaneseBenchmarkCSV.ParseError.malformed("Whisper Turbo is absent.")
            }
            artifact = ModelCatalog.path(for: turbo)
        case .voxtralContinuous:
            artifact = AppStoragePaths.root
                .appendingPathComponent("Runtime/Models", isDirectory: true)
                .appendingPathComponent(
                    VoxtralContinuousConfiguration.default.modelSnapshotDirectoryName,
                    isDirectory: true
                )
        case .nemotron1120, .nemotron560:
            artifact = nemotronModelDirectory(
                engine: engine,
                root: root,
                environment: environment
            )
        }
        let observed = try artifactSHA256(at: artifact)
        return JapaneseBakeoffModelProvenance(
            modelID: base.modelID,
            revision: base.revision,
            revisionEnforced: base.revisionEnforced,
            artifactSHA256: observed,
            expectedArtifactSHA256: base.expectedArtifactSHA256,
            artifactSHA256Verified: base.expectedArtifactSHA256 == observed,
            license: base.license,
            runtime: base.runtime,
            runtimeRevision: base.runtimeRevision
        )
    }

    private func nemotronModelRoot(
        root: URL,
        environment: [String: String]
    ) -> URL {
        if let path = environment["WHISPERASR_NEMOTRON_MODEL_ROOT"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return root.appendingPathComponent(
            ".build/models/nemotron-\(Self.nemotronRevision)",
            isDirectory: true
        )
    }

    private func nemotronModelDirectory(
        engine: JapaneseBakeoffEngine,
        root: URL,
        environment: [String: String]
    ) -> URL {
        let chunkMilliseconds: Int
        switch engine {
        case .nemotron1120: chunkMilliseconds = 1_120
        case .nemotron560: chunkMilliseconds = 560
        case .whisperTurbo, .voxtralContinuous:
            preconditionFailure("Only Nemotron engines have a chunk duration.")
        }
        return nemotronModelRoot(root: root, environment: environment)
            .appendingPathComponent("nemotron-multilingual/multilingual", isDirectory: true)
            .appendingPathComponent("\(chunkMilliseconds)ms", isDirectory: true)
    }

    private static func expectedArtifactSHA256(
        for engine: JapaneseBakeoffEngine
    ) -> String {
        switch engine {
        case .whisperTurbo:
            whisperTurboSHA256
        case .voxtralContinuous:
            "178e8cd18ffe0e6788504cac1146bbc0c0eafb262acecd24aa63c0e863333d86"
        case .nemotron1120:
            "a398b4fb9d1818395934191c7301571f6a958b8ad2a82e670029da38bd3efae9"
        case .nemotron560:
            "ad9a4c88796e765d60e304d36ae2688b914835447203f44af92056212cfc340d"
        }
    }

    private func artifactSHA256(at url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Missing artifact at \(url.path).")
        }
        if !isDirectory.boolValue { return try JapaneseBenchmarkSupport.sha256(at: url) }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Cannot enumerate \(url.path).")
        }
        let files = enumerator.compactMap { $0 as? URL }.filter { file in
            (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(url.path.count + 1))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func blindArtifacts(
        corpusID: String,
        scope: String,
        seed: String,
        reports: [JapaneseBakeoffEngineReport]
    ) -> (report: JapaneseBakeoffBlindReport, key: [String: String]) {
        let engines = JapaneseBakeoffEngine.allCases
        let reportsByEngine = Dictionary(uniqueKeysWithValues: reports.map { ($0.engine, $0) })
        let turnIDs = Set(reports.flatMap { $0.turns.map(\.turnID) }).sorted()
        var key: [String: String] = [:]
        let items = turnIDs.compactMap { turnID -> JapaneseBakeoffBlindItem? in
            let available = reports.compactMap { report in
                report.turns.first { $0.turnID == turnID }
            }
            guard let reference = available.first else { return nil }
            let availableEngines = JapaneseBenchmarkSupport.blindOrder(
                engines.filter { engine in
                    reportsByEngine[engine]?.turns.contains(where: {
                        $0.turnID == turnID
                    }) == true
                },
                seed: seed,
                itemID: turnID,
                identity: { $0.rawValue }
            )
            let candidates = availableEngines.enumerated().compactMap {
                aliasIndex, engine -> JapaneseBakeoffBlindCandidate? in
                guard let turn = reportsByEngine[engine]?.turns.first(where: {
                    $0.turnID == turnID
                }) else { return nil }
                let alias = String(UnicodeScalar(65 + aliasIndex)!)
                key["\(turnID):\(alias)"] = engine.rawValue
                return JapaneseBakeoffBlindCandidate(
                    alias: alias,
                    japanese: turn.hypothesisJapanese,
                    english: turn.appleEnglish
                )
            }
            return JapaneseBakeoffBlindItem(
                turnID: turnID,
                confidence: reference.confidence,
                referenceJapanese: reference.referenceJapanese,
                candidates: candidates
            )
        }
        return (
            JapaneseBakeoffBlindReport(
                schemaVersion: 1,
                corpusID: corpusID,
                scope: scope,
                note: "Aliases are randomized independently for each turn with a secret stored only in the separate key. English is present only when WHISPERASR_JAPANESE_BAKEOFF_APPLE=1.",
                items: items
            ),
            key
        )
    }

    private func writeBakeoffArtifacts(
        report: JapaneseBakeoffFullReport,
        blind: JapaneseBakeoffBlindReport,
        key: [String: String],
        corpusID: String,
        scope: String,
        runID: String,
        root: URL
    ) throws {
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/\(runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let safeScope = scope.replacingOccurrences(of: "/", with: "-")
        let stem = "\(corpusID)-asr-bakeoff-\(safeScope)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifacts: [(String, Data)] = [
            ("\(stem)-full.json", try encoder.encode(report)),
            ("\(stem)-blind.json", try encoder.encode(blind)),
            ("\(stem)-key.json", try encoder.encode(key)),
        ]
        for (name, data) in artifacts {
            let url = output.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            print("[JapaneseBakeoff] wrote \(url.path)")
        }
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "n/a"
    }

    private func referenceTurn(
        _ record: [String: String],
        expectedID: Int
    ) throws -> JapaneseBenchmarkManifest.Turn {
        let id = try integer(record["tour"], field: "tour")
        guard id == expectedID else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Expected turn \(expectedID), found \(id)."
            )
        }
        let start = try JapaneseBenchmarkCSV.sampleIndex(
            timecode: try required(record["debut_switch"], field: "debut_switch")
        )
        let end = try JapaneseBenchmarkCSV.sampleIndex(
            timecode: try required(record["fin"], field: "fin")
        )
        guard end > start else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Turn \(id) has an invalid range.")
        }
        let confidence = try confidence(record["confiance"])
        let note = record["note"].flatMap { $0.isEmpty ? nil : $0 }
        return JapaneseBenchmarkManifest.Turn(
            id: id,
            speaker: try required(record["locuteur"], field: "locuteur"),
            startSample: start,
            endSample: end,
            japanese: try required(record["japonais"], field: "japonais"),
            english: nil,
            confidence: confidence,
            criticalTerms: [],
            overlap: nil,
            note: note
        )
    }

    private func validateDetailedRecords(_ records: [[String: String]]) throws {
        guard records.count == 102 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Expected 102 detailed fragments, found \(records.count)."
            )
        }
        var high = 0
        var medium = 0
        var previousEnd = 0
        for (index, record) in records.enumerated() {
            let id = try integer(record["index"], field: "index")
            guard id == index + 1 else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Expected detailed fragment \(index + 1), found \(id)."
                )
            }
            let start = try JapaneseBenchmarkCSV.sampleIndex(
                timecode: try required(record["debut"], field: "debut")
            )
            let end = try JapaneseBenchmarkCSV.sampleIndex(
                timecode: try required(record["fin"], field: "fin")
            )
            guard start >= previousEnd,
                  end > start,
                  ["OUI", "NON"].contains(try required(
                    record["changement_de_locuteur"],
                    field: "changement_de_locuteur"
                  )) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Detailed fragment \(id) has invalid timing or speaker-change state."
                )
            }
            _ = try required(record["locuteur"], field: "locuteur")
            _ = try required(record["japonais"], field: "japonais")
            switch try confidence(record["confiance"]) {
            case .high: high += 1
            case .medium: medium += 1
            case .low, .unverified:
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Detailed CSV can only contain high or medium confidence."
                )
            }
            previousEnd = end
        }
        guard high == 89, medium == 13 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Unexpected detailed confidence counts: high=\(high), medium=\(medium)."
            )
        }
    }

    private func confidence(
        _ value: String?
    ) throws -> JapaneseBenchmarkManifest.Turn.Confidence {
        switch value {
        case "élevée": .high
        case "moyenne": .medium
        default:
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Unexpected confidence: \(value ?? "nil")."
            )
        }
    }

    private func integer(_ value: String?, field: String) throws -> Int {
        guard let value, let result = Int(value) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Invalid integer in \(field).")
        }
        return result
    }

    private func required(_ value: String?, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Missing \(field).")
        }
        return value
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
