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

    func testShadowVerdictDoesNotChangePublishedDeliverable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data().write(to: source)
        let published = "Good morning. おはよう"
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [Float](repeating: 0.1, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはよう。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            translateEnglish: { request in
                .init(
                    model: "fixture-model",
                    response: #"{"translations":[{"id":"unit-0001","text":"Good morning. おはよう"}]}"#,
                    attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
                    batches: [batch(request.turns[0].id, published)]
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: source,
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        XCTAssertEqual(result.englishTranscript, published)
        XCTAssertEqual(
            try String(contentsOf: result.directory
                .appendingPathComponent("english-translation-transcript.txt"), encoding: .utf8),
            published + "\n"
        )
        let verdict = try XCTUnwrap(result.evidence.translation?.integrityVerdicts.first)
        XCTAssertEqual(verdict.verdict, .hardFailure)
        XCTAssertEqual(verdict.reasons.map(\.code), [.residualJapanese])
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
