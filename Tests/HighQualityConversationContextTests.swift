import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityConversationContextTests: XCTestCase {
    func testJobUsesOnlyEarlierAcceptedPairsAndRetriesWithoutContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let translator = ContextTranslationFixture([
            "Amayui Moka arrived.",
            "She is ready. おはよう",
            "Me too.",
            "Amayui Moka wins.",
            "She is ready.",
        ])
        let result = try await job(translator: translator).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            translationContextPolicy: .previousAcceptedV1,
            outputRoot: root
        ))

        let requests = await translator.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].context(for: requests[0].turns[0])?.acceptedHistory, [])
        XCTAssertEqual(
            requests[1].context(for: requests[1].turns[0])?.acceptedHistory.map(\.cueID),
            ["unit-0001"]
        )
        XCTAssertEqual(
            requests[2].context(for: requests[2].turns[0])?.acceptedHistory.map(\.cueID),
            ["unit-0001"]
        )
        XCTAssertEqual(
            requests[3].context(for: requests[3].turns[0])?.acceptedHistory.map(\.cueID),
            ["unit-0001", "unit-0003"]
        )
        XCTAssertFalse(
            requests[2].context(for: requests[2].turns[0])?.acceptedHistory
                .contains { $0.japanese == requests[3].turns[0].japanese } == true
        )
        XCTAssertNil(requests[4].context(for: requests[4].turns[0]))
        XCTAssertNotNil(requests[4].retryReasonCodes)

        let batches = try XCTUnwrap(result.evidence.translation?.batches)
        XCTAssertEqual(batches.count, 5)
        XCTAssertEqual(batches[1].context?.currentTarget, requests[1].turns[0].japanese)
        XCTAssertEqual(batches[1].context?.acceptedHistory.map(\.english), ["Amayui Moka arrived."])
        XCTAssertEqual(batches[1].nativeOutput, "She is ready. おはよう")
        XCTAssertEqual(batches[1].validationReasonCodes, [.residualJapanese])
        XCTAssertGreaterThan(batches[1].inputTokens, 0)
        XCTAssertEqual(result.englishTranscript,
                       "Amayui Moka arrived.\nShe is ready.\nMe too.\nAmayui Moka wins.")
    }

    func testContextResetsAtFrozenDiscontinuitiesAndStaysWithinBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let translator = ContextTranslationFixture([
            "Amayui Moka arrived.",
            "She is ready.",
            "Me too.",
            "Amayui Moka wins.",
        ])
        let alignment: @Sendable (
            [Float], [HighQualityTranslationTurn]
        ) async throws -> HighQualityAlignmentExchange = { _, turns in
            let times: [(Double, Double)] = [(0, 1), (1, 2), (12, 13), (13, 14)]
            return .init(
                chunks: [.init(
                    index: 0,
                    sourceStart: 0,
                    sourceEnd: 14,
                    cues: zip(turns, times).map { turn, time in
                        .init(id: turn.id, text: turn.japanese, start: time.0, end: time.1)
                    }
                )],
                modelID: "fixture-aligner",
                revision: "fixture-revision",
                peakMemoryBytes: 0
            )
        }
        _ = try await job(translator: translator, alignment: alignment).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            translationContextPolicy: .previousAcceptedV1,
            translationContextResetReasonsByCueID: ["unit-0004": .sceneBoundary],
            outputRoot: root
        ))

        let requests = await translator.requests
        XCTAssertEqual(requests[0].context(for: requests[0].turns[0])?.resetReason, .jobStart)
        XCTAssertEqual(requests[1].context(for: requests[1].turns[0])?.acceptedHistory.count, 1)
        XCTAssertEqual(requests[2].context(for: requests[2].turns[0])?.resetReason, .largePause)
        XCTAssertEqual(requests[2].context(for: requests[2].turns[0])?.acceptedHistory, [])
        XCTAssertEqual(requests[3].context(for: requests[3].turns[0])?.resetReason, .sceneBoundary)
        XCTAssertEqual(requests[3].context(for: requests[3].turns[0])?.acceptedHistory, [])
        XCTAssertTrue(requests.allSatisfy { request in
            guard let turn = request.turns.first, let context = request.context(for: turn) else {
                return false
            }
            return context.acceptedHistory.count <= HighQualityConversationContextPolicy.previousAcceptedV1.maximumDepth
                && context.encodedHistoryBytes <= HighQualityConversationContextPolicy.previousAcceptedV1.maximumEncodedHistoryBytes
        })

        let budgetTurns = (1...3).map {
            HighQualityTranslationTurn(
                id: "budget-\($0)", japanese: "文\($0)。",
                precedingJapanese: [], followingJapanese: [], speakerLabel: nil
            )
        }
        var budgetState = HighQualityConversationContextState(
            policy: .previousAcceptedV1,
            explicitResetReasons: [:]
        )
        _ = budgetState.context(for: budgetTurns[0])
        budgetState.accept(budgetTurns[0], english: String(repeating: "first", count: 60))
        _ = budgetState.context(for: budgetTurns[1])
        budgetState.accept(budgetTurns[1], english: String(repeating: "second", count: 60))
        let pruned = try XCTUnwrap(budgetState.context(for: budgetTurns[2]))
        XCTAssertEqual(pruned.acceptedHistory.map(\.cueID), ["budget-2"])
        XCTAssertLessThanOrEqual(pruned.encodedHistoryBytes, 512)
    }

    func testNativeContextPromptAlternatesAcceptedRolesAndKeepsCurrentUserClean() throws {
        let context = HighQualityConversationContextEvidence(
            policyVersion: HighQualityConversationContextPolicy.previousAcceptedV1.version,
            acceptedHistory: [
                .init(cueID: "unit-0001", japanese: "甘結もかが来た。", english: "Amayui Moka arrived."),
                .init(cueID: "unit-0002", japanese: "彼女は元気だ。", english: "She is doing well."),
            ],
            resetReason: nil,
            currentTarget: "私も。",
            encodedHistoryBytes: 92
        )
        let data = Data(try LocalMLXTranslator.contextNativePrompt(context).utf8)
        let messages = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(messages.compactMap { $0["role"] as? String },
                       ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "Amayui Moka arrived.")
        XCTAssertEqual(messages[3]["content"] as? String, "She is doing well.")
        let currentContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(currentContent.count, 1)
        XCTAssertEqual(currentContent[0]["text"] as? String, "私も。")
        XCTAssertFalse(try LocalMLXTranslator.contextNativePrompt(context).contains("未来の日本語"))
    }

    func testCopiedNeighbourNeverBecomesAcceptedContext() async throws {
        let translator = ContextTranslationFixture([
            "Amayui Moka arrived today.",
            "Amayui Moka arrived today.",
            "Me too.",
            "Amayui Moka wins.",
            "Amayui Moka came today.",
            "She is ready.",
        ])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await job(translator: translator).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            translationContextPolicy: .previousAcceptedV1,
            outputRoot: root
        ))

        let requests = await translator.requests
        XCTAssertEqual(
            requests[2].context(for: requests[2].turns[0])?.acceptedHistory.map(\.cueID),
            ["unit-0001"]
        )
    }

    func testFrozenReportPromotesContextAsTheHighQualityDefault() throws {
        let data = try Data(contentsOf: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent("docs/high-quality-context-e14.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let gates = try XCTUnwrap(report["gates"] as? [String: [String: Bool]])

        XCTAssertEqual(report["ticket"] as? Int, 55)
        XCTAssertEqual(report["promoted"] as? Bool, true)
        XCTAssertEqual(report["liveGatesUnchanged"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(gates["holdout"]).values.allSatisfy { $0 })
        XCTAssertEqual(HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA
        ).translationContextPolicy, .none)
        XCTAssertEqual(HighQualityConversationContextPolicy.productDefault,
                       .previousAcceptedV1)
    }

    func testLaterFailureRetainsCompletedContextEvidence() async throws {
        let turns = [
            HighQualityTranslationTurn(
                id: "first", japanese: "最初です。", precedingJapanese: [],
                followingJapanese: [], speakerLabel: nil
            ),
            HighQualityTranslationTurn(
                id: "second", japanese: "次です。", precedingJapanese: [],
                followingJapanese: [], speakerLabel: nil
            ),
        ]
        let request = HighQualityTranslationBatch(
            source: .init(
                path: "/tmp/source.wav", fileName: "source.wav", byteCount: nil,
                modifiedAt: nil, sourceURL: nil, youtube: nil
            ),
            turns: turns,
            glossary: []
        )
        let translator = ContextTranslationFixture(["This is the first."])
        let attempts = ContextAttemptCounter()

        do {
            _ = try await HighQualityJob.firstTranslationPass(
                request: request,
                contextPolicy: .previousAcceptedV1,
                resetReasons: [:],
                integrityGlossaryByCueID: [:],
                translate: { unitRequest in
                    guard await attempts.next() == 1 else {
                        let turn = unitRequest.turns[0]
                        throw HighQualityTranslationServiceError(
                            model: "fixture-model",
                            attempts: [.init(number: 1, duration: 0.1, outcome: "failed")],
                            response: nil,
                            batches: [.init(
                                cueIDs: [turn.id],
                                sanitizedPrompt: turn.japanese,
                                sanitizedOutput: "",
                                inputTokens: 8,
                                context: unitRequest.context(for: turn)
                            )],
                            message: "fixture failure"
                        )
                    }
                    return try await translator.translate(unitRequest)
                }
            )
            XCTFail("The second unit must fail.")
        } catch let error as HighQualityTranslationServiceError {
            XCTAssertEqual(error.batches.map(\.cueIDs), [["first"], ["second"]])
            XCTAssertEqual(error.batches[1].context?.acceptedHistory.map(\.cueID), ["first"])
            XCTAssertEqual(error.attempts.count, 2)
        }
    }

    func testWritesFrozenContextCorpusWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_CONTEXT_EXPERIMENT"] == "1",
              let split = environment["WHISPERASR_CONTEXT_SPLIT"],
              let baselinePath = environment["WHISPERASR_CONTEXT_BASELINE"],
              let outputPath = environment["WHISPERASR_CONTEXT_OUTPUT"] else {
            throw XCTSkip("Set the previous-accepted-context experiment paths.")
        }
        if split == "holdout" {
            XCTAssertEqual(environment["WHISPERASR_CONTEXT_ALLOW_HOLDOUT"], "1")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityTranslationEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: baselinePath))
        )
        let catalog = Dictionary(uniqueKeysWithValues: HighQualityGlossaryCatalog.terms.map {
            ($0.id, $0)
        })
        let integrityByCueID = baseline.request.glossaryByCueID.mapValues { terms in
            terms.map {
                HighQualityTranslationIntegrityGlossaryTerm(
                    $0,
                    critical: catalog[$0.id]?.domain != .conversation
                )
            }
        }
        let translator = HighQualityTranslationWorkerClient(
            executableURL: highQualityTranslationWorkerExecutableURL()
        )
        let evidence: HighQualityTranslationEvidence
        var retryCueIDs: [String] = []
        do {
            try await translator.prepare(progress: { _, _ in })
            let first = try await HighQualityJob.firstTranslationPass(
                request: baseline.request,
                contextPolicy: .previousAcceptedV1,
                resetReasons: [:],
                integrityGlossaryByCueID: integrityByCueID,
                translate: { try await translator.translate($0) }
            )
            var translations = try HighQualityJob.validatedTranslations(
                first.exchange.response,
                for: first.request.turns
            )
            let firstVerdicts = HighQualityTranslationIntegrityValidator.validate(
                turns: first.request.turns,
                translations: translations,
                batches: first.exchange.batches,
                glossary: [],
                glossaryByCueID: integrityByCueID
            )
            let rejected = firstVerdicts.filter { $0.verdict != .pass }
            retryCueIDs = rejected.map(\.cueID)
            var attempts = first.exchange.attempts
            var batches = HighQualityJob.annotatedBatches(
                first.exchange.batches,
                verdicts: firstVerdicts,
                attempt: 1
            )
            var finalVerdicts = firstVerdicts
            var peakMemoryBytes = first.exchange.peakMemoryBytes
            var model = first.exchange.model
            var revision = first.exchange.revision
            var runtimeVersion = first.exchange.runtimeVersion

            if !rejected.isEmpty {
                let rejectedIDs = Set(retryCueIDs)
                let criticalTermIDs = Set(rejected.flatMap {
                    $0.glossaryOpportunities.filter(\.critical).map(\.id)
                })
                let retryTurns = first.request.turns.filter { rejectedIDs.contains($0.id) }
                let retryRequest = HighQualityTranslationBatch(
                    source: first.request.source,
                    turns: retryTurns,
                    glossary: first.request.glossary.filter { criticalTermIDs.contains($0.id) },
                    glossaryByCueID: Dictionary(uniqueKeysWithValues: retryTurns.map { turn in
                        (turn.id, first.request.glossary(for: turn).filter {
                            criticalTermIDs.contains($0.id)
                        })
                    }),
                    retryReasonCodes: Dictionary(uniqueKeysWithValues: rejected.map {
                        ($0.cueID, $0.reasons.map(\.code))
                    })
                )
                let retry = try await translator.translate(retryRequest)
                let retryTranslations = try HighQualityJob.validatedTranslations(
                    retry.response,
                    for: retryTurns
                )
                var candidates = translations
                candidates.merge(retryTranslations) { _, retry in retry }
                let retryVerdicts = HighQualityTranslationIntegrityValidator.validate(
                    turns: first.request.turns,
                    translations: candidates,
                    batches: retry.batches,
                    glossary: [],
                    glossaryByCueID: integrityByCueID
                ).filter { rejectedIDs.contains($0.cueID) }
                translations = candidates
                finalVerdicts = first.request.turns.compactMap { turn in
                    retryVerdicts.first { $0.cueID == turn.id }
                        ?? firstVerdicts.first { $0.cueID == turn.id }
                }
                attempts += retry.attempts.map {
                    .init(number: attempts.count + $0.number, duration: $0.duration, outcome: $0.outcome)
                }
                batches += HighQualityJob.annotatedBatches(
                    retry.batches,
                    verdicts: retryVerdicts,
                    attempt: 2
                )
                peakMemoryBytes = max(peakMemoryBytes, retry.peakMemoryBytes)
                model = retry.model
                revision = retry.revision
                runtimeVersion = retry.runtimeVersion
            }
            await translator.unload()
            let hardFailures = finalVerdicts.filter { $0.verdict == .hardFailure }
            evidence = .init(
                request: first.request,
                response: try HighQualityJob.translationResponse(
                    translations,
                    for: first.request.turns
                ),
                model: model,
                attempts: attempts,
                revision: revision,
                runtimeVersion: runtimeVersion,
                batches: batches,
                peakMemoryBytes: peakMemoryBytes,
                validationFailures: hardFailures.map { "terminal-hard-failure:\($0.cueID)" },
                integrityVerdicts: finalVerdicts,
                worker: await translator.evidence
            )
        } catch {
            await translator.unload()
            throw error
        }

        let artifact = HighQualityContextCorpusArtifact(
            schemaVersion: 1,
            ticket: 55,
            split: split,
            baselineArtifact: baselinePath,
            policy: .previousAcceptedV1,
            retryCueIDs: retryCueIDs,
            evidence: evidence
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(
            to: URL(fileURLWithPath: outputPath),
            options: .atomic
        )
    }

    private func job(
        translator: ContextTranslationFixture,
        alignment: @escaping @Sendable (
            [Float], [HighQualityTranslationTurn]
        ) async throws -> HighQualityAlignmentExchange = highQualityFixtureAlignment
    ) -> HighQualityJob {
        HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 14 * 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in
                "甘結もかが来た。彼女は準備できた。私も。甘結もかが勝つ。"
            },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: alignment,
            translateEnglish: { try await translator.translate($0) }
        ))
    }
}

