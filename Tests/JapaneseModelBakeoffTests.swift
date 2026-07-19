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
    case mlxWhisperTurbo = "mlx-whisper-large-v3-turbo"
    case voxtralContinuous = "voxtral-q4-continuous-960ms"
    case nemotron1120 = "nemotron-multilingual-coreml-1120ms"
    case nemotron560 = "nemotron-multilingual-coreml-560ms"
    case kotobaQ5 = "kotoba-whisper-v2.0-q5"
    case qwen17 = "qwen3-asr-1.7b"
    case whisperMLXBatch = "whispermlx-v3.12.2-turbo"

    var finalLatencyIsMeasuredByOfflineRun: Bool {
        switch self {
        case .voxtralContinuous, .nemotron1120, .nemotron560:
            false
        default:
            true
        }
    }
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
    let corpusID: String
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
    let asrFedSampleCount: Int
    let asrMilliseconds: Double
    let residentBytes: UInt64
    let asrError: String?
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
    let diagnosticLowConfidenceCER: JapaneseBakeoffCERReport
    let diagnosticOverlapCER: JapaneseBakeoffCERReport
    let exploratoryUnverifiedCER: JapaneseBakeoffCERReport
    let criticalDiagnostics: JapaneseBakeoffCriticalDiagnostics
    let expectedPCMSamples: Int
    let inputPCMSamples: Int
    let asrFedPCMSamples: Int
    let pcmInputCoverageComplete: Bool
    let pcmConsumptionStatus: String
    let corpusCoverage: [JapaneseBakeoffCorpusCoverage]
    let asrP50Milliseconds: Double?
    let asrP95Milliseconds: Double?
    let asrWorstMilliseconds: Double?
    let primaryEmptySpeechTurnCount: Int
    let diagnosticEmptySpeechTurnCount: Int
    let maximumObservedResidentBytes: UInt64
    let turns: [JapaneseBakeoffTurnReport]
}

private struct JapaneseBakeoffCorpusCoverage: Codable {
    let corpusID: String
    let expectedSelectedPCMSamples: Int
    let inputSelectedPCMSamples: Int
    let asrFedSelectedPCMSamples: Int
    let selectedPCMInputComplete: Bool
    let lastSelectedSpeechPresent: Bool
}

private struct JapaneseBakeoffCriticalDiagnostics: Codable {
    struct MissingTerm: Codable {
        let corpusID: String
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
    let mlxWhisperVersion: String
    let whisperMLXVersion: String
    let sileroRevision: String
    let mlxInferenceSeedStrategy: String
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
    let corpusCERDeltas: [JapaneseBakeoffCorpusCERDelta]
    let qualityPathPasses: Bool
    let criticalCorrectionPathPasses: Bool
    let l5GatePasses: Bool
    let l5BlockingReasons: [String]
    let normalizedTextAgreement: Double?
    let previewPathStatus: String
    let blockingReasons: [String]
}

private struct JapaneseBakeoffCorpusCERDelta: Codable {
    let corpusID: String
    let baselineRate: Double?
    let candidateRate: Double?
    let delta: Double?
    let noMoreThanTwoPointRegression: Bool
}

private struct JapanesePairedCERObservation {
    let baselineErrors: Int
    let candidateErrors: Int
    let referenceCharacters: Int
}

private struct JapaneseBakeoffCorpusReport: Codable {
    let corpusID: String
    let purpose: String
    let manifestSHA256: String
    let audioSHA256: String
    let annotationStatus: String
    let promotionEligibleReference: Bool
    let selectedTurnIDs: [Int]
}

private struct JapaneseBakeoffFullReport: Codable {
    let schemaVersion: Int
    let runID: String
    let gitCommit: String
    let worktreeDirty: Bool
    let modelHubOfflineMode: Bool
    let externalNetworkAccessDenied: Bool
    let corpora: [JapaneseBakeoffCorpusReport]
    let generatedAt: String
    let scope: String
    let boundaryMode: String
    let productionBoundaryStatus: String
    let productionBoundaryNote: String
    let voxtralConfiguration: VoxtralContinuousConfiguration
    let configuration: JapaneseBakeoffConfiguration
    let engines: [JapaneseBakeoffEngineReport]
    let comparisons: [JapaneseBakeoffComparison]
    let promotionDecision: String
}

private struct JapaneseASRResult {
    let text: String
    let asrFedSampleCount: Int
}

private struct JapaneseBakeoffCorpusInput {
    let manifest: JapaneseBenchmarkManifest
    let manifestSHA256: String
    let wavURL: URL
    let samples: [Float]
    let turns: [JapaneseBenchmarkManifest.Turn]
}

private struct JapaneseExternalASRRequest: Codable {
    struct Corpus: Codable {
        struct Turn: Codable {
            let turnID: Int
            let startSample: Int
            let endSample: Int
        }

        let corpusID: String
        let audioPath: String
        let turns: [Turn]
    }

    let backend: String
    let modelPath: String
    let sileroPath: String?
    let corpora: [Corpus]
}

private struct JapaneseExternalASRResponse: Codable {
    struct Turn: Codable {
        let corpusID: String
        let turnID: Int
        let hypothesisJapanese: String
        let inputSampleCount: Int
        let fedSampleCount: Int
        let asrMilliseconds: Double
        let residentBytes: UInt64
        let error: String?
    }

    let setupError: String?
    let turns: [Turn]
}

private struct JapaneseBakeoffBlindCandidate: Codable {
    let alias: String
    let japanese: String
}

private struct JapaneseBakeoffBlindItem: Codable {
    let corpusID: String
    let turnID: Int
    let confidence: JapaneseBenchmarkManifest.Turn.Confidence
    let referenceJapanese: String
    let candidates: [JapaneseBakeoffBlindCandidate]
}

private struct JapaneseBakeoffBlindReport: Codable {
    let schemaVersion: Int
    let corpusIDs: [String]
    let scope: String
    let note: String
    let items: [JapaneseBakeoffBlindItem]
}

final class JapaneseModelBakeoffTests: XCTestCase {
    private static let fluidAudioVersion = "0.15.5"
    private static let fluidAudioRevision = "19600a485baa4998812e4654b70d2bab8f2c9949"
    private static let nemotronModelID =
        "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    private static let nemotronRevision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let whisperTurboSHA256 =
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    private static let mlxWhisperVersion = "0.4.3"
    private static let mlxWhisperWheelSHA256 =
        "6b82b6597a994643a3e5496c7bc229a672e5ca308458455bfe276e76ae024489"
    private static let mlxWhisperModelRevision =
        "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
    private static let mlxWhisperWeightsSHA256 =
        "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"
    private static let kotobaRevision =
        "e3a0cf6a62b95911703cfb97d819292e058f12c3"
    private static let kotobaQ5SHA256 =
        "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"
    private static let qwenRevision =
        "e5450a26d1fd417c45fc9c405651ddc3180a27a6"
    private static let qwenWeightsSHA256 =
        "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
    private static let whisperMLXVersion = "3.12.2"
    private static let whisperMLXRevision =
        "37816743c29a569405f300bbb4b3ef8001152651"
    private static let whisperMLXWheelSHA256 =
        "60845ff695168aeb3b8d8b1887481ffe02f5e11ec0426c706a9f7cd0a37917a4"
    private static let sileroRevision =
        "7e30209a3e901f9842f81b225f3e93d8199902b1"
    private static let baselineResidentBytes: UInt64 = 4_185_313_288
    private static let stressTurnIDs: [String: [Int]] = [
        "qudu2fx3ncc": Array(147...183) + Array(193...199),
        "md62mmdz0m": Array(149...187) + Array(265...273),
    ]
    private static let turnsHeader = [
        "tour", "debut_switch", "fin", "locuteur", "description_locuteur",
        "japonais", "confiance", "note",
    ]
    private static let detailedHeader = [
        "index", "debut", "fin", "locuteur", "description_locuteur",
        "changement_de_locuteur", "japonais", "confiance", "note",
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
        XCTAssertTrue(lastSpeechPresent(reference: "私でも重いのかな", hypothesis: "私でも重いかな"))
        XCTAssertFalse(lastSpeechPresent(reference: "私でも重いのかな", hypothesis: "ありがとうございました"))
    }

