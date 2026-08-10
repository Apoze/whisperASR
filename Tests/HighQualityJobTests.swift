import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityJobTests: XCTestCase {
    func testAutoAndExpectedSpeakerCountsReachSpeakerKitAndRawEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for policy in [HighQualitySpeakerCountPolicy.automatic, .expected(2)] {
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
                prepareDiarization: { _ in },
                diarizeSpeakers: { _, _, receivedPolicy in
                    XCTAssertEqual(receivedPolicy, policy)
                    return .init(
                        spans: [.init(speakerID: 0, start: 0, end: 1)],
                        modelID: "speakerkit",
                        revision: "revision",
                        peakMemoryBytes: 0,
                        speakerCountPolicy: receivedPolicy
                    )
                },
                unloadDiarization: {}
            ))
            let request = HighQualityJobRequest(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                speakerLabels: true,
                speakerCountPolicy: policy,
                outputRoot: root
            )

            XCTAssertEqual(request.speakerCountPolicy, policy)
            let result = try await job.run(request)

            XCTAssertEqual(result.manifest.speakerCountPolicy, policy)
            XCTAssertEqual(result.evidence.speakerCountPolicy, policy)
            XCTAssertEqual(result.evidence.diarization?.speakerCountPolicy, policy)
        }
    }

    func testInvalidOrDisabledExpectedSpeakerCountFailsBeforeModelPreparation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (speakerLabels, policy) in [
            (true, HighQualitySpeakerCountPolicy.expected(0)),
            (true, .expected(21)),
            (false, .expected(2)),
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
                speakerCountPolicy: policy,
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
                XCTAssertEqual(manifest.speakerCountPolicy, policy)
                XCTAssertEqual(evidence.speakerCountPolicy, policy)
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
                prepareDiarization: { _ in },
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
            prepareDiarization: { _ in await calls.append("prepare-speakerkit") },
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
            prepareDiarization: { _ in },
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
            prepareDiarization: { _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, speakerCountPolicy in
                XCTAssertTrue(useExclusiveReconciliation)
                XCTAssertEqual(speakerCountPolicy, .expected(2))
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
                speakerCountPolicy: .expected(2),
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
            XCTAssertEqual(manifest.speakerCountPolicy, .expected(2))
            XCTAssertEqual(evidence.speakerCountPolicy, .expected(2))
        }
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, ["unload-speakerkit"])
    }

    func testChunkedASRMovesCutsToSilenceAndCoversTheSourceExactlyOnce() async throws {
        let sampleRate = 16_000
        var samples = [Float](repeating: 0.5, count: 121 * sampleRate)
        samples.replaceSubrange((58 * sampleRate)..<(59 * sampleRate), with: [Float](
            repeating: 0,
            count: sampleRate
        ))
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            let index = await counts.append(chunk.count)
            return index == 1 ? "一。" : "二。"
        }

        XCTAssertEqual(result.rawTranscript, "一。\n二。")
        XCTAssertEqual(result.chunks.count, 2)
        XCTAssertTrue((58..<59).contains(result.chunks[0].sourceEnd))
        XCTAssertEqual(result.chunks[0].sourceEnd, result.chunks[1].sourceStart)
        XCTAssertEqual(result.chunks[1].sourceEnd, 121)
        let processedSampleCount = await counts.values.reduce(0, +)
        XCTAssertEqual(processedSampleCount, samples.count)
    }

    func testChunkedASROverlapsAndReconcilesWhenNoSilenceExists() async throws {
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.5, count: 121 * sampleRate)
        let counts = SampleCounts()

        let result = try await HighQualityJob.Services.chunkedASR(samples) { chunk in
            let index = await counts.append(chunk.count)
            return index == 1 ? "一。共通。" : "共通。二。"
        }

        XCTAssertEqual(result.rawTranscript, "一。共通。\n二。")
        XCTAssertEqual(result.chunks.count, 2)
        XCTAssertEqual(result.chunks[0].sourceEnd, 61)
        XCTAssertEqual(result.chunks[1].sourceStart, 59)
        XCTAssertEqual(result.chunks[1].sourceEnd, 121)
        let processedSampleCount = await counts.values.reduce(0, +)
        XCTAssertEqual(processedSampleCount, samples.count + 2 * sampleRate)
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
                    ["id": $0.element.id, "text": $0.offset == 0 ? "One" : "Two"]
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
        XCTAssertEqual(result.subtitleCues.map(\.text), ["One", "Two"])
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
            "WEBVTT\n\nunit-0001\n00:00:01.500 --> 00:00:02.750\nOne\n\n"
                + "unit-0002\n00:00:06.250 --> 00:00:08.000\nTwo\n\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: result.directory.appendingPathComponent("english-subtitles.srt"),
                encoding: .utf8
            ),
            "1\n00:00:01,500 --> 00:00:02,750\nOne\n\n"
                + "2\n00:00:06,250 --> 00:00:08,000\nTwo\n\n"
        )
    }

    func testEnglishSubtitlesRejectInvalidCuesAndRetainAlignmentDiagnostics() async throws {
        let invalidCues: [HighQualityAlignedCue] = [
            .init(id: "cue-0001", text: "一。", start: -1, end: 1),
            .init(id: "cue-0001", text: "一。", start: 2, end: 1),
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
            prepareDiarization: { _ in },
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

        for backend in HighQualityASRBackend.allCases {
            let progress = ProgressLog()
            let expectedRawASR = switch backend {
            case .qwenJA: " こんにちは \n"
            case .parakeetJA: " 日本語 \n"
            case .whisperKit: " 音声認識 \n"
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
            prepareDiarization: { _ in },
            diarizeSpeakers: { _, exclusive, policy in
                .init(
                    spans: [.init(speakerID: 0, start: 0, end: 1)],
                    modelID: "fixture-speakerkit",
                    revision: "fixture-revision",
                    peakMemoryBytes: 0,
                    useExclusiveReconciliation: exclusive,
                    speakerCountPolicy: policy,
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