private struct HighQualityContextCorpusArtifact: Codable {
    let schemaVersion: Int
    let ticket: Int
    let split: String
    let baselineArtifact: String
    let policy: HighQualityConversationContextPolicy
    let retryCueIDs: [String]
    let evidence: HighQualityTranslationEvidence
}

private actor ContextTranslationFixture {
    private var outputs: [String]
    private(set) var requests: [HighQualityTranslationBatch] = []

    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    func translate(_ request: HighQualityTranslationBatch) throws -> HighQualityTranslationExchange {
        requests.append(request)
        let translated = request.turns.map { turn in
            (turn, outputs.removeFirst())
        }
        return .init(
            model: "fixture-model",
            response: String(decoding: try JSONSerialization.data(withJSONObject: [
                "translations": translated.map { ["id": $0.0.id, "text": $0.1] },
            ]), as: UTF8.self),
            attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
            revision: "fixture-revision",
            runtimeVersion: "fixture-runtime",
            batches: translated.map { turn, output in .init(
                cueIDs: [turn.id],
                sanitizedPrompt: turn.japanese,
                nativePrompt: "fixture-native-prompt",
                nativeOutput: output,
                sanitizedOutput: output,
                inputTokens: 12,
                outputTokens: 4,
                finishReason: "stop",
                duration: 0.1,
                context: request.context(for: turn)
            ) }
        )
    }
}

private actor ContextAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