    func testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns() {
        let reports = [
            JapaneseBakeoffTurnReport(
                corpusID: "fixture",
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
                asrFedSampleCount: 16_000,
                asrMilliseconds: 10,
                residentBytes: 1,
                asrError: nil
            ),
            JapaneseBakeoffTurnReport(
                corpusID: "fixture",
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
                asrFedSampleCount: 16_000,
                asrMilliseconds: 20,
                residentBytes: 2,
                asrError: nil
            ),
            JapaneseBakeoffTurnReport(
                corpusID: "fixture",
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
                asrFedSampleCount: 16_000,
                asrMilliseconds: 30,
                residentBytes: 3,
                asrError: nil
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
        let emptySpeech = emptySpeechCounts(reports)
        XCTAssertEqual(emptySpeech.primary, 0)
        XCTAssertEqual(emptySpeech.diagnostic, 2)
        XCTAssertTrue(JapaneseBakeoffEngine.whisperTurbo.finalLatencyIsMeasuredByOfflineRun)
        XCTAssertFalse(
            JapaneseBakeoffEngine.voxtralContinuous.finalLatencyIsMeasuredByOfflineRun
        )
        let critical = criticalDiagnostics(reports)
        XCTAssertEqual(critical.annotatedTermCount, 1)
        XCTAssertEqual(critical.missingAnnotatedTermCount, 1)
        XCTAssertEqual(critical.missingTerms.first?.japanese, "語")

        let artifacts = blindArtifacts(
            corpusIDs: ["fixture"],
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
                    diagnosticLowConfidenceCER: cerReport(reports, confidence: .low),
                    diagnosticOverlapCER: cerReport(reports, overlapOnly: true),
                    exploratoryUnverifiedCER: cerReport(reports, confidence: .unverified),
                    criticalDiagnostics: criticalDiagnostics(reports),
                    expectedPCMSamples: 48_000,
                    inputPCMSamples: 48_000,
                    asrFedPCMSamples: 48_000,
                    pcmInputCoverageComplete: true,
                    pcmConsumptionStatus: "not-exposed-by-benchmark-api",
                    corpusCoverage: [
                        JapaneseBakeoffCorpusCoverage(
                            corpusID: "fixture",
                            expectedSelectedPCMSamples: 48_000,
                            inputSelectedPCMSamples: 48_000,
                            asrFedSelectedPCMSamples: 48_000,
                            selectedPCMInputComplete: true,
                            lastSelectedSpeechPresent: false
                        )
                    ],
                    asrP50Milliseconds: 10,
                    asrP95Milliseconds: 30,
                    asrWorstMilliseconds: 30,
                    primaryEmptySpeechTurnCount: emptySpeech.primary,
                    diagnosticEmptySpeechTurnCount: emptySpeech.diagnostic,
                    maximumObservedResidentBytes: 3,
                    turns: reports
                )
            }
        )
        XCTAssertEqual(artifacts.report.items.count, 3)
        XCTAssertEqual(
            Set(artifacts.report.items[0].candidates.map(\.alias)),
            Set(["A", "B", "C", "D", "E", "F", "G", "H"])
        )
        XCTAssertEqual(artifacts.key.count, 24)
    }

    func testBakeoffModelArtifactsArePinned() throws {
        let turbo = try XCTUnwrap(ModelCatalog.model(id: "large-v3-turbo"))
        XCTAssertEqual(turbo.sha256, Self.whisperTurboSHA256)
        XCTAssertTrue(turbo.url.path.contains(Self.whisperRevision))
    }

    func testL5StressPackIsFixedAndBandSeparated() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifests = try ["qudu2fx3ncc", "md62mmdz0m"].map { corpusID in
            try JapaneseBenchmarkSupport.loadManifest(
                at: root.appendingPathComponent(
                    "docs/japanese-live/corpora/\(corpusID)/manifest.json"
                )
            )
        }
        let selected = try manifests.flatMap { manifest -> [JapaneseBenchmarkManifest.Turn] in
            let identifiers = try selectedTurnIDs(
                environment: [:],
                scope: "stress",
                corpusID: manifest.corpusID,
                turns: manifest.annotations.turns
            )
            return manifest.annotations.turns.filter { identifiers.contains($0.id) }
        }
        XCTAssertEqual(selected.count, 92)
        XCTAssertEqual(selected.filter { $0.confidence == .high && $0.overlap != true }.count, 58)
        XCTAssertEqual(selected.filter { $0.confidence == .medium && $0.overlap != true }.count, 19)
        XCTAssertEqual(selected.filter { $0.confidence == .low && $0.overlap != true }.count, 2)
        XCTAssertEqual(selected.filter { $0.overlap == true }.count, 13)
        XCTAssertThrowsError(try selectedTurnIDs(
            environment: ["WHISPERASR_JAPANESE_BAKEOFF_TURN_IDS": "1"],
            scope: "stress",
            corpusID: manifests[0].corpusID,
            turns: manifests[0].annotations.turns
        ))
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

