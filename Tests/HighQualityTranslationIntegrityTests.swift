import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityTranslationIntegrityTests: XCTestCase {
    func testDeterministicCorruptionFixturesAndValidTranslations() throws {
        let results = try fixtureResults()
        for result in results {
            for expectation in result.expectations {
                let verdict = try XCTUnwrap(result.verdicts.first { $0.cueID == expectation.cueID })
                XCTAssertEqual(
                    Set(verdict.reasons.map(\.code)),
                    Set(expectation.expectedReasonCodes),
                    result.name
                )
                XCTAssertFalse(verdict.testedSource.isEmpty, result.name)
                XCTAssertEqual(
                    verdict.thresholdVersion,
                    HighQualityTranslationIntegrityThresholds.developmentV1.version,
                    result.name
                )
                XCTAssertTrue(verdict.reasons.allSatisfy { !$0.matchedEvidence.isEmpty }, result.name)
            }
        }

        let allowlisted = HighQualityTranslationIntegrityValidator.validate(
            turns: [turn("allowlist", "任天堂です。")],
            batches: [batch("allowlist", "Nintendo 任天堂")],
            glossary: [],
            japaneseAllowlist: ["任天堂"]
        )
        XCTAssertEqual(allowlisted.first?.verdict, .pass)

        if let path = ProcessInfo.processInfo.environment["WHISPERASR_TRANSLATION_INTEGRITY_FIXTURES_OUTPUT"] {
            try write(
                FixtureArtifact(
                    schemaVersion: 1,
                    thresholds: .developmentV1,
                    fixtures: results
                ),
                to: URL(fileURLWithPath: path)
            )
        }
    }

    func testValidTranslationCompletesWithoutRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data().write(to: source)
        let translator = RetryFixture(["Good morning."])
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはよう。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { try await translator.translate($0) }
        ))

        let result = try await job.run(.init(
            sourceURL: source,
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        XCTAssertEqual(result.englishTranscript, "Good morning.")
        let requestCount = await translator.requests.count
        XCTAssertEqual(requestCount, 1)
        let verdict = try XCTUnwrap(result.evidence.translation?.integrityVerdicts.first)
        XCTAssertEqual(verdict.verdict, .pass)
        XCTAssertEqual(result.evidence.translation?.batches.first?.attemptNumber, 1)
        XCTAssertEqual(result.evidence.translation?.batches.first?.selected, true)
        XCTAssertEqual(result.evidence.translation?.batches.first?.terminalOutcome, "accepted")
    }

    func testRetriesOnlyRejectedUnitWithCriticalTermsAndSelectsRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let translator = RetryFixture([
            "Good morning.", "Sweet Moka has arrived.",
            "Amayui Moka has arrived.",
        ])
        let result = try await HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 32_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはよう。甘結もかが来ました。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { try await translator.translate($0) }
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        let requests = await translator.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].turns.map(\.id), ["unit-0001", "unit-0002"])
        XCTAssertEqual(requests[1].turns.map(\.id), ["unit-0002"])
        XCTAssertEqual(requests[1].turns.map(\.japanese), ["甘結もかが来ました。"])
        XCTAssertEqual(requests[1].glossary.map(\.id), ["amayui-moka"])
        XCTAssertEqual(
            requests[1].retryReasonCodes?["unit-0002"],
            [.criticalGlossaryViolation]
        )
        XCTAssertNotEqual(requests[0], requests[1])
        XCTAssertEqual(result.turns.compactMap(\.english), ["Good morning.", "Amayui Moka has arrived."])
        XCTAssertEqual(result.evidence.translation?.attempts.map(\.number), [1, 2])
        XCTAssertEqual(result.evidence.translation?.batches.map(\.attemptNumber), [1, 1, 2])
        XCTAssertEqual(result.evidence.translation?.batches.map(\.selected), [true, false, true])
        XCTAssertEqual(
            result.evidence.translation?.batches.map(\.terminalOutcome),
            ["accepted", "rejected", "accepted"]
        )
        XCTAssertEqual(
            result.evidence.translation?.batches[1].validationReasonCodes,
            [.criticalGlossaryViolation]
        )
        XCTAssertTrue(result.evidence.translation?.integrityVerdicts.allSatisfy {
            $0.verdict == .pass
        } == true)
    }

    func testRetryValidationKeepsAcceptedNeighboursForCopyDetection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let translator = RetryFixture([
            "A completely unrelated sentence.", "Invalid. おはよう",
            "A completely unrelated sentence.",
        ])
        let result = try await HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 32_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "今日は東京で晴れです。猫が静かに眠っています。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { try await translator.translate($0) }
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        let retryVerdict = try XCTUnwrap(result.evidence.translation?.integrityVerdicts
            .first { $0.cueID == "unit-0002" })
        XCTAssertEqual(retryVerdict.verdict, .suspect)
        XCTAssertTrue(retryVerdict.reasons.contains { $0.code == .copiedNeighbour })
        XCTAssertEqual(result.evidence.translation?.batches.last?.selected, true)
    }

    func testSecondValidationFailureFailsTranslationWithoutPublishingEnglish() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let translator = RetryFixture(["Good morning. おはよう", "Morning. おはよう"])
        do {
            _ = try await HighQualityJob(services: .init(
                loadSource: { _ in [Float](repeating: 0.1, count: 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "おはよう。" },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: highQualityFixtureAlignment,
                translateEnglish: { try await translator.translate($0) }
            )).run(request)
            XCTFail("A twice-rejected translation must fail.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .translation)
            XCTAssertTrue(error.message.contains("failed validation twice"))
        }

        let directory = root.appendingPathComponent(request.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory
            .appendingPathComponent("english-translation-transcript.txt").path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.translation?.batches.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(evidence.translation?.batches.map(\.selected), [false, false])
        XCTAssertEqual(evidence.translation?.batches.last?.terminalOutcome, "failed")
        XCTAssertEqual(evidence.translation?.validationFailures.count, 1)
    }

    func testMalformedRetryPreservesSecondAttemptEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let calls = RetryCounter()
        do {
            _ = try await HighQualityJob(services: .init(
                loadSource: { _ in [Float](repeating: 0.1, count: 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "おはよう。" },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: highQualityFixtureAlignment,
                translateEnglish: { batch in
                    let attempt = await calls.increment()
                    let output = attempt == 1 ? "Good morning. おはよう" : "malformed output"
                    return .init(
                        model: "fixture-model",
                        response: attempt == 1
                            ? #"{"translations":[{"id":"unit-0001","text":"Good morning. おはよう"}]}"#
                            : "not-json",
                        attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
                        batches: [.init(
                            cueIDs: [batch.turns[0].id],
                            sanitizedPrompt: batch.turns[0].japanese,
                            nativePrompt: "native-\(attempt)",
                            nativeOutput: output,
                            sanitizedOutput: output,
                            inputTokens: 7,
                            outputTokens: 3,
                            finishReason: "stop",
                            duration: 0.1
                        )]
                    )
                }
            )).run(request)
            XCTFail("A malformed retry must fail.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .translation)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: root.appendingPathComponent(request.id.uuidString)
                .appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.translation?.attempts.map(\.number), [1, 2])
        XCTAssertEqual(evidence.translation?.batches.map(\.nativePrompt), ["native-1", "native-2"])
        XCTAssertEqual(evidence.translation?.batches.last?.attemptNumber, 2)
        XCTAssertEqual(evidence.translation?.batches.last?.terminalOutcome, "failed")
        XCTAssertEqual(evidence.translation?.batches.last?.inputTokens, 7)
        XCTAssertEqual(evidence.translation?.batches.last?.duration, 0.1)
    }

    func testCancellationDuringRetryUnloadsTranslatorAndReleasesModelGate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = RetryCounter()
        let unloads = RetryCounter()
        let retryStarted = expectation(description: "retry started")
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
            reserveBytes: HeavyweightModelGate.systemReserveBytes,
            releaseToleranceBytes: 1,
            releaseTimeout: .milliseconds(20),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { 1_000 }
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはよう。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { request in
                if await calls.increment() == 1 {
                    return .init(
                        model: "fixture-model",
                        response: #"{"translations":[{"id":"unit-0001","text":"Good morning. おはよう"}]}"#,
                        attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
                        batches: [batch(request.turns[0].id, "Good morning. おはよう")]
                    )
                }
                retryStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    throw HighQualityTranslationServiceError(
                        model: "fixture-model",
                        attempts: [.init(number: 1, duration: 0.1, outcome: "cancelled")],
                        response: nil,
                        batches: [batch(request.turns[0].id, "")],
                        message: "cancelled"
                    )
                }
                throw CancellationError()
            },
            unloadTranslation: { _ = await unloads.increment() },
            heavyweightGate: gate
        ))
        let task = Task {
            try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishTranslationTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        await fulfillment(of: [retryStarted], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the retry.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }
        let unloadCount = await unloads.value
        XCTAssertEqual(unloadCount, 1)
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.translation?.batches.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(evidence.translation?.batches.last?.terminalOutcome, "failed")
        let live = try await gate.beginWorkflow(.live)
        try await gate.endWorkflow(live)
    }

    func testWritesFrozenCorpusVerdictsWhenOptedIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TRANSLATION_INTEGRITY_EXPERIMENT"] == "1",
              let corpus = environment["WHISPERASR_TRANSLATION_INTEGRITY_CORPUS"],
              let input = environment["WHISPERASR_TRANSLATION_INTEGRITY_INPUT"],
              let output = environment["WHISPERASR_TRANSLATION_INTEGRITY_OUTPUT"] else {
            throw XCTSkip("Set translation-integrity corpus, input, and output paths.")
        }
        if corpus == "holdout" {
            XCTAssertEqual(environment["WHISPERASR_TRANSLATION_INTEGRITY_ALLOW_HOLDOUT"], "1")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityTranslationEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: input))
        )
        let catalog = Dictionary(uniqueKeysWithValues: HighQualityGlossaryCatalog.terms.map {
            ($0.id, $0)
        })
        let glossary = evidence.request.glossary.map {
            HighQualityTranslationIntegrityGlossaryTerm(
                $0,
                critical: catalog[$0.id]?.domain != .conversation
            )
        }
        let verdicts = HighQualityTranslationIntegrityValidator.validate(
            turns: evidence.request.turns,
            batches: evidence.batches,
            glossary: glossary
        )
        let artifact = CorpusArtifact(
            schemaVersion: 1,
            corpus: corpus,
            sourceArtifact: input,
            thresholds: .developmentV1,
            verdicts: verdicts
        )
        try write(artifact, to: URL(fileURLWithPath: output))

        XCTAssertEqual(verdicts.count, evidence.request.turns.count)
        XCTAssertTrue(verdicts.allSatisfy {
            $0.thresholdVersion == HighQualityTranslationIntegrityThresholds.developmentV1.version
        })
    }

    func testRetriesFrozenRejectedUnitsWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TRANSLATION_RETRY_EXPERIMENT"] == "1",
              let corpus = environment["WHISPERASR_TRANSLATION_RETRY_CORPUS"],
              let baselinePath = environment["WHISPERASR_TRANSLATION_RETRY_BASELINE"],
              let verdictsPath = environment["WHISPERASR_TRANSLATION_RETRY_VERDICTS"],
              let outputPath = environment["WHISPERASR_TRANSLATION_RETRY_OUTPUT"] else {
            throw XCTSkip("Set translation-retry corpus, baseline, verdict, and output paths.")
        }
        if corpus == "holdout" {
            XCTAssertEqual(environment["WHISPERASR_TRANSLATION_RETRY_ALLOW_HOLDOUT"], "1")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityTranslationEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: baselinePath))
        )
        let validation = try decoder.decode(
            CorpusArtifact.self,
            from: Data(contentsOf: URL(fileURLWithPath: verdictsPath))
        )
        let rejected = validation.verdicts.filter { $0.verdict != .pass }
        let rejectedIDs = Set(rejected.map(\.cueID))
        let criticalTermIDs = Set(rejected.flatMap {
            $0.glossaryOpportunities.filter(\.critical).map(\.id)
        })
        let request = HighQualityTranslationBatch(
            source: baseline.request.source,
            turns: baseline.request.turns.filter { rejectedIDs.contains($0.id) },
            glossary: baseline.request.glossary.filter { criticalTermIDs.contains($0.id) },
            retryReasonCodes: Dictionary(uniqueKeysWithValues: rejected.map {
                ($0.cueID, $0.reasons.map(\.code))
            })
        )
        var retryEvidence: HighQualityTranslationEvidence?
        var retryVerdicts: [HighQualityTranslationIntegrityVerdict] = []
        if !request.turns.isEmpty {
            let translator = LocalMLXTranslator()
            do {
                try await translator.prepare(progress: { _, _ in })
                let exchange = try await translator.translate(request)
                await translator.unload()
                let translations: [String: String] = Dictionary(uniqueKeysWithValues: exchange.batches.compactMap {
                    guard let id = $0.cueIDs.first else { return nil }
                    return (id, $0.sanitizedOutput)
                })
                let glossary = request.glossary.map {
                    HighQualityTranslationIntegrityGlossaryTerm($0, critical: true)
                }
                retryVerdicts = HighQualityTranslationIntegrityValidator.validate(
                    turns: request.turns,
                    translations: translations,
                    batches: exchange.batches,
                    glossary: glossary
                )
                retryEvidence = .init(
                    request: request,
                    response: exchange.response,
                    model: exchange.model,
                    attempts: exchange.attempts,
                    revision: exchange.revision,
                    runtimeVersion: exchange.runtimeVersion,
                    batches: exchange.batches,
                    peakMemoryBytes: exchange.peakMemoryBytes,
                    validationFailures: [],
                    integrityVerdicts: retryVerdicts
                )
            } catch {
                await translator.unload()
                throw error
            }
        }
        try write(
            RetryCorpusArtifact(
                schemaVersion: 1,
                corpus: corpus,
                baselineArtifact: baselinePath,
                verdictArtifact: verdictsPath,
                rejectedCueIDs: request.turns.map(\.id),
                retry: retryEvidence,
                retryVerdicts: retryVerdicts
            ),
            to: URL(fileURLWithPath: outputPath)
        )
    }

    private func fixtureResults() throws -> [FixtureResult] {
        let critical = HighQualityTranslationIntegrityGlossaryTerm(
            HighQualityGlossaryPromptTerm(
                id: "amayui-moka",
                japanese: ["甘結もか"],
                english: "Amayui Moka",
                englishAliases: ["Moka Amayui"]
            ),
            critical: true
        )
        let fixtures: [Fixture] = [
            .one("empty", "何", "", .emptyOutput),
            .one("residual-japanese", "今日は晴れです。", "Good weather あアｱ漢.", .residualJapanese),
            .one(
                "prompt-scaffolding",
                "この文章を英語に翻訳してください。",
                #"{"role":"user","source_lang_code":"ja"}"#,
                .controlScaffolding
            ),
            .one(
                "control-scaffolding",
                "皆さん、おはようございます。",
                "SPEAKER_ID: 2 Good morning everyone.",
                .controlScaffolding
            ),
            .one(
                "truncation",
                "この文章は途中で終わりました。",
                "This sentence stops abruptly",
                .truncatedOutput,
                finishReason: "length"
            ),
            .one("repetition", "行け、行け、行け。", "go go go go", .degenerateRepetition),
            .one(
                "long-repetition",
                "危険なので私たちは今すぐこの場所から離れるべきだと何度も繰り返して説明しました。",
                "we should leave this place now we should leave this place now we should leave this place now we should leave this place now",
                .degenerateRepetition
            ),
            .one(
                "pathological-length",
                "短い",
                "This output is deliberately much too long for its tiny source and keeps adding unrelated words.",
                .pathologicalLength
            ),
            Fixture(
                name: "critical-glossary",
                turns: [turn("critical-glossary", "甘結もかが来ました。")],
                batches: [batch("critical-glossary", "Sweet Moka has arrived.")],
                glossary: [critical],
                expectations: [.init(
                    cueID: "critical-glossary",
                    expectedReasonCodes: [.criticalGlossaryViolation]
                )]
            ),
            Fixture(
                name: "critical-glossary-word-boundary",
                turns: [turn("critical-glossary-word-boundary", "甘結もかが来ました。")],
                batches: [batch("critical-glossary-word-boundary", "Amayui Mokashi has arrived.")],
                glossary: [critical],
                expectations: [.init(
                    cueID: "critical-glossary-word-boundary",
                    expectedReasonCodes: [.criticalGlossaryViolation]
                )]
            ),
            Fixture(
                name: "copied-neighbour",
                turns: [
                    turn("copied-1", "今日は東京で晴れです。"),
                    turn("copied-2", "猫が静かに眠っています。"),
                ],
                batches: [
                    batch("copied-1", "It is sunny today in Tokyo."),
                    batch("copied-2", "It is sunny today in Tokyo."),
                ],
                glossary: [],
                expectations: [
                    .init(cueID: "copied-1", expectedReasonCodes: [.copiedNeighbour]),
                    .init(cueID: "copied-2", expectedReasonCodes: [.copiedNeighbour]),
                ]
            ),
            .valid("valid-short", "はい。", "Yes."),
            .valid(
                "valid-long",
                "今日は長い会議でしたが、全員で重要な問題を解決できました。",
                "It was a long meeting today, but together we resolved the important issue."
            ),
            Fixture(
                name: "valid-named-entity",
                turns: [turn("valid-named-entity", "甘結もかが来ました。")],
                batches: [batch("valid-named-entity", "Amayui Moka has arrived.")],
                glossary: [critical],
                expectations: [.init(cueID: "valid-named-entity", expectedReasonCodes: [])]
            ),
            .valid("valid-mixed-punctuation", "えっ、42％！？", "What, 42%?!"),
        ]
        return fixtures.map { fixture in
            .init(
                name: fixture.name,
                expectations: fixture.expectations,
                verdicts: HighQualityTranslationIntegrityValidator.validate(
                    turns: fixture.turns,
                    batches: fixture.batches,
                    glossary: fixture.glossary
                )
            )
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct Fixture {
    let name: String
    let turns: [HighQualityTranslationTurn]
    let batches: [HighQualityLocalTranslationBatch]
    let glossary: [HighQualityTranslationIntegrityGlossaryTerm]
    let expectations: [FixtureExpectation]

    static func one(
        _ name: String,
        _ source: String,
        _ output: String,
        _ reason: HighQualityTranslationIntegrityReasonCode,
        finishReason: String? = nil
    ) -> Self {
        .init(
            name: name,
            turns: [turn(name, source)],
            batches: [batch(name, output, finishReason: finishReason)],
            glossary: [],
            expectations: [.init(cueID: name, expectedReasonCodes: [reason])]
        )
    }

    static func valid(_ name: String, _ source: String, _ output: String) -> Self {
        .init(
            name: name,
            turns: [turn(name, source)],
            batches: [batch(name, output)],
            glossary: [],
            expectations: [.init(cueID: name, expectedReasonCodes: [])]
        )
    }
}

private struct FixtureExpectation: Codable {
    let cueID: String
    let expectedReasonCodes: [HighQualityTranslationIntegrityReasonCode]
}

private struct FixtureResult: Codable {
    let name: String
    let expectations: [FixtureExpectation]
    let verdicts: [HighQualityTranslationIntegrityVerdict]
}

private struct FixtureArtifact: Codable {
    let schemaVersion: Int
    let thresholds: HighQualityTranslationIntegrityThresholds
    let fixtures: [FixtureResult]
}

private struct CorpusArtifact: Codable {
    let schemaVersion: Int
    let corpus: String
    let sourceArtifact: String
    let thresholds: HighQualityTranslationIntegrityThresholds
    let verdicts: [HighQualityTranslationIntegrityVerdict]
}

private struct RetryCorpusArtifact: Codable {
    let schemaVersion: Int
    let corpus: String
    let baselineArtifact: String
    let verdictArtifact: String
    let rejectedCueIDs: [String]
    let retry: HighQualityTranslationEvidence?
    let retryVerdicts: [HighQualityTranslationIntegrityVerdict]
}

private func turn(_ id: String, _ japanese: String) -> HighQualityTranslationTurn {
    .init(
        id: id,
        japanese: japanese,
        precedingJapanese: [],
        followingJapanese: [],
        speakerLabel: nil
    )
}

private func batch(
    _ id: String,
    _ output: String,
    finishReason: String? = "stop"
) -> HighQualityLocalTranslationBatch {
    .init(
        cueIDs: [id],
        sanitizedPrompt: "fixture",
        nativeOutput: output,
        sanitizedOutput: output,
        inputTokens: 1,
        outputTokens: max(1, output.count / 4),
        finishReason: finishReason
    )
}

private actor RetryFixture {
    private var outputs: [String]
    private(set) var requests: [HighQualityTranslationBatch] = []

    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    func translate(_ request: HighQualityTranslationBatch) throws -> HighQualityTranslationExchange {
        requests.append(request)
        let attempt = requests.count
        let selected = Array(outputs.prefix(request.turns.count))
        outputs.removeFirst(selected.count)
        let translations = zip(request.turns, selected).map {
            ["id": $0.id, "text": $1]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: [
            "translations": translations,
        ]), as: UTF8.self)
        return .init(
            model: "fixture-model",
            response: response,
            attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
            revision: "fixture-revision",
            runtimeVersion: "fixture-runtime",
            batches: zip(request.turns, selected).map { turn, output in
                .init(
                    cueIDs: [turn.id],
                    sanitizedPrompt: turn.japanese,
                    nativePrompt: "attempt-\(attempt):\(turn.japanese)",
                    nativeOutput: output,
                    sanitizedOutput: output,
                    inputTokens: turn.japanese.count,
                    outputTokens: output.count,
                    finishReason: "stop",
                    duration: 0.1
                )
            }
        )
    }
}

private actor RetryCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
