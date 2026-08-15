import XCTest
@testable import WhisperASRApp

final class HighQualityAdaptiveASRTests: XCTestCase {
    func testAdaptiveModeUsesShortAcousticSegmentsWithoutChangingTheDefault() {
        var samples = [Float](repeating: 0.01, count: 20 * 16_000)
        samples.replaceSubrange(
            (8 * 16_000)..<(8 * 16_000 + 320),
            with: repeatElement(0, count: 320)
        )

        let segments = HighQualityAdaptiveASR.plan(samples: samples)

        XCTAssertEqual(HighQualityASRMode.productDefault, .backend(.qwenJA))
        XCTAssertEqual(
            HighQualityASRMode.selectableCases,
            HighQualityASRBackend.allCases.map(HighQualityASRMode.backend)
        )
        XCTAssertFalse(HighQualityASRMode.selectableCases.contains(.adaptiveQwenParakeet))
        XCTAssertTrue(
            HighQualityASRMode.adaptiveQwenParakeet.detail?.contains("coût") == true
        )
        XCTAssertEqual(segments.first?.startSample, 0)
        XCTAssertEqual(segments.last?.endSample, samples.count)
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy {
            $0.endSample == $1.startSample
        })
        XCTAssertTrue(segments.allSatisfy {
            $0.endSample - $0.startSample <= 8 * 16_000
        })
    }

    func testRuntimeDetectorReportsAuditableWeaknessSignals() throws {
        let segment = HighQualityAdaptiveASRSegment(
            id: "segment-0001",
            startSample: 0,
            endSample: 4 * 16_000,
            rmsDBFS: -24,
            activeFrameRatio: 0.8
        )
        let empty = HighQualityAdaptiveASR.assess(
            qwen: .init(
                rawTranscript: "",
                chunks: [],
                diagnostics: .init(emptyOutput: true)
            ),
            segment: segment,
            scopedTerms: []
        )
        XCTAssertEqual(
            Set(empty.signals),
            [.speechWithEmptyText, .abnormalTextAudioCompression]
        )

        let protected = HighQualityAdaptiveASR.assess(
            qwen: .init(
                rawTranscript: "立川は42回成功しました",
                chunks: [],
                wordTimings: [.init(
                    text: "立川",
                    tokenIDs: [1],
                    sourceStart: 0,
                    sourceEnd: 0.2,
                    confidence: nil
                )]
            ),
            segment: segment,
            scopedTerms: ["立川"]
        )
        XCTAssertEqual(
            Set(protected.signals),
            [.incompleteTimingCoverage, .questionableNumber, .questionableScopedTerm]
        )

        let repeated = HighQualityAdaptiveASR.assess(
            qwen: .init(rawTranscript: String(repeating: "はい", count: 15), chunks: []),
            segment: segment,
            scopedTerms: []
        )
        XCTAssertEqual(Set(repeated.signals), [.degenerateRepetition])
        XCTAssertTrue(empty.isSuspect && protected.isSuspect && repeated.isSuspect)

        let silence = HighQualityAdaptiveASR.assess(
            qwen: .init(rawTranscript: "", chunks: []),
            segment: .init(
                id: "segment-0002",
                startSample: 0,
                endSample: 4 * 16_000,
                rmsDBFS: -120,
                activeFrameRatio: 0
            ),
            scopedTerms: []
        )
        XCTAssertFalse(silence.isSuspect)
    }

    func testSelectorUsesSeparateCalibrationsAndOneWholeHypothesis() throws {
        let segment = HighQualityAdaptiveASRSegment(
            id: "segment-0001",
            startSample: 0,
            endSample: 4 * 16_000,
            rmsDBFS: -24,
            activeFrameRatio: 0.8
        )
        let qwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15),
            chunks: []
        )
        let parakeet = HighQualityASRExchange(
            rawTranscript: "正常な文章です",
            chunks: [],
            confidence: 0.95
        )
        let calibration = HighQualityAdaptiveASRCalibration(
            version: "test-dev-v1",
            qwen: .init(
                backend: .qwenJA,
                bestObservedDefect: 0,
                worstObservedDefect: 4,
                developmentSamples: 40,
                validationBlocks: 5,
                stable: true
            ),
            parakeet: .init(
                backend: .parakeetJA,
                bestObservedDefect: 0,
                worstObservedDefect: 1,
                developmentSamples: 20,
                validationBlocks: 5,
                stable: true
            ),
            minimumMargin: 0.2,
            tieTolerance: 0.01,
            stableAcrossBlocks: true
        )

        let decision = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: qwen,
            qwenDuration: 1.2,
            parakeet: parakeet,
            parakeetDuration: 0.4,
            scopedTerms: [],
            calibration: calibration
        )

        XCTAssertEqual(decision.executedBackends, [.qwenJA, .parakeetJA])
        XCTAssertEqual(decision.selectedBackend, .parakeetJA)
        XCTAssertEqual(decision.selectedText, parakeet.rawTranscript)
        XCTAssertNotEqual(decision.selectedText, qwen.rawTranscript + parakeet.rawTranscript)
        XCTAssertGreaterThan(
            try XCTUnwrap(decision.parakeetCalibratedScore),
            try XCTUnwrap(decision.qwenCalibratedScore)
        )
        XCTAssertNil(decision.fallbackReason)
    }

    func testSelectorFallsBackWhenParakeetLosesProtectedContent() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: "立川は42回成功しました",
            chunks: []
        )
        let parakeet = HighQualityASRExchange(
            rawTranscript: "成功しました",
            chunks: [],
            confidence: 1
        )

        let decision = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: qwen,
            qwenDuration: 1,
            parakeet: parakeet,
            parakeetDuration: 0.5,
            scopedTerms: ["立川"],
            calibration: stableCalibration()
        )

        XCTAssertEqual(Set(decision.vetoes), [.lostNumber, .lostScopedTerm])
        XCTAssertEqual(decision.selectedBackend, .qwenJA)
        XCTAssertEqual(decision.selectedText, qwen.rawTranscript)
        XCTAssertEqual(decision.fallbackReason, .integrityVeto)
    }

    func testIntegrityVetoesCoverEmptyCoverageRepetitionAndDuplication() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: "これは正常な文章です",
            chunks: [],
            wordTimings: [.init(
                text: "これは正常な文章です",
                tokenIDs: [1],
                sourceStart: 0,
                sourceEnd: 4,
                confidence: nil
            )]
        )
        XCTAssertTrue(HighQualityAdaptiveASR.vetoes(
            qwen: qwen,
            parakeet: .init(rawTranscript: "", chunks: []),
            segment: segment,
            scopedTerms: []
        ).contains(.newEmptySpeech))
        XCTAssertTrue(HighQualityAdaptiveASR.vetoes(
            qwen: qwen,
            parakeet: .init(
                rawTranscript: "こちらも正常な文章です",
                chunks: [],
                wordTimings: [.init(
                    text: "こちらも正常な文章です",
                    tokenIDs: [2],
                    sourceStart: 0,
                    sourceEnd: 0.5,
                    confidence: nil
                )]
            ),
            segment: segment,
            scopedTerms: []
        ).contains(.lostCoverage))
        XCTAssertTrue(HighQualityAdaptiveASR.vetoes(
            qwen: qwen,
            parakeet: .init(
                rawTranscript: String(repeating: "はい", count: 15),
                chunks: []
            ),
            segment: segment,
            scopedTerms: []
        ).contains(.degenerateRepetition))
        XCTAssertTrue(HighQualityAdaptiveASR.vetoes(
            qwen: qwen,
            parakeet: .init(rawTranscript: "正常です正常です", chunks: []),
            segment: segment,
            scopedTerms: []
        ).contains(.duplicatedText))
    }

    func testSelectorAbstainsWithoutStableCompleteEvidence() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15),
            chunks: []
        )
        let missingConfidence = HighQualityASRExchange(
            rawTranscript: "正常な文章です",
            chunks: []
        )

        XCTAssertEqual(
            HighQualityAdaptiveASR.decide(
                segment: segment,
                qwen: qwen,
                qwenDuration: 1,
                parakeet: missingConfidence,
                parakeetDuration: 0.5,
                scopedTerms: [],
                calibration: stableCalibration()
            ).fallbackReason,
            .missingEvidence
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.decide(
                segment: segment,
                qwen: qwen,
                qwenDuration: 1,
                parakeet: .init(
                    rawTranscript: "正常な文章です",
                    chunks: [],
                    confidence: 1
                ),
                parakeetDuration: 0.5,
                scopedTerms: [],
                calibration: .developmentV1
            ).fallbackReason,
            .unstableCalibration
        )

        let unstableBackend = HighQualityAdaptiveASRCalibration(
            version: "test-dev-unstable-backend",
            qwen: stableCalibration().qwen,
            parakeet: .init(
                backend: .parakeetJA,
                bestObservedDefect: 0,
                worstObservedDefect: 1,
                developmentSamples: 20,
                validationBlocks: 5,
                stable: false
            ),
            minimumMargin: 0.1,
            tieTolerance: 0.01,
            stableAcrossBlocks: true
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.decide(
                segment: segment,
                qwen: qwen,
                qwenDuration: 1,
                parakeet: .init(
                    rawTranscript: "正常な文章です",
                    chunks: [],
                    confidence: 1
                ),
                parakeetDuration: 0.5,
                scopedTerms: [],
                calibration: unstableBackend
            ).fallbackReason,
            .unstableCalibration
        )
    }

    func testAdaptiveJobRunsQwenFirstParakeetOnlyForSuspectsAndTranslatesOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = AdaptiveASRCallLog()
        let calibration = stableCalibration()
        let job = HighQualityJob(servicesForBackend: { backend in
            HighQualityJob.Services(
                loadSource: { _ in Array(repeating: 0.01, count: 12 * 16_000) },
                prepareASR: { _ in await calls.append("prepare-\(backend.rawValue)") },
                transcribeJapanese: { _ in XCTFail("Adaptive mode must retain ASR evidence."); return "" },
                transcribeJapaneseEvidence: { samples in
                    await calls.append("transcribe-\(backend.rawValue)-\(samples.count)")
                    switch backend {
                    case .qwenJA where samples.count > 4 * 16_000:
                        return .init(rawTranscript: "これは正常な文章です。", chunks: [])
                    case .qwenJA:
                        return .init(
                            rawTranscript: String(repeating: "はい", count: 15),
                            chunks: []
                        )
                    case .parakeetJA:
                        return .init(
                            rawTranscript: "こちらは修正文章です。",
                            chunks: [],
                            confidence: 1
                        )
                    default:
                        XCTFail("Unexpected adaptive backend: \(backend)")
                        return .init(rawTranscript: "", chunks: [])
                    }
                },
                unloadASR: { await calls.append("unload-\(backend.rawValue)") },
                prepareAlignment: { _ in await calls.append("prepare-alignment") },
                alignJapanese: { samples, turns in
                    await calls.append("align")
                    let duration = Double(samples.count) / 16_000
                    let cueDuration = duration / Double(turns.count)
                    return .init(
                        chunks: [.init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: duration,
                            cues: turns.enumerated().map { index, turn in
                                .init(
                                    id: turn.id,
                                    text: turn.japanese,
                                    start: Double(index) * cueDuration,
                                    end: Double(index + 1) * cueDuration
                                )
                            }
                        )],
                        modelID: "fixture-aligner",
                        revision: "fixture",
                        peakMemoryBytes: 0
                    )
                },
                unloadAlignment: { await calls.append("unload-alignment") },
                prepareTranslation: { _ in await calls.append("prepare-translation") },
                translateEnglish: { batch in
                    await calls.append("translate")
                    let translations = batch.turns.map {
                        ["id": $0.id, "text": "English \($0.id)"]
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "translations": translations,
                    ])
                    return .init(
                        model: "fixture-translator",
                        response: String(decoding: data, as: UTF8.self),
                        attempts: []
                    )
                },
                unloadTranslation: { await calls.append("unload-translation") }
            )
        })

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript, .englishTranslationTranscript],
            asrMode: .adaptiveQwenParakeet,
            adaptiveCalibration: calibration,
            outputRoot: root
        ))

        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [
            "prepare-qwen-ja",
            "transcribe-qwen-ja-128000",
            "transcribe-qwen-ja-64000",
            "unload-qwen-ja",
            "prepare-parakeet-ja",
            "transcribe-parakeet-ja-64000",
            "unload-parakeet-ja",
            "prepare-alignment",
            "align",
            "unload-alignment",
            "prepare-translation",
            "translate",
            "unload-translation",
        ])
        XCTAssertEqual(
            result.japaneseTranscript,
            "これは正常な文章です。こちらは修正文章です。"
        )
        XCTAssertEqual(result.manifest.selectedASRMode, .adaptiveQwenParakeet)
        XCTAssertEqual(result.evidence.adaptiveASR?.decisions.count, 2)
        XCTAssertEqual(
            result.evidence.adaptiveASR?.decisions.map(\.selectedBackend),
            [.qwenJA, .parakeetJA]
        )
        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        XCTAssertEqual(
            try HighQualityJob.reopen(saved).evidence.adaptiveASR,
            result.evidence.adaptiveASR
        )
    }

    func testAdaptiveJobAuditsParakeetFailureAndKeepsQwen() async throws {
        struct CandidateError: LocalizedError {
            var errorDescription: String? { "fixture candidate failure" }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let qwenText = String(repeating: "はい", count: 15)
        let job = HighQualityJob(servicesForBackend: { backend in
            .init(
                loadSource: { _ in Array(repeating: 0.01, count: 4 * 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "" },
                transcribeJapaneseEvidence: { _ in
                    if backend == .parakeetJA { throw CandidateError() }
                    return .init(rawTranscript: qwenText, chunks: [])
                },
                unloadASR: {}
            )
        })

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            asrMode: .adaptiveQwenParakeet,
            adaptiveCalibration: stableCalibration(),
            outputRoot: root
        ))

        XCTAssertEqual(result.japaneseTranscript, qwenText)
        XCTAssertEqual(
            result.evidence.adaptiveASR?.decisions.first?.fallbackReason,
            .alternateFailure
        )
        XCTAssertEqual(
            result.evidence.adaptiveASR?.errors.first?.route,
            .candidate
        )
    }

    func testAdaptiveJobChecksCancellationBetweenSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = AdaptiveASRCallLog()
        let job = HighQualityJob(servicesForBackend: { _ in
            .init(
                loadSource: { _ in Array(repeating: 0.01, count: 12 * 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "" },
                transcribeJapaneseEvidence: { _ in
                    await calls.append("transcribe")
                    if await calls.values.count == 1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return .init(rawTranscript: "正常な文章です。", chunks: [])
                },
                unloadASR: {}
            )
        })

        do {
            _ = try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                asrMode: .adaptiveQwenParakeet,
                outputRoot: root
            ))
            XCTFail("Cancellation must stop the adaptive segment loop.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }
        let transcriptionCount = await calls.values.filter { $0 == "transcribe" }.count
        XCTAssertEqual(transcriptionCount, 1)
    }

    func testErrorRoutingSeparatesInfrastructureFromCandidateFailures() {
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(HighQualityASRWorkerError.protocolFailure("bad JSON")),
            .infrastructure
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(HighQualityASRWorkerError.backendFailure("model")),
            .candidate
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(CancellationError()),
            .infrastructure
        )
    }

    private func testSegment() -> HighQualityAdaptiveASRSegment {
        .init(
            id: "segment-0001",
            startSample: 0,
            endSample: 4 * 16_000,
            rmsDBFS: -24,
            activeFrameRatio: 0.8
        )
    }

    private func stableCalibration() -> HighQualityAdaptiveASRCalibration {
        .init(
            version: "test-dev-v1",
            qwen: .init(
                backend: .qwenJA,
                bestObservedDefect: 0,
                worstObservedDefect: 1,
                developmentSamples: 40,
                validationBlocks: 5,
                stable: true
            ),
            parakeet: .init(
                backend: .parakeetJA,
                bestObservedDefect: 0,
                worstObservedDefect: 1,
                developmentSamples: 20,
                validationBlocks: 5,
                stable: true
            ),
            minimumMargin: 0.1,
            tieTolerance: 0.01,
            stableAcrossBlocks: true
        )
    }
}

private actor AdaptiveASRCallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
