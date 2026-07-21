import CryptoKit
import Darwin
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
    var setupMilliseconds: Double? = nil
    var warmupMilliseconds: Double? = nil
    var startupMeasurementScope: String? = nil
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

    struct Window: Codable {
        struct AudioRange: Codable {
            let startSample: Int
            let endSample: Int
        }

        let sessionID: String
        let corpusID: String
        let windowID: String
        let replay: Int
        let seed: Int
        let startSample: Int
        let endSample: Int
        let realtime: Bool
        let ranges: [AudioRange]
    }

    let backend: String
    let modelPath: String
    let sileroPath: String?
    let corpora: [Corpus]
    var decoder: String? = nil
    var mode: String? = nil
    var emitEvents: Bool? = nil
    var waitForSessionAck: Bool? = nil
    var windows: [Window]? = nil
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


    struct Window: Codable {
        struct AudioRange: Codable {
            let startSample: Int
            let endSample: Int
            let hypothesisJapanese: String
            let asrMilliseconds: Double
            let fedSampleCount: Int
            let completedMilliseconds: Double
            let backlogMilliseconds: Double
        }

        struct Segment: Codable {
            let id: Int
            let start: Double
            let end: Double
            let text: String
        }

        let sessionID: String
        let corpusID: String
        let windowID: String
        let replay: Int
        let hypothesisJapanese: String
        let inputSampleCount: Int
        let fedSampleCount: Int
        let asrMilliseconds: Double
        let wallMilliseconds: Double
        let residentBytes: UInt64
        let ranges: [AudioRange]
        let segments: [Segment]
        let error: String?
    }

    let setupError: String?
    var setupMilliseconds: Double? = nil
    var warmupMilliseconds: Double? = nil
    let turns: [Turn]
    var windows: [Window]? = nil
}

private struct JapaneseExternalASREvent: Decodable, Sendable {
    let type: String
    let sessionID: String
    var rangeIndex: Int? = nil
    var startSample: Int? = nil
    var endSample: Int? = nil
    var hypothesisJapanese: String? = nil
    var completedMilliseconds: Double? = nil
    var backlogMilliseconds: Double? = nil
    var error: String? = nil
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

private struct JapaneseCorrectiveEndpoint: Codable, Sendable {
    let kind: String
    let startSample: Int
    let endSample: Int
    let speechEndSample: Int
    let detectedAtSample: Int
}

private struct JapaneseCorrectiveFragment: Codable, Sendable {
    let startSample: Int
    let endSample: Int
    let text: String
    let asrMilliseconds: Double
}

private struct JapaneseCorrectiveCriticalTerms: Codable, Sendable {
    let status: String
    let annotatedCount: Int
    let missing: [String]
}

private struct JapaneseCorrectiveSession: Codable, Sendable {
    let recipeID: String
    let effectiveDecoder: String
    let effectiveRecipeSHA256: String
    let corpusID: String
    let windowID: String
    let replay: Int
    let windowStartSample: Int
    let windowEndSample: Int
    let expectedSampleCount: Int
    let asrFedSampleCount: Int
    let pcmAnalyzedThrough: Int
    let asrFinalizedThrough: Int
    let englishValidatedThrough: Int
    let terminalSilenceStartSample: Int?
    let terminalSilenceEndSample: Int?
    let unaccountedSampleCount: Int
    let endpointDecisionsSHA256: String
    let endpoints: [JapaneseCorrectiveEndpoint]
    let fragments: [JapaneseCorrectiveFragment]
    let japaneseFinal: String
    let normalizedFinalSHA256: String
    let continuousCER: ContinuousJapaneseCER.Result?
    let lastSpeech: JapaneseBenchmarkSupport.LastSpeechEvidence?
    let criticalTerms: JapaneseCorrectiveCriticalTerms
    let asrMilliseconds: [Double]
    let finalLatencyMilliseconds: [Double]
    let finalLatencyScope: String
    let previewRole: String
    let previewLatencyScope: String
    let previewEvents: [BenchmarkPreviewTranslationEvent]
    let previewSourceFirstLatencyMilliseconds: [Double]
    let previewFirstLatencyMilliseconds: [Double]
    let previewRevisionCount: Int
    let confirmedPrefixRewriteCount: Int
    let finalTranslationEvents: [BenchmarkFinalTranslationEvent]
    let finalTranslationsAppendOnly: Bool
    let audioMilliseconds: Double
    let asrWallMilliseconds: Double
    let pipelineWallMilliseconds: Double
    let completionAfterAudioEndMilliseconds: Double
    let computeRTF: Double
    let endToEndWallRTF: Double
    let maximumBacklogMilliseconds: Double
    let endingBacklogMilliseconds: Double
    let maximumResidentBytes: UInt64?
    let averageCPUPercent: Double?
    let thermalStateBefore: String
    let thermalStateAfter: String
    let backlogApplicable: Bool
    let errors: [String]
}

private struct JapaneseCorrectiveCalibration: Codable, Sendable {
    let recipeID: String
    let corpusID: String
    let windowID: String
    let greedyCER: Double?
    let beam5CER: Double?
    let greedyP95Milliseconds: Double?
    let beam5P95Milliseconds: Double?
    let chosenDecoder: String
    let decision: String
}

private struct JapaneseCorrectiveStability: Codable, Sendable {
    let recipeID: String
    let windowID: String
    let replayCount: Int
    let distinctNormalizedFinalCount: Int
    let normalizedFinalsIdentical: Bool
    let highCERLowerMinimum: Double?
    let highCERLowerMaximum: Double?
    let highCERUpperMinimum: Double?
    let highCERUpperMaximum: Double?
    let lastSpeechPresentCount: Int
    let endingBacklogMaximumMilliseconds: Double
    let errorCount: Int
}

private struct JapaneseCorrectiveCorpus: Codable, Sendable {
    let corpusID: String
    let manifestSHA256: String
    let audioSHA256: String
    let annotationStatus: String
}

private struct JapaneseCorrectiveReport: Codable, Sendable {
    let schemaVersion: Int
    let runID: String
    let benchmarkScope: String
    let gitCommit: String
    let sourceTreeSHA256: String
    let runtimeSHA256: String
    let worktreeDirty: Bool
    let networkDenied: Bool
    let modelRecipesSHA256: String
    let generatedAt: String
    let sampleRate: Int
    let replayCount: Int
    let expectedRecipeIDs: [String]
    let matrixAttempted: Bool
    let matrixComplete: Bool
    let promotionEligible: Bool
    let corpora: [JapaneseCorrectiveCorpus]
    let models: [JapaneseBakeoffModelProvenance]
    let calibrations: [JapaneseCorrectiveCalibration]
    let sessions: [JapaneseCorrectiveSession]
    let stability: [JapaneseCorrectiveStability]
}

private struct JapaneseCorrectiveWindowInput {
    let window: JapaneseBenchmarkSupport.StressWindow
    let manifest: JapaneseBenchmarkSupport.Manifest
    let samples: [Float]
    let analyzedThrough: Int
    let decisions: [LocalEndpointDecision]
    let speechObservations: [JapaneseBenchmarkSupport.EndpointSpeechObservation]
}

private struct JapaneseCorrectiveEngineResult {
    let model: JapaneseBakeoffModelProvenance
    let calibration: JapaneseCorrectiveCalibration?
    let sessions: [JapaneseCorrectiveSession]
}

private struct JapaneseCorrectiveExternalExecution {
    let response: JapaneseExternalASRResponse?
    let error: String?
    let finalTranslations: [String: BenchmarkFinalTranslationSummary]
    let pipelineWallMilliseconds: [String: Double]
    let resources: [String: BenchmarkResourceSummary]
}

@available(macOS 26.4, *)
private actor JapaneseCorrectiveVoxtralCollector {
    private(set) var deltas: [(text: String, sentThrough: Int?)] = []
    private(set) var acknowledgedThrough: Int?
    private(set) var completed: (transcript: String, sentThrough: Int?)?
    private(set) var failures: [String] = []
    private var planner: VoxtralClausePlanner
    private let windowStartSample: Int
    private let sessionStart: UInt64
    private let preview: BenchmarkPreviewTranslator?
    private let final: BenchmarkFinalTranslator?
    private var transcript = ""
    private var fragments: [JapaneseCorrectiveFragment] = []
    private var lastPreview: (generation: Int, text: String)?
    private var confirmedPrefixRewrites = 0

    init(
        windowStartSample: Int,
        sessionStart: UInt64,
        stabilityGuardSamples: Int,
        preview: BenchmarkPreviewTranslator?,
        final: BenchmarkFinalTranslator?
    ) {
        self.windowStartSample = windowStartSample
        self.sessionStart = sessionStart
        self.preview = preview
        self.final = final
        planner = VoxtralClausePlanner(stabilityGuardSamples: stabilityGuardSamples)
    }

    func accept(_ event: VoxtralHelperEvent) async {
        var boundary: VoxtralClauseBoundary?
        switch event {
        case .delta(let text, let sentThrough):
            deltas.append((text, sentThrough))
            transcript += text
            boundary = planner.observe(
                delta: text,
                fedThrough: local(sentThrough ?? acknowledgedThrough ?? windowStartSample),
                sourceUpdateThrough: sentThrough.map(local)
            )
        case .acknowledged(let through):
            acknowledgedThrough = through
            boundary = planner.observe(fedThrough: local(through))
        case .completed(let transcript, let sentThrough):
            completed = (transcript, sentThrough)
            let finalDelta: String
            if transcript.hasPrefix(self.transcript) {
                finalDelta = String(transcript.dropFirst(self.transcript.count))
            } else if self.transcript.isEmpty {
                finalDelta = transcript
            } else {
                failures.append("Voxtral final source differed from its append-only stream.")
                return
            }
            self.transcript = transcript
            boundary = planner.finish(
                delta: finalDelta,
                fedThrough: local(sentThrough ?? acknowledgedThrough ?? windowStartSample)
            )
        case .failed(let message):
            failures.append(message)
        case .emissionMarker(let marker):
            let localMarker = VoxtralEmissionMarker(
                generatedIndex: marker.generatedIndex,
                decoderPosition: marker.decoderPosition,
                delayFrames: marker.delayFrames,
                proxyEndSample: local(marker.proxyEndSample),
                groupTextStartUTF8: marker.groupTextStartUTF8,
                isUsable: marker.isUsable
            )
            boundary = planner.observe(
                fedThrough: local(acknowledgedThrough ?? windowStartSample),
                emissionMarkers: [localMarker]
            )
        case .ready:
            return
        }
        if let boundary { await stage(boundary) }
        await publishPreview()
    }

    func observeSpeech(
        _ ranges: [SpeechSampleRange],
        observedThrough: Int
    ) async {
        if let boundary = planner.observe(
            fedThrough: max(planner.fedThrough, observedThrough),
            speech: ranges
        ) {
            await stage(boundary)
        }
        await publishPreview()
    }

    func snapshot() -> (
        deltas: [(text: String, sentThrough: Int?)],
        acknowledgedThrough: Int?,
        completed: (transcript: String, sentThrough: Int?)?,
        failures: [String],
        fragments: [JapaneseCorrectiveFragment],
        confirmedPrefixRewrites: Int
    ) {
        (
            deltas,
            acknowledgedThrough,
            completed,
            failures,
            fragments,
            confirmedPrefixRewrites
        )
    }

    private func local(_ absolute: Int) -> Int {
        max(0, absolute - windowStartSample)
    }

    private func stage(_ boundary: VoxtralClauseBoundary) async {
        let text = boundary.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fragments.append(JapaneseCorrectiveFragment(
            startSample: windowStartSample + boundary.sampleRange.lowerBound,
            endSample: windowStartSample + boundary.sampleRange.upperBound,
            text: text,
            asrMilliseconds: 0
        ))
        let endpoint = sessionStart
            + UInt64(max(0, boundary.endpointDetectedAt)) * 1_000_000_000 / 16_000
        await final?.submit(
            finalID: "voxtral:\(boundary.generation)",
            source: text,
            sourceStartSample: windowStartSample + boundary.sampleRange.lowerBound,
            sourceEndSample: windowStartSample + boundary.sampleRange.upperBound,
            endpointUptimeNanoseconds: endpoint
        )
    }

    private func publishPreview() async {
        guard let current = planner.preview else { return }
        let text = current.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              lastPreview?.generation != current.generation
                || lastPreview?.text != text else { return }
        if let previous = lastPreview,
           previous.generation == current.generation,
           !text.hasPrefix(previous.text) {
            confirmedPrefixRewrites += 1
        }
        lastPreview = (current.generation, text)
        let phraseStart = sessionStart
            + UInt64(max(0, current.sampleRange.lowerBound)) * 1_000_000_000 / 16_000
        await preview?.submit(
            source: text,
            phraseKey: UInt64(current.generation),
            phraseStartUptimeNanoseconds: phraseStart,
            sourceStartSample: windowStartSample + current.sampleRange.lowerBound,
            sourceEndSample: windowStartSample + current.sampleRange.upperBound
        )
    }
}

final class JapaneseModelBakeoffTests: XCTestCase {
    private static let modelRecipesSHA256 =
        "d4ed138de85c40fee4ae0340ceca39149fbc6e5331845377b4931dc5043f000a"
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
    private static let mlxWhisperConfigSHA256 =
        "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"
    private static let kotobaRevision =
        "e3a0cf6a62b95911703cfb97d819292e058f12c3"
    private static let kotobaQ5SHA256 =
        "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"
    private static let qwenRevision =
        "e5450a26d1fd417c45fc9c405651ddc3180a27a6"
    private static let qwenRuntimeRevision =
        "9c4bff5a8f0287a179b9a039da25ff9fa02553a3"
    private static let qwenWeightsSHA256 =
        "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
    private static let whisperMLXVersion = "3.12.2"
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
            let hash = try JapaneseBenchmarkSupport.artifactSHA256(at: directory)
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

