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

    func testWhisperKitLaunchNeedsIndependentWeaknessAndMaterialDisagreement() {
        let segment = testSegment()
        let healthyQwen = HighQualityASRExchange(
            rawTranscript: "これは正常な文章です",
            chunks: []
        )
        let differentParakeet = HighQualityASRExchange(
            rawTranscript: "まったく異なる文章です",
            chunks: [],
            tokenTimings: [.init(
                text: "まったく異なる文章です",
                tokenIDs: [1],
                sourceStart: 0,
                sourceEnd: 4,
                confidence: 0.9
            )],
            confidence: 0.9
        )

        XCTAssertEqual(
            HighQualityAdaptiveASR.whisperKitLaunch(
                segment: segment,
                qwen: healthyQwen,
                parakeet: differentParakeet,
                scopedTerms: [],
                calibration: stableWhisperKitCalibration(),
                qwenParakeetFallback: .insufficientMargin
            ).reason,
            .qwenNotSuspect
        )

        let weakQwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15),
            chunks: []
        )
        let launch = HighQualityAdaptiveASR.whisperKitLaunch(
            segment: segment,
            qwen: weakQwen,
            parakeet: differentParakeet,
            scopedTerms: [],
            calibration: stableWhisperKitCalibration(),
            qwenParakeetFallback: .insufficientMargin
        )
        XCTAssertTrue(launch.shouldLaunch)
        XCTAssertEqual(launch.reason, .unresolvedMaterialDisagreement)
        XCTAssertGreaterThanOrEqual(launch.normalizedDisagreement ?? 0, 0.15)

        let mereDifference = HighQualityAdaptiveASR.whisperKitLaunch(
            segment: segment,
            qwen: weakQwen,
            parakeet: .init(
                rawTranscript: weakQwen.rawTranscript + "。",
                chunks: [],
                tokenTimings: [.init(
                    text: weakQwen.rawTranscript + "。",
                    tokenIDs: [1],
                    sourceStart: 0,
                    sourceEnd: 4,
                    confidence: 0.9
                )],
                confidence: 0.9
            ),
            scopedTerms: [],
            calibration: stableWhisperKitCalibration(),
            qwenParakeetFallback: .insufficientMargin
        )
        XCTAssertFalse(mereDifference.shouldLaunch)
        XCTAssertEqual(mereDifference.reason, .disagreementBelowThreshold)

        let unstable = HighQualityAdaptiveASR.whisperKitLaunch(
            segment: segment,
            qwen: weakQwen,
            parakeet: differentParakeet,
            scopedTerms: [],
            calibration: .developmentV1,
            qwenParakeetFallback: .unstableCalibration
        )
        XCTAssertEqual(unstable.reason, .unstableCalibration)

        let resolved = HighQualityAdaptiveASR.whisperKitLaunch(
            segment: segment,
            qwen: weakQwen,
            parakeet: differentParakeet,
            scopedTerms: [],
            calibration: stableWhisperKitCalibration(),
            qwenParakeetFallback: nil
        )
        XCTAssertEqual(resolved.reason, .qwenParakeetDecisionResolved)
    }

    func testEmptyZeroCoverageOrUnmappedTimingCannotLaunchWhisperKit() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15),
            chunks: []
        )
        let fixtures = [
            HighQualityASRExchange(
                rawTranscript: "別の仮説です",
                chunks: [],
                wordTimings: [],
                confidence: 0.9
            ),
            HighQualityASRExchange(
                rawTranscript: "別の仮説です",
                chunks: [],
                wordTimings: [.init(
                    text: "別の仮説です", tokenIDs: [1],
                    sourceStart: 1, sourceEnd: 1, confidence: 0.9
                )],
                confidence: 0.9
            ),
            HighQualityASRExchange(
                rawTranscript: "別の仮説です",
                chunks: [],
                wordTimings: [.init(
                    text: "対応しない文字列", tokenIDs: [1],
                    sourceStart: 0, sourceEnd: 1, confidence: 0.9
                )],
                confidence: 0.9
            ),
        ]

        for fixture in fixtures {
            XCTAssertEqual(
                HighQualityAdaptiveASR.whisperKitLaunch(
                    segment: segment,
                    qwen: qwen,
                    parakeet: fixture,
                    scopedTerms: [],
                    calibration: stableWhisperKitCalibration(),
                    qwenParakeetFallback: .insufficientMargin
                ).reason,
                .missingParakeetEvidence
            )
        }
    }

    func testWhisperKitAuditExplainsEveryNonLaunch() {
        let segment = testSegment()
        let healthy = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: .init(rawTranscript: "これは正常な文章です", chunks: []),
            qwenDuration: 1,
            parakeet: nil,
            parakeetDuration: nil,
            scopedTerms: [],
            calibration: .developmentV1
        )
        XCTAssertEqual(healthy.whisperKitLaunch?.reason, .qwenNotSuspect)
        XCTAssertEqual(healthy.whisperKitDisposition, .notLaunched)

        let suspect = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: .init(rawTranscript: String(repeating: "はい", count: 15), chunks: []),
            qwenDuration: 1,
            parakeet: nil,
            parakeetDuration: nil,
            scopedTerms: [],
            calibration: .developmentV1
        )
        XCTAssertEqual(suspect.whisperKitLaunch?.reason, .missingParakeetEvidence)
        XCTAssertEqual(suspect.whisperKitDisposition, .notLaunched)
    }

    func testThreePassSelectorChoosesOneCompleteWhisperKitHypothesis() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15),
            chunks: []
        )
        let parakeet = timedParakeet("こちらも決め手に欠ける文章です")
        let whisperKit = timedWhisperKit("WhisperKitの完全な仮説です", logProbability: -0.1)

        let decision = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: qwen,
            qwenDuration: 1,
            parakeet: parakeet,
            parakeetDuration: 0.5,
            whisperKit: whisperKit,
            whisperKitDuration: 0.8,
            scopedTerms: [],
            calibration: stableWhisperKitCalibration()
        )

        XCTAssertEqual(decision.executedBackends, [.qwenJA, .parakeetJA, .whisperKit])
        XCTAssertEqual(decision.selectedBackend, .whisperKit)
        XCTAssertEqual(decision.selectedText, whisperKit.rawTranscript)
        XCTAssertEqual(decision.whisperKit, whisperKit)
        XCTAssertEqual(decision.whisperKitDisposition, .override)
        XCTAssertNil(decision.fallbackReason)
    }

    func testThreePassSelectorFallsBackToQwenOnMissingEvidenceMarginOrVeto() {
        let segment = testSegment()
        let qwen = HighQualityASRExchange(
            rawTranscript: String(repeating: "はい", count: 15) + "42",
            chunks: []
        )
        let parakeet = timedParakeet("こちらは別の仮説ですが42を保ちます")
        let missingTiming = HighQualityASRExchange(
            rawTranscript: "完全な別仮説42",
            chunks: [],
            averageLogProbability: -0.1
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.decide(
                segment: segment,
                qwen: qwen,
                qwenDuration: 1,
                parakeet: parakeet,
                parakeetDuration: 0.5,
                whisperKit: missingTiming,
                whisperKitDuration: 0.8,
                scopedTerms: [],
                calibration: stableWhisperKitCalibration()
            ).fallbackReason,
            .missingEvidence
        )

        let insufficient = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: qwen,
            qwenDuration: 1,
            parakeet: parakeet,
            parakeetDuration: 0.5,
            whisperKit: timedWhisperKit("完全な別仮説42", logProbability: -0.1),
            whisperKitDuration: 0.8,
            scopedTerms: [],
            calibration: stableWhisperKitCalibration(minimumMargin: 1)
        )
        XCTAssertEqual(insufficient.selectedBackend, .qwenJA)
        XCTAssertEqual(insufficient.fallbackReason, .insufficientMargin)

        let vetoed = HighQualityAdaptiveASR.decide(
            segment: segment,
            qwen: qwen,
            qwenDuration: 1,
            parakeet: parakeet,
            parakeetDuration: 0.5,
            whisperKit: timedWhisperKit("完全な別仮説", logProbability: -0.1),
            whisperKitDuration: 0.8,
            scopedTerms: [],
            calibration: stableWhisperKitCalibration()
        )
        XCTAssertEqual(vetoed.selectedBackend, .qwenJA)
        XCTAssertEqual(vetoed.fallbackReason, .integrityVeto)
        XCTAssertEqual(vetoed.whisperKitVetoes, [.lostNumber])
        XCTAssertEqual(vetoed.whisperKitDisposition, .veto)
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

    func testAdaptiveJobRunsTargetedWhisperKitLastAndTranslatesOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = AdaptiveASRCallLog()
        let qwen = String(repeating: "はい", count: 15)
        let whisperKit = "こちらは第三候補が生成した十分に長い正しい仮説文章です"
        let job = HighQualityJob(servicesForBackend: { backend in
            HighQualityJob.Services(
                loadSource: { _ in Array(repeating: 0.01, count: 4 * 16_000) },
                prepareASR: { _ in await calls.append("prepare-\(backend.rawValue)") },
                transcribeJapanese: { _ in "" },
                transcribeJapaneseEvidence: { samples in
                    await calls.append("transcribe-\(backend.rawValue)-\(samples.count)")
                    switch backend {
                    case .qwenJA:
                        return .init(rawTranscript: qwen, chunks: [])
                    case .parakeetJA:
                        return self.timedParakeet(
                            "こちらはパラキートが生成した十分に長い別の仮説文章です"
                        )
                    case .whisperKit:
                        return self.timedWhisperKit(whisperKit, logProbability: -0.1)
                    default:
                        XCTFail("Unexpected adaptive backend: \(backend)")
                        return .init(rawTranscript: "", chunks: [])
                    }
                },
                unloadASR: { await calls.append("unload-\(backend.rawValue)") },
                prepareAlignment: { _ in await calls.append("prepare-alignment") },
                alignJapanese: { samples, turns in
                    await calls.append("align")
                    return .init(
                        chunks: [.init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: Double(samples.count) / 16_000,
                            cues: turns.map {
                                .init(
                                    id: $0.id,
                                    text: $0.japanese,
                                    start: 0,
                                    end: Double(samples.count) / 16_000
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
            adaptiveCalibration: stableWhisperKitCalibration(),
            outputRoot: root
        ))

        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [
            "prepare-qwen-ja",
            "transcribe-qwen-ja-64000",
            "unload-qwen-ja",
            "prepare-parakeet-ja",
            "transcribe-parakeet-ja-64000",
            "unload-parakeet-ja",
            "prepare-whisperkit",
            "transcribe-whisperkit-64000",
            "unload-whisperkit",
            "prepare-alignment",
            "align",
            "unload-alignment",
            "prepare-translation",
            "translate",
            "unload-translation",
        ])
        XCTAssertEqual(result.japaneseTranscript, whisperKit)
        let decision = try XCTUnwrap(result.evidence.adaptiveASR?.decisions.first)
        XCTAssertEqual(decision.executedBackends, [.qwenJA, .parakeetJA, .whisperKit])
        XCTAssertEqual(decision.selectedBackend, .whisperKit)
        XCTAssertEqual(decision.whisperKitDisposition, .override)
        XCTAssertEqual(result.evidence.adaptiveASR?.workers.map(\.model.backend), [])
    }

    func testAdaptiveJobAuditsThreeInvalidWhisperKitTimingsAndTranslatesOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = AdaptiveASRCallLog()
        let qwen = String(repeating: "はい", count: 15)
        let job = HighQualityJob(servicesForBackend: { backend in
            HighQualityJob.Services(
                loadSource: { _ in Array(repeating: 0.01, count: 20 * 16_000) },
                prepareASR: { _ in await calls.append("prepare-\(backend.rawValue)") },
                transcribeJapanese: { _ in "" },
                transcribeJapaneseEvidence: { _ in
                    await calls.append("transcribe-\(backend.rawValue)")
                    switch backend {
                    case .qwenJA:
                        return .init(rawTranscript: qwen, chunks: [])
                    case .parakeetJA:
                        return self.timedParakeet("別の候補仮説です")
                    case .whisperKit:
                        throw HighQualityASRWorkerError.invalidCandidateEvidence(
                            .invalidTimestamps
                        )
                    default:
                        XCTFail("Unexpected adaptive backend: \(backend)")
                        return .init(rawTranscript: "", chunks: [])
                    }
                },
                unloadASR: { await calls.append("unload-\(backend.rawValue)") },
                prepareAlignment: { _ in },
                alignJapanese: { samples, turns in
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
                unloadAlignment: {},
                prepareTranslation: { _ in await calls.append("prepare-translation") },
                translateEnglish: { batch in
                    await calls.append("translate")
                    let rows = batch.turns.map {
                        ["id": $0.id, "text": "English \($0.id)"]
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "translations": rows,
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
            adaptiveCalibration: stableWhisperKitCalibration(),
            outputRoot: root
        ))

        let audit = try XCTUnwrap(result.evidence.adaptiveASR)
        XCTAssertEqual(audit.decisions.count, 3)
        XCTAssertEqual(audit.errors.count, 3)
        XCTAssertTrue(audit.errors.allSatisfy { $0.route == .candidate })
        XCTAssertTrue(audit.errors.allSatisfy {
            $0.candidateReason == .invalidTimestamps
        })
        XCTAssertTrue(audit.decisions.allSatisfy {
            $0.selectedBackend == .qwenJA
                && $0.whisperKitDisposition == .failure
                && $0.whisperKitError?.route == .candidate
        })
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls.filter { $0 == "transcribe-whisperkit" }.count, 3)
        XCTAssertEqual(recordedCalls.filter { $0 == "prepare-translation" }.count, 1)
        XCTAssertEqual(recordedCalls.filter { $0 == "unload-translation" }.count, 1)
    }

    func testAdaptiveJobAuditsParakeetFailureAndKeepsQwen() async throws {
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
                    if backend == .parakeetJA {
                        throw HighQualityASRWorkerError.invalidCandidateEvidence(
                            .invalidHypothesis
                        )
                    }
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

    func testAdaptiveJobPersistsPartialAuditForCandidateInfrastructureFailures() async throws {
        enum FailureKind: Sendable { case protocolFailure, ioWrite, unknown }
        struct UnknownFailure: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let qwen = String(repeating: "はい", count: 15)
        let scenarios: [(HighQualityASRBackend, FailureKind)] = [
            (.parakeetJA, .protocolFailure),
            (.whisperKit, .protocolFailure),
            (.whisperKit, .ioWrite),
            (.whisperKit, .unknown),
        ]
        for (failingBackend, failureKind) in scenarios {
            let jobID = UUID()
            let calls = AdaptiveASRCallLog()
            let job = HighQualityJob(servicesForBackend: { backend in
                .init(
                    loadSource: { _ in Array(repeating: 0.01, count: 4 * 16_000) },
                    prepareASR: { _ in },
                    transcribeJapanese: { _ in "" },
                    transcribeJapaneseEvidence: { _ in
                        await calls.append("transcribe-\(backend.rawValue)")
                        if backend == failingBackend {
                            switch failureKind {
                            case .protocolFailure:
                                throw HighQualityASRWorkerError.protocolFailure("bad JSON")
                            case .ioWrite:
                                throw CocoaError(.fileWriteNoPermission)
                            case .unknown:
                                throw UnknownFailure()
                            }
                        }
                        switch backend {
                        case .qwenJA: return .init(rawTranscript: qwen, chunks: [])
                        case .parakeetJA: return self.timedParakeet("別の候補仮説です")
                        default: return .init(rawTranscript: "", chunks: [])
                        }
                    },
                    unloadASR: {},
                    prepareTranslation: { _ in await calls.append("prepare-translation") },
                    translateEnglish: { _ in
                        await calls.append("translate")
                        throw CocoaError(.fileReadCorruptFile)
                    },
                    unloadTranslation: { await calls.append("unload-translation") }
                )
            })

            do {
                _ = try await job.run(.init(
                    id: jobID,
                    sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                    deliverables: [.japaneseTranscript, .englishTranslationTranscript],
                    asrMode: .adaptiveQwenParakeet,
                    adaptiveCalibration: stableWhisperKitCalibration(),
                    outputRoot: root
                ))
                XCTFail("A protocol failure must abort the public job.")
            } catch {
                XCTAssertNotNil((error as? HighQualityJobError)?.resultDirectory)
            }
            let directory = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                HighQualityJobManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            )
            let evidence = try decoder.decode(
                HighQualityRawEvidence.self,
                from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
            )
            XCTAssertEqual(manifest.status, .failed)
            XCTAssertEqual(manifest.failures.map(\.stage), [.asr])
            XCTAssertEqual(evidence.rawASR, qwen)
            let audit = try XCTUnwrap(evidence.adaptiveASR)
            XCTAssertEqual(audit.decisions.count, 1)
            XCTAssertEqual(audit.errors.count, 1)
            XCTAssertEqual(audit.errors.first?.route, .infrastructure)
            XCTAssertEqual(audit.errors.first?.stage, "\(failingBackend.rawValue)-transcription")
            let decisionError = failingBackend == .parakeetJA
                ? audit.decisions.first?.error : audit.decisions.first?.whisperKitError
            XCTAssertEqual(decisionError, audit.errors.first)
            XCTAssertNil(evidence.translation)
            XCTAssertEqual(
                Set(manifest.generatedFiles.map(\.path)),
                ["manifest.json", "raw-asr.json"]
            )
            let recordedCalls = await calls.values
            XCTAssertFalse(recordedCalls.contains("prepare-translation"))
            XCTAssertFalse(recordedCalls.contains("translate"))
        }
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
            .infrastructure
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(
                HighQualityASRWorkerError.invalidCandidateEvidence(.invalidTimestamps)
            ),
            .candidate
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(
                HighQualityASRWorkerError.invalidCandidateEvidence(.unusableTimingMapping)
            ),
            .candidate
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(
                HighQualityASRWorkerError.invalidCandidateEvidence(.invalidHypothesis)
            ),
            .candidate
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(CancellationError()),
            .infrastructure
        )
        XCTAssertEqual(
            HighQualityAdaptiveASR.route(CocoaError(.fileWriteNoPermission)),
            .infrastructure
        )
        struct UnknownError: Error {}
        XCTAssertEqual(HighQualityAdaptiveASR.route(UnknownError()), .infrastructure)
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

    private func stableWhisperKitCalibration(
        minimumMargin: Double = 0.1
    ) -> HighQualityAdaptiveASRCalibration {
        .init(
            version: "test-whisperkit-dev-v1",
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
                worstObservedDefect: 0.1,
                developmentSamples: 20,
                validationBlocks: 5,
                stable: true
            ),
            whisperKit: .init(
                backend: .whisperKit,
                bestObservedDefect: 0,
                worstObservedDefect: 1,
                developmentSamples: 13,
                validationBlocks: 5,
                stable: true
            ),
            minimumMargin: minimumMargin,
            tieTolerance: 0.01,
            stableAcrossBlocks: true
        )
    }

    private func timedParakeet(_ text: String) -> HighQualityASRExchange {
        .init(
            rawTranscript: text,
            chunks: [],
            tokenTimings: [.init(
                text: text,
                tokenIDs: [1],
                sourceStart: 0,
                sourceEnd: 4,
                confidence: 0.9
            )],
            confidence: 0.9
        )
    }

    private func timedWhisperKit(
        _ text: String,
        logProbability: Double
    ) -> HighQualityASRExchange {
        .init(
            rawTranscript: text,
            chunks: [],
            wordTimings: [.init(
                text: text,
                tokenIDs: [2],
                sourceStart: 0,
                sourceEnd: 4,
                confidence: 0.9
            )],
            averageLogProbability: logProbability
        )
    }
}

private actor AdaptiveASRCallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