    /// Run with `Scripts/run_japanese_l5_bakeoff.sh` or the earlier single-corpus script.
    ///
    /// Every engine receives the exact same annotated human turn ranges. The
    /// production clause planner is deliberately not approximated here: its
    /// long-lived state lives in AppState and is measured by the existing live
    /// replay benchmarks instead.
    @MainActor
    func testJapaneseASRBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_JAPANESE_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_l5_bakeoff.sh to compare local Japanese ASR models.")
        }
        guard let gitCommit = environment["WHISPERASR_BENCHMARK_COMMIT"],
              gitCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            XCTFail("WHISPERASR_BENCHMARK_COMMIT must contain the exact 40-character Git commit.")
            return
        }
        ModelHub.offlineMode = environment["WHISPERASR_OFFLINE"] == "1"
        defer { ModelHub.offlineMode = false }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scope = environment["WHISPERASR_JAPANESE_BAKEOFF_SCOPE"] ?? "full"
        let manifestURLs = try benchmarkManifestURLs(
            environment: environment,
            scope: scope,
            root: root
        )
        var corpora: [JapaneseBakeoffCorpusInput] = []
        for manifestURL in manifestURLs {
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            let wavURL = try JapaneseBenchmarkSupport.fixtureURL(
                for: manifest,
                workspaceRoot: root
            )
            XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: wavURL), manifest.fixture.sha256)
            let samples = try await AudioLoader.loadSamples(url: wavURL)
            XCTAssertEqual(samples.count, manifest.fixture.sampleCount)
            XCTAssertEqual(manifest.fixture.sampleRate, 16_000)
            let selectedIDs = try selectedTurnIDs(
                environment: environment,
                scope: scope,
                corpusID: manifest.corpusID,
                turns: manifest.annotations.turns
            )
            let selectedTurns = manifest.annotations.turns.filter { selectedIDs.contains($0.id) }
            guard !selectedTurns.isEmpty, selectedTurns.count == selectedIDs.count else {
                XCTFail("Corpus \(manifest.corpusID) has no complete set of scorable turns.")
                return
            }
            XCTAssertTrue(selectedTurns.allSatisfy { $0.endSample <= samples.count })
            corpora.append(JapaneseBakeoffCorpusInput(
                manifest: manifest,
                manifestSHA256: try JapaneseBenchmarkSupport.sha256(at: manifestURL),
                wavURL: wavURL,
                samples: samples,
                turns: selectedTurns
            ))
        }
        if scope == "stress",
           corpora.map({ $0.manifest.corpusID }) != ["qudu2fx3ncc", "md62mmdz0m"] {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The L5 stress manifests must be ordered qudu2fx3ncc, then md62mmdz0m."
            )
        }

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
                corpora: corpora,
                modelManager: modelManager,
                whisper: whisper,
                root: root,
                environment: environment,
                runID: runID
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
            manifests: corpora.map(\.manifest)
        )

        let report = JapaneseBakeoffFullReport(
            schemaVersion: 6,
            runID: runID,
            gitCommit: gitCommit,
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            modelHubOfflineMode: environment["WHISPERASR_OFFLINE"] == "1",
            externalNetworkAccessDenied:
                environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
            corpora: corpora.map { corpus in
                JapaneseBakeoffCorpusReport(
                    corpusID: corpus.manifest.corpusID,
                    purpose: corpus.manifest.purpose.rawValue,
                    manifestSHA256: corpus.manifestSHA256,
                    audioSHA256: corpus.manifest.fixture.sha256,
                    annotationStatus: corpus.manifest.annotations.status.rawValue,
                    promotionEligibleReference: corpus.manifest.annotations.status == .complete,
                    selectedTurnIDs: corpus.turns.map(\.id)
                )
            },
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            scope: scope,
            boundaryMode: corpora.allSatisfy { $0.manifest.annotations.status == .complete }
                ? "human-reference-turns"
                : "exploratory-unverified-turns",
            productionBoundaryStatus: "not-reproduced",
            productionBoundaryNote: "Production boundaries depend on AppState's continuous VoxtralClausePlanner, VAD, preview scheduler and optional diarization state. Recreating them turn-by-turn here would be a false simulation; use the existing real-time replay reports for that pass.",
            voxtralConfiguration: voxtralConfiguration,
            configuration: JapaneseBakeoffConfiguration(
                language: "ja-JP",
                sampleRate: 16_000,
                executionMode: "sequential-warmed-human-turns",
                engineOrder: requestedEngines,
                fluidAudioVersion: Self.fluidAudioVersion,
                fluidAudioRevision: Self.fluidAudioRevision,
                mlxWhisperVersion: Self.mlxWhisperVersion,
                whisperMLXVersion: Self.whisperMLXVersion,
                sileroRevision: Self.sileroRevision,
                mlxInferenceSeedStrategy: "crc32(corpusID:turnID)"
            ),
            engines: engineReports,
            comparisons: comparisons,
            promotionDecision: promotionDecision(manifests: corpora.map(\.manifest))
        )
        let artifacts = blindArtifacts(
            corpusIDs: corpora.map { $0.manifest.corpusID },
            scope: scope,
            seed: UUID().uuidString,
            reports: engineReports
        )
        try writeBakeoffArtifacts(
            report: report,
            blind: artifacts.report,
            key: artifacts.key,
            runID: runID,
            root: root
        )

        let failures = engineReports.flatMap { engine -> [String] in
            var result: [String] = []
            if engine.status != "execution-complete" {
                result.append("\(engine.engine.rawValue): \(engine.setupError ?? engine.status)")
            }
            result += engine.turns.compactMap { turn in
                turn.asrError.map {
                    "\(engine.engine.rawValue) \(turn.corpusID) turn \(turn.turnID): \($0)"
                }
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

    private func benchmarkManifestURLs(
        environment: [String: String],
        scope: String,
        root: URL
    ) throws -> [URL] {
        let fallback = root.appendingPathComponent(
            "docs/japanese-live/corpora/easy-japanese-1/manifest.json"
        ).path
        let raw = environment["WHISPERASR_JAPANESE_BENCHMARK_MANIFESTS"]
            ?? environment["WHISPERASR_JAPANESE_BENCHMARK_MANIFEST"]
            ?? fallback
        let paths = raw.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }), Set(paths).count == paths.count else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Benchmark manifest paths must be non-empty and unique."
            )
        }
        if scope == "stress", paths.count != 2 {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The fixed L5 stress pack requires exactly two manifests."
            )
        }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func selectedTurnIDs(
        environment: [String: String],
        scope: String,
        corpusID: String,
        turns: [JapaneseBenchmarkManifest.Turn]
    ) throws -> Set<Int> {
        if scope == "stress" {
            guard environment["WHISPERASR_JAPANESE_BAKEOFF_TURN_IDS"] == nil,
                  let expected = Self.stressTurnIDs[corpusID],
                  Set(expected).isSubset(of: Set(turns.map(\.id))) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The L5 stress pack is fixed and cannot be overridden."
                )
            }
            return Set(expected)
        }
        if let raw = environment["WHISPERASR_JAPANESE_BAKEOFF_TURN_IDS"] {
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let identifiers = fields.compactMap(Int.init)
            guard !identifiers.isEmpty,
                  identifiers.count == fields.count,
                  Set(identifiers).count == identifiers.count else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Turn IDs must be non-empty, numeric and unique."
                )
            }
            return Set(identifiers)
        }
        return scope == "smoke"
            ? Set(turns.prefix(4).map(\.id))
            : Set(turns.map(\.id))
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
                "ASR engines must follow the fixed L5 order."
            )
        }
        if scope == "stress", engines != JapaneseBakeoffEngine.allCases {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The L5 stress proof must execute all eight ASR engines."
            )
        }
        return engines
    }

    @MainActor
    private func runEngine(
        _ engine: JapaneseBakeoffEngine,
        corpora: [JapaneseBakeoffCorpusInput],
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        root: URL,
        environment: [String: String],
        runID: String
    ) async -> JapaneseBakeoffEngineReport {
        if engine == .mlxWhisperTurbo || engine == .whisperMLXBatch {
            return await runExternalEngine(
                engine,
                corpora: corpora,
                root: root,
                environment: environment,
                runID: runID
            )
        }
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
            case .kotobaQ5:
                try await whisper.preloadModel(
                    modelPath: kotobaModelURL(root: root, environment: environment).path,
                    requireEnglishTranslation: false
                )
            case .qwen17:
                try await modelManager.prepare(.qwenApple)
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
            case .mlxWhisperTurbo, .whisperMLXBatch:
                preconditionFailure("Python candidates use the external benchmark adapter.")
            }
            if let corpus = corpora.first, let turn = corpus.turns.first {
                _ = try await transcribe(
                    engine,
                    audio: Array(corpus.samples[turn.startSample..<turn.endSample]),
                    absoluteStartSample: turn.startSample,
                    modelManager: modelManager,
                    whisper: whisper,
                    nemotron: nemotron,
                    root: root,
                    environment: environment
                )
            }
        } catch {
            setupError = error.localizedDescription
        }

        if setupError == nil {
            let totalTurns = corpora.reduce(0) { $0 + $1.turns.count }
            var completedTurns = 0
            for corpus in corpora {
                for turn in corpus.turns {
                let audio = Array(corpus.samples[turn.startSample..<turn.endSample])
                let asrStarted = DispatchTime.now().uptimeNanoseconds
                var asrResult = JapaneseASRResult(
                    text: "",
                    asrFedSampleCount: 0
                )
                var asrError: String?
                do {
                    asrResult = try await transcribe(
                        engine,
                        audio: audio,
                        absoluteStartSample: turn.startSample,
                        modelManager: modelManager,
                        whisper: whisper,
                        nemotron: nemotron,
                        root: root,
                        environment: environment
                    )
                } catch {
                    asrError = error.localizedDescription
                }
                let asrFinished = DispatchTime.now().uptimeNanoseconds
                let hypothesis = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

                let helperBytes = engine == .voxtralContinuous
                    ? await modelManager.continuousVoxtralProgress().helperRSSBytes ?? 0
                    : 0
                turnReports.append(JapaneseBakeoffTurnReport(
                    corpusID: corpus.manifest.corpusID,
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
                    asrFedSampleCount: asrResult.asrFedSampleCount,
                    asrMilliseconds: Double(asrFinished - asrStarted) / 1_000_000,
                    residentBytes: modelManager.currentMemoryBytes() + helperBytes,
                    asrError: asrError
                ))
                completedTurns += 1
                print(
                    "[JapaneseBakeoff] \(engine.rawValue) "
                        + "corpus=\(corpus.manifest.corpusID) turn=\(turn.id) "
                        + "progress=\(completedTurns)/\(totalTurns)"
                )
                }
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
            corpora: corpora
        )
    }

    private func runExternalEngine(
        _ engine: JapaneseBakeoffEngine,
        corpora: [JapaneseBakeoffCorpusInput],
        root: URL,
        environment: [String: String],
        runID: String
    ) async -> JapaneseBakeoffEngineReport {
        var provenance = unresolvedProvenance(engine)
        var setupError: String?
        var reports: [JapaneseBakeoffTurnReport] = []
        do {
            provenance = try modelProvenance(engine, root: root, environment: environment)
            guard provenance.artifactSHA256Verified else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The pinned external model artifact failed SHA-256 verification."
                )
            }
            let python = externalPythonURL(
                engine: engine,
                root: root,
                environment: environment
            )
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Missing external ASR Python at \(python.path)."
                )
            }
            if engine == .whisperMLXBatch {
                let head = try String(
                    contentsOf: sileroDirectory(root: root, environment: environment)
                        .appendingPathComponent(".git/HEAD"),
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard head == Self.sileroRevision else {
                    throw JapaneseBenchmarkCSV.ParseError.malformed(
                        "Silero VAD is not at the pinned revision."
                    )
                }
            }
            let output = root.appendingPathComponent(
                ".build/benchmarks/japanese-live/runs/\(runID)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let requestURL = output.appendingPathComponent("\(engine.rawValue)-request.json")
            let responseURL = output.appendingPathComponent("\(engine.rawValue)-response.json")
            let stdoutURL = output.appendingPathComponent("\(engine.rawValue)-stdout.log")
            let stderrURL = output.appendingPathComponent("\(engine.rawValue)-stderr.log")
            let request = JapaneseExternalASRRequest(
                backend: engine == .mlxWhisperTurbo ? "mlx-whisper" : "whispermlx",
                modelPath: mlxWhisperModelDirectory(root: root, environment: environment).path,
                sileroPath: engine == .whisperMLXBatch
                    ? sileroDirectory(root: root, environment: environment).path : nil,
                corpora: corpora.map { corpus in
                    JapaneseExternalASRRequest.Corpus(
                        corpusID: corpus.manifest.corpusID,
                        audioPath: corpus.wavURL.path,
                        turns: corpus.turns.map {
                            JapaneseExternalASRRequest.Corpus.Turn(
                                turnID: $0.id,
                                startSample: $0.startSample,
                                endSample: $0.endSample
                            )
                        }
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(request).write(to: requestURL, options: .atomic)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }
            let process = Process()
            let adapterPath = root.appendingPathComponent(
                "Scripts/japanese_external_asr.py"
            ).path
            let adapterArguments = [
                adapterPath,
                requestURL.path,
                responseURL.path,
            ]
            if environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                process.arguments = [
                    "-p",
                    "(version 1)(allow default)(deny network*)",
                    python.path,
                ] + adapterArguments
            } else {
                process.executableURL = python
                process.arguments = adapterArguments
            }
            process.currentDirectoryURL = root
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()

            let response = try JSONDecoder().decode(
                JapaneseExternalASRResponse.self,
                from: Data(contentsOf: responseURL)
            )
            if let responseError = response.setupError {
                setupError = responseError
            } else if process.terminationStatus != 0 {
                setupError = "External ASR exited with status \(process.terminationStatus)."
            } else {
                let byID = Dictionary(
                    uniqueKeysWithValues: response.turns.map {
                        ("\($0.corpusID):\($0.turnID)", $0)
                    }
                )
                for corpus in corpora {
                    for turn in corpus.turns {
                        let key = "\(corpus.manifest.corpusID):\(turn.id)"
                        guard let result = byID[key] else {
                            throw JapaneseBenchmarkCSV.ParseError.malformed(
                                "External ASR omitted \(key)."
                            )
                        }
                        reports.append(JapaneseBakeoffTurnReport(
                            corpusID: corpus.manifest.corpusID,
                            turnID: turn.id,
                            confidence: turn.confidence,
                            overlap: turn.overlap ?? false,
                            speaker: turn.speaker,
                            startSample: turn.startSample,
                            endSample: turn.endSample,
                            referenceJapanese: turn.japanese,
                            hypothesisJapanese: result.hypothesisJapanese,
                            criticalTerms: turn.criticalTerms,
                            inputSampleCount: result.inputSampleCount,
                            asrFedSampleCount: result.fedSampleCount,
                            asrMilliseconds: result.asrMilliseconds,
                            residentBytes: result.residentBytes,
                            asrError: result.error
                        ))
                    }
                }
            }
        } catch {
            setupError = error.localizedDescription
        }
        return engineReport(
            engine: engine,
            model: provenance,
            setupError: setupError,
            turns: reports,
            corpora: corpora
        )
    }

    @MainActor
    private func transcribe(
        _ engine: JapaneseBakeoffEngine,
        audio: [Float],
        absoluteStartSample: Int,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        nemotron: StreamingNemotronMultilingualAsrManager?,
        root: URL,
        environment: [String: String]
    ) async throws -> JapaneseASRResult {
        switch engine {
        case .whisperTurbo, .kotobaQ5:
            let modelPath: String
            if engine == .whisperTurbo {
                guard let turbo = ModelCatalog.model(id: "large-v3-turbo") else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Whisper Turbo is absent from ModelCatalog."
                        ]
                    )
                }
                modelPath = ModelCatalog.path(for: turbo).path
            } else {
                modelPath = kotobaModelURL(root: root, environment: environment).path
            }
            let text = try await whisper.transcribeChunk(
                samples: audio,
                language: "ja",
                translate: false,
                modelPath: modelPath
            )
            return JapaneseASRResult(
                text: text.text,
                asrFedSampleCount: audio.count
            )
        case .qwen17:
            return JapaneseASRResult(
                text: try await modelManager.transcribeQwen(
                    audio: audio,
                    language: "Japanese"
                ),
                asrFedSampleCount: audio.count
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
                    asrFedSampleCount: audio.count
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
                asrFedSampleCount: audio.count
            )
        case .mlxWhisperTurbo, .whisperMLXBatch:
            preconditionFailure("Python candidates use the external benchmark adapter.")
        }
    }

    private func engineReport(
        engine: JapaneseBakeoffEngine,
        model: JapaneseBakeoffModelProvenance,
        setupError: String?,
        turns: [JapaneseBakeoffTurnReport],
        corpora: [JapaneseBakeoffCorpusInput]
    ) -> JapaneseBakeoffEngineReport {
        let expectedTurnCount = corpora.reduce(0) { $0 + $1.turns.count }
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
        let expectedPCMSamples = corpora.flatMap(\.turns).reduce(0) {
            $0 + $1.endSample - $1.startSample
        }
        let inputPCMSamples = turns.reduce(0) { $0 + $1.inputSampleCount }
        let asrFedPCMSamples = turns.reduce(0) { $0 + $1.asrFedSampleCount }
        let corpusCoverage = corpora.map { corpus -> JapaneseBakeoffCorpusCoverage in
            let corpusTurns = turns.filter { $0.corpusID == corpus.manifest.corpusID }
            let expected = corpus.turns.reduce(0) { $0 + $1.endSample - $1.startSample }
            let input = corpusTurns.reduce(0) { $0 + $1.inputSampleCount }
            let asrFed = corpusTurns.reduce(0) { $0 + $1.asrFedSampleCount }
            let lastTurn = corpus.turns.last
            let lastPresent = lastTurn.map { expectedTurn in
                guard let actual = corpusTurns.first(where: {
                    $0.turnID == expectedTurn.id
                }) else { return false }
                return lastSpeechPresent(
                    reference: expectedTurn.japanese,
                    hypothesis: actual.hypothesisJapanese
                )
            } ?? false
            return JapaneseBakeoffCorpusCoverage(
                corpusID: corpus.manifest.corpusID,
                expectedSelectedPCMSamples: expected,
                inputSelectedPCMSamples: input,
                asrFedSelectedPCMSamples: asrFed,
                selectedPCMInputComplete: corpusTurns.count == corpus.turns.count
                    && input == expected,
                lastSelectedSpeechPresent: lastPresent
            )
        }
        let emptySpeech = emptySpeechCounts(turns)
        return JapaneseBakeoffEngineReport(
            engine: engine,
            model: model,
            status: status,
            setupError: setupError,
            primaryHighConfidenceCER: cerReport(turns, confidence: .high),
            diagnosticMediumConfidenceCER: cerReport(turns, confidence: .medium),
            diagnosticLowConfidenceCER: cerReport(turns, confidence: .low),
            diagnosticOverlapCER: cerReport(turns, overlapOnly: true),
            exploratoryUnverifiedCER: cerReport(turns, confidence: .unverified),
            criticalDiagnostics: criticalDiagnostics(turns),
            expectedPCMSamples: expectedPCMSamples,
            inputPCMSamples: inputPCMSamples,
            asrFedPCMSamples: asrFedPCMSamples,
            pcmInputCoverageComplete: expectedPCMSamples > 0
                && inputPCMSamples == expectedPCMSamples,
            pcmConsumptionStatus: asrFedPCMSamples == expectedPCMSamples
                ? "all-selected-pcm-reached-asr"
                : "vad-filtered-before-asr",
            corpusCoverage: corpusCoverage,
            asrP50Milliseconds: percentile(asr, fraction: 0.50),
            asrP95Milliseconds: percentile(asr, fraction: 0.95),
            asrWorstMilliseconds: asr.max(),
            primaryEmptySpeechTurnCount: emptySpeech.primary,
            diagnosticEmptySpeechTurnCount: emptySpeech.diagnostic,
            maximumObservedResidentBytes: turns.map(\.residentBytes).max() ?? 0,
            turns: turns
        )
    }

    private func cerReport(
        _ turns: [JapaneseBakeoffTurnReport],
        confidence: JapaneseBenchmarkManifest.Turn.Confidence? = nil,
        overlapOnly: Bool = false
    ) -> JapaneseBakeoffCERReport {
        let selected = turns.filter { turn in
            overlapOnly ? turn.overlap : !turn.overlap && turn.confidence == confidence
        }
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

    private func emptySpeechCounts(
        _ turns: [JapaneseBakeoffTurnReport]
    ) -> (primary: Int, diagnostic: Int) {
        let emptySpeech = turns.filter {
            !JapaneseCER.normalized($0.referenceJapanese).isEmpty
                && JapaneseCER.normalized($0.hypothesisJapanese).isEmpty
        }
        let primary = emptySpeech.filter {
            !$0.overlap && $0.confidence == .high
        }.count
        return (primary, emptySpeech.count - primary)
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
                    corpusID: turn.corpusID,
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

    private func lastSpeechPresent(reference: String, hypothesis: String) -> Bool {
        let score = JapaneseCER.score([(reference: reference, hypothesis: hypothesis)])
        guard score.referenceCharacterCount > 0 else { return false }
        let matchingCharacters = score.referenceCharacterCount
            - score.substitutionCount
            - score.deletionCount
        return matchingCharacters * 2 >= score.referenceCharacterCount
    }

    private func normalizedTextAgreement(
        candidate: [JapaneseBakeoffTurnReport],
        baseline: [String: JapaneseBakeoffTurnReport]
    ) -> Double? {
        let comparable = candidate.compactMap { turn -> (String, String)? in
            guard turn.confidence == .high, !turn.overlap,
                  let reference = baseline["\(turn.corpusID):\(turn.turnID)"] else {
                return nil
            }
            return (
                String(JapaneseCER.normalized(turn.hypothesisJapanese)),
                String(JapaneseCER.normalized(reference.hypothesisJapanese))
            )
        }
        guard !comparable.isEmpty else { return nil }
        return Double(comparable.filter { $0.0 == $0.1 }.count) / Double(comparable.count)
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
        manifests: [JapaneseBenchmarkManifest]
    ) -> [JapaneseBakeoffComparison] {
        reports.filter { $0.engine != .whisperTurbo }.compactMap { candidate in
            let baselineEngine: JapaneseBakeoffEngine = candidate.engine == .whisperMLXBatch
                ? .mlxWhisperTurbo : .whisperTurbo
            guard let baseline = reports.first(where: { $0.engine == baselineEngine }) else {
                return nil
            }
            let baselineTurns = Dictionary(uniqueKeysWithValues: baseline.turns.map {
                ("\($0.corpusID):\($0.turnID)", $0)
            })
            let observations = candidate.turns.compactMap { turn -> JapanesePairedCERObservation? in
                guard turn.confidence == .high, !turn.overlap,
                      let baselineTurn = baselineTurns["\(turn.corpusID):\(turn.turnID)"] else {
                    return nil
                }
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
            let statisticalQualityPasses = bootstrap.lower95.map { $0 >= 0.10 } == true
            let textAgreement = normalizedTextAgreement(
                candidate: candidate.turns,
                baseline: baselineTurns
            )
            let corpusDeltas = manifests.map { manifest -> JapaneseBakeoffCorpusCERDelta in
                let baselineRate = cerReport(
                    baseline.turns.filter { $0.corpusID == manifest.corpusID },
                    confidence: .high
                ).rate
                let candidateRate = cerReport(
                    candidate.turns.filter { $0.corpusID == manifest.corpusID },
                    confidence: .high
                ).rate
                let delta = baselineRate.flatMap { base in candidateRate.map { $0 - base } }
                return JapaneseBakeoffCorpusCERDelta(
                    corpusID: manifest.corpusID,
                    baselineRate: baselineRate,
                    candidateRate: candidateRate,
                    delta: delta,
                    noMoreThanTwoPointRegression: delta.map { $0 <= 0.02 } == true
                )
            }
            var l5Blockers: [String] = []
            if baseline.status != "execution-complete"
                || candidate.status != "execution-complete" {
                l5Blockers.append("one or both ASR executions are incomplete")
            }
            if !baseline.model.revisionEnforced || !candidate.model.revisionEnforced
                || !baseline.model.artifactSHA256Verified
                || !candidate.model.artifactSHA256Verified {
                l5Blockers.append("one or both model artifacts are not revision and SHA-pinned")
            }
            if !baseline.pcmInputCoverageComplete || !candidate.pcmInputCoverageComplete {
                l5Blockers.append("not all selected PCM reached the benchmark adapter")
            }
            if !baseline.corpusCoverage.allSatisfy(\.lastSelectedSpeechPresent)
                || !candidate.corpusCoverage.allSatisfy(\.lastSelectedSpeechPresent) {
                l5Blockers.append("the final annotated speech is not recognizably present")
            }
            let baselineMissingTerms = Set(baseline.criticalDiagnostics.missingTerms.map {
                "\($0.corpusID)|\($0.turnID)|\($0.category.rawValue)|\($0.japanese)"
            })
            let candidateMissingTerms = Set(candidate.criticalDiagnostics.missingTerms.map {
                "\($0.corpusID)|\($0.turnID)|\($0.category.rawValue)|\($0.japanese)"
            })
            let addsCriticalOmissions = !candidateMissingTerms
                .subtracting(baselineMissingTerms).isEmpty
            let corpusQualityIsSafe = corpusDeltas.allSatisfy(\.noMoreThanTwoPointRegression)
            let criticalCorrectionPasses = candidate.criticalDiagnostics.annotatedTermCount > 0
                && candidateMissingTerms.isStrictSubset(of: baselineMissingTerms)
                && !addsCriticalOmissions
                && corpusQualityIsSafe
            let qualityPasses = statisticalQualityPasses || criticalCorrectionPasses
            if addsCriticalOmissions {
                l5Blockers.append("the candidate adds critical-term omissions")
            }
            if !qualityPasses {
                l5Blockers.append(
                    "neither the paired CER 10% quality gate nor critical correction passes"
                )
            }
            if !corpusQualityIsSafe {
                l5Blockers.append("at least one corpus regresses by more than 2 CER points")
            }
            if candidate.primaryEmptySpeechTurnCount
                > baseline.primaryEmptySpeechTurnCount {
                l5Blockers.append("the candidate adds primary empty speech turns")
            }
            if candidate.engine == .whisperMLXBatch, textAgreement.map({ $0 >= 0.95 }) == true {
                l5Blockers.append("whispermlx duplicates at least 95% of normalized MLX outputs")
            }
            if candidate.engine.finalLatencyIsMeasuredByOfflineRun,
               candidate.asrP95Milliseconds.map({ $0 > 1_500 }) != false {
                l5Blockers.append("batch final p95 exceeds the 1.5 second budget")
            }
            if candidate.maximumObservedResidentBytes >= 10 * 1_024 * 1_024 * 1_024
                || Double(candidate.maximumObservedResidentBytes)
                    > Double(Self.baselineResidentBytes) * 1.20 {
                l5Blockers.append("observed memory exceeds the L0 gate")
            }
            var blockers = l5Blockers
            if manifests.contains(where: { $0.annotations.status != .complete }) {
                blockers.insert("corpus annotations are not complete", at: 0)
            }
            if candidate.criticalDiagnostics.annotatedTermCount == 0 {
                blockers.append("critical terms are not human-annotated")
            }
            blockers.append("English preview, final stability and backlog need exact product replay")
            blockers.append("all independent holdouts must be evaluated together")
            return JapaneseBakeoffComparison(
                baseline: baselineEngine,
                candidate: candidate.engine,
                pairedCERBootstrap: bootstrap,
                corpusCERDeltas: corpusDeltas,
                qualityPathPasses: qualityPasses,
                criticalCorrectionPathPasses: criticalCorrectionPasses,
                l5GatePasses: l5Blockers.isEmpty,
                l5BlockingReasons: l5Blockers,
                normalizedTextAgreement: textAgreement,
                previewPathStatus: "not-measured-by-offline-ASR-oracle",
                blockingReasons: blockers
            )
        }
    }

    private func promotionDecision(
        manifests: [JapaneseBenchmarkManifest]
    ) -> String {
        if manifests.contains(where: { $0.annotations.status != .complete }) {
            return "blocked: corpora require human validation"
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
        case .mlxWhisperTurbo:
            return JapaneseBakeoffModelProvenance(
                modelID: "mlx-community/whisper-large-v3-turbo",
                revision: Self.mlxWhisperModelRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "MIT",
                runtime: "mlx-whisper \(Self.mlxWhisperVersion)",
                runtimeRevision: Self.mlxWhisperWheelSHA256
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
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "OpenMDW-1.1",
                runtime: "FluidAudio \(Self.fluidAudioVersion)",
                runtimeRevision: Self.fluidAudioRevision
            )
        case .kotobaQ5:
            return JapaneseBakeoffModelProvenance(
                modelID: "kotoba-tech/kotoba-whisper-v2.0-ggml:q5_0",
                revision: Self.kotobaRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "Apache-2.0",
                runtime: "CWhisper.xcframework",
                runtimeRevision: "repository-binary"
            )
        case .qwen17:
            return JapaneseBakeoffModelProvenance(
                modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                revision: Self.qwenRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "Apache-2.0",
                runtime: "Qwen3ASR Swift/MLX",
                runtimeRevision: "pinned-by-benchmark-git-commit"
            )
        case .whisperMLXBatch:
            return JapaneseBakeoffModelProvenance(
                modelID: "mlx-community/whisper-large-v3-turbo",
                revision: Self.mlxWhisperModelRevision,
                revisionEnforced: true,
                artifactSHA256: nil,
                expectedArtifactSHA256: Self.expectedArtifactSHA256(for: engine),
                artifactSHA256Verified: false,
                license: "MIT + BSD-2-Clause wrapper",
                runtime: "whispermlx \(Self.whisperMLXVersion)",
                runtimeRevision: "\(Self.whisperMLXRevision):\(Self.whisperMLXWheelSHA256)"
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
        case .mlxWhisperTurbo, .whisperMLXBatch:
            artifact = mlxWhisperModelDirectory(root: root, environment: environment)
                .appendingPathComponent("weights.safetensors")
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
        case .kotobaQ5:
            artifact = kotobaModelURL(root: root, environment: environment)
        case .qwen17:
            artifact = qwenModelURL(environment: environment)
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

    private func mlxWhisperModelDirectory(
        root: URL,
        environment: [String: String]
    ) -> URL {
        if let path = environment["WHISPERASR_MLX_WHISPER_MODEL"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return root.appendingPathComponent(
            ".build/benchmarks/japanese-live/tools/models/"
                + "mlx-whisper-large-v3-turbo/\(Self.mlxWhisperModelRevision)",
            isDirectory: true
        )
    }

    private func kotobaModelURL(
        root: URL,
        environment: [String: String]
    ) -> URL {
        if let path = environment["WHISPERASR_KOTOBA_Q5_MODEL"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return root.appendingPathComponent(
            ".build/benchmarks/japanese-live/tools/models/"
                + "kotoba-whisper-v2.0-ggml/\(Self.kotobaRevision)/"
                + "ggml-kotoba-whisper-v2.0-q5_0.bin"
        )
    }

    private func qwenModelURL(environment: [String: String]) -> URL {
        if let path = environment["WHISPERASR_QWEN_MODEL_FILE"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/model.safetensors"
            )
    }

    private func sileroDirectory(
        root: URL,
        environment: [String: String]
    ) -> URL {
        if let path = environment["WHISPERASR_SILERO_DIRECTORY"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return root.appendingPathComponent(
            ".build/benchmarks/japanese-live/tools/silero-vad/\(Self.sileroRevision)",
            isDirectory: true
        )
    }

    private func externalPythonURL(
        engine: JapaneseBakeoffEngine,
        root: URL,
        environment: [String: String]
    ) -> URL {
        let key = engine == .mlxWhisperTurbo
            ? "WHISPERASR_MLX_WHISPER_PYTHON" : "WHISPERASR_WHISPERMLX_PYTHON"
        if let path = environment[key] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let relative = engine == .mlxWhisperTurbo
            ? ".build/benchmarks/japanese-live/tools/mlx-whisper/0.4.3/venv/bin/python"
            : ".build/benchmarks/japanese-live/tools/whispermlx/v3.12.2/venv/bin/python"
        return root.appendingPathComponent(relative)
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
        case .whisperTurbo, .mlxWhisperTurbo, .voxtralContinuous,
             .kotobaQ5, .qwen17, .whisperMLXBatch:
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
        case .mlxWhisperTurbo, .whisperMLXBatch:
            mlxWhisperWeightsSHA256
        case .voxtralContinuous:
            "178e8cd18ffe0e6788504cac1146bbc0c0eafb262acecd24aa63c0e863333d86"
        case .nemotron1120:
            "a398b4fb9d1818395934191c7301571f6a958b8ad2a82e670029da38bd3efae9"
        case .nemotron560:
            "ad9a4c88796e765d60e304d36ae2688b914835447203f44af92056212cfc340d"
        case .kotobaQ5:
            kotobaQ5SHA256
        case .qwen17:
            qwenWeightsSHA256
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
        corpusIDs: [String],
        scope: String,
        seed: String,
        reports: [JapaneseBakeoffEngineReport]
    ) -> (report: JapaneseBakeoffBlindReport, key: [String: String]) {
        let engines = JapaneseBakeoffEngine.allCases
        let reportsByEngine = Dictionary(uniqueKeysWithValues: reports.map { ($0.engine, $0) })
        var key: [String: String] = [:]
        let items = corpusIDs.enumerated().flatMap { corpusIndex, corpusID in
          Set(reports.flatMap { report in
              report.turns.filter { $0.corpusID == corpusID }.map(\.turnID)
          }).sorted().compactMap { turnID -> JapaneseBakeoffBlindItem? in
            let available = reports.compactMap { report in
                report.turns.first { $0.corpusID == corpusID && $0.turnID == turnID }
            }
            guard let reference = available.first else { return nil }
            let availableEngines = JapaneseBenchmarkSupport.blindOrder(
                engines.filter { engine in
                    reportsByEngine[engine]?.turns.contains(where: {
                        $0.corpusID == corpusID && $0.turnID == turnID
                    }) == true
                },
                seed: seed,
                itemID: corpusIndex * 1_000_000 + turnID,
                identity: { $0.rawValue }
            )
            let candidates = availableEngines.enumerated().compactMap {
                aliasIndex, engine -> JapaneseBakeoffBlindCandidate? in
                guard let turn = reportsByEngine[engine]?.turns.first(where: {
                    $0.corpusID == corpusID && $0.turnID == turnID
                }) else { return nil }
                let alias = String(UnicodeScalar(65 + aliasIndex)!)
                key["\(corpusID):\(turnID):\(alias)"] = engine.rawValue
                return JapaneseBakeoffBlindCandidate(
                    alias: alias,
                    japanese: turn.hypothesisJapanese
                )
            }
            return JapaneseBakeoffBlindItem(
                corpusID: corpusID,
                turnID: turnID,
                confidence: reference.confidence,
                referenceJapanese: reference.referenceJapanese,
                candidates: candidates
            )
          }
        }
        return (
            JapaneseBakeoffBlindReport(
                schemaVersion: 1,
                corpusIDs: corpusIDs,
                scope: scope,
                note: "Aliases are randomized independently for each turn; the key is stored separately.",
                items: items
            ),
            key
        )
    }

    private func writeBakeoffArtifacts(
        report: JapaneseBakeoffFullReport,
        blind: JapaneseBakeoffBlindReport,
        key: [String: String],
        runID: String,
        root: URL
    ) throws {
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let blindOutput = output.appendingPathComponent("blind-review", isDirectory: true)
        try FileManager.default.createDirectory(at: blindOutput, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifacts: [(URL, Data)] = [
            (output.appendingPathComponent("ja-asr.json"), try encoder.encode(report)),
            (output.appendingPathComponent("comparison.json"), try encoder.encode(report.comparisons)),
            (blindOutput.appendingPathComponent("blind.json"), try encoder.encode(blind)),
            (blindOutput.appendingPathComponent("key.json"), try encoder.encode(key)),
            (
                output.appendingPathComponent("report-fr.md"),
                Data(frenchReport(report).utf8)
            ),
        ]
        for (url, data) in artifacts {
            try data.write(to: url, options: .atomic)
            print("[JapaneseBakeoff] wrote \(url.path)")
        }
    }

    private func frenchReport(_ report: JapaneseBakeoffFullReport) -> String {
        let comparisons = Dictionary(
            uniqueKeysWithValues: report.comparisons.map { ($0.candidate, $0) }
        )
        var lines = [
            "# L5 — Bakeoff japonais",
            "",
            "Run `\(report.runID)`, commit `\(report.gitCommit)`, worktree "
                + (report.worktreeDirty ? "modifié" : "propre") + ".",
            "Réseau des moteurs Python : "
                + (report.externalNetworkAccessDenied
                    ? "interdit par sandbox macOS." : "autorisé."),
            "",
            "Les scores restent exploratoires tant que les annotations ne sont pas validées humainement.",
            "",
            "| Moteur | CER high | medium | overlap | p95 calcul ASR | RSS max | Vides high/diag | PCM vers ASR | Dernière parole | Verdict |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
        ]
        for engine in report.engines {
            let comparison = comparisons[engine.engine]
            let memory = String(format: "%.2f Gio", Double(engine.maximumObservedResidentBytes) / 1_073_741_824)
            let lastSpeech = engine.corpusCoverage.allSatisfy(\.lastSelectedSpeechPresent)
                ? "oui" : "non"
            let verdict: String
            if engine.engine == .whisperTurbo {
                verdict = "témoin retenu"
            } else if comparison?.l5GatePasses == true {
                verdict = "survit L5"
            } else if engine.engine == .whisperMLXBatch {
                verdict = "arrêté L5"
            } else {
                verdict = "écarté L5"
            }
            lines.append(
                "| \(engine.engine.rawValue) | \(percent(engine.primaryHighConfidenceCER.rate)) "
                    + "| \(percent(engine.diagnosticMediumConfidenceCER.rate)) "
                    + "| \(percent(engine.diagnosticOverlapCER.rate)) "
                    + "| \(milliseconds(engine.asrP95Milliseconds)) | \(memory) "
                    + "| \(engine.primaryEmptySpeechTurnCount)/"
                    + "\(engine.diagnosticEmptySpeechTurnCount) "
                    + "| \(pcmCoverage(engine)) | \(lastSpeech) | \(verdict) |"
            )
        }
        lines += [
            "",
            "Décisions mesurées :",
            "",
        ]
        lines += report.engines.compactMap { engine in
            guard let comparison = comparisons[engine.engine] else { return nil }
            let useful = comparison.l5BlockingReasons.filter {
                !$0.contains("critical terms are not human-annotated")
            }
            let reasons = useful.prefix(3).map(frenchBlockingReason).joined(separator: "; ")
            return "- `\(engine.engine.rawValue)` : "
                + (reasons.isEmpty ? "aucun échec L5 mesuré" : reasons) + "."
        }
        lines += [
            "",
            "Les termes critiques attendent la validation humaine. La preview et l’anglais appartiennent à L6.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private func percent(_ rate: Double?) -> String {
        rate.map { String(format: "%.2f %%", $0 * 100) } ?? "n/a"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "n/a"
    }

    private func pcmCoverage(_ engine: JapaneseBakeoffEngineReport) -> String {
        guard engine.expectedPCMSamples > 0 else { return "n/a" }
        return String(
            format: "%.1f %%",
            Double(engine.asrFedPCMSamples) / Double(engine.expectedPCMSamples) * 100
        )
    }

    private func frenchBlockingReason(_ reason: String) -> String {
        switch reason {
        case let value where value.contains("executions are incomplete"):
            "exécution incomplète"
        case let value where value.contains("revision and SHA-pinned"):
            "pin modèle invalide"
        case let value where value.contains("benchmark adapter"):
            "couverture PCM d’entrée incomplète"
        case let value where value.contains("final annotated speech"):
            "dernière parole absente"
        case let value where value.contains("critical-term omissions"):
            "nouvelles omissions critiques"
        case let value where value.contains("10% quality gate"):
            "gain CER inférieur au gate de 10 %"
        case let value where value.contains("corpus regresses"):
            "régression de plus de 2 points sur un corpus"
        case let value where value.contains("primary empty speech turns"):
            "tours high vides supplémentaires"
        case let value where value.contains("duplicates at least"):
            "sorties MLX pratiquement identiques"
        case let value where value.contains("batch final p95"):
            "p95 final batch supérieur à 1,5 s"
        case let value where value.contains("memory"):
            "mémoire au-dessus du gate"
        default:
            reason
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