    @MainActor
    func testCorrectiveStressReplaysWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fullReplay = environment["WHISPERASR_L7C_REPLAY"] == "1"
        let vadPreflight = environment["WHISPERASR_L7C_VAD_PREFLIGHT"] == "1"
        guard environment["WHISPERASR_L7B_REPLAY"] == "1" || fullReplay || vadPreflight else {
            throw XCTSkip("Run the L7B or L7C replay script.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("L7B/L7C requires the local Apple Translation runtime.")
        }
        guard let gitCommit = environment["WHISPERASR_BENCHMARK_COMMIT"],
              gitCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "WHISPERASR_BENCHMARK_COMMIT must be an exact Git commit."
            )
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recipeURL = root.appendingPathComponent("docs/japanese-live/model-recipes.json")
        let recipeSHA = try JapaneseBenchmarkSupport.sha256(at: recipeURL)
        guard recipeSHA == Self.modelRecipesSHA256 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "model-recipes.json changed after L7A; audit it before replaying."
            )
        }
        ModelHub.offlineMode = environment["WHISPERASR_OFFLINE"] == "1"
        defer { ModelHub.offlineMode = false }

        let benchmarkScope = fullReplay ? "full-video" : "corrective"
        let replayCount = fullReplay
            ? max(1, Int(environment["WHISPERASR_L7C_REPLAY_COUNT"] ?? "1") ?? 1)
            : max(1, Int(environment["WHISPERASR_L7B_REPLAY_COUNT"] ?? "3") ?? 3)
        let requestedEngines = try selectedEngines(
            environment: environment,
            scope: benchmarkScope
        )
        let runID = try benchmarkRunID(environment: environment)

        var manifests: [String: JapaneseBenchmarkSupport.Manifest] = [:]
        var allSamples: [String: [Float]] = [:]
        var corpora: [JapaneseCorrectiveCorpus] = []
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let manifestURL = root.appendingPathComponent(
                "docs/japanese-live/corpora/\(corpusID)/manifest.json"
            )
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            let wavURL = try JapaneseBenchmarkSupport.fixtureURL(
                for: manifest,
                workspaceRoot: root
            )
            let audioSHA = try JapaneseBenchmarkSupport.sha256(at: wavURL)
            guard audioSHA == manifest.fixture.sha256 else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Audio SHA mismatch for \(corpusID)."
                )
            }
            let samples = try await AudioLoader.loadSamples(url: wavURL)
            guard samples.count == manifest.fixture.sampleCount else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Audio sample count mismatch for \(corpusID)."
                )
            }
            manifests[corpusID] = manifest
            allSamples[corpusID] = samples
            corpora.append(JapaneseCorrectiveCorpus(
                corpusID: corpusID,
                manifestSHA256: try JapaneseBenchmarkSupport.sha256(at: manifestURL),
                audioSHA256: audioSHA,
                annotationStatus: manifest.annotations.status.rawValue
            ))
        }

        let selectedWindows: [JapaneseBenchmarkSupport.StressWindow]
        if fullReplay {
            selectedWindows = ["qudu2fx3ncc", "md62mmdz0m"].compactMap {
                manifests[$0].map(JapaneseBenchmarkSupport.fullWindow(for:))
            }
        } else {
            let windowLimit = min(
                JapaneseBenchmarkSupport.correctiveStressWindows.count,
                max(1, Int(environment["WHISPERASR_L7B_WINDOW_LIMIT"] ?? "4") ?? 4)
            )
            selectedWindows = Array(
                JapaneseBenchmarkSupport.correctiveStressWindows.prefix(windowLimit)
            )
        }

        let modelManager = LocalEnglishModelManager()
        try await modelManager.prepare(.whisperTurboApple)
        var windows: [JapaneseCorrectiveWindowInput] = []
        for window in selectedWindows {
            guard let manifest = manifests[window.corpusID],
                  let corpusSamples = allSamples[window.corpusID] else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Missing corpus for stress window \(window.id)."
                )
            }
            let samples = Array(corpusSamples[window.startSample..<window.endSample])
            let trace = try await JapaneseBenchmarkSupport.productEndpointTrace(
                samples: samples,
                manager: modelManager
            )
            guard !trace.decisions.isEmpty,
                  fullReplay || trace.decisions.last?.audioEnd == samples.count else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "FireRedVAD did not finalize the full window \(window.id)."
                )
            }
            windows.append(JapaneseCorrectiveWindowInput(
                window: window,
                manifest: manifest,
                samples: samples,
                analyzedThrough: samples.count,
                decisions: trace.decisions,
                speechObservations: trace.speechObservations
            ))
        }
        let calibrationManifestURL = root.appendingPathComponent(
            "docs/japanese-live/corpora/easy-japanese-1/manifest.json"
        )
        let calibrationManifest = try JapaneseBenchmarkSupport.loadManifest(
            at: calibrationManifestURL
        )
        let calibrationWAV = try JapaneseBenchmarkSupport.fixtureURL(
            for: calibrationManifest,
            workspaceRoot: root
        )
        guard try JapaneseBenchmarkSupport.sha256(at: calibrationWAV)
                == calibrationManifest.fixture.sha256 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "The decoder calibration WAV failed SHA-256 verification."
            )
        }
        let calibrationCorpusSamples = try await AudioLoader.loadSamples(url: calibrationWAV)
        let calibrationWindow = JapaneseBenchmarkSupport.StressWindow(
            id: "easy-japanese-decoder-calibration",
            corpusID: calibrationManifest.corpusID,
            startSample: 0,
            endSample: min(1_200_000, calibrationCorpusSamples.count)
        )
        let calibrationSamples = Array(
            calibrationCorpusSamples[calibrationWindow.startSample..<calibrationWindow.endSample]
        )
        let calibrationDecisions = try await JapaneseBenchmarkSupport.productEndpointDecisions(
            samples: calibrationSamples,
            manager: modelManager
        )
        guard !calibrationDecisions.isEmpty,
              calibrationDecisions.last?.audioEnd == calibrationSamples.count else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "FireRedVAD did not finalize the decoder calibration window."
            )
        }
        let calibrationWindows = [JapaneseCorrectiveWindowInput(
            window: calibrationWindow,
            manifest: calibrationManifest,
            samples: calibrationSamples,
            analyzedThrough: calibrationSamples.count,
            decisions: calibrationDecisions,
            speechObservations: []
        )]
        await modelManager.unload()

        var finalService: AppleTranslationService?
        var finalServiceError: String?
        var previewService: AppleTranslationService?
        var previewServiceError: String?
        if fullReplay {
            let finalCandidate = AppleTranslationService()
            do {
                try await finalCandidate.configure(sourceLocale: "ja", mode: .highFidelityOnly)
                try await finalCandidate.warmup(highFidelity: true)
                finalService = finalCandidate
            } catch {
                finalServiceError = error.localizedDescription
            }
            let previewCandidate = AppleTranslationService()
            do {
                try await previewCandidate.configure(sourceLocale: "ja", mode: .lowLatencyOnly)
                try await previewCandidate.warmup(highFidelity: false)
                previewService = previewCandidate
            } catch {
                previewServiceError = error.localizedDescription
            }
        }

        let whisper = TranscriptionService()
        var sessions: [JapaneseCorrectiveSession] = []
        var calibrations: [JapaneseCorrectiveCalibration] = []
        var models: [JapaneseBakeoffModelProvenance] = []
        for engine in requestedEngines {
            print("[L7B] preparing \(engine.rawValue)")
            let result = await runCorrectiveEngine(
                engine,
                windows: windows,
                calibrationWindows: calibrationWindows,
                replayCount: replayCount,
                modelManager: modelManager,
                whisper: whisper,
                root: root,
                environment: environment,
                runID: runID,
                benchmarkScope: benchmarkScope,
                previewService: previewService,
                previewServiceError: previewServiceError,
                finalService: finalService,
                finalServiceError: finalServiceError
            )
            sessions += result.sessions
            if let calibration = result.calibration { calibrations.append(calibration) }
            models.append(result.model)
            let report = correctiveReport(
                runID: runID,
                benchmarkScope: benchmarkScope,
                gitCommit: gitCommit,
                sourceTreeSHA256: environment["WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256"]
                    ?? "unknown",
                runtimeSHA256: environment["WHISPERASR_BENCHMARK_RUNTIME_SHA256"]
                    ?? "unknown",
                worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
                networkDenied: environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
                recipeSHA: recipeSHA,
                replayCount: replayCount,
                expectedEngines: requestedEngines,
                expectedWindowIDs: selectedWindows.map(\.id),
                expectedRecipeIDs: requestedEngines.map {
                    correctiveRecipeID(engine: $0, environment: environment)
                },
                corpora: corpora,
                models: models,
                calibrations: calibrations,
                sessions: sessions
            )
            try writeCorrectiveReport(report, runID: runID, root: root)
            print("[L7B] \(engine.rawValue) sessions=\(result.sessions.count)")
        }
        await modelManager.shutdown()
        await whisper.unloadModel()
        await previewService?.cancel()
        await finalService?.cancel()

        let expected = requestedEngines.count * selectedWindows.count * replayCount
        XCTAssertEqual(sessions.count, expected)
        XCTAssertTrue(sessions.allSatisfy { $0.expectedSampleCount > 0 })
        let finalReport = correctiveReport(
            runID: runID,
            benchmarkScope: benchmarkScope,
            gitCommit: gitCommit,
            sourceTreeSHA256: environment["WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256"]
                ?? "unknown",
            runtimeSHA256: environment["WHISPERASR_BENCHMARK_RUNTIME_SHA256"]
                ?? "unknown",
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            networkDenied: environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
            recipeSHA: recipeSHA,
            replayCount: replayCount,
            expectedEngines: requestedEngines,
            expectedWindowIDs: selectedWindows.map(\.id),
            expectedRecipeIDs: requestedEngines.map {
                correctiveRecipeID(engine: $0, environment: environment)
            },
            corpora: corpora,
            models: models,
            calibrations: calibrations,
            sessions: sessions
        )
        XCTAssertTrue(finalReport.matrixAttempted, "The replay matrix was not fully attempted.")
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

    private func correctiveRecipeID(
        engine: JapaneseBakeoffEngine,
        environment: [String: String]
    ) -> String {
        guard engine == .whisperMLXBatch else { return engine.rawValue }
        if environment["WHISPERASR_WHISPERMLX_MODE"] == "vad-finals" {
            return "\(engine.rawValue)-vad-finals"
        }
        if environment["WHISPERASR_L7C_REPLAY"] == "1" {
            return "\(engine.rawValue)-long-form"
        }
        return engine.rawValue
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
            let prepared = try await prepareNativeEngine(
                engine,
                modelManager: modelManager,
                whisper: whisper,
                root: root,
                environment: environment
            )
            provenance = prepared.model
            nemotron = prepared.nemotron
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

    @MainActor
    private func prepareNativeEngine(
        _ engine: JapaneseBakeoffEngine,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        root: URL,
        environment: [String: String]
    ) async throws -> (
        model: JapaneseBakeoffModelProvenance,
        nemotron: StreamingNemotronMultilingualAsrManager?
    ) {
        await modelManager.unload()
        await whisper.unloadModel()
        let provenance = try modelProvenance(engine, root: root, environment: environment)
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
        var nemotron: StreamingNemotronMultilingualAsrManager?
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
        return (provenance, nemotron)
    }

    @available(macOS 26.4, *)
    @MainActor
    private func runCorrectiveEngine(
        _ engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        calibrationWindows: [JapaneseCorrectiveWindowInput],
        replayCount: Int,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        root: URL,
        environment: [String: String],
        runID: String,
        benchmarkScope: String,
        previewService: AppleTranslationService?,
        previewServiceError: String?,
        finalService: AppleTranslationService?,
        finalServiceError: String?
    ) async -> JapaneseCorrectiveEngineResult {
        if engine == .mlxWhisperTurbo || engine == .whisperMLXBatch {
            return await runCorrectiveExternalEngine(
                engine,
                windows: windows,
                calibrationWindows: calibrationWindows,
                replayCount: replayCount,
                root: root,
                environment: environment,
                runID: runID,
                benchmarkScope: benchmarkScope,
                finalService: finalService,
                finalServiceError: finalServiceError
            )
        }

        var provenance = unresolvedProvenance(engine)
        var nemotron: StreamingNemotronMultilingualAsrManager?
        let setupStarted = DispatchTime.now().uptimeNanoseconds
        do {
            let prepared = try await prepareNativeEngine(
                engine,
                modelManager: modelManager,
                whisper: whisper,
                root: root,
                environment: environment
            )
            provenance = prepared.model
            provenance.setupMilliseconds = elapsedMilliseconds(since: setupStarted)
            provenance.startupMeasurementScope = "model-load-or-runtime-prepare"
            nemotron = prepared.nemotron
        } catch {
            return JapaneseCorrectiveEngineResult(
                model: provenance,
                calibration: nil,
                sessions: correctiveFailureSessions(
                    engine: engine,
                    windows: windows,
                    replayCount: replayCount,
                    message: error.localizedDescription,
                    recipeID: correctiveRecipeID(engine: engine, environment: environment)
                )
            )
        }

        var decoding = WhisperDecodingStrategy.greedy
        var calibration: JapaneseCorrectiveCalibration?
        if engine == .whisperTurbo || engine == .kotobaQ5 {
            let result = await calibrateNativeWhisperDecoder(
                engine,
                windows: calibrationWindows,
                modelManager: modelManager,
                whisper: whisper,
                root: root,
                environment: environment
            )
            calibration = result.report
            decoding = result.chosen
        }

        var sessions: [JapaneseCorrectiveSession] = []
        for replay in 1...replayCount {
            for window in windows {
                do {
                    sessions.append(try await runCorrectiveNativeSession(
                        engine,
                        input: window,
                        replay: replay,
                        decoding: decoding,
                        modelManager: modelManager,
                        whisper: whisper,
                        nemotron: nemotron,
                        root: root,
                        environment: environment,
                        recipeID: correctiveRecipeID(engine: engine, environment: environment),
                        benchmarkScope: benchmarkScope,
                        previewService: previewService,
                        previewServiceError: previewServiceError,
                        finalService: finalService,
                        finalServiceError: finalServiceError
                    ))
                } catch {
                    if engine == .voxtralContinuous {
                        await modelManager.cancelContinuousVoxtral()
                    }
                    if let nemotron { await nemotron.reset() }
                    sessions.append(correctiveSession(
                        engine: engine,
                        recipeID: correctiveRecipeID(engine: engine, environment: environment),
                        input: window,
                        replay: replay,
                        asrFedSampleCount: 0,
                        finalizedThrough: 0,
                        fragments: [],
                        asrMilliseconds: [],
                        wallMilliseconds: 0,
                        maximumBacklogMilliseconds: 0,
                        endingBacklogMilliseconds: 0,
                        maximumResidentBytes: nil,
                        errors: [error.localizedDescription]
                    ))
                }
            }
        }
        if let nemotron { await nemotron.cleanup() }
        await whisper.unloadModel()
        await modelManager.unload()
        return JapaneseCorrectiveEngineResult(
            model: provenance,
            calibration: calibration,
            sessions: sessions
        )
    }

    @available(macOS 26.4, *)
    @MainActor
    private func runCorrectiveNativeSession(
        _ engine: JapaneseBakeoffEngine,
        input: JapaneseCorrectiveWindowInput,
        replay: Int,
        decoding: WhisperDecodingStrategy,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        nemotron: StreamingNemotronMultilingualAsrManager?,
        root: URL,
        environment: [String: String],
        recipeID: String,
        benchmarkScope: String,
        previewService: AppleTranslationService?,
        previewServiceError: String?,
        finalService: AppleTranslationService?,
        finalServiceError: String?
    ) async throws -> JapaneseCorrectiveSession {
        var started = DispatchTime.now().uptimeNanoseconds
        var fragments: [JapaneseCorrectiveFragment] = []
        var timings: [Double] = []
        var finalLatencies: [Double] = []
        var finalLatencyScope = "product-vad-final-after-speech-end"
        var fedSamples = 0
        var finalizedThrough = 0
        var maximumBacklog = 0.0
        var endingBacklog = 0.0
        var maximumResident = modelManager.currentMemoryBytes()
        var sessionErrors: [String] = []
        var confirmedPrefixRewrites = 0
        var watchdog = BenchmarkBacklogWatchdog()
        let supportsOwnPreview = engine == .voxtralContinuous
            || engine == .nemotron1120
            || engine == .nemotron560
        let previewTranslator = benchmarkScope == "full-video"
            && supportsOwnPreview
            && previewService != nil
            ? BenchmarkPreviewTranslator(service: previewService!, highFidelity: false)
            : nil
        let finalTranslator = benchmarkScope == "full-video"
            ? BenchmarkFinalTranslator(
                service: finalService,
                unavailableReason: finalServiceError
            ) : nil
        let voxtralEvents: AsyncStream<VoxtralHelperEvent>?
        let sampledPIDs: [Int32]
        if engine == .voxtralContinuous {
            voxtralEvents = try await modelManager.startContinuousVoxtral()
            let progress = await modelManager.continuousVoxtralProgress()
            guard let helperPID = progress.helperProcessIdentifier else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Voxtral helper PID is unavailable for resource measurement."
                )
            }
            sampledPIDs = [getpid(), helperPID]
            started = DispatchTime.now().uptimeNanoseconds
        } else {
            voxtralEvents = nil
            sampledPIDs = [getpid()]
        }
        let resourceSampler = startBenchmarkResourceSampler { sampledPIDs }
        defer { resourceSampler.cancel() }

        switch engine {
        case .whisperTurbo, .kotobaQ5, .qwen17:
            for (decisionIndex, decision) in input.decisions.enumerated() {
                try await sleepCorrectiveReplay(
                    started: started,
                    through: decision.audioEnd
                )
                let decodeStarted = DispatchTime.now().uptimeNanoseconds
                let result = try await transcribe(
                    engine,
                    audio: Array(input.samples[decision.audioStart..<decision.audioEnd]),
                    absoluteStartSample: input.window.startSample + decision.audioStart,
                    modelManager: modelManager,
                    whisper: whisper,
                    nemotron: nemotron,
                    root: root,
                    environment: environment,
                    decoding: decoding
                )
                let decodeMilliseconds = elapsedMilliseconds(since: decodeStarted)
                timings.append(decodeMilliseconds)
                fedSamples += result.asrFedSampleCount
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let acceptedStart = max(finalizedThrough, decision.audioStart)
                if let previous = fragments.last,
                   input.window.startSample + acceptedStart < previous.endSample {
                    text = AppState.trimOverlap(previous: previous.text, current: text)
                }
                if !text.isEmpty {
                    let fragment = JapaneseCorrectiveFragment(
                        startSample: input.window.startSample + acceptedStart,
                        endSample: input.window.startSample + decision.speechEnd,
                        text: text,
                        asrMilliseconds: decodeMilliseconds
                    )
                    fragments.append(fragment)
                    let endpoint = started
                        + UInt64(max(0, decision.speechEnd)) * 1_000_000_000 / 16_000
                    await finalTranslator?.submit(
                        finalID: "\(recipeID):\(decisionIndex)",
                        source: text,
                        sourceStartSample: fragment.startSample,
                        sourceEndSample: input.window.startSample + decision.stableThrough,
                        endpointUptimeNanoseconds: endpoint
                    )
                } else {
                    sessionErrors.append(
                        "\(engine.rawValue) returned an empty product VAD final at decision \(decisionIndex)."
                    )
                }
                finalizedThrough = max(finalizedThrough, decision.stableThrough)
                let completion = elapsedMilliseconds(since: started)
                finalLatencies.append(max(
                    0,
                    completion - Double(decision.speechEnd) / 16
                ))
                let currentBacklog = max(
                    0,
                    completion - Double(decision.audioEnd) / 16
                )
                maximumBacklog = max(maximumBacklog, currentBacklog)
                if watchdog.observe(milliseconds: currentBacklog) {
                    sessionErrors.append("Backlog exceeded 30 seconds continuously for one minute.")
                    break
                }
                maximumResident = max(maximumResident, modelManager.currentMemoryBytes())
            }

        case .nemotron1120, .nemotron560:
            guard let nemotron else {
                throw JapaneseBenchmarkCSV.ParseError.malformed("Nemotron was not prepared.")
            }
            await nemotron.reset()
            started = DispatchTime.now().uptimeNanoseconds
            var cursor = input.decisions.first?.audioStart ?? 0
            var utteranceStart = cursor
            var lastPartial = ""
            var previewGeneration: UInt64 = 0
            for (decisionIndex, decision) in input.decisions.enumerated() {
                if decision.audioStart > cursor {
                    cursor = decision.audioStart
                    utteranceStart = cursor
                }
                while cursor < decision.audioEnd {
                    let end = min(decision.audioEnd, cursor + 2_560)
                    try await sleepCorrectiveReplay(started: started, through: end)
                    let callStarted = DispatchTime.now().uptimeNanoseconds
                    _ = try await nemotron.process(samples: Array(input.samples[cursor..<end]))
                    timings.append(elapsedMilliseconds(since: callStarted))
                    fedSamples += end - cursor
                    cursor = end
                    let partial = await nemotron.getPartialTranscript()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty, partial != lastPartial {
                        if !lastPartial.isEmpty, !partial.hasPrefix(lastPartial) {
                            confirmedPrefixRewrites += 1
                        }
                        lastPartial = partial
                        await previewTranslator?.submit(
                            source: partial,
                            phraseKey: previewGeneration,
                            phraseStartUptimeNanoseconds: started
                                + UInt64(max(0, utteranceStart)) * 1_000_000_000 / 16_000,
                            sourceStartSample: input.window.startSample + utteranceStart,
                            sourceEndSample: input.window.startSample + cursor
                        )
                    }
                    maximumResident = max(maximumResident, modelManager.currentMemoryBytes())
                    let currentBacklog = max(
                        0,
                        elapsedMilliseconds(since: started) - Double(cursor) / 16
                    )
                    maximumBacklog = max(maximumBacklog, currentBacklog)
                    if watchdog.observe(milliseconds: currentBacklog) {
                        sessionErrors.append(
                            "Backlog exceeded 30 seconds continuously for one minute."
                        )
                        break
                    }
                }
                if sessionErrors.last?.contains("Backlog exceeded") == true { break }
                // A forced planner cut is not a safe speech end. Keep the
                // streaming state and finish/reset only at a VAD endpoint.
                guard decision.kind != .forced else { continue }
                let finalStarted = DispatchTime.now().uptimeNanoseconds
                let text = try await nemotron.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let finalMilliseconds = elapsedMilliseconds(since: finalStarted)
                timings.append(finalMilliseconds)
                finalLatencies.append(max(
                    0,
                    elapsedMilliseconds(since: started) - Double(decision.speechEnd) / 16
                ))
                if !text.isEmpty {
                    let fragment = JapaneseCorrectiveFragment(
                        startSample: input.window.startSample + utteranceStart,
                        endSample: input.window.startSample + decision.speechEnd,
                        text: text,
                        asrMilliseconds: finalMilliseconds
                    )
                    fragments.append(fragment)
                    let endpoint = started
                        + UInt64(max(0, decision.speechEnd)) * 1_000_000_000 / 16_000
                    await finalTranslator?.submit(
                        finalID: "\(recipeID):\(decisionIndex)",
                        source: text,
                        sourceStartSample: fragment.startSample,
                        sourceEndSample: input.window.startSample + decision.stableThrough,
                        endpointUptimeNanoseconds: endpoint
                    )
                } else {
                    sessionErrors.append(
                        "\(engine.rawValue) returned an empty safe VAD final at decision \(decisionIndex)."
                    )
                }
                finalizedThrough = max(finalizedThrough, decision.stableThrough)
                utteranceStart = cursor
                lastPartial = ""
                previewGeneration += 1
                await nemotron.reset()
            }

        case .voxtralContinuous:
            guard let events = voxtralEvents else {
                preconditionFailure("Voxtral events must be prepared before sampling.")
            }
            let collector = JapaneseCorrectiveVoxtralCollector(
                windowStartSample: input.window.startSample,
                sessionStart: started,
                stabilityGuardSamples: modelManager.continuousVoxtralConfiguration
                    .stabilityGuardSamples,
                preview: previewTranslator,
                final: finalTranslator
            )
            let receiver = Task {
                for await event in events { await collector.accept(event) }
            }
            do {
                let blockSamples = 2_560
                var observationIndex = 0
                for start in stride(from: 0, to: input.samples.count, by: blockSamples) {
                    let end = min(input.samples.count, start + blockSamples)
                    try await sleepCorrectiveReplay(started: started, through: end)
                    let feedStarted = DispatchTime.now().uptimeNanoseconds
                    try await modelManager.feedContinuousVoxtral(
                        samples: Array(input.samples[start..<end]),
                        range: (input.window.startSample + start)..<(input.window.startSample + end)
                    )
                    timings.append(elapsedMilliseconds(since: feedStarted))
                    fedSamples = end
                    let progress = await modelManager.continuousVoxtralProgress()
                    while observationIndex < input.speechObservations.count,
                          input.speechObservations[observationIndex].observedThrough <= end {
                        let observation = input.speechObservations[observationIndex]
                        await collector.observeSpeech(
                            observation.ranges,
                            observedThrough: max(
                                0,
                                (progress.acknowledgedThrough
                                    ?? input.window.startSample) - input.window.startSample
                            )
                        )
                        observationIndex += 1
                    }
                    maximumResident = max(
                        maximumResident,
                        modelManager.currentMemoryBytes() + (progress.helperRSSBytes ?? 0)
                    )
                    let currentBacklog = max(
                        max(0, elapsedMilliseconds(since: started) - Double(end) / 16),
                        Double(progress.backlogSamples) / 16
                    )
                    maximumBacklog = max(
                        maximumBacklog,
                        max(
                            currentBacklog,
                            Double(progress.maximumBacklogSamples) / 16
                        )
                    )
                    if watchdog.observe(milliseconds: currentBacklog) {
                        throw JapaneseBenchmarkCSV.ParseError.malformed(
                            "Backlog exceeded 30 seconds continuously for one minute."
                        )
                    }
                }
                let finalStarted = DispatchTime.now().uptimeNanoseconds
                let final = try await modelManager.finishContinuousVoxtral()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                timings.append(elapsedMilliseconds(since: finalStarted))
                _ = await receiver.result
                let snapshot = await collector.snapshot()
                guard snapshot.failures.isEmpty else {
                    throw JapaneseBenchmarkCSV.ParseError.malformed(
                        snapshot.failures.joined(separator: "; ")
                    )
                }
                let progress = await modelManager.continuousVoxtralProgress()
                guard progress.sentThrough == input.window.endSample,
                      progress.acknowledgedThrough == input.window.endSample,
                      progress.backlogSamples == 0,
                      snapshot.acknowledgedThrough == input.window.endSample,
                      snapshot.completed?.sentThrough == input.window.endSample,
                      JapaneseCER.normalized(snapshot.completed?.transcript ?? "")
                        == JapaneseCER.normalized(final) else {
                    throw JapaneseBenchmarkCSV.ParseError.malformed(
                        "Voxtral did not prove full acknowledged PCM coverage and a zero final backlog."
                    )
                }
                fragments = snapshot.fragments.isEmpty
                    ? correctiveVoxtralFragments(
                        deltas: snapshot.deltas,
                        final: final,
                        input: input,
                        asrMilliseconds: timings.reduce(0, +)
                    ) : snapshot.fragments
                if snapshot.fragments.isEmpty {
                    for (index, fragment) in fragments.enumerated() {
                        await finalTranslator?.submit(
                            finalID: "\(recipeID):fallback:\(index)",
                            source: fragment.text,
                            sourceStartSample: fragment.startSample,
                            sourceEndSample: input.window.endSample,
                            endpointUptimeNanoseconds: started
                                + UInt64(input.samples.count) * 1_000_000_000 / 16_000
                        )
                    }
                }
                if JapaneseCER.normalized(fragments.map(\.text).joined())
                    != JapaneseCER.normalized(final) {
                    sessionErrors.append(
                        "Voxtral clause text did not reconstruct its append-only final."
                    )
                }
                confirmedPrefixRewrites = snapshot.confirmedPrefixRewrites
                finalizedThrough = input.samples.count
                finalLatencyScope = "capture-eos-final-after-last-speech"
                finalLatencies = [max(
                    0,
                    elapsedMilliseconds(since: started)
                        - Double(input.decisions.last?.speechEnd ?? input.samples.count) / 16
                )]
                maximumBacklog = max(
                    maximumBacklog,
                    Double(progress.maximumBacklogSamples) / 16
                )
                endingBacklog = Double(progress.backlogSamples) / 16
                maximumResident = max(
                    maximumResident,
                    modelManager.currentMemoryBytes() + (progress.helperRSSBytes ?? 0)
                )
            } catch {
                await modelManager.cancelContinuousVoxtral()
                receiver.cancel()
                _ = await receiver.result
                throw error
            }

        case .mlxWhisperTurbo, .whisperMLXBatch:
            preconditionFailure("External candidates use the Python adapter.")
        }

        if benchmarkScope == "full-video" {
            try await sleepCorrectiveReplay(
                started: started,
                through: input.analyzedThrough
            )
        }
        let asrWallMilliseconds = elapsedMilliseconds(since: started)
        let previewSummary = await previewTranslator?.finish() ?? .empty
        let finalSummary = await finalTranslator?.finish() ?? .empty
        let wallMilliseconds = elapsedMilliseconds(since: started)
        if benchmarkScope == "full-video", supportsOwnPreview, previewTranslator == nil {
            sessionErrors.append(
                "Apple lowLatency preview unavailable: \(previewServiceError ?? "unknown error")"
            )
        }
        sessionErrors += previewSummary.events.compactMap(\.error).map {
            "Apple lowLatency preview: \($0)"
        }
        sessionErrors += finalSummary.events.compactMap(\.error).map {
            "Apple highFidelity final: \($0)"
        }
        if benchmarkScope == "full-video" {
            finalLatencies = finalSummary.events.map(\.endpointToAcceptedMilliseconds)
            finalLatencyScope = engine == .voxtralContinuous
                ? "voxtral-clause-detected-to-accepted-apple-high-fidelity"
                : "speech-end-to-accepted-apple-high-fidelity"
        }
        resourceSampler.cancel()
        let resources = await resourceSampler.value
        maximumResident = max(
            maximumResident,
            resources.maximumResidentBytes ?? 0
        )
        return correctiveSession(
            engine: engine,
            recipeID: recipeID,
            input: input,
            replay: replay,
            asrFedSampleCount: fedSamples,
            finalizedThrough: finalizedThrough,
            fragments: fragments,
            asrMilliseconds: timings,
            wallMilliseconds: wallMilliseconds,
            asrWallMilliseconds: asrWallMilliseconds,
            maximumBacklogMilliseconds: max(0, maximumBacklog),
            endingBacklogMilliseconds: endingBacklog,
            maximumResidentBytes: maximumResident,
            errors: sessionErrors,
            finalLatencyMilliseconds: finalLatencies,
            finalLatencyScope: finalLatencyScope,
            previewRole: supportsOwnPreview ? "candidate-native" : "apple-speech-common",
            previewLatencyScope: supportsOwnPreview
                ? "source-phrase-start-to-accepted-apple-low-latency"
                : "shared-apple-speech-control",
            previewSummary: previewSummary,
            confirmedPrefixRewriteCount: confirmedPrefixRewrites,
            finalSummary: finalSummary,
            resourceSummary: resources,
            backlogApplicable: true,
            effectiveDecoder: (engine == .whisperTurbo || engine == .kotobaQ5)
                ? decoding.rawValue : "native-fixed"
        )
    }

    @MainActor
    private func calibrateNativeWhisperDecoder(
        _ engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        root: URL,
        environment: [String: String]
    ) async -> (report: JapaneseCorrectiveCalibration, chosen: WhisperDecodingStrategy) {
        func measure(
            _ strategy: WhisperDecodingStrategy
        ) async -> (cer: Double?, p95: Double?) {
            var pairs: [(reference: String, hypothesis: String)] = []
            var latencies: [Double] = []
            do {
                for input in windows {
                    var hypothesis = ""
                    var previousEnd = 0
                    for decision in input.decisions {
                        let started = DispatchTime.now().uptimeNanoseconds
                        let result = try await transcribe(
                            engine,
                            audio: Array(input.samples[decision.audioStart..<decision.audioEnd]),
                            absoluteStartSample: input.window.startSample + decision.audioStart,
                            modelManager: modelManager,
                            whisper: whisper,
                            nemotron: nil,
                            root: root,
                            environment: environment,
                            decoding: strategy
                        )
                        latencies.append(elapsedMilliseconds(since: started))
                        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if decision.audioStart < previousEnd {
                            text = AppState.trimOverlap(previous: hypothesis, current: text)
                        }
                        hypothesis += text
                        previousEnd = decision.speechEnd
                    }
                    let turns = JapaneseBenchmarkSupport.referenceTurns(
                        manifest: input.manifest,
                        window: input.window
                    )
                    pairs.append((turns.map(\.japanese).joined(), hypothesis))
                }
            } catch {
                return (nil, nil)
            }
            return (
                JapaneseCER.score(pairs).rate,
                percentile(latencies, fraction: 0.95)
            )
        }

        let greedy = await measure(.greedy)
        let beam = await measure(.beam5)
        let beamWins = greedy.cer.map { greedyCER in
            beam.cer.map { greedyCER - $0 >= 0.01 } ?? false
        } ?? false
            && (beam.p95.map { $0 <= 1_500 } ?? false)
        let chosen: WhisperDecodingStrategy = beamWins ? .beam5 : .greedy
        return (
            JapaneseCorrectiveCalibration(
                recipeID: engine.rawValue,
                corpusID: windows.first?.window.corpusID ?? "unknown",
                windowID: windows.first?.window.id ?? "unknown",
                greedyCER: greedy.cer,
                beam5CER: beam.cer,
                greedyP95Milliseconds: greedy.p95,
                beam5P95Milliseconds: beam.p95,
                chosenDecoder: chosen.rawValue,
                decision: beamWins
                    ? "beam5: CER improves by at least 1 point and p95 remains <=1.5s"
                    : "greedy: beam5 did not clear both quality and latency gates"
            ),
            chosen
        )
    }

    private func correctiveVoxtralFragments(
        deltas: [(text: String, sentThrough: Int?)],
        final: String,
        input: JapaneseCorrectiveWindowInput,
        asrMilliseconds: Double
    ) -> [JapaneseCorrectiveFragment] {
        let deltaText = deltas.map(\.text).joined()
        guard !final.isEmpty,
              JapaneseCER.normalized(deltaText) == JapaneseCER.normalized(final) else {
            return final.isEmpty ? [] : [JapaneseCorrectiveFragment(
                startSample: input.window.startSample,
                endSample: input.window.endSample,
                text: final,
                asrMilliseconds: asrMilliseconds
            )]
        }
        var result: [JapaneseCorrectiveFragment] = []
        var pending = ""
        var start = input.window.startSample
        for delta in deltas {
            pending += delta.text
            guard let reportedEnd = delta.sentThrough else { continue }
            let end = min(input.window.endSample, max(start, reportedEnd))
            guard end > start, !pending.isEmpty else { continue }
            result.append(JapaneseCorrectiveFragment(
                startSample: start,
                endSample: end,
                text: pending,
                asrMilliseconds: 0
            ))
            pending = ""
            start = end
        }
        if !pending.isEmpty {
            result.append(JapaneseCorrectiveFragment(
                startSample: start,
                endSample: input.window.endSample,
                text: pending,
                asrMilliseconds: asrMilliseconds
            ))
        }
        return result.isEmpty ? [JapaneseCorrectiveFragment(
            startSample: input.window.startSample,
            endSample: input.window.endSample,
            text: final,
            asrMilliseconds: asrMilliseconds
        )] : result
    }

    private func correctiveSession(
        engine: JapaneseBakeoffEngine,
        recipeID: String? = nil,
        input: JapaneseCorrectiveWindowInput,
        replay: Int,
        asrFedSampleCount: Int,
        finalizedThrough: Int,
        fragments: [JapaneseCorrectiveFragment],
        asrMilliseconds: [Double],
        wallMilliseconds: Double,
        asrWallMilliseconds: Double? = nil,
        maximumBacklogMilliseconds: Double,
        endingBacklogMilliseconds: Double,
        maximumResidentBytes: UInt64?,
        errors: [String],
        finalLatencyMilliseconds: [Double] = [],
        finalLatencyScope: String = "unavailable",
        previewRole: String = "not-measured",
        previewLatencyScope: String = "not-measured",
        previewSummary: BenchmarkPreviewTranslationSummary = .empty,
        confirmedPrefixRewriteCount: Int = 0,
        finalSummary: BenchmarkFinalTranslationSummary = .empty,
        englishValidationThroughOverride: Int? = nil,
        resourceSummary: BenchmarkResourceSummary? = nil,
        backlogApplicable: Bool = true,
        effectiveDecoder: String = "not-executed"
    ) -> JapaneseCorrectiveSession {
        let effectiveRecipeID = recipeID ?? engine.rawValue
        let endpoints = input.decisions.map { decision in
            JapaneseCorrectiveEndpoint(
                kind: decision.kind.rawValue,
                startSample: input.window.startSample + decision.audioStart,
                endSample: input.window.startSample + decision.audioEnd,
                speechEndSample: input.window.startSample + decision.speechEnd,
                detectedAtSample: input.window.startSample + decision.endpointDetectedAt
            )
        }
        let endpointData = (try? JSONEncoder().encode(endpoints)) ?? Data()
        let scorerFragments = fragments.enumerated().map { index, fragment in
            ManyToManyTurnScorer.Fragment(
                id: index + 1,
                startSample: fragment.startSample,
                endSample: fragment.endSample,
                text: fragment.text
            )
        }
        let turns = JapaneseBenchmarkSupport.referenceTurns(
            manifest: input.manifest,
            window: input.window
        )
        let final = fragments.map(\.text).joined()
        let normalized = String(JapaneseCER.normalized(final))
        let terms = input.manifest.annotations.turns.filter {
            max($0.startSample, input.window.startSample)
                < min($0.endSample, input.window.endSample)
        }.flatMap(\.criticalTerms)
        let missing = terms.compactMap { term -> String? in
            let expected = String(JapaneseCER.normalized(term.japanese))
            return expected.isEmpty || normalized.contains(expected) ? nil : term.japanese
        }
        let lastSpeech = turns.max { $0.endSample < $1.endSample }.map {
            JapaneseBenchmarkSupport.lastSpeechEvidence(turn: $0, fragments: scorerFragments)
        }
        let audioMilliseconds = Double(input.samples.count) / 16
        let analyzedThrough = min(max(0, input.analyzedThrough), input.samples.count)
        let processedThrough = min(
            analyzedThrough,
            max(0, input.decisions.last?.stableThrough ?? 0)
        )
        let terminalSilenceStart = processedThrough < analyzedThrough
            ? input.window.startSample + processedThrough : nil
        let finalTranslationsMatchFragments = finalSummary.events.count == fragments.count
            && zip(finalSummary.events, fragments).allSatisfy { event, fragment in
                event.sourceStartSample == fragment.startSample
                    && JapaneseCER.normalized(event.source)
                        == JapaneseCER.normalized(fragment.text)
            }
        var englishValidatedThrough = input.window.startSample
        for event in finalSummary.events {
            guard event.error == nil,
                  !event.english.isEmpty,
                  event.sourceStartSample <= event.sourceEndSample,
                  event.sourceEndSample >= englishValidatedThrough else { break }
            englishValidatedThrough = event.sourceEndSample
        }
        if !finalSummary.events.isEmpty,
           finalTranslationsMatchFragments,
           finalSummary.events.allSatisfy({ $0.error == nil && !$0.english.isEmpty }),
           let englishValidationThroughOverride {
            englishValidatedThrough = englishValidationThroughOverride
        }
        return JapaneseCorrectiveSession(
            recipeID: effectiveRecipeID,
            effectiveDecoder: effectiveDecoder,
            effectiveRecipeSHA256: digest(Data(
                "\(Self.modelRecipesSHA256)\u{0}\(effectiveRecipeID)\u{0}\(effectiveDecoder)".utf8
            )),
            corpusID: input.window.corpusID,
            windowID: input.window.id,
            replay: replay,
            windowStartSample: input.window.startSample,
            windowEndSample: input.window.endSample,
            expectedSampleCount: input.samples.count,
            asrFedSampleCount: asrFedSampleCount,
            pcmAnalyzedThrough: input.window.startSample + analyzedThrough,
            asrFinalizedThrough: input.window.startSample + finalizedThrough,
            englishValidatedThrough: englishValidatedThrough,
            terminalSilenceStartSample: terminalSilenceStart,
            terminalSilenceEndSample: terminalSilenceStart.map {
                _ in input.window.startSample + analyzedThrough
            },
            unaccountedSampleCount: input.samples.count - analyzedThrough,
            endpointDecisionsSHA256: digest(endpointData),
            endpoints: endpoints,
            fragments: fragments,
            japaneseFinal: final,
            normalizedFinalSHA256: digest(Data(normalized.utf8)),
            continuousCER: ContinuousJapaneseCER.score(
                turns: turns,
                finalSourceFragments: scorerFragments
            ),
            lastSpeech: lastSpeech,
            criticalTerms: JapaneseCorrectiveCriticalTerms(
                status: terms.isEmpty
                    ? "not-evaluable-no-human-annotations" : "diagnostic-unreviewed",
                annotatedCount: terms.count,
                missing: missing
            ),
            asrMilliseconds: asrMilliseconds,
            finalLatencyMilliseconds: finalLatencyMilliseconds,
            finalLatencyScope: finalLatencyScope,
            previewRole: previewRole,
            previewLatencyScope: previewLatencyScope,
            previewEvents: previewSummary.events,
            previewSourceFirstLatencyMilliseconds: previewSummary.sourceLatencies,
            previewFirstLatencyMilliseconds: previewSummary.firstLatencies,
            previewRevisionCount: previewSummary.revisions.reduce(0, +),
            confirmedPrefixRewriteCount: confirmedPrefixRewriteCount,
            finalTranslationEvents: finalSummary.events,
            finalTranslationsAppendOnly:
                finalSummary.appendOnly && finalTranslationsMatchFragments,
            audioMilliseconds: audioMilliseconds,
            asrWallMilliseconds: asrWallMilliseconds ?? wallMilliseconds,
            pipelineWallMilliseconds: wallMilliseconds,
            completionAfterAudioEndMilliseconds: max(0, wallMilliseconds - audioMilliseconds),
            computeRTF: audioMilliseconds > 0
                ? asrMilliseconds.reduce(0, +) / audioMilliseconds : 0,
            endToEndWallRTF: audioMilliseconds > 0 ? wallMilliseconds / audioMilliseconds : 0,
            maximumBacklogMilliseconds: maximumBacklogMilliseconds,
            endingBacklogMilliseconds: endingBacklogMilliseconds,
            maximumResidentBytes: maximumResidentBytes,
            averageCPUPercent: resourceSummary?.averageCPUPercent,
            thermalStateBefore: resourceSummary?.thermalStateBefore ?? "not-measured",
            thermalStateAfter: resourceSummary?.thermalStateAfter ?? "not-measured",
            backlogApplicable: backlogApplicable,
            errors: errors
        )
    }

    private func correctiveFailureSessions(
        engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        replayCount: Int,
        message: String,
        recipeID: String? = nil
    ) -> [JapaneseCorrectiveSession] {
        (1...replayCount).flatMap { replay in
            windows.map { input in
                correctiveSession(
                    engine: engine,
                    recipeID: recipeID,
                    input: input,
                    replay: replay,
                    asrFedSampleCount: 0,
                    finalizedThrough: 0,
                    fragments: [],
                    asrMilliseconds: [],
                    wallMilliseconds: 0,
                    maximumBacklogMilliseconds: 0,
                    endingBacklogMilliseconds: 0,
                    maximumResidentBytes: nil,
                    errors: [message]
                )
            }
        }
    }

    private func sleepCorrectiveReplay(started: UInt64, through sample: Int) async throws {
        let deadline = started + UInt64(max(0, sample)) * 1_000_000_000 / 16_000
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
    }

    private func elapsedMilliseconds(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    @available(macOS 26.4, *)
    private func runCorrectiveExternalEngine(
        _ engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        calibrationWindows: [JapaneseCorrectiveWindowInput],
        replayCount: Int,
        root: URL,
        environment: [String: String],
        runID: String,
        benchmarkScope: String,
        finalService: AppleTranslationService?,
        finalServiceError: String?
    ) async -> JapaneseCorrectiveEngineResult {
        var provenance = unresolvedProvenance(engine)
        do {
            provenance = try modelProvenance(engine, root: root, environment: environment)
            guard provenance.artifactSHA256Verified else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The pinned external model artifact failed SHA-256 verification."
                )
            }
            if engine == .whisperMLXBatch {
                try verifyPinnedGitCheckout(
                    sileroDirectory(root: root, environment: environment),
                    revision: Self.sileroRevision
                )
            }
        } catch {
            return JapaneseCorrectiveEngineResult(
                model: provenance,
                calibration: nil,
                sessions: correctiveFailureSessions(
                    engine: engine,
                    windows: windows,
                    replayCount: replayCount,
                    message: error.localizedDescription,
                    recipeID: correctiveRecipeID(engine: engine, environment: environment)
                )
            )
        }

        var chosenDecoder = "greedy"
        var calibration: JapaneseCorrectiveCalibration?
        if engine == .mlxWhisperTurbo {
            let greedy = await executeCorrectiveExternal(
                engine,
                windows: calibrationWindows,
                replayCount: 1,
                decoder: "greedy",
                realtime: false,
                root: root,
                environment: environment,
                runID: runID,
                suffix: "calibration-greedy",
                benchmarkScope: "calibration",
                finalService: nil,
                finalServiceError: nil
            )
            let beam = await executeCorrectiveExternal(
                engine,
                windows: calibrationWindows,
                replayCount: 1,
                decoder: "beam5",
                realtime: false,
                root: root,
                environment: environment,
                runID: runID,
                suffix: "calibration-beam5",
                benchmarkScope: "calibration",
                finalService: nil,
                finalServiceError: nil
            )
            let greedySessions = correctiveExternalSessions(
                engine: engine,
                windows: calibrationWindows,
                response: greedy.response,
                batchAfterCapture: false,
                decoder: "greedy"
            )
            let beamSessions = correctiveExternalSessions(
                engine: engine,
                windows: calibrationWindows,
                response: beam.response,
                batchAfterCapture: false,
                decoder: "beam5"
            )
            let greedyCER = aggregateOverallCER(greedySessions)
            let beamCER = aggregateOverallCER(beamSessions)
            let greedyP95 = percentile(
                greedySessions.flatMap(\.asrMilliseconds),
                fraction: 0.95
            )
            let beamP95 = percentile(
                beamSessions.flatMap(\.asrMilliseconds),
                fraction: 0.95
            )
            let beamWins = greedyCER.map { baseline in
                beamCER.map { baseline - $0 >= 0.01 } ?? false
            } ?? false
                && (beamP95.map { $0 <= 1_500 } ?? false)
            chosenDecoder = beamWins ? "beam5" : "greedy"
            calibration = JapaneseCorrectiveCalibration(
                recipeID: engine.rawValue,
                corpusID: calibrationWindows.first?.window.corpusID ?? "unknown",
                windowID: calibrationWindows.first?.window.id ?? "unknown",
                greedyCER: greedyCER,
                beam5CER: beamCER,
                greedyP95Milliseconds: greedyP95,
                beam5P95Milliseconds: beamP95,
                chosenDecoder: chosenDecoder,
                decision: beamWins
                    ? "beam5: CER improves by at least 1 point and p95 remains <=1.5s"
                    : "greedy: beam5 did not clear both quality and latency gates"
            )
        }

        let whisperMLXMode = environment["WHISPERASR_WHISPERMLX_MODE"] ?? "long-form"
        let batchAfterCapture = engine == .whisperMLXBatch
            && whisperMLXMode == "long-form"
        let execution = await executeCorrectiveExternal(
            engine,
            windows: windows,
            replayCount: replayCount,
            decoder: chosenDecoder,
            realtime: benchmarkScope == "full-video"
                || engine == .mlxWhisperTurbo,
            root: root,
            environment: environment,
            runID: runID,
            suffix: "replay",
            benchmarkScope: benchmarkScope,
            finalService: finalService,
            finalServiceError: finalServiceError
        )
        provenance.setupMilliseconds = execution.response?.setupMilliseconds
        provenance.warmupMilliseconds = execution.response?.warmupMilliseconds
        provenance.startupMeasurementScope = "fresh-process-model-load-and-pinned-warmup"
        if let error = execution.error {
            return JapaneseCorrectiveEngineResult(
                model: provenance,
                calibration: calibration,
                sessions: correctiveFailureSessions(
                    engine: engine,
                    windows: windows,
                replayCount: replayCount,
                    message: error,
                    recipeID: correctiveRecipeID(engine: engine, environment: environment)
                )
            )
        }
        return JapaneseCorrectiveEngineResult(
            model: provenance,
            calibration: calibration,
            sessions: correctiveExternalSessions(
                engine: engine,
                windows: windows,
                response: execution.response,
                batchAfterCapture: batchAfterCapture,
                decoder: engine == .whisperMLXBatch
                    ? (batchAfterCapture
                        ? "native-long-form-silero" : "product-vad-plus-native-silero")
                    : chosenDecoder,
                recipeID: correctiveRecipeID(engine: engine, environment: environment),
                finalTranslations: execution.finalTranslations,
                pipelineWallMilliseconds: execution.pipelineWallMilliseconds,
                resourceSummaries: execution.resources
            )
        )
    }

    private func stopCorrectiveExternalProcess(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        for _ in 0..<100 {
            guard process.isRunning else { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for _ in 0..<100 {
            guard process.isRunning else { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    @available(macOS 26.4, *)
    private func executeCorrectiveExternal(
        _ engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        replayCount: Int,
        decoder: String,
        realtime: Bool,
        root: URL,
        environment: [String: String],
        runID: String,
        suffix: String,
        benchmarkScope: String,
        finalService: AppleTranslationService?,
        finalServiceError: String?
    ) async -> JapaneseCorrectiveExternalExecution {
        do {
            let python = externalPythonURL(engine: engine, root: root, environment: environment)
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Missing external ASR Python at \(python.path)."
                )
            }
            let output = root.appendingPathComponent(
                ".build/benchmarks/japanese-live/runs/\(runID)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let stem = "\(engine.rawValue)-\(suffix)"
            let requestURL = output.appendingPathComponent("\(stem)-request.json")
            let responseURL = output.appendingPathComponent("\(stem)-response.json")
            let stdoutURL = output.appendingPathComponent("\(stem)-stdout.log")
            let stderrURL = output.appendingPathComponent("\(stem)-stderr.log")
            let corpusIDs = Array(Set(windows.map { $0.window.corpusID })).sorted()
            let corpora = try corpusIDs.map { corpusID -> JapaneseExternalASRRequest.Corpus in
                guard let input = windows.first(where: { $0.window.corpusID == corpusID }) else {
                    throw JapaneseBenchmarkCSV.ParseError.malformed("Missing external corpus input.")
                }
                let wavURL = try JapaneseBenchmarkSupport.fixtureURL(
                    for: input.manifest,
                    workspaceRoot: root
                )
                return JapaneseExternalASRRequest.Corpus(
                    corpusID: corpusID,
                    audioPath: wavURL.path,
                    turns: []
                )
            }
            let requestedWindows = (1...replayCount).flatMap { replay in
                windows.enumerated().map { index, input in
                    JapaneseExternalASRRequest.Window(
                        sessionID: "\(engine.rawValue):\(input.window.id):r\(replay)",
                        corpusID: input.window.corpusID,
                        windowID: input.window.id,
                        replay: replay,
                        // Replays must be bit-for-bit repetitions, not new
                        // stochastic trials.
                        seed: index,
                        startSample: input.window.startSample,
                        endSample: input.window.endSample,
                        realtime: realtime,
                        ranges: input.decisions.map {
                            JapaneseExternalASRRequest.Window.AudioRange(
                                startSample: input.window.startSample + $0.audioStart,
                                endSample: input.window.startSample + $0.audioEnd
                            )
                        }
                    )
                }
            }
            var request = JapaneseExternalASRRequest(
                backend: engine == .mlxWhisperTurbo ? "mlx-whisper" : "whispermlx",
                modelPath: mlxWhisperModelDirectory(root: root, environment: environment).path,
                sileroPath: engine == .whisperMLXBatch
                    ? sileroDirectory(root: root, environment: environment).path : nil,
                corpora: corpora
            )
            request.decoder = decoder
            request.mode = engine == .whisperMLXBatch
                ? environment["WHISPERASR_WHISPERMLX_MODE"] ?? "long-form"
                : "vad-finals"
            request.emitEvents = benchmarkScope == "full-video"
            request.waitForSessionAck = benchmarkScope == "full-video"
            request.windows = requestedWindows
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(request).write(to: requestURL, options: .atomic)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderr.close() }
            let adapterArguments = [
                root.appendingPathComponent("Scripts/japanese_external_asr.py").path,
                requestURL.path,
                responseURL.path,
            ]
            let process = Process()
            if environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
               environment["WHISPERASR_PROCESS_ALREADY_SANDBOXED"] != "1" {
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
            let stdoutPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardInput = stdinPipe
            process.standardError = stderr
            try process.run()
            let childPID = process.processIdentifier
            let maximumRunSeconds = Int(ceil(
                Double(requestedWindows.reduce(0) {
                    $0 + max(0, $1.endSample - $1.startSample)
                }) / 16_000
            )) + 1_800
            let deadline = Task.detached(priority: .utility) { () -> Bool in
                do {
                    try await Task.sleep(for: .seconds(maximumRunSeconds))
                } catch {
                    return false
                }
                _ = Darwin.kill(childPID, SIGTERM)
                try? await Task.sleep(for: .seconds(5))
                if Darwin.kill(childPID, 0) == 0 {
                    _ = Darwin.kill(childPID, SIGKILL)
                }
                return true
            }
            var sessionStarts: [String: UInt64] = [:]
            var resourceSamplers: [String: Task<BenchmarkResourceSummary, Never>] = [:]
            var resources: [String: BenchmarkResourceSummary] = [:]
            var finalTranslators: [String: BenchmarkFinalTranslator] = [:]
            var finalTranslations: [String: BenchmarkFinalTranslationSummary] = [:]
            var pipelineWallMilliseconds: [String: Double] = [:]
            var translatedFinalizedThrough: [String: Int] = [:]
            var lastTranslatedFragment: [String: (text: String, endSample: Int)] = [:]
            var watchdog = BenchmarkBacklogWatchdog()
            var watchdogFailure: String?
            let sessionsRequiringACK = Set(requestedWindows.dropLast().map(\.sessionID))
            let inputBySession = Dictionary(uniqueKeysWithValues: requestedWindows.compactMap {
                window -> (String, JapaneseCorrectiveWindowInput)? in
                guard let input = windows.first(where: {
                    $0.window.id == window.windowID
                }) else { return nil }
                return (window.sessionID, input)
            })
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            let stdoutLog = try FileHandle(forWritingTo: stdoutURL)
            defer { try? stdoutLog.close() }
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    try stdoutLog.write(contentsOf: Data("\(line)\n".utf8))
                    guard let data = line.data(using: .utf8),
                          let event = try? JSONDecoder().decode(
                            JapaneseExternalASREvent.self,
                            from: data
                          ) else { continue }
                    switch event.type {
                    case "session-start":
                        sessionStarts[event.sessionID] = DispatchTime.now().uptimeNanoseconds
                        resourceSamplers[event.sessionID] = await MainActor.run {
                            startBenchmarkResourceSampler {
                                [parentPID = getpid(), childPID] in
                                [parentPID, childPID]
                            }
                        }
                        if benchmarkScope == "full-video" {
                            finalTranslators[event.sessionID] = BenchmarkFinalTranslator(
                                service: finalService,
                                unavailableReason: finalServiceError
                            )
                        }
                    case "final":
                        guard benchmarkScope == "full-video",
                              var source = event.hypothesisJapanese,
                              let startSample = event.startSample,
                              let endSample = event.endSample,
                              let sessionStart = sessionStarts[event.sessionID],
                              let input = inputBySession[event.sessionID],
                              let translator = finalTranslators[event.sessionID] else { continue }
                        let longForm = engine == .whisperMLXBatch
                            && request.mode == "long-form"
                        var translationStart = startSample
                        var translationFragmentEnd = endSample
                        let endpoint: UInt64
                        if longForm {
                            endpoint = sessionStart
                                + UInt64(input.samples.count) * 1_000_000_000 / 16_000
                        } else if let index = event.rangeIndex,
                                  index < input.decisions.count {
                            endpoint = sessionStart
                                + UInt64(max(0, input.decisions[index].speechEnd))
                                    * 1_000_000_000 / 16_000
                        } else {
                            endpoint = sessionStart
                                + UInt64(max(0, endSample - input.window.startSample))
                                    * 1_000_000_000 / 16_000
                        }
                        let validationEnd: Int
                        if !longForm,
                           let index = event.rangeIndex,
                           index < input.decisions.count {
                            let decision = input.decisions[index]
                            let acceptedStart = max(
                                translatedFinalizedThrough[event.sessionID] ?? 0,
                                decision.audioStart
                            )
                            translationStart = input.window.startSample + acceptedStart
                            if let previous = lastTranslatedFragment[event.sessionID],
                               translationStart < previous.endSample {
                                source = AppState.trimOverlap(
                                    previous: previous.text,
                                    current: source
                                )
                            }
                            validationEnd = input.window.startSample
                                + decision.stableThrough
                            translationFragmentEnd = input.window.startSample
                                + decision.speechEnd
                            translatedFinalizedThrough[event.sessionID] = max(
                                translatedFinalizedThrough[event.sessionID] ?? 0,
                                decision.stableThrough
                            )
                        } else if longForm {
                            validationEnd = endSample
                        } else {
                            continue
                        }
                        source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !source.isEmpty else { continue }
                        lastTranslatedFragment[event.sessionID] = (
                            source,
                            translationFragmentEnd
                        )
                        await translator.submit(
                            finalID: "\(event.sessionID):\(event.rangeIndex ?? 0)",
                            source: source,
                            sourceStartSample: translationStart,
                            sourceEndSample: validationEnd,
                            endpointUptimeNanoseconds: endpoint
                        )
                    case "session-end":
                        if let translator = finalTranslators[event.sessionID] {
                            finalTranslations[event.sessionID] = await translator.finish()
                        }
                        if let sessionStart = sessionStarts[event.sessionID] {
                            pipelineWallMilliseconds[event.sessionID] =
                                elapsedMilliseconds(since: sessionStart)
                        }
                        if let sampler = resourceSamplers.removeValue(
                            forKey: event.sessionID
                        ) {
                            sampler.cancel()
                            resources[event.sessionID] = await sampler.value
                        }
                        if sessionsRequiringACK.contains(event.sessionID) {
                            try stdinPipe.fileHandleForWriting.write(
                                contentsOf: Data("\n".utf8)
                            )
                        }
                    default:
                        break
                    }
                    if let backlog = event.backlogMilliseconds,
                       watchdog.observe(milliseconds: backlog) {
                        watchdogFailure = "Backlog exceeded 30 seconds continuously for one minute."
                        process.terminate()
                        break
                    }
                }
            } catch {
                watchdogFailure = "External ASR event stream failed: \(error.localizedDescription)"
                if process.isRunning { process.terminate() }
            }
            deadline.cancel()
            let deadlineFired = await deadline.value
            if deadlineFired {
                watchdogFailure = "External ASR exceeded its bounded execution deadline."
            }
            let processStopped = await stopCorrectiveExternalProcess(process)
            if !processStopped, watchdogFailure == nil {
                watchdogFailure = "External ASR could not be stopped after SIGKILL."
            }
            for (sessionID, translator) in finalTranslators {
                if finalTranslations[sessionID] == nil {
                    finalTranslations[sessionID] = await translator.finish()
                    if let sessionStart = sessionStarts[sessionID] {
                        pipelineWallMilliseconds[sessionID] =
                            elapsedMilliseconds(since: sessionStart)
                    }
                }
            }
            for (sessionID, sampler) in resourceSamplers {
                sampler.cancel()
                resources[sessionID] = await sampler.value
            }
            try? stdinPipe.fileHandleForWriting.close()
            let response = try JSONDecoder().decode(
                JapaneseExternalASRResponse.self,
                from: Data(contentsOf: responseURL)
            )
            if let setupError = response.setupError {
                return JapaneseCorrectiveExternalExecution(
                    response: response,
                    error: setupError,
                    finalTranslations: finalTranslations,
                    pipelineWallMilliseconds: pipelineWallMilliseconds,
                    resources: resources
                )
            }
            if let watchdogFailure {
                return JapaneseCorrectiveExternalExecution(
                    response: response,
                    error: watchdogFailure,
                    finalTranslations: finalTranslations,
                    pipelineWallMilliseconds: pipelineWallMilliseconds,
                    resources: resources
                )
            }
            if process.terminationStatus != 0 {
                return JapaneseCorrectiveExternalExecution(
                    response: response,
                    error: "External ASR exited with status \(process.terminationStatus).",
                    finalTranslations: finalTranslations,
                    pipelineWallMilliseconds: pipelineWallMilliseconds,
                    resources: resources
                )
            }
            return JapaneseCorrectiveExternalExecution(
                response: response,
                error: nil,
                finalTranslations: finalTranslations,
                pipelineWallMilliseconds: pipelineWallMilliseconds,
                resources: resources
            )
        } catch {
            return JapaneseCorrectiveExternalExecution(
                response: nil,
                error: error.localizedDescription,
                finalTranslations: [:],
                pipelineWallMilliseconds: [:],
                resources: [:]
            )
        }
    }

    private func correctiveExternalSessions(
        engine: JapaneseBakeoffEngine,
        windows: [JapaneseCorrectiveWindowInput],
        response: JapaneseExternalASRResponse?,
        batchAfterCapture: Bool,
        decoder: String,
        recipeID: String? = nil,
        finalTranslations: [String: BenchmarkFinalTranslationSummary] = [:],
        pipelineWallMilliseconds: [String: Double] = [:],
        resourceSummaries: [String: BenchmarkResourceSummary] = [:]
    ) -> [JapaneseCorrectiveSession] {
        guard let response else { return [] }
        let inputs = Dictionary(uniqueKeysWithValues: windows.map { ($0.window.id, $0) })
        return (response.windows ?? []).compactMap { result in
            guard let input = inputs[result.windowID] else { return nil }
            let expectedRanges: [(Int, Int)] = batchAfterCapture
                ? [(input.window.startSample, input.window.endSample)]
                : input.decisions.map {
                    (
                        input.window.startSample + $0.audioStart,
                        input.window.startSample + $0.audioEnd
                    )
                }
            let rangeFeedsComplete = result.fedSampleCount
                    == result.ranges.reduce(0) { $0 + $1.fedSampleCount }
                && result.ranges.allSatisfy { range in
                    if engine == .mlxWhisperTurbo {
                        return range.fedSampleCount == range.endSample - range.startSample
                    }
                    // whispermlx's native Silero VAD intentionally removes
                    // silence before MLX, but every speech-bearing product
                    // range must still reach the decoder.
                    return range.fedSampleCount > 0
                }
            let rangesComplete = result.inputSampleCount == input.samples.count
                && result.ranges.count == expectedRanges.count
                && zip(result.ranges, expectedRanges).allSatisfy { range, expected in
                    range.startSample == expected.0
                        && range.endSample == expected.1
                }
            var fragments: [JapaneseCorrectiveFragment] = []
            var emptyProductFinalIndices: [Int] = []
            if batchAfterCapture, !result.segments.isEmpty {
                fragments = result.segments.compactMap { segment in
                    let start = input.window.startSample
                        + Int((segment.start * 16_000).rounded())
                    let end = input.window.startSample
                        + Int((segment.end * 16_000).rounded())
                    guard end > start, !segment.text.isEmpty else { return nil }
                    return JapaneseCorrectiveFragment(
                        startSample: max(input.window.startSample, start),
                        endSample: min(input.window.endSample, end),
                        text: segment.text,
                        asrMilliseconds: 0
                    )
                }
            } else {
                var finalized = 0
                for (index, range) in result.ranges.enumerated() {
                    guard index < input.decisions.count else { break }
                    let decision = input.decisions[index]
                    var text = range.hypothesisJapanese
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let acceptedStart = max(finalized, decision.audioStart)
                    if let previous = fragments.last,
                       input.window.startSample + acceptedStart < previous.endSample {
                        text = AppState.trimOverlap(previous: previous.text, current: text)
                    }
                    if !text.isEmpty {
                        fragments.append(JapaneseCorrectiveFragment(
                            startSample: input.window.startSample + acceptedStart,
                            endSample: input.window.startSample + decision.speechEnd,
                            text: text,
                            asrMilliseconds: range.asrMilliseconds
                        ))
                    } else {
                        emptyProductFinalIndices.append(index)
                    }
                    finalized = max(finalized, decision.stableThrough)
                }
            }
            if batchAfterCapture,
               fragments.isEmpty,
               !result.hypothesisJapanese.isEmpty {
                fragments = [JapaneseCorrectiveFragment(
                    startSample: input.window.startSample,
                    endSample: input.window.endSample,
                    text: result.hypothesisJapanese,
                    asrMilliseconds: result.asrMilliseconds
                )]
            }
            let asrTimings = result.ranges.isEmpty
                ? [result.asrMilliseconds] : result.ranges.map(\.asrMilliseconds)
            let rawWall = result.wallMilliseconds
            let wall = max(rawWall, pipelineWallMilliseconds[result.sessionID] ?? rawWall)
            let finalSummary = finalTranslations[result.sessionID] ?? .empty
            let resourceSummary = resourceSummaries[result.sessionID]
            let finalLatencies: [Double]
            let finalLatencyScope: String
            if !finalSummary.events.isEmpty {
                finalLatencies = finalSummary.events.map(\.endpointToAcceptedMilliseconds)
                finalLatencyScope = batchAfterCapture
                    ? "capture-eos-to-accepted-apple-high-fidelity"
                    : "speech-end-to-accepted-apple-high-fidelity"
            } else if batchAfterCapture {
                finalLatencies = [rawWall]
                finalLatencyScope = "batch-after-capture"
            } else {
                finalLatencies = zip(result.ranges, input.decisions).map { range, decision in
                    max(
                        0,
                        range.completedMilliseconds - Double(decision.speechEnd) / 16
                    )
                }
                finalLatencyScope = "product-vad-final-after-speech-end"
            }
            var errors = result.error.map { [$0] } ?? []
            if !rangesComplete {
                errors.append("External ASR returned incomplete or reordered PCM ranges.")
            }
            if !rangeFeedsComplete {
                errors.append(
                    "External ASR did not forward every speech-bearing range to its decoder."
                )
            }
            if !emptyProductFinalIndices.isEmpty {
                errors.append(
                    "External ASR returned empty product VAD finals at indices "
                        + emptyProductFinalIndices.map(String.init).joined(separator: ",")
                        + "."
                )
            }
            errors += finalSummary.events.compactMap(\.error).map {
                "Apple highFidelity final: \($0)"
            }
            return correctiveSession(
                engine: engine,
                recipeID: recipeID,
                input: input,
                replay: result.replay,
                asrFedSampleCount: result.fedSampleCount,
                finalizedThrough: result.error == nil && rangesComplete
                    ? (batchAfterCapture
                        ? input.samples.count
                        : input.decisions.last?.stableThrough ?? 0)
                    : 0,
                fragments: fragments,
                asrMilliseconds: asrTimings,
                wallMilliseconds: wall,
                asrWallMilliseconds: rawWall,
                maximumBacklogMilliseconds: batchAfterCapture
                    ? 0 : (result.ranges.map(\.backlogMilliseconds).max() ?? 0),
                endingBacklogMilliseconds: 0,
                maximumResidentBytes: max(
                    result.residentBytes,
                    resourceSummary?.maximumResidentBytes ?? 0
                ),
                errors: errors,
                finalLatencyMilliseconds: finalLatencies,
                finalLatencyScope: finalLatencyScope,
                previewRole: "apple-speech-common",
                previewLatencyScope: "shared-apple-speech-control",
                finalSummary: finalSummary,
                englishValidationThroughOverride: batchAfterCapture
                    ? input.window.endSample : nil,
                resourceSummary: resourceSummary,
                backlogApplicable: !batchAfterCapture,
                effectiveDecoder: decoder
            )
        }
    }

    private func aggregateOverallCER(_ sessions: [JapaneseCorrectiveSession]) -> Double? {
        let values = sessions.compactMap(\.continuousCER?.overall)
        let reference = values.reduce(0) { $0 + $1.referenceCharacterCount }
        guard reference > 0 else { return nil }
        return Double(values.reduce(0) { $0 + $1.editDistance }) / Double(reference)
    }

    private func correctiveReport(
        runID: String,
        benchmarkScope: String,
        gitCommit: String,
        sourceTreeSHA256: String,
        runtimeSHA256: String,
        worktreeDirty: Bool,
        networkDenied: Bool,
        recipeSHA: String,
        replayCount: Int,
        expectedEngines: [JapaneseBakeoffEngine],
        expectedWindowIDs: [String],
        expectedRecipeIDs: [String],
        corpora: [JapaneseCorrectiveCorpus],
        models: [JapaneseBakeoffModelProvenance],
        calibrations: [JapaneseCorrectiveCalibration],
        sessions: [JapaneseCorrectiveSession]
    ) -> JapaneseCorrectiveReport {
        let expectedCount = expectedRecipeIDs.count * expectedWindowIDs.count * replayCount
        let expectedAttemptKeys = Set(expectedRecipeIDs.flatMap { recipeID in
            expectedWindowIDs.flatMap { windowID in
                (1...replayCount).map { "\(recipeID):\(windowID):\($0)" }
            }
        })
        let actualAttemptKeys = sessions.map {
            "\($0.recipeID):\($0.windowID):\($0.replay)"
        }
        let matrixAttempted = !expectedEngines.isEmpty
            && expectedRecipeIDs.count == expectedEngines.count
            && sessions.count == expectedCount
            && Set(actualAttemptKeys) == expectedAttemptKeys
            && Set(actualAttemptKeys).count == actualAttemptKeys.count
        let matrixComplete = matrixAttempted
            && sessions.allSatisfy { session in
                let requiredThrough = session.terminalSilenceStartSample
                    ?? session.windowEndSample
                let terminalSilenceValid = session.terminalSilenceStartSample == nil
                    ? session.terminalSilenceEndSample == nil
                    : session.terminalSilenceEndSample == session.windowEndSample
                return session.errors.isEmpty
                    && !session.japaneseFinal.isEmpty
                    && session.continuousCER != nil
                    && session.pcmAnalyzedThrough == session.windowEndSample
                    && session.unaccountedSampleCount == 0
                    && terminalSilenceValid
                    && session.asrFinalizedThrough >= requiredThrough
                    && session.asrFinalizedThrough <= session.windowEndSample
                    && (benchmarkScope != "full-video"
                        || (session.englishValidatedThrough >= requiredThrough
                            && session.englishValidatedThrough <= session.windowEndSample
                            && session.finalTranslationsAppendOnly))
            }
        let qualityAndResourceGates = sessions.allSatisfy {
            $0.lastSpeech?.heuristicPresent == true
                && $0.criticalTerms.missing.isEmpty
                && ($0.maximumResidentBytes ?? UInt64.max) < 10 * 1_024 * 1_024 * 1_024
                && $0.endingBacklogMilliseconds == 0
        }
        let deterministic = correctiveStability(sessions).allSatisfy {
            $0.replayCount == replayCount
                && (replayCount == 1 || $0.normalizedFinalsIdentical)
                && $0.errorCount == 0
        }
        let comparableFinalScope = "speech-end-to-accepted-apple-high-fidelity"
        let finalLatencyGate = !sessions.isEmpty
            && sessions.allSatisfy {
                $0.finalLatencyScope == comparableFinalScope
                    && !$0.finalLatencyMilliseconds.isEmpty
                    && (percentile(
                        $0.finalLatencyMilliseconds,
                        fraction: 0.95
                    ).map { $0 <= 1_500 } ?? false)
            }
        let previewLatencyGate = !sessions.isEmpty
            && sessions.allSatisfy {
                $0.previewRole == "candidate-native"
                    && $0.previewLatencyScope
                        == "source-phrase-start-to-accepted-apple-low-latency"
                    && !$0.previewFirstLatencyMilliseconds.isEmpty
                    && (percentile(
                        $0.previewFirstLatencyMilliseconds,
                        fraction: 0.95
                    ).map { $0 <= 1_800 } ?? false)
            }
        return JapaneseCorrectiveReport(
            schemaVersion: benchmarkScope == "full-video" ? 4 : 2,
            runID: runID,
            benchmarkScope: benchmarkScope,
            gitCommit: gitCommit,
            sourceTreeSHA256: sourceTreeSHA256,
            runtimeSHA256: runtimeSHA256,
            worktreeDirty: worktreeDirty,
            networkDenied: networkDenied,
            modelRecipesSHA256: recipeSHA,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            sampleRate: 16_000,
            replayCount: replayCount,
            expectedRecipeIDs: expectedRecipeIDs,
            matrixAttempted: matrixAttempted,
            matrixComplete: matrixComplete,
            promotionEligible: matrixComplete
                && !worktreeDirty
                && networkDenied
                && qualityAndResourceGates
                && deterministic
                && previewLatencyGate
                && finalLatencyGate
                && corpora.allSatisfy { $0.annotationStatus == "complete" },
            corpora: corpora,
            models: models,
            calibrations: calibrations,
            sessions: sessions,
            stability: correctiveStability(sessions)
        )
    }

    private func correctiveStability(
        _ sessions: [JapaneseCorrectiveSession]
    ) -> [JapaneseCorrectiveStability] {
        Dictionary(grouping: sessions) { "\($0.recipeID):\($0.windowID)" }
            .values.map { group in
                let lower = group.compactMap(\.continuousCER?.highConfidence.rateLowerBound)
                let upper = group.compactMap(\.continuousCER?.highConfidence.rateUpperBound)
                return JapaneseCorrectiveStability(
                    recipeID: group[0].recipeID,
                    windowID: group[0].windowID,
                    replayCount: group.count,
                    distinctNormalizedFinalCount: Set(group.map(\.normalizedFinalSHA256)).count,
                    normalizedFinalsIdentical: Set(group.map(\.normalizedFinalSHA256)).count == 1,
                    highCERLowerMinimum: lower.min(),
                    highCERLowerMaximum: lower.max(),
                    highCERUpperMinimum: upper.min(),
                    highCERUpperMaximum: upper.max(),
                    lastSpeechPresentCount: group.filter {
                        $0.lastSpeech?.heuristicPresent == true
                    }.count,
                    endingBacklogMaximumMilliseconds:
                        group.map(\.endingBacklogMilliseconds).max() ?? 0,
                    errorCount: group.reduce(0) { $0 + $1.errors.count }
                )
            }.sorted {
                ($0.recipeID, $0.windowID) < ($1.recipeID, $1.windowID)
            }
    }

    private func writeCorrectiveReport(
        _ report: JapaneseCorrectiveReport,
        runID: String,
        root: URL
    ) throws {
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: output.appendingPathComponent("live-replay.json"),
            options: .atomic
        )
        try correctiveFrenchReport(report).write(
            to: output.appendingPathComponent("live-report-fr.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func correctiveFrenchReport(_ report: JapaneseCorrectiveReport) -> String {
        var lines = [
            "# L7B — replays corrigés",
            "",
            "Matrice complète : \(report.matrixComplete ? "oui" : "non"). Promotion : non, références encore `pending-human-review`.",
            "",
            "| Recette | Sessions | CER high | Dernière parole | Final p95 | RSS max | Backlog final | Stabilité | Verdict |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---|",
        ]
        for recipeID in report.expectedRecipeIDs {
            let sessions = report.sessions.filter { $0.recipeID == recipeID }
            let scopes = sessions.compactMap(\.continuousCER?.highConfidence)
            let references = scopes.reduce(0) { $0 + $1.referenceCharacterCount }
            let lower = references > 0 ? scopes.reduce(0.0) {
                $0 + ($1.rateLowerBound ?? 0) * Double($1.referenceCharacterCount)
            } / Double(references) : nil
            let upper = references > 0 ? scopes.reduce(0.0) {
                $0 + ($1.rateUpperBound ?? 0) * Double($1.referenceCharacterCount)
            } / Double(references) : nil
            let p95 = percentile(sessions.flatMap(\.finalLatencyMilliseconds), fraction: 0.95)
            let resident = sessions.compactMap(\.maximumResidentBytes).max()
            let last = sessions.filter { $0.lastSpeech?.heuristicPresent == true }.count
            let stable = report.stability.filter {
                $0.recipeID == recipeID && $0.normalizedFinalsIdentical
            }.count
            let errors = sessions.reduce(0) { $0 + $1.errors.count }
            let verdict = errors > 0 ? "échec observé" : "mesuré, attente L7C"
            lines.append(
                "| \(recipeID) | \(sessions.count) | \(percent(lower))–\(percent(upper)) "
                    + "| \(last)/\(sessions.count) | \(milliseconds(p95)) | "
                    + "\(resident.map { String(format: "%.2f Gio", Double($0) / 1_073_741_824) } ?? "n/a") | "
                    + "\(milliseconds(sessions.map(\.endingBacklogMilliseconds).max())) | "
                    + "\(stable)/4 | \(verdict) |"
            )
        }
        lines += [
            "",
            "Le p95 final mesure la fin VAD → final, sauf Voxtral (`capture-eos`) et `whispermlx` (`batch-after-capture`), affichés mais non comparables aux finales par phrase.",
            "Les termes critiques sont `n/a` : les deux manifests n'en contiennent aucun. Le CER high est un intervalle; le CER global reste diagnostique.",
        ]
        return lines.joined(separator: "\n") + "\n"
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
            if environment["WHISPERASR_EXTERNAL_NETWORK_DENIED"] == "1",
               environment["WHISPERASR_PROCESS_ALREADY_SANDBOXED"] != "1" {
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
        environment: [String: String],
        decoding: WhisperDecodingStrategy = .greedy
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
                modelPath: modelPath,
                decoding: decoding
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
                runtimeRevision: Self.qwenRuntimeRevision
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
                runtimeRevision: "wheel:\(Self.whisperMLXWheelSHA256)"
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
            let directory = mlxWhisperModelDirectory(root: root, environment: environment)
            guard try JapaneseBenchmarkSupport.sha256(
                at: directory.appendingPathComponent("config.json")
            ) == Self.mlxWhisperConfigSHA256 else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "The pinned MLX Whisper config failed SHA-256 verification."
                )
            }
            artifact = directory.appendingPathComponent("weights.safetensors")
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
        let observed = try JapaneseBenchmarkSupport.artifactSHA256(at: artifact)
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

    private func verifyPinnedGitCheckout(_ directory: URL, revision: String) throws {
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(text)
            }
            return text
        }
        guard try git(["rev-parse", "HEAD"]) == revision,
              try git(["status", "--porcelain", "--untracked-files=no"]).isEmpty else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Pinned checkout \(directory.lastPathComponent) is modified or at the wrong revision."
            )
        }
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
