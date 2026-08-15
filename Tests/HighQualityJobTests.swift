import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityJobTests: XCTestCase {
    func testReadableSubtitleBetaControlsVisibilityAndSafeDefault() {
        var controls = HighQualityReadableSubtitleBetaControls()

        XCTAssertFalse(controls.enabled)
        XCTAssertFalse(controls.isVisible(hasEnglishSubtitles: false))
        XCTAssertTrue(controls.isVisible(hasEnglishSubtitles: true))

        controls.enabled = true
        controls.reconcile(hasEnglishSubtitles: false)
        XCTAssertFalse(controls.enabled)
    }

    func testSpeakerBetaControlsVisibilityAndSafeDefaults() {
        var controls = HighQualitySpeakerBetaControls()

        XCTAssertFalse(controls.showsAdvancedSettings)
        XCTAssertFalse(controls.isExpanded)
        XCTAssertFalse(controls.showsExpectedCount)
        XCTAssertEqual(controls.configuration, .standard)

        controls.includeLabels = true
        XCTAssertTrue(controls.showsAdvancedSettings)
        XCTAssertFalse(controls.isExpanded)
        XCTAssertFalse(controls.showsExpectedCount)
        XCTAssertEqual(controls.configuration, .standard)

        controls.enhancedPrecision = true
        controls.sensitiveDetection = true
        controls.knowsSpeakerCount = true
        controls.expectedSpeakerCount = 3
        XCTAssertTrue(controls.showsExpectedCount)
        XCTAssertEqual(controls.configuration, .init(
            enhancedPrecision: true,
            sensitiveDetection: true,
            countPolicy: .expected(3)
        ))
    }

    func testIndependentSpeakerBetaSettingsReachSpeakerKitManifestAndRawEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurations = [
            HighQualitySpeakerConfiguration.standard,
            .init(enhancedPrecision: true, sensitiveDetection: false, countPolicy: .automatic),
            .init(enhancedPrecision: false, sensitiveDetection: true, countPolicy: .automatic),
            .init(enhancedPrecision: false, sensitiveDetection: false, countPolicy: .expected(2)),
            .init(enhancedPrecision: true, sensitiveDetection: true, countPolicy: .expected(3)),
        ]
        for configuration in configurations {
            let job = HighQualityJob(services: .init(
                loadSource: { _ in Array(repeating: 0, count: 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "一。" },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: { _, _ in
                    .init(
                        chunks: [.init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: 1,
                            cues: [.init(id: "cue-0001", text: "一。", start: 0, end: 1)]
                        )],
                        modelID: "aligner",
                        revision: "revision",
                        peakMemoryBytes: 0
                    )
                },
                unloadAlignment: {},
                prepareDiarization: { _, _ in },
                diarizeSpeakers: { _, _, receivedConfiguration in
                    XCTAssertEqual(receivedConfiguration, configuration)
                    return .init(
                        spans: [.init(speakerID: 0, start: 0, end: 1)],
                        modelID: "speakerkit",
                        revision: "revision",
                        peakMemoryBytes: 0,
                        speakerCountPolicy: receivedConfiguration.countPolicy
                    )
                },
                unloadDiarization: {}
            ))
            let request = HighQualityJobRequest(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                speakerLabels: true,
                speakerConfiguration: configuration,
                outputRoot: root
            )

            XCTAssertEqual(request.speakerConfiguration, configuration)
            let result = try await job.run(request)

            XCTAssertEqual(result.manifest.speakerConfiguration, configuration)
            XCTAssertEqual(result.evidence.speakerConfiguration, configuration)
            XCTAssertEqual(result.evidence.diarization?.speakerCountPolicy, configuration.countPolicy)
            XCTAssertTrue(result.manifest.dependencies.contains(.forcedAlignment))
            XCTAssertTrue(result.manifest.dependencies.contains(.speakerDiarization))
            XCTAssertEqual(result.turns.map(\.speakerLabel), ["SPEAKER_00"])
            XCTAssertEqual(result.evidence.diarization?.mappings.count, 1)
        }
    }

    func testInvalidOrDisabledExpectedSpeakerCountFailsBeforeModelPreparation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (speakerLabels, enhancedPrecision, sensitiveDetection, policy) in [
            (true, false, false, HighQualitySpeakerCountPolicy.expected(0)),
            (true, false, false, .expected(21)),
            (false, false, false, .expected(2)),
            (false, true, false, .automatic),
            (false, false, true, .automatic),
        ] {
            let calls = CallLog()
            let job = HighQualityJob(services: .init(
                loadSource: { _ in
                    await calls.append("load-source")
                    return [0]
                },
                prepareASR: { _ in await calls.append("prepare-asr") },
                transcribeJapanese: { _ in "一。" },
                unloadASR: {}
            ))
            let request = HighQualityJobRequest(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                speakerLabels: speakerLabels,
                speakerConfiguration: .init(
                    enhancedPrecision: enhancedPrecision,
                    sensitiveDetection: sensitiveDetection,
                    countPolicy: policy
                ),
                outputRoot: root
            )

            do {
                _ = try await job.run(request)
                XCTFail("Invalid Speaker-count policy must fail.")
            } catch let error as HighQualityJobError {
                XCTAssertEqual(error.stage, .application)
                let directory = try XCTUnwrap(error.resultDirectory)
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
                XCTAssertEqual(manifest.failures.first?.stage, .application)
                XCTAssertEqual(manifest.speakerConfiguration, request.speakerConfiguration)
                XCTAssertEqual(evidence.speakerConfiguration, request.speakerConfiguration)
            }
            let recordedCalls = await calls.values
            XCTAssertTrue(recordedCalls.isEmpty)
        }
    }

    func testForcedAlignmentTimesStayInsideTheirAudioWindow() {
        let interval = HighQualityForcedAlignerRuntime.boundedInterval(
            start: 612.5,
            end: 613.3,
            sourceStart: 553.62,
            sourceEnd: 612.88
        )

        XCTAssertEqual(interval.start, 612.5)
        XCTAssertEqual(interval.end, 612.88)
    }

    func testForcedAlignmentRetryRequiresPositiveMonotonicCues() {
        let valid = [
            HighQualityAlignedCue(id: "one", text: "一。", start: 1, end: 2),
            HighQualityAlignedCue(id: "two", text: "二。", start: 2.5, end: 3),
        ]
        let zero = [
            HighQualityAlignedCue(id: "one", text: "一。", start: 1, end: 1),
        ]
        let overlap = [
            HighQualityAlignedCue(id: "one", text: "一。", start: 1, end: 2),
            HighQualityAlignedCue(id: "two", text: "二。", start: 1.5, end: 3),
        ]

        XCTAssertTrue(HighQualityForcedAlignerRuntime.hasValidCueTimeline(
            valid,
            after: 0,
            before: 4
        ))
        XCTAssertFalse(HighQualityForcedAlignerRuntime.hasValidCueTimeline(
            zero,
            after: 0,
            before: 4
        ))
        XCTAssertFalse(HighQualityForcedAlignerRuntime.hasValidCueTimeline(
            overlap,
            after: 0,
            before: 4
        ))
    }

    func testForcedAlignmentCoarseFallbackUsesOnlyTheFreeWindowGap() throws {
        let result = try XCTUnwrap(
            HighQualityForcedAlignerRuntime.contentPreservingFallback(
                cues: [
                    .init(id: "cue-0057", text: "あああああ", start: 1, end: 1.24),
                    .init(id: "cue-0058", text: "いいいいい", start: 1.24, end: 1.24),
                ],
                after: 0,
                before: 10
            )
        )

        XCTAssertEqual(result.cues, [
            .init(id: "cue-0057", text: "あああああいいいいい", start: 1, end: 1.5),
        ])
        XCTAssertEqual(result.merges.first?.sourceCueID, "cue-0058")
        XCTAssertEqual(result.merges.first?.targetCueID, "cue-0057")
        XCTAssertEqual(result.merges.first?.targetOriginalEnd, 1.24)
        XCTAssertEqual(result.merges.first?.finalEnd, 1.5)
        XCTAssertEqual(result.merges.first?.timingPolicy, "coarse-fallback-free-window-gap")

        let turns = [
            HighQualityTranslationTurn(
                id: "cue-0057", japanese: "あああああ", precedingJapanese: [],
                followingJapanese: ["いいいいい"], speakerLabel: nil,
                sourceStart: 0, sourceEnd: 10
            ),
            HighQualityTranslationTurn(
                id: "cue-0058", japanese: "いいいいい", precedingJapanese: ["あああああ"],
                followingJapanese: [], speakerLabel: nil, sourceStart: 0, sourceEnd: 10
            ),
        ]
        let chunks = [HighQualityAlignmentChunk(
            index: 0,
            sourceStart: 0,
            sourceEnd: 10,
            cues: result.cues,
            rawItems: [
                .init(cueID: "cue-0057", text: "あああああ", start: 1, end: 1.24),
                .init(cueID: "cue-0058", text: "いいいいい", start: 1.24, end: 1.24),
            ]
        )]
        let validated = try HighQualityJob.validatedAlignment(
            chunks,
            turns: turns,
            duration: 10,
            fallbackMerges: result.merges
        )
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: "fixture",
                revision: "fixture",
                chunks: chunks,
                mergedCues: validated,
                sourceDuration: 10,
                peakMemoryBytes: 0,
                validationDiagnostics: [],
                fallbackMerges: result.merges
            ),
            sourceTurns: turns
        )
        XCTAssertEqual(semantic.turns.map(\.japanese).joined(), turns.map(\.japanese).joined())
        XCTAssertEqual(semantic.units.map { ($0.start, $0.end) }.first?.0, 1)
        XCTAssertEqual(semantic.units.map { ($0.start, $0.end) }.last?.1, 1.5)
    }

    func testForcedAlignmentCoarseAnchorRejectsMultipleZeroCues() {
        XCTAssertNil(HighQualityForcedAlignerRuntime.contentPreservingFallback(
            cues: [
                .init(id: "cue-0159", text: "気を取っちゃう。", start: 551.62, end: 551.62),
                .init(id: "cue-0160", text: "ピヨピヨ。", start: 551.62, end: 551.62),
            ],
            rawItems: [
                .init(cueID: "cue-0159", text: "気", start: 551.62, end: 551.62),
                .init(cueID: "cue-0160", text: "ピ", start: 551.62, end: 551.62),
            ],
            after: 551.62,
            before: 566.26
        ))
    }

    func testForcedAlignmentCoarseFallbackUsesASRAnchorForOnlyZeroCue() throws {
        let rawItems = [
            HighQualityAlignmentItem(
                cueID: "cue-0295", text: "う", start: 957.18, end: 957.18
            ),
            HighQualityAlignmentItem(
                cueID: "cue-0295", text: "ん", start: 957.18, end: 957.18
            ),
        ]
        let result = try XCTUnwrap(
            HighQualityForcedAlignerRuntime.contentPreservingFallback(
                cues: [
                    .init(id: "cue-0295", text: "うん。", start: 957.18, end: 957.18),
                ],
                rawItems: rawItems,
                after: 950.62,
                before: 957.2078125
            )
        )

        XCTAssertEqual(result.cues[0].id, "cue-0295")
        XCTAssertEqual(result.cues[0].text, "うん。")
        XCTAssertEqual(result.cues[0].start, 957.03, accuracy: 0.000_000_1)
        XCTAssertEqual(result.cues[0].end, 957.18, accuracy: 0.000_000_1)
        XCTAssertEqual(result.cues[0].timingOrigin, "asr-window-anchor")
        XCTAssertEqual(result.cues[0].timingPolicy, "single-zero-cue-asr-anchor-20cps")
        XCTAssertEqual(result.cues[0].timingQuality, "coarse")
        XCTAssertTrue(result.merges.isEmpty)

        let turn = HighQualityTranslationTurn(
            id: "cue-0295", japanese: "うん。", precedingJapanese: [], followingJapanese: [],
            speakerLabel: nil, sourceStart: 950.62, sourceEnd: 957.2078125
        )
        let chunk = HighQualityAlignmentChunk(
            index: 168,
            sourceStart: 950.62,
            sourceEnd: 957.2078125,
            cues: result.cues,
            rawItems: rawItems
        )
        let validated = try HighQualityJob.validatedAlignment(
            [chunk], turns: [turn], duration: 957.2078125
        )
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: "fixture", revision: "fixture", chunks: [chunk],
                mergedCues: validated, sourceDuration: 957.2078125,
                peakMemoryBytes: 0, validationDiagnostics: []
            ),
            sourceTurns: [turn]
        )
        XCTAssertEqual(semantic.units.map(\.japanese), ["うん。"])
        XCTAssertTrue(semantic.units[0].decisions.contains("fallback:positive-cue-timing"))
    }

    func testForcedAlignmentCoarseAnchorRejectsLongTextAndInsufficientSpace() {
        let raw = [HighQualityAlignmentItem(
            cueID: "cue", text: "あ", start: 1, end: 1
        )]
        XCTAssertNil(HighQualityForcedAlignerRuntime.contentPreservingFallback(
            cues: [.init(id: "cue", text: String(repeating: "あ", count: 49), start: 1, end: 1)],
            rawItems: raw,
            after: 0,
            before: 10
        ))
        XCTAssertNil(HighQualityForcedAlignerRuntime.contentPreservingFallback(
            cues: [.init(id: "cue", text: "うん。", start: 1, end: 1)],
            rawItems: raw,
            after: 0.95,
            before: 1.05
        ))
    }

    func testAlignmentValidatorRejectsUnauditedCoarseTiming() {
        let turn = HighQualityTranslationTurn(
            id: "cue", japanese: "うん。", precedingJapanese: [], followingJapanese: [],
            speakerLabel: nil, sourceStart: 0, sourceEnd: 1
        )
        let chunk = HighQualityAlignmentChunk(
            index: 0,
            sourceStart: 0,
            sourceEnd: 1,
            cues: [.init(
                id: "cue", text: "うん。", start: 0, end: 0.15,
                timingOrigin: "asr-window-anchor",
                timingPolicy: "unapproved",
                timingQuality: "coarse"
            )],
            rawItems: [.init(cueID: "cue", text: "う", start: 0.15, end: 0.15)]
        )

        XCTAssertThrowsError(try HighQualityJob.validatedAlignment(
            [chunk], turns: [turn], duration: 1
        ))
    }

    func testAlignmentValidatorRejectsShiftedCoarseTiming() {
        let turn = HighQualityTranslationTurn(
            id: "cue", japanese: "うん。", precedingJapanese: [], followingJapanese: [],
            speakerLabel: nil, sourceStart: 0, sourceEnd: 1
        )
        let chunk = HighQualityAlignmentChunk(
            index: 0,
            sourceStart: 0,
            sourceEnd: 1,
            cues: [.init(
                id: "cue", text: "うん。", start: 0.4, end: 0.55,
                timingOrigin: "asr-window-anchor",
                timingPolicy: "single-zero-cue-asr-anchor-20cps",
                timingQuality: "coarse"
            )],
            rawItems: [.init(cueID: "cue", text: "う", start: 0.5, end: 0.5)]
        )

        XCTAssertThrowsError(try HighQualityJob.validatedAlignment(
            [chunk], turns: [turn], duration: 1
        ))
    }

    func testSemanticTranslationUnitsMergeZeroItemDraftsIntoSameCueNeighbor() throws {
        let turns = [
            HighQualityTranslationTurn(
                id: "cue-0001", japanese: "え、これ辛い。", precedingJapanese: [],
                followingJapanese: ["しかもまだ思えない。"], speakerLabel: nil,
                sourceStart: 1, sourceEnd: 3
            ),
            HighQualityTranslationTurn(
                id: "cue-0002", japanese: "しかもまだ思えない。",
                precedingJapanese: ["え、これ辛い。"], followingJapanese: [],
                speakerLabel: nil, sourceStart: 4, sourceEnd: 6
            ),
        ]
        let chunks = [HighQualityAlignmentChunk(
            index: 0,
            sourceStart: 0,
            sourceEnd: 10,
            cues: [
                .init(id: "cue-0001", text: turns[0].japanese, start: 1, end: 3),
                .init(id: "cue-0002", text: turns[1].japanese, start: 4, end: 6),
            ],
            rawItems: [
                .init(cueID: "cue-0001", text: "え", start: 1, end: 1),
                .init(cueID: "cue-0001", text: "これ辛い", start: 2, end: 3),
                .init(cueID: "cue-0002", text: "しかもまだ思えな", start: 4, end: 5),
                .init(cueID: "cue-0002", text: "い", start: 6, end: 6),
            ]
        )]

        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: "fixture", revision: "fixture", chunks: chunks,
                mergedCues: chunks[0].cues, sourceDuration: 10,
                peakMemoryBytes: 0, validationDiagnostics: []
            ),
            sourceTurns: turns
        )

        XCTAssertEqual(semantic.units.map(\.japanese), turns.map(\.japanese))
        XCTAssertTrue(semantic.units.allSatisfy { $0.end > $0.start })
        XCTAssertTrue(semantic.units[0].decisions.contains("merge:zero-duration-items-into-next"))
        XCTAssertTrue(semantic.units[1].decisions.contains("merge:zero-duration-items-into-previous"))
    }

    func testSemanticTranslationUnitsUsePositiveCueTimingWhenEveryItemIsZero() throws {
        let turn = HighQualityTranslationTurn(
            id: "cue-0001", japanese: "そんな通ってない。",
            precedingJapanese: [], followingJapanese: [], speakerLabel: nil,
            sourceStart: 1, sourceEnd: 4
        )
        let chunk = HighQualityAlignmentChunk(
            index: 0, sourceStart: 0, sourceEnd: 5,
            cues: [.init(id: turn.id, text: turn.japanese, start: 1, end: 4)],
            rawItems: [
                .init(cueID: turn.id, text: "そんな通ってな", start: 1, end: 1),
                .init(cueID: turn.id, text: "い", start: 4, end: 4),
            ]
        )

        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: "fixture", revision: "fixture", chunks: [chunk],
                mergedCues: chunk.cues, sourceDuration: 5,
                peakMemoryBytes: 0, validationDiagnostics: []
            ),
            sourceTurns: [turn]
        )

        XCTAssertEqual(semantic.units.map(\.japanese), [turn.japanese])
        XCTAssertEqual(semantic.units.map { [$0.start, $0.end] }, [[1, 4]])
        XCTAssertTrue(semantic.units[0].decisions.contains("fallback:positive-cue-timing"))
    }

    func testSemanticTranslationUnitsReplayEvidenceWhenOptedIn() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_SEMANTIC_ALIGNMENT_EVIDENCE"
        ] else {
            throw XCTSkip("Set WHISPERASR_SEMANTIC_ALIGNMENT_EVIDENCE to replay raw evidence.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let recorded = try XCTUnwrap(evidence.alignment)
        let cues = recorded.chunks.sorted { $0.index < $1.index }.flatMap(\.cues)
        let turns = cues.enumerated().map { index, cue in
            HighQualityTranslationTurn(
                id: cue.id, japanese: cue.text,
                precedingJapanese: index == 0 ? [] : [cues[index - 1].text],
                followingJapanese: index + 1 == cues.count ? [] : [cues[index + 1].text],
                speakerLabel: nil, sourceStart: cue.start, sourceEnd: cue.end
            )
        }
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: recorded.modelID, revision: recorded.revision,
                chunks: recorded.chunks, mergedCues: cues,
                sourceDuration: recorded.sourceDuration,
                peakMemoryBytes: recorded.peakMemoryBytes,
                validationDiagnostics: recorded.validationDiagnostics,
                fallbackMerges: recorded.fallbackMerges
            ),
            sourceTurns: turns
        )

        XCTAssertEqual(semantic.units.map(\.japanese).joined(), cues.map(\.text).joined())
        XCTAssertTrue(semantic.units.allSatisfy { $0.end > $0.start && $0.japanese.count <= 48 })
        XCTAssertTrue(semantic.units.contains {
            $0.sourceCueIDs.contains("cue-0178")
                && $0.decisions.contains("fallback:positive-cue-timing")
        })
    }

    func testForcedAlignmentFallbackReplayEvidenceWhenOptedIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WHISPERASR_FORCED_ALIGNMENT_EVIDENCE"],
              let expectation = environment["WHISPERASR_FORCED_ALIGNMENT_EXPECTATION"] else {
            throw XCTSkip("Set the raw alignment evidence and expected fallback result.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let recorded = try XCTUnwrap(evidence.alignment)
        let chunks = recorded.chunks.sorted { $0.index < $1.index }
        let invalidIndex = try XCTUnwrap(chunks.firstIndex {
            !HighQualityForcedAlignerRuntime.hasValidCueTimeline(
                $0.cues, after: $0.sourceStart, before: $0.sourceEnd
            )
        })
        let chunk = chunks[invalidIndex]
        let previousEnd = invalidIndex == 0
            ? chunk.sourceStart : chunks[invalidIndex - 1].cues.last?.end ?? chunk.sourceStart
        let upperBound = min(
            chunk.sourceEnd,
            chunks.indices.contains(invalidIndex + 1)
                ? chunks[invalidIndex + 1].sourceStart : chunk.sourceEnd
        )
        let fallback = HighQualityForcedAlignerRuntime.contentPreservingFallback(
            cues: chunk.cues,
            rawItems: chunk.rawItems,
            after: max(previousEnd, chunk.sourceStart),
            before: upperBound,
            chunkIndex: chunk.index
        )
        if expectation == "fail-closed" {
            XCTAssertNil(fallback)
            return
        }
        XCTAssertEqual(expectation, "single-coarse-anchor")
        let fixed = try XCTUnwrap(fallback)
        XCTAssertTrue(fixed.merges.isEmpty)
        XCTAssertEqual(fixed.cues.map(\.id), ["cue-0295"])
        XCTAssertEqual(fixed.cues.first?.timingQuality, "coarse")
        let fixedChunk = HighQualityAlignmentChunk(
            index: chunk.index,
            sourceStart: chunk.sourceStart,
            sourceEnd: chunk.sourceEnd,
            cues: fixed.cues,
            rawItems: chunk.rawItems
        )
        XCTAssertEqual(fixedChunk.rawItems, chunk.rawItems)
        let turns = chunk.cues.enumerated().map { index, cue in
            HighQualityTranslationTurn(
                id: cue.id,
                japanese: cue.text,
                precedingJapanese: index == 0 ? [] : [chunk.cues[index - 1].text],
                followingJapanese: index + 1 == chunk.cues.count
                    ? [] : [chunk.cues[index + 1].text],
                speakerLabel: nil,
                sourceStart: chunk.sourceStart,
                sourceEnd: chunk.sourceEnd
            )
        }
        let validated = try HighQualityJob.validatedAlignment(
            [fixedChunk], turns: turns, duration: recorded.sourceDuration
        )
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: recorded.modelID,
                revision: recorded.revision,
                chunks: [fixedChunk],
                mergedCues: validated,
                sourceDuration: recorded.sourceDuration,
                peakMemoryBytes: recorded.peakMemoryBytes,
                validationDiagnostics: []
            ),
            sourceTurns: turns
        )
        XCTAssertEqual(semantic.units.map(\.japanese), turns.map(\.japanese))
    }

    func testSemanticTranslationUnitsIgnoreDiarizationAndPreserveAlignedJapanese() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = "これは 続きです。え。次です。" + String(repeating: "あ", count: 60) + "。"

        func run(spans: [HighQualityDiarizationSpan]) async throws -> HighQualityJobResult {
            let job = HighQualityJob(services: .init(
                loadSource: { _ in Array(repeating: 0, count: 320_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in transcript },
                transcribeJapaneseAnchored: { _ in
                    .init(
                        rawTranscript: transcript,
                        chunks: [.init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: 20,
                            transcript: transcript
                        )]
                    )
                },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: { _, turns in
                    var time = 0.0
                    var items: [HighQualityAlignmentItem] = []
                    var cues: [HighQualityAlignedCue] = []
                    for turn in turns {
                        let start = time
                        if turn.japanese.count > 48 {
                            items.append(.init(
                                cueID: turn.id,
                                text: turn.japanese,
                                start: time,
                                end: time + 6.1
                            ))
                            time += 6.1
                        } else {
                            for character in turn.japanese where character.isLetter || character.isNumber {
                                items.append(.init(
                                    cueID: turn.id,
                                    text: String(character),
                                    start: time,
                                    end: time + 0.1
                                ))
                                time += character == "は" ? 1.1 : 0.1
                            }
                        }
                        cues.append(.init(id: turn.id, text: turn.japanese, start: start, end: time))
                    }
                    return .init(
                        chunks: [.init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: 20,
                            cues: cues,
                            rawItems: items
                        )],
                        modelID: "fixture-aligner",
                        revision: "frozen-revision",
                        peakMemoryBytes: 0
                    )
                },
                unloadAlignment: {},
                prepareDiarization: { _, _ in },
                diarizeSpeakers: { _, _, _ in
                    .init(
                        spans: spans,
                        modelID: "fixture-speakerkit",
                        revision: "frozen-revision",
                        peakMemoryBytes: 0
                    )
                },
                unloadDiarization: {},
                translateEnglish: { request in
                    XCTAssertTrue(request.turns.allSatisfy { $0.speakerLabel == nil })
                    let translations = request.turns.enumerated().map {
                        ["id": $0.element.id, "text": "English \($0.offset + 1)"]
                    }
                    let response = try JSONSerialization.data(withJSONObject: [
                        "translations": translations,
                    ])
                    return .init(
                        model: "fixture-translator",
                        response: String(decoding: response, as: UTF8.self),
                        attempts: []
                    )
                }
            ))
            return try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: Set(HighQualityDeliverable.allCases),
                backend: .qwenJA,
                speakerLabels: true,
                outputRoot: root
            ))
        }

        let first = try await run(spans: [
            .init(speakerID: 2, start: 0, end: 20),
            .init(speakerID: 7, start: 2, end: 6),
        ])
        let second = try await run(spans: [
            .init(speakerID: 9, start: 0, end: 1),
            .init(speakerID: 3, start: 1, end: 20),
        ])

        let expectedJapanese = [
            "これは 続きです。",
            "え。",
            "次です。",
            String(repeating: "あ", count: 48),
            String(repeating: "あ", count: 12) + "。",
        ]
        XCTAssertEqual(first.turns.map(\.id), second.turns.map(\.id))
        XCTAssertEqual(first.turns.map(\.japanese), expectedJapanese)
        XCTAssertEqual(second.turns.map(\.japanese), expectedJapanese)
        XCTAssertEqual(first.evidence.translation?.request, second.evidence.translation?.request)
        XCTAssertEqual(first.evidence.glossary.promptTerms, second.evidence.glossary.promptTerms)
        XCTAssertEqual(first.turns.map(\.japanese).joined(), transcript)
        XCTAssertEqual(first.subtitleCues.map(\.id), first.turns.map(\.id))
        XCTAssertEqual(first.subtitleCues.map(\.start), first.turns.compactMap(\.start))
        XCTAssertEqual(first.subtitleCues.map(\.end), first.turns.compactMap(\.end))

        let semanticUnits = try XCTUnwrap(first.evidence.alignment?.semanticUnits)
        XCTAssertEqual(semanticUnits.map(\.id), first.turns.map(\.id))
        XCTAssertEqual(semanticUnits.map(\.japanese), expectedJapanese)
        XCTAssertTrue(semanticUnits[0].decisions.contains("merge:short-fragment-into-next"))
        XCTAssertTrue(semanticUnits[1].decisions.contains("keep:standalone-interjection"))
        XCTAssertTrue(semanticUnits[3].decisions.contains("boundary:maximum-size"))
        XCTAssertEqual(
            Set(semanticUnits.flatMap(\.sourceFragmentIndices)).count,
            first.evidence.alignment?.semanticFragments?.count
        )
        XCTAssertTrue(first.subtitleCues.allSatisfy { $0.speakerLabel != nil })
        let webVTT = try String(
            contentsOf: first.directory.appendingPathComponent("english-subtitles.vtt"),
            encoding: .utf8
        )
        let srt = try String(
            contentsOf: first.directory.appendingPathComponent("english-subtitles.srt"),
            encoding: .utf8
        )
        XCTAssertTrue(webVTT.contains(first.turns[0].id))
        XCTAssertTrue(srt.contains("[SPEAKER_"))
    }

    func testSpeakerLabelsAssignEachAlignedUnitOnceByDominantOverlap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 160_000) },
            prepareASR: { _ in await calls.append("prepare-asr") },
            transcribeJapanese: { _ in "unused" },
            transcribeJapaneseAnchored: { _ in
                .init(
                    rawTranscript: "一。\n二。",
                    chunks: [
                        .init(index: 0, sourceStart: 0, sourceEnd: 5, transcript: "一。"),
                        .init(index: 1, sourceStart: 5, sourceEnd: 10, transcript: "二。"),
                    ]
                )
            },
            unloadASR: { await calls.append("unload-asr") },
            prepareAlignment: { _ in await calls.append("prepare-alignment") },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 10,
                        cues: [
                            .init(id: "cue-0001", text: "一。", start: 1, end: 4),
                            .init(id: "cue-0002", text: "二。", start: 6, end: 9),
                        ],
                        rawItems: [
                            .init(cueID: "cue-0001", text: "一", start: 1, end: 2),
                            .init(cueID: "cue-0001", text: "。", start: 2, end: 4),
                            .init(cueID: "cue-0002", text: "二。", start: 6, end: 9),
                        ]
                    )],
                    modelID: "fixture-aligner",
                    revision: "aligner-revision",
                    peakMemoryBytes: 100
                )
            },
            unloadAlignment: { await calls.append("unload-alignment") },
            prepareDiarization: { _, _ in await calls.append("prepare-speakerkit") },
            diarizeSpeakers: { _, _, _ in
                .init(
                    spans: [
                        .init(speakerID: 7, start: 1, end: 4),
                        .init(speakerID: 2, start: 0, end: 3),
                    ],
                    modelID: "argmaxinc/speakerkit-coreml",
                    revision: "speakerkit-revision",
                    peakMemoryBytes: 200
                )
            },
            unloadDiarization: { await calls.append("unload-speakerkit") }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            speakerLabels: true,
            outputRoot: root
        ))

        XCTAssertEqual(result.manifest.dependencies, [
            .sourceNormalization, .japaneseASR, .forcedAlignment, .speakerDiarization, .export,
        ])
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [
            "prepare-asr", "unload-asr", "prepare-alignment", "unload-alignment",
            "prepare-speakerkit", "unload-speakerkit",
        ])
        XCTAssertEqual(result.evidence.diarization?.modelID, "argmaxinc/speakerkit-coreml")
        XCTAssertEqual(result.evidence.diarization?.revision, "speakerkit-revision")
        XCTAssertEqual(result.evidence.diarization?.rawSpans.count, 2)
        XCTAssertEqual(result.evidence.diarization?.overlapRanges.count, 1)
        XCTAssertEqual(result.evidence.diarization?.mappings.count, 2)
        XCTAssertEqual(
            result.evidence.diarization?.mappings.map(\.alignmentItemIndex),
            [0, 1]
        )
        XCTAssertEqual(
            result.evidence.diarization?.mappings.map(\.speakerLabel),
            ["SPEAKER_00", "SPEAKER_01"]
        )
        XCTAssertTrue(result.evidence.diarization?.mappings.allSatisfy {
            $0.attributionReason == nil
        } == true)
        XCTAssertEqual(Set(result.turns.compactMap(\.speakerLabel)), ["SPEAKER_01"])
        XCTAssertEqual(result.turns.map(\.japanese), ["一。", "二。"])
        XCTAssertEqual(result.turns.map(\.speakerLabel), ["SPEAKER_01", nil])
        XCTAssertEqual(result.turns.map(\.start), [1, 6])
        XCTAssertEqual(result.turns.map(\.end), [4, 9])
        XCTAssertEqual(result.japaneseTranscript, "SPEAKER_01: 一。\n二。")
        XCTAssertEqual(result.manifest.peakMemoryBytes, 200)
    }

    func testCompleteAttributionIsOptInAndUsesDeterministicNearestSpan() throws {
        let exchange = HighQualityDiarizationExchange(
            spans: [
                .init(speakerID: 7, start: 0, end: 1),
                .init(speakerID: 2, start: 3, end: 4),
            ],
            modelID: "fixture-diarizer",
            revision: "fixture-revision",
            peakMemoryBytes: 0
        )
        let gap = HighQualityAlignmentItem(
            cueID: "cue-0001",
            text: "間",
            start: 1.5,
            end: 2.5
        )

        let productDefault = try HighQualityJob.diarizationEvidence(
            exchange,
            items: [gap],
            duration: 5
        )
        XCTAssertTrue(productDefault.mappings.isEmpty)

        let experimental = try HighQualityJob.diarizationEvidence(
            exchange,
            items: [gap],
            duration: 5,
            completeAttribution: true
        )
        XCTAssertEqual(experimental.mappings.map(\.alignmentItemIndex), [0])
        XCTAssertEqual(experimental.mappings.map(\.speakerLabel), ["SPEAKER_00"])
        XCTAssertEqual(experimental.mappings.map(\.spanIndex), [1])
        XCTAssertEqual(experimental.mappings.map(\.attributionReason), ["nearest-span-fallback"])
        XCTAssertEqual(experimental.mappings.map(\.overlapStart), [3])
        XCTAssertEqual(experimental.mappings.map(\.overlapEnd), [3])
    }

    func testExclusiveSpeakerReconciliationIsAuditableAndKeepsOneTranslationPerUnit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 64_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 4,
                        cues: [.init(id: "cue-0001", text: "一。", start: 0, end: 4)],
                        rawItems: [
                            .init(cueID: "cue-0001", text: "一", start: 0, end: 2),
                            .init(cueID: "cue-0001", text: "。", start: 2, end: 4),
                        ]
                    )],
                    modelID: "fixture-aligner",
                    revision: "frozen-revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, _ in
                XCTAssertTrue(useExclusiveReconciliation)
                return .init(
                    spans: [
                        .init(speakerID: 9, start: 0, end: 2),
                        .init(speakerID: 3, start: 2, end: 4),
                    ],
                    modelID: "fixture-speakerkit",
                    revision: "frozen-revision",
                    peakMemoryBytes: 123,
                    useExclusiveReconciliation: useExclusiveReconciliation
                )
            },
            unloadDiarization: {},
            translateEnglish: { request in
                XCTAssertEqual(request.turns.map(\.japanese), ["一。"])
                return .init(
                    model: "fixture-translator",
                    response: #"{"translations":[{"id":"unit-0001","text":"One"}]}"#,
                    attempts: []
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: .qwenJA,
            speakerLabels: true,
            useExclusiveReconciliation: true,
            outputRoot: root
        ))

        let evidence = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(evidence.useExclusiveReconciliation, true)
        XCTAssertTrue(evidence.overlapRanges.isEmpty)
        XCTAssertEqual(evidence.mappings.map(\.alignmentItemIndex), [0, 1])
        XCTAssertEqual(evidence.mappings.map(\.speakerLabel), ["SPEAKER_01", "SPEAKER_00"])
        XCTAssertEqual(Set(evidence.mappings.map(\.alignmentItemIndex)).count, 2)
        XCTAssertEqual(result.turns.map(\.japanese), ["一。"])
        XCTAssertEqual(result.turns.map(\.english), ["One"])
    }

    func testSpeakerRenameRegeneratesAllDeliverablesWithoutChangingRawIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = speakerSubtitleFixtureJob()
        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript, .englishTranslationTranscript, .englishSubtitles],
            backend: .qwenJA,
            speakerLabels: true,
            useExclusiveReconciliation: true,
            outputRoot: root
        ))

        let renamed = try HighQualityJob.renameSpeakers(
            in: result,
            names: ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"]
        )

        XCTAssertEqual(Set(renamed.turns.compactMap(\.speakerLabel)), ["SPEAKER_00"])
        XCTAssertEqual(Set(renamed.turns.compactMap(\.speakerName)), ["Alice"])
        XCTAssertEqual(result.evidence.diarization?.useExclusiveReconciliation, true)
        XCTAssertEqual(renamed.evidence.diarization, result.evidence.diarization)
        let japanese = try String(
            contentsOf: result.directory.appendingPathComponent("japanese-transcript.txt"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: result.directory.appendingPathComponent("english-translation-transcript.txt"),
            encoding: .utf8
        )
        let webVTT = try String(
            contentsOf: result.directory.appendingPathComponent("english-subtitles.vtt"),
            encoding: .utf8
        )
        let srt = try String(
            contentsOf: result.directory.appendingPathComponent("english-subtitles.srt"),
            encoding: .utf8
        )
        XCTAssertTrue(japanese.contains("Alice: 一。"))
        XCTAssertTrue(english.contains("Alice: One"))
        XCTAssertTrue(webVTT.contains("<v Alice>One"))
        XCTAssertTrue(srt.contains("[Alice] One"))
        XCTAssertEqual(renamed.japaneseTranscript, japanese.trimmingCharacters(in: .newlines))
        XCTAssertEqual(renamed.subtitleCues.map(\.start), [1])
        XCTAssertEqual(renamed.subtitleCues.map(\.end), [4])
    }

    func testCompletedStandaloneJobReopensFromSavedManifestAndEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio-reference".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let completed = try await speakerSubtitleFixtureJob().run(.init(
            sourceURL: source,
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: .qwenJA,
            speakerLabels: true,
            outputRoot: root
        ))
        let rawEvidence = try Data(contentsOf: completed.directory
            .appendingPathComponent("raw-asr.json"))
        let deliverableURLs = completed.manifest.generatedFiles
            .filter { $0.kind == .deliverable }
            .map { completed.directory.appendingPathComponent($0.path) }
        let deliverableData = try deliverableURLs.map { try Data(contentsOf: $0) }
        try Data("interrupted replacement".utf8).write(
            to: completed.directory.appendingPathComponent("japanese-transcript.txt"),
            options: .atomic
        )
        try FileManager.default.removeItem(
            at: completed.directory.appendingPathComponent("english-subtitles.srt")
        )

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)

        XCTAssertEqual(saved.id, completed.manifest.jobID)
        XCTAssertEqual(saved.sourceURL, source)
        XCTAssertNil(saved.sourceRelocationMessage)
        XCTAssertEqual(reopened.japaneseTranscript, completed.japaneseTranscript)
        XCTAssertEqual(reopened.englishTranscript, completed.englishTranscript)
        XCTAssertEqual(reopened.turns, completed.turns)
        XCTAssertEqual(reopened.subtitleCues, completed.subtitleCues)
        XCTAssertEqual(reopened.manifest.jobID, completed.manifest.jobID)
        XCTAssertEqual(reopened.manifest.status, .completed)
        XCTAssertEqual(reopened.manifest.source.path, completed.manifest.source.path)
        XCTAssertEqual(reopened.manifest.source.fileName, completed.manifest.source.fileName)
        XCTAssertEqual(reopened.manifest.deliverables, completed.manifest.deliverables)
        XCTAssertEqual(reopened.evidence.rawASR, completed.evidence.rawASR)
        XCTAssertEqual(reopened.evidence.alignment, completed.evidence.alignment)
        XCTAssertEqual(reopened.evidence.diarization, completed.evidence.diarization)
        XCTAssertEqual(
            reopened.evidence.translation?.request.turns,
            completed.evidence.translation?.request.turns
        )
        XCTAssertEqual(
            reopened.evidence.translation?.response,
            completed.evidence.translation?.response
        )
        XCTAssertEqual(
            try Data(contentsOf: completed.directory.appendingPathComponent("raw-asr.json")),
            rawEvidence
        )
        XCTAssertEqual(try deliverableURLs.map { try Data(contentsOf: $0) }, deliverableData)
    }

    func testSavedYouTubeJobReopensFromRetainedAudioWithoutRepeatingServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let sourceURL = try XCTUnwrap(URL(string: "https://youtu.be/saved123"))
        let job = HighQualityJob(services: .init(
            loadSource: { url in
                await calls.append("load:\(url.lastPathComponent)")
                return [0]
            },
            acquireYouTube: { url, directory in
                await calls.append("acquire")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let audio = directory.appendingPathComponent("source.m4a")
                try Data("retained-audio".utf8).write(to: audio)
                return .init(
                    audioURL: audio,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "Saved video",
                        channel: "Saved channel",
                        description: "Saved description",
                        ytDLPVersion: "fixture",
                        diagnostics: "fixture"
                    )
                )
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in
                await calls.append("transcribe")
                return "保存済み。"
            },
            unloadASR: { await calls.append("unload") }
        ))

        let completed = try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        let callsAfterRun = await calls.values
        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)
        let callsAfterReopen = await calls.values

        XCTAssertEqual(callsAfterReopen, callsAfterRun)
        XCTAssertEqual(saved.sourceURL, completed.directory
            .appendingPathComponent("acquisition/source.m4a"))
        XCTAssertNil(saved.sourceRelocationMessage)
        XCTAssertEqual(reopened.japaneseTranscript, completed.japaneseTranscript)
        XCTAssertEqual(reopened.manifest.source.youtube?.sourceURL, sourceURL.absoluteString)
        XCTAssertEqual(reopened.evidence.source.youtube, reopened.manifest.source.youtube)
    }

    func testMissingLocalSourceRequestsRelocationWithoutCopyingOrHidingResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("moved-source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("external-source".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "結果。" },
            unloadASR: {}
        )).run(.init(
            sourceURL: source,
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: completed.directory.appendingPathComponent(source.lastPathComponent).path
        ))
        try FileManager.default.removeItem(at: source)

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)

        XCTAssertEqual(saved.sourceURL, source)
        XCTAssertTrue(saved.sourceRelocationMessage?.contains("Locate moved-source.wav") == true)
        XCTAssertEqual(reopened.japaneseTranscript, completed.japaneseTranscript)
    }

    func testRelaunchListsRelocatesAndReopensSavedResultWithoutChangingLiveMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        let relocatedSource = root.appendingPathComponent("relocated/source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source-audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let previousLiveMode = defaults.object(forKey: LiveCaptionMode.storageKey)
        defer {
            if let previousLiveMode {
                defaults.set(previousLiveMode, forKey: LiveCaptionMode.storageKey)
            } else {
                defaults.removeObject(forKey: LiveCaptionMode.storageKey)
            }
        }
        defaults.set(LiveCaptionMode.api.rawValue, forKey: LiveCaptionMode.storageKey)
        let calls = CallLog()
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in
                await calls.append("load")
                return [0]
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in
                await calls.append("transcribe")
                return "再開。"
            },
            unloadASR: { await calls.append("unload") }
        )).run(.init(
            sourceURL: source,
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        let callsAfterRun = await calls.values
        let rawEvidence = try Data(contentsOf: completed.directory
            .appendingPathComponent("raw-asr.json"))
        try FileManager.default.createDirectory(
            at: relocatedSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: relocatedSource)

        let relaunchedResults = HighQualityJob.savedResults(in: root)
        let selected = try XCTUnwrap(relaunchedResults.first {
            $0.id == completed.manifest.jobID
        })
        XCTAssertNotNil(selected.sourceRelocationMessage)

        let relocated = try HighQualityJob.relocateSource(selected, to: relocatedSource)
        let selectedAfterSecondRelaunch = try XCTUnwrap(
            HighQualityJob.savedResults(in: root).first { $0.id == relocated.id }
        )
        let reopened = try HighQualityJob.reopen(selectedAfterSecondRelaunch)

        XCTAssertEqual(selectedAfterSecondRelaunch.sourceURL, relocatedSource)
        XCTAssertNil(selectedAfterSecondRelaunch.sourceRelocationMessage)
        XCTAssertEqual(reopened.japaneseTranscript, completed.japaneseTranscript)
        XCTAssertEqual(
            try Data(contentsOf: completed.directory.appendingPathComponent("raw-asr.json")),
            rawEvidence
        )
        let callsAfterReopen = await calls.values
        XCTAssertEqual(callsAfterReopen, callsAfterRun)
        XCTAssertEqual(LiveCaptionMode.stored(), .api)
    }

    func testCompletedJobRejectsTamperedRawEvidenceByManifestHash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "検証。" },
            unloadASR: {}
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        XCTAssertEqual(
            completed.manifest.schemaVersion,
            HighQualityJobManifest.currentSchemaVersion
        )
        XCTAssertNotNil(completed.manifest.rawEvidenceSHA256)
        let evidenceURL = completed.directory.appendingPathComponent("raw-asr.json")
        var data = try Data(contentsOf: evidenceURL)
        data.append(contentsOf: "\n".utf8)
        try data.write(to: evidenceURL, options: .atomic)

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        XCTAssertThrowsError(try HighQualityJob.reopen(saved)) { error in
            XCTAssertTrue(error.localizedDescription.contains("verification"))
        }
    }

    func testCompletedJobCannotBeOverwrittenByRepeatedIdentifier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let request = HighQualityJobRequest(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "最初。" },
            unloadASR: {}
        )).run(request)
        let persistedURLs = ["manifest.json", "raw-asr.json", "japanese-transcript.txt"]
            .map(completed.directory.appendingPathComponent)
        let persistedData = try persistedURLs.map { try Data(contentsOf: $0) }
        let calls = CallLog()
        let replacement = HighQualityJob(services: .init(
            loadSource: { _ in
                await calls.append("load")
                return [0]
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in
                await calls.append("transcribe")
                return "置換。"
            },
            unloadASR: { await calls.append("unload") }
        ))

        do {
            _ = try await replacement.run(request)
            XCTFail("Expected the completed saved result to be protected.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .application)
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        let replacementCalls = await calls.values
        XCTAssertTrue(replacementCalls.isEmpty)
        XCTAssertEqual(try persistedURLs.map { try Data(contentsOf: $0) }, persistedData)
    }

    func testUnreadableExistingDestinationIsReservedBeforeAnyServiceRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("manifest.json")
        let original = Data("unreadable-existing-result".utf8)
        try original.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in
                await calls.append("load")
                return [0]
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in
                await calls.append("transcribe")
                return "置換。"
            },
            unloadASR: { await calls.append("unload") }
        ))

        do {
            _ = try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
            XCTFail("An existing destination must be refused atomically.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .application)
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        let serviceCalls = await calls.values
        XCTAssertTrue(serviceCalls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testConcurrentJobsAtomicallyReserveTheSameDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let request = HighQualityJobRequest(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let calls = SampleCounts()
        let firstStarted = AsyncStream<Void>.makeStream()
        let releaseFirst = AsyncStream<Void>.makeStream()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in
                let call = await calls.append(0)
                if call == 1 {
                    firstStarted.continuation.yield()
                    for await _ in releaseFirst.stream { break }
                }
                return [0]
            },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {}
        ))

        let first = Task { try await job.run(request) }
        var starts = firstStarted.stream.makeAsyncIterator()
        _ = await starts.next()
        let second = Task { try await job.run(request) }

        do {
            _ = try await second.value
            XCTFail("Only one concurrent job may reserve a destination.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .application)
            XCTAssertTrue(error.message.contains("already exists"))
        } catch {
            XCTFail("Unexpected reservation error: \(error)")
        }

        releaseFirst.continuation.finish()
        _ = try await first.value
        let loadCalls = await calls.values
        XCTAssertEqual(loadCalls.count, 1)
    }

    func testSchemaTwoAndIssue110SchemaThreeSavedResultsStillReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "旧結果。" },
            unloadASR: {}
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        let manifestURL = completed.directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        manifest["schemaVersion"] = 3
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let issue110Saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopenedIssue110 = try HighQualityJob.reopen(issue110Saved)
        XCTAssertEqual(reopenedIssue110.manifest.schemaVersion, 3)
        XCTAssertNotNil(reopenedIssue110.manifest.rawEvidenceSHA256)
        XCTAssertNil(reopenedIssue110.manifest.asrWorker)

        manifest["schemaVersion"] = 2
        manifest.removeValue(forKey: "rawEvidenceSHA256")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
        let evidenceURL = completed.directory.appendingPathComponent("raw-asr.json")
        var evidence = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        evidence.removeValue(forKey: "resultTurns")
        evidence.removeValue(forKey: "subtitleCues")
        evidence.removeValue(forKey: "japaneseTranscript")
        evidence.removeValue(forKey: "englishTranscript")
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            .write(to: evidenceURL, options: .atomic)

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)

        XCTAssertEqual(reopened.manifest.schemaVersion, 2)
        XCTAssertNil(reopened.manifest.rawEvidenceSHA256)
        XCTAssertEqual(reopened.japaneseTranscript, completed.japaneseTranscript)
        XCTAssertThrowsError(try HighQualityJob.renameSpeakers(in: reopened, names: [:])) {
            XCTAssertTrue($0.localizedDescription.contains("current schema"))
        }
    }

    func testFutureSavedResultSchemaIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "未来。" },
            unloadASR: {}
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))
        let manifestURL = completed.directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        manifest["schemaVersion"] = HighQualityJobManifest.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
        let saved = HighQualitySavedResult(
            directory: completed.directory,
            manifest: completed.manifest
        )

        XCTAssertTrue(HighQualityJob.savedResults(in: root).isEmpty)
        XCTAssertThrowsError(try HighQualityJob.reopen(saved)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported schema"))
        }
        manifest["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try HighQualityJob.reopen(saved)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported schema"))
        }
    }

    func testSpeakerRenamePersistsSeparatelyAndReopensWithoutChangingRawEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await speakerSubtitleFixtureJob().run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: .qwenJA,
            speakerLabels: true,
            outputRoot: root
        ))
        let evidenceURL = completed.directory.appendingPathComponent("raw-asr.json")
        let originalEvidence = try Data(contentsOf: evidenceURL)
        let renamed = try HighQualityJob.renameSpeakers(
            in: completed,
            names: ["SPEAKER_00": "Alice"]
        )
        let transformedURLs = completed.manifest.generatedFiles
            .filter { $0.kind == .deliverable }
            .map { completed.directory.appendingPathComponent($0.path) }
        let transformedData = try transformedURLs.map { try Data(contentsOf: $0) }
        try Data("interrupted replacement".utf8).write(
            to: completed.directory.appendingPathComponent(
                "english-translation-transcript.txt"
            ),
            options: .atomic
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: completed.directory.appendingPathComponent("transformations.json").path
        ))
        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)

        XCTAssertEqual(reopened.turns, renamed.turns)
        XCTAssertEqual(reopened.subtitleCues, renamed.subtitleCues)
        XCTAssertEqual(reopened.japaneseTranscript, renamed.japaneseTranscript)
        XCTAssertEqual(reopened.englishTranscript, renamed.englishTranscript)
        XCTAssertEqual(try Data(contentsOf: evidenceURL), originalEvidence)
        XCTAssertEqual(reopened.manifest.rawEvidenceSHA256, completed.manifest.rawEvidenceSHA256)
        XCTAssertEqual(try transformedURLs.map { try Data(contentsOf: $0) }, transformedData)
    }

    func testInterruptedSpeakerRenameKeepsThePreviousCompleteResultActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await speakerSubtitleFixtureJob().run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: .qwenJA,
            speakerLabels: true,
            outputRoot: root
        ))
        let active = try HighQualityJob.renameSpeakers(
            in: completed,
            names: ["SPEAKER_00": "Alice"]
        )
        let activeURLs = completed.manifest.generatedFiles
            .filter { $0.kind == .deliverable }
            .map { completed.directory.appendingPathComponent($0.path) }
            + [completed.directory.appendingPathComponent("transformations.json")]
        let activeData = try activeURLs.map { try Data(contentsOf: $0) }

        XCTAssertThrowsError(try HighQualityJob.renameSpeakers(
            in: active,
            names: ["SPEAKER_00": "Bob"],
            beforeCommit: { throw CocoaError(.fileWriteUnknown) }
        ))

        XCTAssertEqual(try activeURLs.map { try Data(contentsOf: $0) }, activeData)
        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)
        XCTAssertEqual(Set(reopened.turns.compactMap(\.speakerName)), ["Alice"])
        XCTAssertEqual(try activeURLs.map { try Data(contentsOf: $0) }, activeData)
    }

    func testSavedResultKeepsVisibleTurnsFromTheCompletedJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try await HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。二。" },
            unloadASR: {}
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            speakerLabelsByCueID: ["cue-0001": "Narrator"],
            outputRoot: root
        ))

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)

        XCTAssertEqual(reopened.turns, completed.turns)
        XCTAssertEqual(reopened.subtitleCues, completed.subtitleCues)
    }

    func testCancellationDuringSpeakerKitReleasesDiarizationRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let started = expectation(description: "SpeakerKit started")
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 1,
                        cues: [.init(id: "cue-0001", text: "一。", start: 0, end: 1)]
                    )],
                    modelID: "aligner",
                    revision: "revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, configuration in
                XCTAssertTrue(useExclusiveReconciliation)
                XCTAssertEqual(configuration, .init(
                    enhancedPrecision: true,
                    sensitiveDetection: true,
                    countPolicy: .expected(2)
                ))
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                return .init(spans: [], modelID: "speakerkit", revision: "revision", peakMemoryBytes: 0)
            },
            unloadDiarization: { await calls.append("unload-speakerkit") }
        ))
        let task = Task {
            try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                speakerLabels: true,
                useExclusiveReconciliation: true,
                speakerConfiguration: .init(
                    enhancedPrecision: true,
                    sensitiveDetection: true,
                    countPolicy: .expected(2)
                ),
                outputRoot: root
            ))
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop SpeakerKit.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
            let directory = try XCTUnwrap(error.resultDirectory)
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
            XCTAssertEqual(manifest.speakerConfiguration, .init(
                enhancedPrecision: true,
                sensitiveDetection: true,
                countPolicy: .expected(2)
            ))
            XCTAssertEqual(evidence.speakerConfiguration, manifest.speakerConfiguration)
        }
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, ["unload-speakerkit"])
    }

    func testChunkedASRMovesEligibleCutToSilenceAndKeepsWindowsBounded() async throws {
        let sampleRate = 16_000
        var samples = [Float](repeating: 0.5, count: 121 * sampleRate)
        samples.replaceSubrange((54 * sampleRate)..<(55 * sampleRate), with: [Float](
            repeating: 0,
            count: sampleRate
        ))
        let transcripts = [
            "一。共通。", "共通。二。", "二。三。", "三。四。",
            "四。五。", "五。六。", "六。七。",
        ]
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            transcripts[await counts.append(chunk.count) - 1]
        }

        XCTAssertEqual(result.rawTranscript, "一。共通。\n二。\n三。\n四。\n五。\n六。\n七。")
        XCTAssertEqual(result.chunks.count, 7)
        XCTAssertTrue((54..<55).contains(result.chunks[2].sourceEnd))
        XCTAssertEqual(result.chunks[2].sourceEnd, result.chunks[3].sourceStart)
        XCTAssertEqual(result.chunks.last?.sourceEnd, 121)
        XCTAssertTrue(result.chunks.allSatisfy { $0.sourceEnd - $0.sourceStart <= 20.000_001 })
        XCTAssertTrue(zip(result.chunks, result.chunks.dropFirst()).allSatisfy { pair in
            pair.0.sourceEnd == pair.1.sourceStart
        })
        let processedSampleCount = await counts.values.reduce(0, +)
        XCTAssertEqual(processedSampleCount, samples.count + 10 * sampleRate)
    }

    func testChunkedASROverlapsAndReconcilesWhenNoSilenceExists() async throws {
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.5, count: 121 * sampleRate)
        let transcripts = [
            "一。共通。", "共通。二。", "二。三。", "三。四。",
            "四。五。", "五。六。", "六。七。",
        ]
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            transcripts[await counts.append(chunk.count) - 1]
        }

        XCTAssertEqual(result.rawTranscript, "一。共通。\n二。\n三。\n四。\n五。\n六。\n七。")
        XCTAssertEqual(result.chunks.count, 7)
        XCTAssertEqual(result.chunks[0].sourceEnd, 20)
        XCTAssertEqual(result.chunks[1].sourceStart, 20)
        XCTAssertEqual(result.chunks.last?.sourceEnd, 121)
        XCTAssertTrue(result.chunks.allSatisfy { $0.sourceEnd - $0.sourceStart <= 20 })
        XCTAssertTrue(zip(result.chunks, result.chunks.dropFirst()).allSatisfy { pair in
            pair.0.sourceEnd == pair.1.sourceStart
        })
        let processedSampleCount = await counts.values.reduce(0, +)
        XCTAssertEqual(processedSampleCount, samples.count + 12 * sampleRate)
    }

    func testChunkedASRRetainsCharacterTimestampsAfterOverlapRemoval() async throws {
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.5, count: 21 * sampleRate)
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            let text = await counts.append(chunk.count) == 1 ? "一共通" : "共通二"
            return .init(
                rawTranscript: text,
                chunks: [],
                characters: Array(text).enumerated().map { offset, character in
                    .init(
                        chunkIndex: 0,
                        text: String(character),
                        sourceStart: Double(offset == 2 && text == "共通二" ? 1 : offset),
                        sourceEnd: offset == 2 && text == "共通二"
                            ? Double(offset + 1).nextUp : Double(offset + 1)
                    )
                }
            )
        }

        XCTAssertEqual(result.rawTranscript, "一共通\n二")
        XCTAssertEqual(result.characters?.map(\.text).joined(), "一共通二")
        XCTAssertEqual(result.characters?.map(\.chunkIndex), [0, 0, 0, 1])
        XCTAssertEqual(result.characters?.last?.sourceStart, 20)
        XCTAssertEqual(result.characters?.last?.sourceEnd, 21)
        XCTAssertEqual(
            result.windows?.last?.result.characters?.last?.sourceEnd,
            Double(3).nextUp
        )
        XCTAssertFalse(HighQualityASRWorkerClient.isValid(
            result, sampleCount: samples.count, anchored: true
        ))
    }

    func testChunkedASRKeepsForcedAlignmentWindowsWithinTwentySeconds() async throws {
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.5, count: 91 * sampleRate)
        let transcripts = ["一。共通。", "共通。二。", "二。三。", "三。四。", "四。五。"]
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            transcripts[await counts.append(chunk.count) - 1]
        }

        XCTAssertEqual(result.rawTranscript, "一。共通。\n二。\n三。\n四。\n五。")
        XCTAssertEqual(result.chunks.map(\.sourceStart), [0, 20, 38, 56, 74])
        XCTAssertEqual(result.chunks.map(\.sourceEnd), [20, 38, 56, 74, 91])
        XCTAssertTrue(result.chunks.allSatisfy { $0.sourceEnd - $0.sourceStart <= 20 })
    }

    func testChunkedASRAdvancesAlignmentAnchorAcrossEmptyWindows() async throws {
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.5, count: 91 * sampleRate)
        let transcripts = ["一。", "", "二。", "", "三。"]
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            transcripts[await counts.append(chunk.count) - 1]
        }

        XCTAssertEqual(result.rawTranscript, "一。\n二。\n三。")
        XCTAssertEqual(result.chunks.map(\.sourceStart), [0, 38, 74])
        XCTAssertEqual(result.chunks.map(\.sourceEnd), [20, 56, 91])
        XCTAssertTrue(result.chunks.allSatisfy { $0.sourceEnd - $0.sourceStart <= 20 })
    }

    func testEnglishSubtitlesAlignTranslateMergeAndExportBothFormats() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 160_000) },
            prepareASR: { _ in await calls.append("prepare-asr") },
            transcribeJapanese: { _ in "unused" },
            transcribeJapaneseAnchored: { _ in
                .init(
                    rawTranscript: "一。\n二。",
                    chunks: [
                        .init(index: 0, sourceStart: 0, sourceEnd: 5, transcript: "一。"),
                        .init(index: 1, sourceStart: 5, sourceEnd: 10, transcript: "二。"),
                    ]
                )
            },
            unloadASR: { await calls.append("unload-asr") },
            prepareAlignment: { _ in await calls.append("prepare-alignment") },
            alignJapanese: { _, turns in
                XCTAssertEqual(turns.map(\.id), ["cue-0001", "cue-0002"])
                XCTAssertEqual(turns.map(\.sourceStart), [0, 5])
                XCTAssertEqual(turns.map(\.sourceEnd), [5, 10])
                return .init(
                    chunks: [
                        .init(
                            index: 1,
                            sourceStart: 5,
                            sourceEnd: 10,
                            cues: [.init(id: "cue-0002", text: "二。", start: 6.25, end: 8)]
                        ),
                        .init(
                            index: 0,
                            sourceStart: 0,
                            sourceEnd: 5,
                            cues: [.init(id: "cue-0001", text: "一。", start: 1.5, end: 2.75)]
                        ),
                    ],
                    modelID: "fixture-aligner",
                    revision: "fixture-revision",
                    peakMemoryBytes: 456
                )
            },
            unloadAlignment: { await calls.append("unload-alignment") },
            translateEnglish: { request in
                let translations = request.turns.enumerated().map {
                    ["id": $0.element.id, "text": $0.offset == 0 ? "One\n\ncontinued" : "Two"]
                }
                let response = try JSONSerialization.data(withJSONObject: [
                    "translations": translations,
                ])
                return .init(
                    model: "fixture-translator",
                    response: String(decoding: response, as: UTF8.self),
                    attempts: []
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishSubtitles],
            backend: .parakeetJA,
            outputRoot: root
        ))

        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceNormalization, .japaneseASR, .forcedAlignment, .llmTranslation, .export]
        )
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [
            "prepare-asr", "unload-asr", "prepare-alignment", "unload-alignment",
        ])
        XCTAssertEqual(result.subtitleCues.map(\.id), ["unit-0001", "unit-0002"])
        XCTAssertEqual(result.subtitleCues.map(\.start), [1.5, 6.25])
        XCTAssertEqual(result.subtitleCues.map(\.end), [2.75, 8])
        XCTAssertEqual(result.subtitleCues.map(\.text), ["One\n\ncontinued", "Two"])
        XCTAssertTrue(result.subtitleCues.allSatisfy { $0.renderedLines == nil })
        XCTAssertNil(result.manifest.readableSubtitles)
        XCTAssertNil(result.evidence.readableSubtitles)
        XCTAssertNil(result.englishTranscript)
        XCTAssertEqual(result.evidence.alignment?.modelID, "fixture-aligner")
        XCTAssertEqual(result.evidence.alignment?.revision, "fixture-revision")
        XCTAssertEqual(result.evidence.alignment?.chunks.map(\.index), [0, 1])
        XCTAssertEqual(result.evidence.alignment?.peakMemoryBytes, 456)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
            ["english-subtitles.srt", "english-subtitles.vtt", "manifest.json", "raw-asr.json"]
        )
        XCTAssertEqual(
            try String(
                contentsOf: result.directory.appendingPathComponent("english-subtitles.vtt"),
                encoding: .utf8
            ),
            "WEBVTT\n\nunit-0001\n00:00:01.500 --> 00:00:02.750\nOne continued\n\n"
                + "unit-0002\n00:00:06.250 --> 00:00:08.000\nTwo\n\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: result.directory.appendingPathComponent("english-subtitles.srt"),
                encoding: .utf8
            ),
            "1\n00:00:01,500 --> 00:00:02,750\nOne continued\n\n"
                + "2\n00:00:06,250 --> 00:00:08,000\nTwo\n\n"
        )
    }

    func testReadableSubtitlesSplitAtJapanesePauseWithoutChangingWordsOrTimeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let english = "The first measured subtitle clause stays clear and calm as the second measured clause remains equally easy to read."
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 96_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "前半、後半。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, turns in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 6,
                        cues: [.init(
                            id: turns[0].id,
                            text: turns[0].japanese,
                            start: 0,
                            end: 6
                        )],
                        rawItems: [
                            .init(cueID: turns[0].id, text: "前半、", start: 0, end: 2.5),
                            .init(cueID: turns[0].id, text: "後半。", start: 3, end: 6),
                        ]
                    )],
                    modelID: "fixture-aligner",
                    revision: "fixture-revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {},
            translateEnglish: { request in
                let response = try JSONSerialization.data(withJSONObject: [
                    "translations": [["id": request.turns[0].id, "text": english]],
                ])
                return .init(
                    model: "fixture-translator",
                    response: String(decoding: response, as: UTF8.self),
                    attempts: []
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishSubtitles],
            backend: .qwenJA,
            readableSubtitles: true,
            outputRoot: root
        ))

        XCTAssertEqual(result.subtitleCues.count, 2)
        XCTAssertEqual(result.subtitleCues.first?.start, 0)
        XCTAssertEqual(result.subtitleCues.first?.end, 3)
        XCTAssertEqual(result.subtitleCues.last?.start, 3)
        XCTAssertEqual(result.subtitleCues.last?.end, 6)
        XCTAssertEqual(
            result.subtitleCues.flatMap { $0.text.split(whereSeparator: \.isWhitespace) },
            english.split(whereSeparator: \.isWhitespace)
        )
        XCTAssertTrue(result.subtitleCues.allSatisfy {
            guard let lines = $0.renderedLines else { return false }
            return lines.count <= 2 && lines.allSatisfy { $0.count <= 42 }
        })
        let audit = try XCTUnwrap(result.evidence.readableSubtitles)
        XCTAssertEqual(result.manifest.readableSubtitles, true)
        XCTAssertEqual(audit.policy, .product)
        XCTAssertTrue(audit.integrityPassed)
        XCTAssertEqual(audit.splitSourceCueCount, 1)
        XCTAssertEqual(audit.unresolvedSourceCueCount, 0)
        XCTAssertEqual(audit.decisions.first?.boundaries.first?.seconds, 3)
        XCTAssertEqual(
            audit.decisions.first?.boundaries.first?.reasons,
            ["japanese-pause", "japanese-punctuation"]
        )
        let srt = try String(
            contentsOf: result.directory.appendingPathComponent("english-subtitles.srt"),
            encoding: .utf8
        )
        XCTAssertTrue(srt.contains(result.subtitleCues[0].renderedLines!.joined(separator: "\n")))
        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)
        XCTAssertEqual(reopened.subtitleCues, result.subtitleCues)
        XCTAssertEqual(reopened.evidence.readableSubtitles, audit)
    }

    func testReadableSubtitleCancellationBeforeExportKeepsPreviousCompletedResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = [HighQualityAlignedCue(
            id: "cue-0001",
            text: "一。",
            start: 1,
            end: 4
        )]
        let completed = try await subtitleFixtureJob(cues: cues).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishSubtitles],
            backend: .qwenJA,
            readableSubtitles: true,
            outputRoot: root
        ))
        let completedURLs = completed.manifest.generatedFiles
            .filter { $0.kind == .deliverable }
            .map { completed.directory.appendingPathComponent($0.path) }
        let completedData = try completedURLs.map { try Data(contentsOf: $0) }
        let cancelledID = UUID()
        let exportStarted = expectation(description: "readable subtitle export started")
        let task = Task {
            try await subtitleFixtureJob(cues: cues).run(.init(
                id: cancelledID,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: .qwenJA,
                readableSubtitles: true,
                outputRoot: root
            )) { progress in
                guard progress.stage == .exporting else { return }
                exportStarted.fulfill()
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            _ = try await task.value
            XCTFail("Cancellation at the export boundary must stop the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }
        await fulfillment(of: [exportStarted], timeout: 1)

        XCTAssertEqual(try completedURLs.map { try Data(contentsOf: $0) }, completedData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(cancelledID.uuidString).path
            ).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
        let saved = try XCTUnwrap(
            HighQualityJob.savedResults(in: root).first { $0.id == completed.manifest.jobID }
        )
        XCTAssertEqual(try HighQualityJob.reopen(saved).subtitleCues, completed.subtitleCues)
    }

    func testReadableSubtitlesRequireEnglishSubtitleDeliverable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await assertFailure(.application) {
            try await subtitleFixtureJob(cues: []).run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                readableSubtitles: true,
                outputRoot: root
            ))
        }
    }

    func testEnglishSubtitlesRejectInvalidCuesAndRetainAlignmentDiagnostics() async throws {
        let invalidCues: [HighQualityAlignedCue] = [
            .init(id: "cue-0001", text: "一。", start: -1, end: 1),
            .init(id: "cue-0001", text: "一。", start: 2, end: 1),
            .init(id: "cue-0001", text: "一。", start: 1, end: 1),
            .init(id: "cue-0001", text: "一。", start: .nan, end: 1),
            .init(id: "cue-0001", text: "一。", start: 0, end: 11),
            .init(id: "cue-0001", text: "", start: 0, end: 1),
        ]
        for cue in invalidCues {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let job = subtitleFixtureJob(cues: [cue])

            await assertFailure(.alignment) {
                try await job.run(.init(
                    id: id,
                    sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                    deliverables: [.englishSubtitles],
                    backend: .qwenJA,
                    outputRoot: root
                ))
            }

            let evidence = try String(
                contentsOf: root.appendingPathComponent(id.uuidString)
                    .appendingPathComponent("raw-asr.json"),
                encoding: .utf8
            )
            XCTAssertTrue(evidence.contains("fixture-aligner"))
            XCTAssertTrue(evidence.contains("validationDiagnostics"))
        }

        let duplicate = subtitleFixtureJob(cues: [
            .init(id: "cue-0001", text: "一。", start: 0, end: 1),
            .init(id: "cue-0001", text: "一。", start: 1, end: 2),
        ])
        let duplicateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        await assertFailure(.alignment) {
            try await duplicate.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: .qwenJA,
                outputRoot: duplicateRoot
            ))
        }
    }

    func testEnglishSubtitlesUseTheSameJobSeamForEveryOfflineBackend() async throws {
        for backend in HighQualityASRBackend.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let result = try await subtitleFixtureJob(cues: [
                .init(id: "cue-0001", text: "一。", start: 0.25, end: 1),
            ]).run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: backend,
                outputRoot: root
            ))

            XCTAssertEqual(result.manifest.selectedBackend, backend)
            XCTAssertEqual(result.manifest.translationModel, HighQualityTranslator.productDefault.model)
            XCTAssertEqual(result.subtitleCues.map(\.text), ["One"])
        }
    }

    func testEnglishSubtitlesRejectInvalidRawAlignmentTiming() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 160_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 10,
                        cues: [.init(id: "cue-0001", text: "一。", start: 0, end: 1)],
                        rawItems: [.init(
                            cueID: "cue-0001",
                            text: "一",
                            start: .nan,
                            end: 1
                        )]
                    )],
                    modelID: "fixture-aligner",
                    revision: "fixture-revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {}
        ))

        await assertFailure(.alignment) {
            try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
    }

    private func subtitleFixtureJob(cues: [HighQualityAlignedCue]) -> HighQualityJob {
        HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 160_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(index: 0, sourceStart: 0, sourceEnd: 10, cues: cues)],
                    modelID: "fixture-aligner",
                    revision: "fixture-revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {},
            translateEnglish: { request in
                let translations = request.turns.map {
                    ["id": $0.id, "text": "One"]
                }
                let response = try JSONSerialization.data(withJSONObject: [
                    "translations": translations,
                ])
                return .init(
                    model: "fixture-translator",
                    response: String(decoding: response, as: UTF8.self),
                    attempts: []
                )
            }
        ))
    }

    private func speakerSubtitleFixtureJob() -> HighQualityJob {
        HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 160_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            transcribeJapaneseAnchored: { _ in
                .init(
                    rawTranscript: "一。",
                    chunks: [.init(index: 0, sourceStart: 0, sourceEnd: 10, transcript: "一。")]
                )
            },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: 10,
                        cues: [.init(id: "cue-0001", text: "一。", start: 1, end: 4)]
                    )],
                    modelID: "aligner",
                    revision: "revision",
                    peakMemoryBytes: 0
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, _ in
                .init(
                    spans: [
                        .init(speakerID: 0, start: 1, end: 4),
                        .init(speakerID: 1, start: 4, end: 5),
                    ],
                    modelID: "speakerkit",
                    revision: "revision",
                    peakMemoryBytes: 0,
                    useExclusiveReconciliation: useExclusiveReconciliation
                )
            },
            unloadDiarization: {},
            translateEnglish: { request in
                XCTAssertTrue(request.turns.allSatisfy { $0.speakerLabel == nil })
                let translations = request.turns.map {
                    #"{"id":"\#($0.id)","text":"One"}"#
                }.joined(separator: ",")
                return .init(
                    model: "translator",
                    response: #"{"translations":[\#(translations)]}"#,
                    attempts: []
                )
            }
        ))
    }

    func testJobSelectsSourceRelevantGlossaryAndPreservesRawASR() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rawASR = "  甘結もかがエーペックスレジェンズをプレイ。お疲れさま。\n"
        let sourceURL = try XCTUnwrap(URL(string: "https://youtu.be/abc123"))
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            acquireYouTube: { url, directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let audioURL = directory.appendingPathComponent("source.m4a")
                try Data().write(to: audioURL)
                return .init(
                    audioURL: audioURL,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "甘結もか Apex Legends",
                        channel: "Fixture channel",
                        description: "VTuber gaming conversation",
                        ytDLPVersion: "fixture",
                        diagnostics: "fixture"
                    )
                )
            },
            prepareASR: { _ in },
            transcribeJapanese: { _ in rawASR },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { request in
                XCTAssertEqual(
                    Set(request.glossary.map(\.id)),
                    ["amayui-moka", "apex-legends", "otsukaresama"]
                )
                XCTAssertEqual(
                    Set(request.glossary(for: request.turns[0]).map(\.id)),
                    ["amayui-moka", "apex-legends"]
                )
                XCTAssertEqual(
                    request.glossary(for: request.turns[1]).map(\.id),
                    ["otsukaresama"]
                )
                let translations = request.turns.enumerated().map {
                    [
                        "id": $0.element.id,
                        "text": $0.offset == 0
                            ? "Amayui Moka plays Apex Legends."
                            : "Thanks for your hard work.",
                    ]
                }
                let response = try JSONSerialization.data(withJSONObject: [
                    "translations": translations,
                ])
                return .init(
                    model: "fixture",
                    response: String(decoding: response, as: UTF8.self),
                    attempts: []
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        XCTAssertEqual(result.evidence.rawASR, rawASR)
        XCTAssertEqual(
            Set(result.evidence.glossary.decisions.filter(\.selected).map(\.term.id)),
            ["amayui-moka", "apex-legends", "otsukaresama"]
        )
        XCTAssertEqual(
            result.evidence.glossary.terminologyRegister["amayui-moka"],
            "Amayui Moka"
        )
    }

    func testEnglishOnlyJobTranslatesContextualStableCuesAndExportsOnlyEnglish() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("conversation.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: source)
        let workerEvidence = HighQualityTranslationWorkerEvidence(
            command: ["fixture-worker"],
            processIdentifier: 42,
            startedAt: Date(timeIntervalSince1970: 1),
            exitedAt: Date(timeIntervalSince1970: 2),
            elapsedSeconds: 1,
            exitStatus: 0,
            terminationReason: "exit",
            forcedTermination: false,
            peakPhysicalFootprintBytes: 123,
            pressureTransitions: [],
            availableMemorySamples: [],
            swapUsedBeforeBytes: 10,
            swapUsedAfterBytes: 10,
            rawLogPath: "/tmp/fixture-worker.log",
            rawLog: "fixture"
        )

        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはよう。今日は元気ですか？" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { request in
                XCTAssertEqual(request.source.fileName, "conversation.wav")
                XCTAssertEqual(request.turns.map(\.id), ["unit-0001", "unit-0002"])
                XCTAssertEqual(request.turns[0].followingJapanese, ["今日は元気ですか？"])
                XCTAssertEqual(request.turns[1].precedingJapanese, ["おはよう。"])
                XCTAssertNil(request.turns[1].speakerLabel)
                let outputs = ["Good morning", "How are you today?"]
                return .init(
                    model: "fixture-model",
                    response: #"{"translations":[{"id":"unit-0001","text":"Good morning"},{"id":"unit-0002","text":"How are you today?"}]}"#,
                    attempts: [.init(number: 1, duration: 0.25, outcome: "success")],
                    batches: zip(request.turns, outputs).map { turn, output in
                        .init(
                            cueIDs: [turn.id],
                            sanitizedPrompt: turn.japanese,
                            nativePrompt: "official-direct-prompt",
                            nativeOutput: output,
                            model: "fixture-model",
                            revision: "fixture-revision",
                            sanitizedOutput: output,
                            inputTokens: 8,
                            duration: 0.1
                        )
                    }
                )
            },
            translationWorkerEvidence: { workerEvidence }
        ))

        let result = try await job.run(.init(
            sourceURL: source,
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            speakerLabelsByCueID: ["cue-0002": "Speaker 2"],
            outputRoot: root
        ))

        XCTAssertEqual(result.englishTranscript, "Good morning\nSpeaker 2: How are you today?")
        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceNormalization, .japaneseASR, .forcedAlignment, .llmTranslation, .export]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
            ["english-translation-transcript.txt", "manifest.json", "raw-asr.json"]
        )
        XCTAssertEqual(result.evidence.translation?.model, "fixture-model")
        XCTAssertEqual(result.evidence.translation?.attempts.count, 1)
        XCTAssertEqual(result.evidence.translation?.validationFailures, [])
        XCTAssertEqual(result.evidence.translation?.worker, workerEvidence)
        XCTAssertEqual(result.turns.map(\.id), ["unit-0001", "unit-0002"])
        XCTAssertEqual(result.turns.compactMap(\.english), ["Good morning", "How are you today?"])
        XCTAssertEqual(
            result.evidence.translation?.batches.compactMap(\.nativeOutput),
            ["Good morning", "How are you today?"]
        )
        XCTAssertTrue(result.evidence.translation?.batches.allSatisfy {
            !($0.nativeOutput ?? "").contains($0.cueIDs[0])
        } == true)

        let combined = try await job.run(.init(
            sourceURL: source,
            deliverables: [.japaneseTranscript, .englishTranslationTranscript],
            backend: .qwenJA,
            speakerLabelsByCueID: ["cue-0002": "Speaker 2"],
            outputRoot: root
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: combined.directory.path).sorted(),
            [
                "english-translation-transcript.txt",
                "japanese-transcript.txt",
                "manifest.json",
                "raw-asr.json",
            ]
        )
    }

    func testMalformedTranslationsFailAndRetainSanitizedEvidence() async throws {
        let responses = [
            #"{"translations":[]}"#,
            #"{"translations":[{"id":"unit-0001","text":"One"},{"id":"unit-0001","text":"Again"}]}"#,
            #"{"translations":[{"id":"unit-9999","text":"Unknown"}]}"#,
            #"{"translations":[{"id":"unit-0001","text":"Here's the translation: One"}]}"#,
            #"{"translations":[{"id":"unit-0001","text":"speaker_id: One"}]}"#,
        ]
        for response in responses {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let job = HighQualityJob(services: .init(
                loadSource: { _ in [0.1] },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "一\n二" },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: highQualityFixtureAlignment,
                translateEnglish: { _ in
                    .init(
                        model: "fixture-model",
                        response: response,
                        attempts: [.init(number: 1, duration: 0.1, outcome: "success")]
                    )
                }
            ))

            do {
                _ = try await job.run(.init(
                    id: id,
                    sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                    deliverables: [.englishTranslationTranscript],
                    backend: .qwenJA,
                    outputRoot: root
                ))
                XCTFail("Malformed translations must fail.")
            } catch let error as HighQualityJobError {
                XCTAssertEqual(error.stage, .translation)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let evidence = try decoder.decode(
                HighQualityRawEvidence.self,
                from: Data(contentsOf: root.appendingPathComponent(id.uuidString)
                    .appendingPathComponent("raw-asr.json"))
            )
            XCTAssertEqual(evidence.translation?.response, response)
            XCTAssertEqual(evidence.translation?.model, "fixture-model")
            XCTAssertEqual(evidence.translation?.validationFailures.count, 1)
        }
    }

    func testBackupNeverContainsTranslationAPIKey() throws {
        let defaults = UserDefaults.standard
        let key = "ticket-40-secret-\(UUID().uuidString)"
        defaults.set(key, forKey: "translationAPIKey")
        defer { defaults.removeObject(forKey: "translationAPIKey") }

        let json = String(decoding: try BackupService.encode(BackupService.makeBackup()), as: UTF8.self)

        XCTAssertFalse(json.contains(key))
        XCTAssertFalse(json.contains("translationAPIKey"))
    }

    func testYouTubeSourceUsesAcquiredAudioAndRetainsAcquisitionEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let loadedURL = URLBox()
        let job = HighQualityJob(services: .init(
            loadSource: {
                await loadedURL.set($0)
                return [0.1]
            },
            acquireYouTube: { url, directory in
                let audioURL = directory.appendingPathComponent("source.m4a")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("audio".utf8).write(to: audioURL)
                return HighQualityYouTubeAcquisition(
                    audioURL: audioURL,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "Fixture title",
                        channel: "Fixture channel",
                        description: "Fixture description",
                        ytDLPVersion: "2026.08.08",
                        diagnostics: "fixture format=m4a"
                    )
                )
            },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "日本語" },
            unloadASR: {}
        ))

        let result = try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        let normalizedURL = await loadedURL.value
        XCTAssertEqual(normalizedURL?.lastPathComponent, "source.m4a")
        XCTAssertEqual(result.manifest.source.youtube?.title, "Fixture title")
        XCTAssertEqual(result.manifest.source.youtube?.channel, "Fixture channel")
        XCTAssertEqual(result.manifest.source.youtube?.description, "Fixture description")
        XCTAssertEqual(result.manifest.source.youtube?.sourceURL, sourceURL.absoluteString)
        XCTAssertEqual(result.manifest.source.youtube?.ytDLPVersion, "2026.08.08")
        XCTAssertEqual(result.manifest.source.youtube?.diagnostics, "fixture format=m4a")
        XCTAssertEqual(result.evidence.source.youtube, result.manifest.source.youtube)
        XCTAssertTrue(result.manifest.generatedFiles.contains {
            $0.path == "acquisition/source.m4a" && $0.kind == .evidence
        })
        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceAcquisition, .sourceNormalization, .japaneseASR, .export]
        )
    }

    func testYouTubeValidationAndAcquisitionFailuresStopBeforeModels() async throws {
        struct FixtureError: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in await calls.append("source"); return [] },
            acquireYouTube: { _, directory in
                await calls.append("acquire")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent("source.webm.part")
                )
                throw FixtureError()
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in await calls.append("asr"); return "unused" },
            unloadASR: {}
        ))

        for url in [
            "https://example.com/watch?v=abc123",
            "https://www.youtube.com/watch?v=abc123&list=playlist",
            "https://user:password@www.youtube.com/watch?v=abc123",
        ] {
            await assertFailure(.acquisition) {
                try await job.run(.init(
                    sourceURL: try XCTUnwrap(URL(string: url)),
                    deliverables: [.japaneseTranscript],
                    backend: .qwenJA,
                    outputRoot: root
                ))
            }
        }
        let callsAfterValidation = await calls.values
        XCTAssertEqual(callsAfterValidation, [])

        let id = UUID()
        await assertFailure(.acquisition) {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        let callsAfterAcquisition = await calls.values
        XCTAssertEqual(callsAfterAcquisition, ["acquire"])
        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.source.sourceURL, "https://youtu.be/abc123")
    }

    func testCancellingYouTubeAcquisitionRemovesIncompleteDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in XCTFail("Incomplete acquisition must not be normalized."); return [] },
            acquireYouTube: { _, directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent("source.webm.part")
                )
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            },
            prepareASR: { _ in XCTFail("Incomplete acquisition must not reach ASR.") },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        let task = Task {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop YouTube acquisition.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
    }

    func testCancellationAfterYouTubeAcquisitionPreservesCompletedSourceEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            acquireYouTube: { url, directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let audioURL = directory.appendingPathComponent("source.m4a")
                try Data("complete".utf8).write(to: audioURL)
                let acquisition = HighQualityYouTubeAcquisition(
                    audioURL: audioURL,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "Completed source",
                        channel: "Channel",
                        description: "Description",
                        ytDLPVersion: "fixture",
                        diagnostics: "complete"
                    )
                )
                withUnsafeCurrentTask { $0?.cancel() }
                return acquisition
            },
            prepareASR: { _ in },
            transcribeJapanese: { _ in
                try await Task.sleep(for: .seconds(10))
                return "unused"
            },
            unloadASR: {}
        ))
        let task = Task {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation immediately after acquisition must stop the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition/source.m4a").path
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
        XCTAssertEqual(manifest.source.youtube?.title, "Completed source")
        XCTAssertTrue(manifest.generatedFiles.contains {
            $0.path == "acquisition/source.m4a" && $0.kind == .evidence
        })
    }

    func testYouTubeAcquirerUsesDeterministicExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("acquisition", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --ignore-config "*) ;; *) exit 2 ;; esac
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            case " $* " in *" --no-playlist "*) ;; *) exit 3 ;; esac
            case " $* " in *" --no-simulate "*) ;; *) exit 4 ;; esac
            printf 'audio' > '\(directory.appendingPathComponent("source.m4a").path)'
            printf '%s\\n' '{"title":"Fixture title","channel":"Fixture channel","description":"Fixture description","format_id":"140","ext":"m4a"}'
            printf 'fixture diagnostics\\n' >&2
            """)
        let sourceURL = try XCTUnwrap(URL(string: "https://youtu.be/abc123"))

        let acquisition = try await YouTubeAcquirer.acquire(
            sourceURL,
            to: directory,
            using: executable
        )

        XCTAssertEqual(acquisition.audioURL.lastPathComponent, "source.m4a")
        XCTAssertEqual(acquisition.evidence.title, "Fixture title")
        XCTAssertEqual(acquisition.evidence.channel, "Fixture channel")
        XCTAssertEqual(acquisition.evidence.description, "Fixture description")
        XCTAssertEqual(acquisition.evidence.ytDLPVersion, "fixture-version")
        XCTAssertEqual(acquisition.evidence.diagnostics, "format=140/m4a\nfixture diagnostics")
    }

    func testYouTubeAcquirerTerminatesItsProcessWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("acquisition", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            while :; do :; done
            """)
        let task = Task {
            try await YouTubeAcquirer.acquire(
                XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                to: directory,
                using: executable
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must terminate yt-dlp.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testYouTubeDownloadFailureRetainsVersionAndDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            printf 'private or unsupported source\\n' >&2
            exit 5
            """)
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in XCTFail("Failed acquisition must not be normalized."); return [] },
            acquireYouTube: {
                try await YouTubeAcquirer.acquire($0, to: $1, using: executable)
            },
            prepareASR: { _ in XCTFail("Failed acquisition must not reach ASR.") },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))

        await assertFailure(.acquisition) {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.source.youtube?.ytDLPVersion, "fixture-version")
        XCTAssertEqual(
            manifest.source.youtube?.diagnostics,
            "private or unsupported source"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("acquisition").path
        ))
    }

    private func makeFakeYTDLP(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("yt-dlp")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func testRejectsJobWithoutDeliverableBeforeProcessing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in await calls.append("source"); return [] },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in await calls.append("asr"); return "" },
            unloadASR: { await calls.append("unload") }
        ))

        do {
            _ = try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/input.wav"),
                deliverables: [],
                backend: .qwenJA,
                outputRoot: root
            ))
            XCTFail("A job without a Deliverable must fail.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .application)
        }

        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

    }

    func testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(HighQualityASRBackend.allCases, [.qwenJA, .parakeetJA, .whisperKit])
        XCTAssertEqual(HighQualityASRBackend.productDefault, .qwenJA)
        XCTAssertEqual(
            HighQualityASRBackend(rawValue: "funasr-nano-int8"),
            .funASRNanoInt8
        )

        for backend in HighQualityASRBackend.allCases {
            let progress = ProgressLog()
            let expectedRawASR = switch backend {
            case .qwenJA: " こんにちは \n"
            case .parakeetJA: " 日本語 \n"
            case .whisperKit: " 音声認識 \n"
            case .funASRNanoInt8: " 実験 \n"
            case .reazonSpeechK2V2: ""
            }
            let job = HighQualityJob(servicesForBackend: { _ in
                .init(
                    loadSource: { _ in [0.1, 0.2] },
                    prepareASR: { $0(1, "ready") },
                    transcribeJapanese: { _ in expectedRawASR },
                    unloadASR: {},
                    currentMemoryBytes: { 123 }
                )
            })
            let result = try await job.run(.init(
                sourceURL: source,
                deliverables: [.japaneseTranscript],
                backend: backend,
                outputRoot: root
            )) { progress.append($0) }

            XCTAssertEqual(result.japaneseTranscript, expectedRawASR
                .trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(result.manifest.status, .completed)
            XCTAssertEqual(
                result.manifest.dependencies,
                [.sourceNormalization, .japaneseASR, .export]
            )
            XCTAssertEqual(result.manifest.peakMemoryBytes, 123)
            XCTAssertEqual(result.manifest.selectedBackend, backend)
            XCTAssertNil(result.manifest.translationModel)
            XCTAssertEqual(result.manifest.model.backend, backend)
            XCTAssertFalse(result.manifest.model.revision.isEmpty)
            if backend == .whisperKit {
                XCTAssertEqual(
                    result.manifest.model.modelID,
                    LocalPrototypeModelID.whisperKitEvidenceModelID
                )
                XCTAssertEqual(
                    result.manifest.model.revision,
                    LocalPrototypeModelID.whisperKitModelRevision
                )
                XCTAssertEqual(
                    result.manifest.model.runtimeVersion,
                    LocalPrototypeModelID.whisperKitRuntimeVersion
                )
            }
            XCTAssertFalse(result.manifest.speakerLabels)
            XCTAssertEqual(result.evidence.rawASR, expectedRawASR)
            XCTAssertEqual(result.evidence.peakMemoryBytes, 123)
            XCTAssertEqual(result.evidence.modelEvents.map(\.kind), [
                .loadStarted, .loadCompleted, .unloadCompleted,
            ])
            XCTAssertEqual(result.manifest.modelEvents, result.evidence.modelEvents)
            XCTAssertTrue(result.manifest.stageDurations.keys.contains(.preparingASR))
            XCTAssertTrue(result.manifest.stageDurations.keys.contains(.transcribing))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
                ["japanese-transcript.txt", "manifest.json", "raw-asr.json"]
            )
            XCTAssertEqual(
                try String(
                    contentsOf: result.directory.appendingPathComponent("japanese-transcript.txt"),
                    encoding: .utf8
                ),
                expectedRawASR.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            )
            let evidence = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: result.directory
                    .appendingPathComponent("raw-asr.json"))) as? [String: Any]
            )
            XCTAssertEqual(evidence["rawASR"] as? String, expectedRawASR)
            XCTAssertEqual(evidence["sampleCount"] as? Int, 2)
            XCTAssertEqual((evidence["source"] as? [String: Any])?["fileName"] as? String, "source.mp4")
            XCTAssertEqual((evidence["generatedFiles"] as? [[String: Any]])?.count, 3)
            XCTAssertTrue(progress.values.contains {
                $0.stage == .preparingASR && $0.message == "ready"
            })
        }
    }

    func testRealOfflineBackendFunctionalGateWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE"
        ], let expectedSHA256 = ProcessInfo.processInfo.environment[
            "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256"
        ] else {
            throw XCTSkip(
                "Set WHISPERASR_HIGH_QUALITY_ASR_FIXTURE and its SHA-256 to a long Japanese fixture."
            )
        }
        let sourceURL = URL(fileURLWithPath: path)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: sourceURL), expectedSHA256)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for backend in HighQualityASRBackend.allCases {
            let result = try await HighQualityJob().run(.init(
                sourceURL: sourceURL,
                deliverables: [.japaneseTranscript],
                backend: backend,
                outputRoot: root
            ))
            XCTAssertFalse(result.japaneseTranscript.isEmpty)
            XCTAssertEqual(result.manifest.selectedBackend, backend)
            XCTAssertEqual(result.manifest.status, .completed)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
                ["japanese-transcript.txt", "manifest.json", "raw-asr.json"]
            )

            let startedTranscribing = expectation(
                description: "\(backend.displayName) started transcribing"
            )
            let cancellationID = UUID()
            let task = Task {
                try await HighQualityJob().run(.init(
                    id: cancellationID,
                    sourceURL: sourceURL,
                    deliverables: [.japaneseTranscript],
                    backend: backend,
                    outputRoot: root
                )) { progress in
                    if progress.stage == .transcribing { startedTranscribing.fulfill() }
                }
            }
            await fulfillment(of: [startedTranscribing], timeout: 600)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancelling \(backend.displayName) must stop the job.")
            } catch let error as HighQualityJobError {
                XCTAssertEqual(error.stage, .cancelled)
                XCTAssertEqual(error.message, "Job cancelled.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cancelledManifest = try decoder.decode(
                HighQualityJobManifest.self,
                from: Data(contentsOf: root.appendingPathComponent(cancellationID.uuidString)
                    .appendingPathComponent("manifest.json"))
            )
            XCTAssertEqual(cancelledManifest.status, .cancelled)
            XCTAssertEqual(cancelledManifest.selectedBackend, backend)
            XCTAssertFalse(cancelledManifest.modelEvents.contains {
                $0.kind == .guardFailed
            })
        }
    }

    func testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface() async throws {
        struct FixtureError: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFailure = HighQualityJob(services: .init(
            loadSource: { _ in throw FixtureError() },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        await assertFailure(.source) {
            try await sourceFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }

        let preparationFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in throw FixtureError() },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        await assertFailure(.modelPreparation) {
            try await preparationFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .whisperKit,
                outputRoot: root
            ))
        }

        let asrFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in throw FixtureError() },
            unloadASR: {}
        ))
        await assertFailure(.asr) {
            try await asrFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .whisperKit,
                outputRoot: root
            ))
        }

        let emptyOutputID = UUID()
        let emptyOutput = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in " \n" },
            unloadASR: {}
        ))
        await assertFailure(.asr) {
            try await emptyOutput.run(.init(
                id: emptyOutputID,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let emptyEvidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: root.appendingPathComponent(emptyOutputID.uuidString)
                .appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(emptyEvidence.rawASR, " \n")

        let exportID = UUID()
        let exportDirectory = root.appendingPathComponent(exportID.uuidString)
        let exportFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in
                try FileManager.default.removeItem(at: exportDirectory)
                return "日本語"
            },
            unloadASR: {}
        ))
        await assertFailure(.export) {
            try await exportFailure.run(.init(
                id: exportID,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
    }

    func testCancellationIsSafeForEveryOfflineBackend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for backend in HighQualityASRBackend.allCases {
            let id = UUID()
            let job = HighQualityJob(services: .init(
                loadSource: { _ in [0] },
                prepareASR: { _ in },
                transcribeJapanese: { _ in
                    try await Task.sleep(for: .seconds(10))
                    return "unused"
                },
                unloadASR: {}
            ))
            let task = Task {
                try await job.run(.init(
                    id: id,
                    sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                    deliverables: [.japaneseTranscript],
                    backend: backend,
                    outputRoot: root
                ))
            }
            try await Task.sleep(for: .milliseconds(20))
            task.cancel()

            do {
                _ = try await task.value
                XCTFail("Cancellation must stop the job.")
            } catch let error as HighQualityJobError {
                XCTAssertEqual(error.stage, .cancelled)
            }

            let directory = root.appendingPathComponent(id.uuidString)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            XCTAssertEqual(files, ["manifest.json", "raw-asr.json"])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                HighQualityJobManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            )
            XCTAssertEqual(manifest.status, .cancelled)
            XCTAssertEqual(manifest.selectedBackend, backend)
            XCTAssertEqual(manifest.modelEvents.last?.kind, .unloadCompleted)
        }
    }

    func testCancellationDuringModelPreparationIsClassifiedAsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "model preparation started")
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in
                started.fulfill()
                while !Task.isCancelled { await Task.yield() }
                throw URLError(.cancelled)
            },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        let task = Task {
            try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .whisperKit,
                outputRoot: root
            ))
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelling model preparation must stop the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
    }

    func testPeakMemoryIsSampledDuringASRStages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = MemoryReadings([100, 500, 200])
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in try await Task.sleep(for: .milliseconds(250)) },
            transcribeJapanese: { _ in "日本語" },
            unloadASR: {},
            currentMemoryBytes: { await readings.next() }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .whisperKit,
            outputRoot: root
        ))

        XCTAssertEqual(result.manifest.peakMemoryBytes, 500)
    }

    func testCriticalMemoryPressureFailsClosedUnloadsAndReleasesTheWorkflow() async throws {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let footprint = MemoryValue(gib)
        let available = MemoryValue(20 * gib)
        let pressure = MacMemoryPressureMonitor(native: false)
        let calls = CallLog()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24 * gib,
            reserveBytes: 8 * gib,
            releaseToleranceBytes: gib / 10,
            releaseTimeout: .milliseconds(50),
            releasePollInterval: .milliseconds(1),
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await footprint.value },
            currentAvailableMemoryBytes: { await available.value },
            memoryPressure: pressure
        )
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in
                pressure.record(.critical)
                while true { try await Task.sleep(for: .milliseconds(1)) }
            },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {
                await calls.append("unload")
                await footprint.set(gib)
            },
            currentMemoryBytes: { await footprint.value },
            heavyweightGate: gate
        ))

        do {
            _ = try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .whisperKit,
                outputRoot: root
            ))
            XCTFail("The job must fail when macOS memory pressure becomes critical.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .modelPreparation)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .failed)
        XCTAssertTrue(manifest.modelEvents.contains {
            $0.kind == .guardFailed && $0.message?.contains("memory pressure") == true
        }, "\(manifest.modelEvents)")
        XCTAssertTrue(
            manifest.modelEvents.contains { $0.kind == .memoryReleaseChecked },
            "\(manifest.modelEvents)"
        )
        let callValues = await calls.values
        XCTAssertEqual(callValues, ["unload"])

        pressure.record(.normal)
        let live = try await gate.beginWorkflow(.live)
        try await gate.endWorkflow(live)
    }

    func testAlignmentAndDiarizationWorkerEvidenceReachesRawEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alignmentWorker = Self.workerEvidence(pid: 41, peak: 120)
        let diarizationWorker = Self.workerEvidence(pid: 42, peak: 240)
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { samples, turns in
                var exchange = try await highQualityFixtureAlignment(samples, turns)
                exchange = .init(
                    chunks: exchange.chunks,
                    modelID: exchange.modelID,
                    revision: exchange.revision,
                    peakMemoryBytes: exchange.peakMemoryBytes,
                    configuration: ["language": "Japanese", "sampleRate": "16000"]
                )
                return exchange
            },
            unloadAlignment: {},
            alignmentWorkerEvidence: { alignmentWorker },
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, exclusive, configuration in
                .init(
                    spans: [.init(speakerID: 0, start: 0, end: 1)],
                    modelID: "fixture-speakerkit",
                    revision: "fixture-revision",
                    peakMemoryBytes: 0,
                    useExclusiveReconciliation: exclusive,
                    speakerCountPolicy: configuration.countPolicy,
                    configuration: [
                        "precision": "quantized",
                        "clusterDistanceThreshold": "library-default",
                        "overlap": "non-exclusive",
                        "attribution": "principal",
                    ]
                )
            },
            unloadDiarization: {},
            diarizationWorkerEvidence: { diarizationWorker }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            speakerLabels: true,
            outputRoot: root
        ))

        XCTAssertEqual(result.evidence.alignment?.worker, alignmentWorker)
        XCTAssertEqual(result.evidence.diarization?.worker, diarizationWorker)
        XCTAssertEqual(result.evidence.alignment?.configuration?["sampleRate"], "16000")
        XCTAssertEqual(result.evidence.diarization?.configuration?["precision"], "quantized")
        XCTAssertEqual(result.manifest.peakMemoryBytes, 240)
        XCTAssertEqual(result.turns.map(\.speakerLabel), ["SPEAKER_00"])
    }

    func testAlignmentWorkerFailureIsClassifiedAndPreservesPartialEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let worker = Self.workerEvidence(pid: 43, peak: 333)
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in
                throw HighQualityAlignmentSpeakerWorkerError.protocolFailure(
                    stage: "Forced alignment",
                    message: "malformed evidence"
                )
            },
            unloadAlignment: {},
            alignmentWorkerEvidence: { worker }
        ))

        do {
            _ = try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: .qwenJA,
                outputRoot: root
            ))
            XCTFail("Malformed alignment evidence must fail the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .alignment)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.alignment?.worker, worker)
        XCTAssertEqual(evidence.alignment?.validationDiagnostics, [
            "Forced alignment worker failed: malformed evidence",
        ])
        XCTAssertEqual(evidence.failures.first?.stage, .alignment)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("english-subtitles.srt").path
        ))
    }

    func testCriticalTransitionAfterAlignmentResponseFailsBeforeExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let worker = Self.workerEvidence(
            pid: 44,
            peak: 444,
            pressureTransitions: [
                .init(level: .critical, at: Date(timeIntervalSince1970: 2)),
            ]
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            unloadAlignment: {},
            alignmentWorkerEvidence: { worker }
        ))

        do {
            _ = try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishSubtitles],
                backend: .qwenJA,
                outputRoot: root
            ))
            XCTFail("A terminal critical-pressure transition must fail before export.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .alignment)
            XCTAssertTrue(error.message.contains("recoverable"))
        }

        let directory = root.appendingPathComponent(id.uuidString)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.alignment?.worker, worker)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("english-subtitles.srt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("english-subtitles.vtt").path
        ))
    }

    private static func workerEvidence(
        pid: Int32,
        peak: UInt64,
        pressureTransitions: [MacMemoryPressureTransition] = []
    ) -> HighQualityWorkerEvidence {
        .init(
            command: ["fixture-worker"],
            processIdentifier: pid,
            startedAt: Date(timeIntervalSince1970: 1),
            exitedAt: Date(timeIntervalSince1970: 2),
            elapsedSeconds: 1,
            exitStatus: 0,
            terminationReason: "exit",
            forcedTermination: false,
            peakPhysicalFootprintBytes: peak,
            pressureTransitions: pressureTransitions,
            availableMemorySamples: [],
            swapUsedBeforeBytes: 10,
            swapUsedAfterBytes: 10,
            rawLogPath: "/tmp/fixture-worker.log",
            rawLog: "fixture"
        )
    }

    private func assertFailure(
        _ expected: HighQualityJobFailureStage,
        operation: () async throws -> HighQualityJobResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected.rawValue) failure.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor CallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor SampleCounts {
    private(set) var values: [Int] = []

    func append(_ value: Int) -> Int {
        values.append(value)
        return values.count
    }
}

private actor URLBox {
    private(set) var value: URL?

    func set(_ value: URL) {
        self.value = value
    }
}

private actor MemoryReadings {
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        values.count > 1 ? values.removeFirst() : values[0]
    }
}

private actor MemoryValue {
    private(set) var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func set(_ value: UInt64) {
        self.value = value
    }
}

let highQualityFixtureAlignment: @Sendable (
    [Float],
    [HighQualityTranslationTurn]
) async throws -> HighQualityAlignmentExchange = { samples, turns in
    let duration = Double(samples.count) / 16_000
    let cueDuration = duration / Double(max(turns.count, 1))
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
        revision: "fixture-revision",
        peakMemoryBytes: 0
    )
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HighQualityJobProgress] = []

    var values: [HighQualityJobProgress] {
        lock.withLock { storage }
    }

    func append(_ value: HighQualityJobProgress) {
        lock.withLock { storage.append(value) }
    }
}
