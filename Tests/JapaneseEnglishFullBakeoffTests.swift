import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseEnglishFullBakeoffTests: XCTestCase {
    private struct L5Report: Decodable {
        struct Corpus: Codable {
            let corpusID: String
            let manifestSHA256: String
            let audioSHA256: String
            let annotationStatus: String
            let selectedTurnIDs: [Int]
        }

        struct Rate: Decodable { let rate: Double? }

        struct Engine: Decodable {
            let engine: String
            let status: String
            let setupError: String?
            let primaryHighConfidenceCER: Rate
            let asrP95Milliseconds: Double?
            let primaryEmptySpeechTurnCount: Int
            let diagnosticEmptySpeechTurnCount: Int
            let maximumObservedResidentBytes: UInt64
            let turns: [Turn]
        }

        struct Turn: Decodable {
            let corpusID: String
            let turnID: Int
            let confidence: String
            let overlap: Bool
            let referenceJapanese: String
            let hypothesisJapanese: String
            let asrMilliseconds: Double
            let residentBytes: UInt64
            let asrError: String?
        }

        let schemaVersion: Int
        let runID: String
        let gitCommit: String
        let worktreeDirty: Bool
        let modelHubOfflineMode: Bool
        let externalNetworkAccessDenied: Bool
        let corpora: [Corpus]
        let scope: String
        let engines: [Engine]
    }

    private struct ReferenceTurn {
        let corpusID: String
        let turnID: Int
        let confidence: String
        let overlap: Bool
        let japanese: String
        let english: String?
    }

    private struct SourceItem {
        let pipeline: String
        let sourceKind: String
        let reference: ReferenceTurn
        let japanese: String
    }

    private struct TranslationOutput: Codable {
        let pipeline: String
        let sourceKind: String
        let corpusID: String
        let turnID: Int
        let confidence: String
        let overlap: Bool
        let referenceJapanese: String
        let referenceEnglish: String?
        let sourceJapanese: String
        let english: String
        let validEnglish: Bool
        let translationMilliseconds: Double?
        let residentBytes: UInt64
        let error: String?
    }

    private struct TranslationReport: Codable {
        let schemaVersion: Int
        let runID: String
        let gitCommit: String
        let worktreeDirty: Bool
        let remoteNetworkDeniedForXCTest: Bool
        let sourceL5RunID: String
        let sourceL5Commit: String
        let sourceL5SHA256: String
        let sourceCorpora: [L5Report.Corpus]
        let macOSVersion: String
        let macOSBuild: String
        let strategy: String
        let semanticRole: String
        let generatedAt: String
        let items: [TranslationOutput]
    }

    private struct PipelineComparison: Codable {
        let pipeline: String
        let sourceKind: String
        let japaneseCER: Double?
        let japaneseASRP95Milliseconds: Double?
        let primaryEmptySpeechTurnCount: Int
        let diagnosticEmptySpeechTurnCount: Int
        let asrMaximumObservedResidentBytes: UInt64
        let appleXCTestMaximumObservedResidentBytes: UInt64
        let primaryTurnCount: Int
        let primarySourceNonEmptyCount: Int
        let previewTranslationAttemptCount: Int
        let previewTranslationSuccessCount: Int
        let previewTranslationSuccessRate: Double
        let previewPipelineCoverageIncludingASROmissions: Double
        let previewTranslationP50Milliseconds: Double?
        let previewTranslationP95Milliseconds: Double?
        let previewTranslationWorstMilliseconds: Double?
        let finalTranslationAttemptCount: Int
        let finalTranslationSuccessCount: Int
        let finalTranslationSuccessRate: Double
        let finalPipelineCoverageIncludingASROmissions: Double
        let finalTranslationP50Milliseconds: Double?
        let finalTranslationP95Milliseconds: Double?
        let finalTranslationWorstMilliseconds: Double?
        let previewToFinalChangeRate: Double?
        let referenceEnglishPresentCount: Int
        let qualityReviewStatus: String
        let verdict: String
    }

    private struct ComparisonReport: Codable {
        let schemaVersion: Int
        let runID: String
        let sourceL5RunID: String
        let sourceL5SHA256: String
        let note: String
        let pipelines: [PipelineComparison]
    }

    private struct BlindCandidate: Codable {
        let alias: String
        let english: String
        let missing: Bool
        let fidelityScore1To5: Int?
        let naturalnessScore1To5: Int?
        let criticalError: String?
    }

    private struct BlindItem: Codable {
        let corpusID: String
        let turnID: Int
        let referenceJapanese: String
        let candidates: [BlindCandidate]
    }

    private struct BlindReport: Codable {
        let schemaVersion: Int
        let kind: String
        let note: String
        let items: [BlindItem]
    }

    private static let humanPipeline = "human-reference-japanese"
    private static let expectedEngines = [
        "whisper-large-v3-turbo",
        "mlx-whisper-large-v3-turbo",
        "voxtral-q4-continuous-960ms",
        "nemotron-multilingual-coreml-1120ms",
        "nemotron-multilingual-coreml-560ms",
        "kotoba-whisper-v2.0-q5",
        "qwen3-asr-1.7b",
        "whispermlx-v3.12.2-turbo",
    ]
    private static let expectedStressTurnIDs: [String: [Int]] = [
        "qudu2fx3ncc": Array(147...183) + Array(193...199),
        "md62mmdz0m": Array(149...187) + Array(265...273),
    ]

    @MainActor
    func testFullEnglishBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_L6_APPLE_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_english_bakeoff.sh after L5.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple Translation requires macOS 26.4 or later.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let inputURL = URL(fileURLWithPath: environment["WHISPERASR_L5_REPORT"]
            ?? root.appendingPathComponent(
                ".build/benchmarks/japanese-live/runs/l5-final-offline/ja-asr.json"
            ).path)
        let sourceL5SHA256 = try JapaneseBenchmarkSupport.sha256(at: inputURL)
        let l5 = try JSONDecoder().decode(
            L5Report.self,
            from: Data(contentsOf: inputURL)
        )
        let references = try loadAndValidateReferences(l5: l5, root: root)
        try validate(l5: l5, references: references)

        let previewService = AppleTranslationService()
        let finalService = AppleTranslationService()
        try await previewService.configure(sourceLocale: "ja", mode: .lowLatencyOnly)
        try await finalService.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        try await previewService.warmup(highFidelity: false)
        try await finalService.warmup(highFidelity: true)
        defer {
            Task {
                await previewService.cancel()
                await finalService.cancel()
            }
        }

        let sources = sourceItems(l5: l5, references: references)
        var previewOutputs: [TranslationOutput] = []
        var finalOutputs: [TranslationOutput] = []
        for (index, source) in sources.enumerated() {
            previewOutputs.append(await translate(
                source,
                service: previewService,
                highFidelity: false
            ))
            finalOutputs.append(await translate(
                source,
                service: finalService,
                highFidelity: true
            ))
            if index.isMultiple(of: 100) || index + 1 == sources.count {
                print("[JapaneseEnglishL6] progress=\(index + 1)/\(sources.count)")
            }
        }
        await previewService.cancel()
        await finalService.cancel()

        let runID = environment["WHISPERASR_L6_RUN_ID"]
            ?? "l6-apple-\(ISO8601DateFormatter().string(from: Date()))"
        let gitCommit = environment["WHISPERASR_BENCHMARK_COMMIT"] ?? "unknown"
        let worktreeDirty = environment["WHISPERASR_BENCHMARK_DIRTY"] == "1"
        let remoteNetworkDenied =
            environment["WHISPERASR_REMOTE_NETWORK_DENIED"] == "1"
        let macOSVersion = environment["WHISPERASR_MACOS_VERSION"]
            ?? ProcessInfo.processInfo.operatingSystemVersionString
        let macOSBuild = environment["WHISPERASR_MACOS_BUILD"] ?? "unknown"
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let previewReport = TranslationReport(
            schemaVersion: 2,
            runID: runID,
            gitCommit: gitCommit,
            worktreeDirty: worktreeDirty,
            remoteNetworkDeniedForXCTest: remoteNetworkDenied,
            sourceL5RunID: l5.runID,
            sourceL5Commit: l5.gitCommit,
            sourceL5SHA256: sourceL5SHA256,
            sourceCorpora: l5.corpora,
            macOSVersion: macOSVersion,
            macOSBuild: macOSBuild,
            strategy: "apple-low-latency",
            semanticRole: "translation-strategy-isolation-not-live-preview",
            generatedAt: generatedAt,
            items: previewOutputs
        )
        let finalReport = TranslationReport(
            schemaVersion: 2,
            runID: runID,
            gitCommit: gitCommit,
            worktreeDirty: worktreeDirty,
            remoteNetworkDeniedForXCTest: remoteNetworkDenied,
            sourceL5RunID: l5.runID,
            sourceL5Commit: l5.gitCommit,
            sourceL5SHA256: sourceL5SHA256,
            sourceCorpora: l5.corpora,
            macOSVersion: macOSVersion,
            macOSBuild: macOSBuild,
            strategy: "apple-high-fidelity",
            semanticRole: "final-translation-strategy-isolation",
            generatedAt: generatedAt,
            items: finalOutputs
        )
        let comparison = comparisonReport(
            runID: runID,
            sourceL5SHA256: sourceL5SHA256,
            l5: l5,
            preview: previewOutputs,
            final: finalOutputs
        )
        let blind = blindArtifacts(
            preview: previewOutputs,
            final: finalOutputs,
            seed: UUID().uuidString
        )
        try write(
            preview: previewReport,
            final: finalReport,
            comparison: comparison,
            blind: blind,
            root: root
        )

        XCTAssertEqual(previewOutputs.count, 9 * 92)
        XCTAssertEqual(finalOutputs.count, 9 * 92)
        XCTAssertTrue(previewOutputs.filter { !$0.sourceJapanese.isEmpty }.allSatisfy {
            $0.validEnglish && $0.error == nil
        }, "Every non-empty Japanese source must produce a valid Apple lowLatency translation.")
        XCTAssertTrue(finalOutputs.filter { !$0.sourceJapanese.isEmpty }.allSatisfy {
            $0.validEnglish && $0.error == nil
        }, "Every non-empty Japanese source must produce a valid Apple highFidelity translation.")
        XCTAssertEqual(
            previewOutputs.filter { $0.pipeline == Self.humanPipeline && $0.validEnglish }.count,
            92
        )
        XCTAssertEqual(
            finalOutputs.filter { $0.pipeline == Self.humanPipeline && $0.validEnglish }.count,
            92
        )
        XCTAssertTrue(comparison.pipelines.allSatisfy { $0.primaryTurnCount == 58 })
        XCTAssertTrue(comparison.pipelines.allSatisfy {
            $0.asrMaximumObservedResidentBytes < 10 * 1_024 * 1_024 * 1_024
                && $0.appleXCTestMaximumObservedResidentBytes < 10 * 1_024 * 1_024 * 1_024
        })
    }

    func testBlindArtifactsMaskEveryPipeline() throws {
        let pipelines = [Self.humanPipeline] + Self.expectedEngines
        let outputs = pipelines.enumerated().map { index, pipeline in
            TranslationOutput(
                pipeline: pipeline,
                sourceKind: pipeline == Self.humanPipeline
                    ? "human-reference-japanese" : "asr-final-japanese",
                corpusID: "fixture",
                turnID: 1,
                confidence: "high",
                overlap: false,
                referenceJapanese: "日本語",
                referenceEnglish: "Japanese",
                sourceJapanese: "日本語",
                english: "candidate \(index)",
                validEnglish: true,
                translationMilliseconds: 1,
                residentBytes: 1,
                error: nil
            )
        }
        let artifacts = blindArtifacts(
            preview: outputs,
            final: outputs,
            seed: "fixture"
        )
        XCTAssertEqual(artifacts.preview.items.first?.candidates.count, 9)
        XCTAssertEqual(artifacts.final.items.first?.candidates.count, 9)
        XCTAssertEqual(artifacts.key.count, 18)
        let encoded = String(data: try JSONEncoder().encode(artifacts.preview), encoding: .utf8)
        XCTAssertFalse(encoded?.contains(Self.expectedEngines[0]) == true)
        XCTAssertFalse(encoded?.contains("referenceEnglish") == true)
    }

    private func loadAndValidateReferences(
        l5: L5Report,
        root: URL
    ) throws -> [String: ReferenceTurn] {
        var references: [String: ReferenceTurn] = [:]
        for corpus in l5.corpora {
            let manifestURL = root.appendingPathComponent(
                "docs/japanese-live/corpora/\(corpus.corpusID)/manifest.json"
            )
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            guard try JapaneseBenchmarkSupport.sha256(at: manifestURL)
                    == corpus.manifestSHA256,
                  manifest.fixture.sha256 == corpus.audioSHA256,
                  manifest.annotations.status.rawValue == corpus.annotationStatus else {
                throw inputError("L5 corpus provenance mismatch for \(corpus.corpusID).")
            }
            let selected = Set(corpus.selectedTurnIDs)
            for turn in manifest.annotations.turns where selected.contains(turn.id) {
                let key = itemKey(corpusID: corpus.corpusID, turnID: turn.id)
                guard references[key] == nil else {
                    throw inputError("Duplicate reference \(key).")
                }
                references[key] = ReferenceTurn(
                    corpusID: corpus.corpusID,
                    turnID: turn.id,
                    confidence: turn.confidence.rawValue,
                    overlap: turn.overlap ?? false,
                    japanese: turn.japanese,
                    english: turn.english
                )
            }
        }
        return references
    }

    private func validate(
        l5: L5Report,
        references: [String: ReferenceTurn]
    ) throws {
        guard l5.schemaVersion == 6,
              l5.scope == "stress",
              !l5.worktreeDirty,
              l5.modelHubOfflineMode,
              l5.externalNetworkAccessDenied,
              l5.corpora.map(\.corpusID) == ["qudu2fx3ncc", "md62mmdz0m"],
              l5.corpora.allSatisfy({
                  $0.selectedTurnIDs == Self.expectedStressTurnIDs[$0.corpusID]
              }),
              l5.engines.map(\.engine) == Self.expectedEngines,
              references.count == 92 else {
            throw inputError("L5 report is not the clean, fixed schema-6 stress run.")
        }
        let expectedKeys = Set(references.keys)
        for engine in l5.engines {
            let keys = Set(engine.turns.map {
                itemKey(corpusID: $0.corpusID, turnID: $0.turnID)
            })
            guard engine.status == "execution-complete",
                  engine.setupError == nil,
                  engine.turns.count == 92,
                  keys == expectedKeys,
                  engine.turns.allSatisfy({ $0.asrError == nil }) else {
                throw inputError("Incomplete L5 engine \(engine.engine).")
            }
            for turn in engine.turns {
                let key = itemKey(corpusID: turn.corpusID, turnID: turn.turnID)
                guard let reference = references[key],
                      turn.confidence == reference.confidence,
                      turn.overlap == reference.overlap,
                      turn.referenceJapanese == reference.japanese else {
                    throw inputError("L5 turn mismatch for \(engine.engine) \(key).")
                }
            }
        }
    }

    private func sourceItems(
        l5: L5Report,
        references: [String: ReferenceTurn]
    ) -> [SourceItem] {
        let orderedReferences = l5.corpora.flatMap { corpus in
            corpus.selectedTurnIDs.compactMap {
                references[itemKey(corpusID: corpus.corpusID, turnID: $0)]
            }
        }
        var items = orderedReferences.map {
            SourceItem(
                pipeline: Self.humanPipeline,
                sourceKind: "human-reference-japanese",
                reference: $0,
                japanese: $0.japanese
            )
        }
        for engine in l5.engines {
            let byKey = Dictionary(uniqueKeysWithValues: engine.turns.map {
                (itemKey(corpusID: $0.corpusID, turnID: $0.turnID), $0)
            })
            items += orderedReferences.map { reference in
                let key = itemKey(corpusID: reference.corpusID, turnID: reference.turnID)
                return SourceItem(
                    pipeline: engine.engine,
                    sourceKind: "asr-final-japanese",
                    reference: reference,
                    japanese: byKey[key]?.hypothesisJapanese ?? ""
                )
            }
        }
        return items
    }

    @available(macOS 26.4, *)
    private func translate(
        _ source: SourceItem,
        service: AppleTranslationService,
        highFidelity: Bool
    ) async -> TranslationOutput {
        let japanese = source.japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !japanese.isEmpty else {
            return translationOutput(
                source,
                japanese: japanese,
                english: "",
                milliseconds: nil,
                error: "empty Japanese source; translation not attempted"
            )
        }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let english = try await translateWithRetry(
                japanese,
                service: service,
                highFidelity: highFidelity
            )
            return translationOutput(
                source,
                japanese: japanese,
                english: english,
                milliseconds: elapsedMilliseconds(since: started),
                error: nil
            )
        } catch {
            return translationOutput(
                source,
                japanese: japanese,
                english: "",
                milliseconds: elapsedMilliseconds(since: started),
                error: error.localizedDescription
            )
        }
    }

    @available(macOS 26.4, *)
    private func translateWithRetry(
        _ japanese: String,
        service: AppleTranslationService,
        highFidelity: Bool
    ) async throws -> String {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                return try EnglishSubtitleValidator.requireEnglish(
                    try await service.translate(japanese, highFidelity: highFidelity)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppleLiveError.emptyTranslation
    }

    private func translationOutput(
        _ source: SourceItem,
        japanese: String,
        english: String,
        milliseconds: Double?,
        error: String?
    ) -> TranslationOutput {
        let valid = error == nil
            && EnglishSubtitleValidator.normalizedEnglish(english) != nil
        return TranslationOutput(
            pipeline: source.pipeline,
            sourceKind: source.sourceKind,
            corpusID: source.reference.corpusID,
            turnID: source.reference.turnID,
            confidence: source.reference.confidence,
            overlap: source.reference.overlap,
            referenceJapanese: source.reference.japanese,
            referenceEnglish: source.reference.english,
            sourceJapanese: japanese,
            english: english,
            validEnglish: valid,
            translationMilliseconds: milliseconds,
            residentBytes: physicalFootprint(),
            error: error
        )
    }

    private func comparisonReport(
        runID: String,
        sourceL5SHA256: String,
        l5: L5Report,
        preview: [TranslationOutput],
        final: [TranslationOutput]
    ) -> ComparisonReport {
        let pipelines = [Self.humanPipeline] + l5.engines.map(\.engine)
        let engineByID = Dictionary(uniqueKeysWithValues: l5.engines.map { ($0.engine, $0) })
        return ComparisonReport(
            schemaVersion: 2,
            runID: runID,
            sourceL5RunID: l5.runID,
            sourceL5SHA256: sourceL5SHA256,
            note: "Both Apple strategies translate a final Japanese string. This measures neither live preview nor endpoint-to-final latency or final immutability. English quality requires two bilingual judges.",
            pipelines: pipelines.map { pipeline in
                let low = primary(preview.filter { $0.pipeline == pipeline })
                let high = primary(final.filter { $0.pipeline == pipeline })
                let lowTimings = low.compactMap { $0.validEnglish
                    ? $0.translationMilliseconds : nil }.sorted()
                let highTimings = high.compactMap { $0.validEnglish
                    ? $0.translationMilliseconds : nil }.sorted()
                let highByKey = Dictionary(uniqueKeysWithValues: high.map {
                    (itemKey(corpusID: $0.corpusID, turnID: $0.turnID), $0)
                })
                let comparable = low.compactMap { item -> Bool? in
                    guard item.validEnglish,
                          let other = highByKey[itemKey(
                            corpusID: item.corpusID,
                            turnID: item.turnID
                          )], other.validEnglish else { return nil }
                    return normalizedEnglish(item.english) != normalizedEnglish(other.english)
                }
                let engine = engineByID[pipeline]
                let nonEmptyLow = low.filter { !$0.sourceJapanese.isEmpty }
                let nonEmptyHigh = high.filter { !$0.sourceJapanese.isEmpty }
                return PipelineComparison(
                    pipeline: pipeline,
                    sourceKind: pipeline == Self.humanPipeline
                        ? "human-reference-japanese" : "asr-final-japanese",
                    japaneseCER: engine?.primaryHighConfidenceCER.rate,
                    japaneseASRP95Milliseconds: engine?.asrP95Milliseconds,
                    primaryEmptySpeechTurnCount:
                        engine?.primaryEmptySpeechTurnCount ?? 0,
                    diagnosticEmptySpeechTurnCount:
                        engine?.diagnosticEmptySpeechTurnCount ?? 0,
                    asrMaximumObservedResidentBytes:
                        engine?.maximumObservedResidentBytes ?? 0,
                    appleXCTestMaximumObservedResidentBytes:
                        (low + high).map(\.residentBytes).max() ?? 0,
                    primaryTurnCount: low.count,
                    primarySourceNonEmptyCount: nonEmptyLow.count,
                    previewTranslationAttemptCount: nonEmptyLow.count,
                    previewTranslationSuccessCount: nonEmptyLow.filter(\.validEnglish).count,
                    previewTranslationSuccessRate: coverage(nonEmptyLow),
                    previewPipelineCoverageIncludingASROmissions: coverage(low),
                    previewTranslationP50Milliseconds: percentile(lowTimings, 0.50),
                    previewTranslationP95Milliseconds: percentile(lowTimings, 0.95),
                    previewTranslationWorstMilliseconds: lowTimings.last,
                    finalTranslationAttemptCount: nonEmptyHigh.count,
                    finalTranslationSuccessCount: nonEmptyHigh.filter(\.validEnglish).count,
                    finalTranslationSuccessRate: coverage(nonEmptyHigh),
                    finalPipelineCoverageIncludingASROmissions: coverage(high),
                    finalTranslationP50Milliseconds: percentile(highTimings, 0.50),
                    finalTranslationP95Milliseconds: percentile(highTimings, 0.95),
                    finalTranslationWorstMilliseconds: highTimings.last,
                    previewToFinalChangeRate: comparable.isEmpty ? nil
                        : Double(comparable.filter { $0 }.count) / Double(comparable.count),
                    referenceEnglishPresentCount: high.filter {
                        $0.referenceEnglish?.isEmpty == false
                    }.count,
                    qualityReviewStatus: "pending-two-bilingual-judges",
                    verdict: verdict(pipeline)
                )
            }
        )
    }

    private func blindArtifacts(
        preview: [TranslationOutput],
        final: [TranslationOutput],
        seed: String
    ) -> (preview: BlindReport, final: BlindReport, key: [String: String]) {
        var key: [String: String] = [:]
        func build(_ kind: String, outputs: [TranslationOutput]) -> BlindReport {
            let grouped = Dictionary(grouping: primary(outputs)) {
                itemKey(corpusID: $0.corpusID, turnID: $0.turnID)
            }
            let orderedKeys = grouped.keys.sorted()
            let items = orderedKeys.enumerated().map { itemIndex, itemKeyValue in
                let values = JapaneseBenchmarkSupport.blindOrder(
                    grouped[itemKeyValue] ?? [],
                    seed: seed + kind,
                    itemID: itemIndex,
                    identity: { $0.pipeline }
                )
                let candidates = values.enumerated().map { index, output in
                    let alias = String(UnicodeScalar(65 + index)!)
                    key["\(kind):\(itemKeyValue):\(alias)"] = output.pipeline
                    return BlindCandidate(
                        alias: alias,
                        english: output.english,
                        missing: !output.validEnglish,
                        fidelityScore1To5: nil,
                        naturalnessScore1To5: nil,
                        criticalError: nil
                    )
                }
                let first = values[0]
                return BlindItem(
                    corpusID: first.corpusID,
                    turnID: first.turnID,
                    referenceJapanese: first.referenceJapanese,
                    candidates: candidates
                )
            }
            return BlindReport(
                schemaVersion: 2,
                kind: kind,
                note: kind == "preview-strategy-isolation"
                    ? "These are lowLatency translations of final Japanese strings, not live previews. Judge fidelity and naturalness separately."
                    : "These are highFidelity translations of final Japanese strings, not end-to-end final timing or immutability proofs. Judge fidelity and naturalness separately.",
                items: items
            )
        }
        return (
            build("preview-strategy-isolation", outputs: preview),
            build("final", outputs: final),
            key
        )
    }

    private func write(
        preview: TranslationReport,
        final: TranslationReport,
        comparison: ComparisonReport,
        blind: (preview: BlindReport, final: BlindReport, key: [String: String]),
        root: URL
    ) throws {
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(preview.runID)",
            isDirectory: true
        )
        let blindOutput = output.appendingPathComponent("blind-review", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blindOutput,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifacts: [(URL, Data)] = [
            (output.appendingPathComponent("en-preview.json"), try encoder.encode(preview)),
            (output.appendingPathComponent("en-final.json"), try encoder.encode(final)),
            (output.appendingPathComponent("comparison.json"), try encoder.encode(comparison)),
            (blindOutput.appendingPathComponent("preview.json"), try encoder.encode(blind.preview)),
            (blindOutput.appendingPathComponent("final.json"), try encoder.encode(blind.final)),
            (blindOutput.appendingPathComponent("key.json"), try encoder.encode(blind.key)),
            (output.appendingPathComponent("report-fr.md"), Data(frenchReport(
                comparison,
                translationReport: preview
            ).utf8)),
        ]
        for (url, data) in artifacts {
            try data.write(to: url, options: .atomic)
            print("[JapaneseEnglishL6] wrote \(url.path)")
        }
    }

    private func frenchReport(
        _ report: ComparisonReport,
        translationReport: TranslationReport
    ) -> String {
        var lines = [
            "# L6 — Apple anglais sur sources finales",
            "",
            "Run `\(report.runID)`, commit `\(translationReport.gitCommit)`, worktree "
                + (translationReport.worktreeDirty ? "modifié" : "propre") + ".",
            "macOS `\(translationReport.macOSVersion)` build `\(translationReport.macOSBuild)`.",
            "Source L5 `\(translationReport.sourceL5RunID)` SHA-256 `\(translationReport.sourceL5SHA256)`.",
            "Réseau distant du processus XCTest : "
                + (translationReport.remoteNetworkDeniedForXCTest
                    ? "interdit; les IPC et le loopback restent autorisés."
                    : "autorisé."),
            "",
            "> Les deux stratégies traduisent ici un texte japonais final. Ce n'est ni une preview live, ni une mesure après fin de parole, ni une preuve d'immuabilité produit.",
            "",
            "| Pipeline | CER japonais | Vides high/diag | Source présente | Succès Apple low | Couverture pipeline low | p95 low seul | Succès Apple high | Couverture pipeline high | p95 high seul | Low→high modifié | Qualité | Verdict |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
        ]
        for row in report.pipelines {
            lines.append(
                "| \(row.pipeline) | \(percent(row.japaneseCER)) "
                    + "| \(row.primaryEmptySpeechTurnCount)/"
                    + "\(row.diagnosticEmptySpeechTurnCount) "
                    + "| \(row.primarySourceNonEmptyCount)/\(row.primaryTurnCount) "
                    + "| \(percent(row.previewTranslationSuccessRate)) "
                    + "| \(percent(row.previewPipelineCoverageIncludingASROmissions)) "
                    + "| \(milliseconds(row.previewTranslationP95Milliseconds)) "
                    + "| \(percent(row.finalTranslationSuccessRate)) "
                    + "| \(percent(row.finalPipelineCoverageIncludingASROmissions)) "
                    + "| \(milliseconds(row.finalTranslationP95Milliseconds)) "
                    + "| \(percent(row.previewToFinalChangeRate)) "
                    + "| en attente de 2 juges | \(row.verdict) |"
            )
        }
        lines += [
            "",
            "Les fichiers aveugles montrent le japonais, pas l'anglais de référence non validé. La vraie preview PCM et le final end-to-end sont mesurés dans la phase live de L6.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private func primary(_ outputs: [TranslationOutput]) -> [TranslationOutput] {
        outputs.filter { $0.confidence == "high" && !$0.overlap }
    }

    private func coverage(_ outputs: [TranslationOutput]) -> Double {
        guard !outputs.isEmpty else { return 0 }
        return Double(outputs.filter(\.validEnglish).count) / Double(outputs.count)
    }

    private func verdict(_ pipeline: String) -> String {
        switch pipeline {
        case Self.humanPipeline: "contrôle traduction"
        case "whisper-large-v3-turbo": "témoin L5; live à mesurer"
        case "whispermlx-v3.12.2-turbo": "arrêté L5; diagnostic traduction"
        default: "écarté L5; diagnostic traduction"
        }
    }

    private func normalizedEnglish(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        )
        return sorted[index]
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.2f %%", $0 * 100) } ?? "n/a"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "n/a"
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func itemKey(corpusID: String, turnID: Int) -> String {
        "\(corpusID):\(turnID)"
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

    private func inputError(_ message: String) -> NSError {
        NSError(
            domain: "JapaneseEnglishL6",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
