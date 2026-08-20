import XCTest
@testable import WhisperASRApp

final class HighQualityLexicalCorrectionTests: XCTestCase {
    func testCloseUniqueScopedFormIsCorrectedAndAudited() throws {
        let turn = HighQualityTranslationTurn(
            id: "cue-0001",
            japanese: "あまゆいもが来ました。",
            precedingJapanese: ["前の文。"],
            followingJapanese: ["次の文。"],
            speakerLabel: "SPEAKER_00",
            sourceStart: 1,
            sourceEnd: 3
        )
        let term = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )

        let result = HighQualityLexicalCorrection.apply(
            to: [turn],
            scope: scope(candidatesByCueID: [turn.id: [term]])
        )

        XCTAssertEqual(result.turns.map(\.japanese), ["甘結もかが来ました。"])
        XCTAssertEqual(result.turns[0].precedingJapanese, turn.precedingJapanese)
        XCTAssertEqual(result.turns[0].followingJapanese, turn.followingJapanese)
        XCTAssertEqual(result.turns[0].speakerLabel, turn.speakerLabel)
        XCTAssertEqual(result.turns[0].sourceStart, turn.sourceStart)
        XCTAssertEqual(result.turns[0].sourceEnd, turn.sourceEnd)
        XCTAssertEqual(result.evidence.changes, [
            .init(
                cueID: turn.id,
                originalText: turn.japanese,
                correctedText: "甘結もかが来ました。",
                canonicalTermID: "amayui-moka",
                canonicalJapanese: "甘結もか",
                matchedForm: "あまゆいも",
                score: 5.0 / 6.0,
                reason: "unique-close-phonetic-match"
            ),
        ])
    }

    func testSingleCharacterErrorInFourCharacterScopedNameIsCorrected() throws {
        let input = turn("甘えもかが来ました。")
        let candidate = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )

        let result = HighQualityLexicalCorrection.apply(
            to: [input],
            scope: scope(candidatesByCueID: [input.id: [candidate]])
        )

        XCTAssertEqual(result.turns.map(\.japanese), ["甘結もかが来ました。"])
        XCTAssertEqual(result.evidence.changes.first?.matchedForm, "甘えもか")
    }

    func testExactAndOutOfScopeFormsRemainUnchanged() throws {
        let term = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )
        let exact = turn("甘結もかが来ました。")
        let unsupported = turn("あまゆいもが来ました。", id: "cue-0002")

        let result = HighQualityLexicalCorrection.apply(
            to: [exact, unsupported],
            scope: scope(candidatesByCueID: [exact.id: [term]])
        )

        XCTAssertEqual(result.turns.map(\.japanese), [exact.japanese, unsupported.japanese])
        XCTAssertTrue(result.evidence.changes.isEmpty)
    }

    func testCandidateOutsideExplicitFrozenUnionIsIgnored() throws {
        let input = turn("あまゆいもが来ました。")
        let candidate = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )
        let emptyScope = HighQualityLexicalCorrectionScope(
            evidence: .init(
                projectMetadataTermIDs: [],
                sourceMetadataTermIDs: [],
                cueLocalSelectedTermIDsByCueID: [:],
                unionTermIDs: [],
                unionTermIDsByCueID: [input.id: []]
            ),
            candidatesByCueID: [input.id: [candidate]]
        )

        let result = HighQualityLexicalCorrection.apply(to: [input], scope: emptyScope)

        XCTAssertEqual(result.turns, [input])
        XCTAssertTrue(result.evidence.changes.isEmpty)
    }

    func testExactClosedCatalogVariantIsNotRewrittenOrExpandedIntoContext() throws {
        let input = turn("これで甘いもか。")
        let candidate = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )

        let result = HighQualityLexicalCorrection.apply(
            to: [input],
            scope: scope(candidatesByCueID: [input.id: [candidate]])
        )

        XCTAssertEqual(result.turns, [input])
        XCTAssertTrue(result.evidence.changes.isEmpty)
    }

    func testCompetingCloseCandidatesAbstain() {
        let input = turn("あかさはなです。")
        let result = HighQualityLexicalCorrection.apply(
            to: [input],
            scope: scope(candidatesByCueID: [input.id: [
                term(id: "first", japanese: "あかさたな"),
                term(id: "second", japanese: "あかさかな"),
            ]])
        )

        XCTAssertEqual(result.turns, [input])
        XCTAssertTrue(result.evidence.changes.isEmpty)
    }

    func testReplacementCannotChangeNumbers() {
        let input = turn("ストリートファイター5をします。")
        let candidate = term(id: "street-fighter", japanese: "ストリートファイター6")

        let result = HighQualityLexicalCorrection.apply(
            to: [input],
            scope: scope(candidatesByCueID: [input.id: [candidate]])
        )

        XCTAssertEqual(result.turns, [input])
        XCTAssertTrue(result.evidence.changes.isEmpty)
    }

    func testScoringBudgetStopsWithoutAnUnverifiedReplacement() throws {
        let input = turn("前置きです。あまゆいもが来ました。")
        let term = try XCTUnwrap(
            HighQualityGlossaryCatalog.terms.first { $0.id == "amayui-moka" }
        )

        let result = HighQualityLexicalCorrection.apply(
            to: [input],
            scope: scope(candidatesByCueID: [input.id: [term]]),
            policy: policy(maximumScoringOperationsPerCue: 1)
        )

        XCTAssertEqual(result.turns, [input])
        XCTAssertEqual(result.evidence.scoringOperations, 1)
    }

    func testScoringBudgetIsAppliedPerCueSoLaterCuesAreNotStarved() {
        let candidate = term(id: "name", japanese: "あまゆいもか")
        let first = turn("あまゆいも", id: "cue-0001")
        let second = turn("あまゆいも", id: "cue-0002")

        let result = HighQualityLexicalCorrection.apply(
            to: [first, second],
            scope: scope(candidatesByCueID: [
                first.id: [candidate],
                second.id: [candidate],
            ]),
            policy: policy(maximumScoringOperationsPerCue: 3)
        )

        XCTAssertEqual(result.turns.map(\.japanese), ["あまゆいもか", "あまゆいもか"])
        XCTAssertEqual(result.evidence.scoringOperations, 2)
    }

    func testClosedScopeKeepsProjectSourceAndCueLocalOriginsSeparate() throws {
        let source = HighQualitySourceProvenance(
            path: "fixture",
            fileName: "fixture.m4a",
            byteCount: nil,
            modifiedAt: nil,
            sourceURL: "https://youtu.be/fixture",
            youtube: .init(
                sourceURL: "https://youtu.be/fixture",
                title: "甘結もか 星野ルナ (Hoshino Luna)",
                channel: "Fixture",
                description: "",
                ytDLPVersion: "fixture",
                diagnostics: "fixture"
            )
        )
        let input = turn("甘結もかが来ました。")
        let selection = HighQualityGlossarySelector.select(
            source: source,
            turns: [input],
            preferredTermIDs: ["apex-legends"],
            budget: .init(
                maxEntries: 12,
                maxEncodedBytes: 2_048,
                maxInputTokenShare: 0.25,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0
            )
        )

        let scope = try HighQualityLexicalCorrection.closedScope(
            turns: [input],
            selection: selection
        )
        let candidates = scope.candidatesByCueID[input.id, default: []]

        XCTAssertEqual(scope.evidence.projectMetadataTermIDs, ["apex-legends"])
        XCTAssertTrue(scope.evidence.sourceMetadataTermIDs.contains("amayui-moka"))
        XCTAssertEqual(
            scope.evidence.cueLocalSelectedTermIDsByCueID[input.id],
            ["amayui-moka"]
        )
        XCTAssertEqual(
            Set(candidates.map(\.id)),
            Set(scope.evidence.unionTermIDsByCueID[input.id, default: []])
        )
    }

    func testClosedScopeFailsInsteadOfTruncatingTheFrozenUnion() {
        let input = turn("甘結もかが来ました。")
        let selection = HighQualityGlossarySelector.select(
            source: .init(
                path: "fixture",
                fileName: "fixture.m4a",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: nil
            ),
            turns: [input],
            preferredTermIDs: ["apex-legends"],
            budget: .init(
                maxEntries: 1,
                maxEncodedBytes: 2_048,
                maxInputTokenShare: 0.25,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0
            )
        )

        XCTAssertThrowsError(try HighQualityLexicalCorrection.closedScope(
            turns: [input],
            selection: selection
        )) {
            XCTAssertEqual(
                $0 as? HighQualityLexicalCorrection.ScopeError,
                .budgetExceeded(cueID: input.id)
            )
        }
    }

    func testWritesFrozenLocalReferenceExperimentWhenOptedIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_LEXICAL_CORRECTION_EXPERIMENT"] == "1" else {
            throw XCTSkip("Set WHISPERASR_RUN_LEXICAL_CORRECTION_EXPERIMENT=1.")
        }
        let inputPath = try XCTUnwrap(environment["WHISPERASR_LEXICAL_INPUT"])
        let outputPath = try XCTUnwrap(environment["WHISPERASR_LEXICAL_OUTPUT"])
        let corpus = try XCTUnwrap(environment["WHISPERASR_LEXICAL_CORPUS"])
        let projectTermIDs = Set(try XCTUnwrap(environment["WHISPERASR_LEXICAL_SCOPE_IDS"])
            .split(separator: ",").map(String.init))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(
            HighQualityRawEvidence.self,
            from: try gunzippedData(at: URL(fileURLWithPath: inputPath))
        )
        let baseline = try XCTUnwrap(raw.translation?.request)
        let selection = HighQualityGlossarySelector.select(
            source: baseline.source,
            turns: baseline.turns,
            preferredTermIDs: projectTermIDs
        )
        let scope = try HighQualityLexicalCorrection.closedScope(
            turns: baseline.turns,
            selection: selection
        )
        let correction = HighQualityLexicalCorrection.apply(
            to: baseline.turns,
            scope: scope
        )
        let artifact = LexicalExperimentArtifact(
            schemaVersion: 2,
            ticket: 119,
            corpus: corpus,
            sourceArtifact: inputPath,
            selection: selection,
            correction: correction.evidence,
            baselineTurns: baseline.turns,
            correctedTurns: correction.turns
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(artifact).write(to: output, options: .atomic)
        if let latencyPath = environment["WHISPERASR_LEXICAL_LATENCY_OUTPUT"] {
            try writeLatencyEvidence(
                to: URL(fileURLWithPath: latencyPath),
                corpus: corpus,
                turns: baseline.turns,
                scope: scope
            )
        }
    }

    private func turn(_ japanese: String, id: String = "cue-0001")
        -> HighQualityTranslationTurn {
        .init(
            id: id,
            japanese: japanese,
            precedingJapanese: [],
            followingJapanese: [],
            speakerLabel: nil,
            sourceStart: 1,
            sourceEnd: 2
        )
    }

    private func term(id: String, japanese: String) -> HighQualityGlossaryTerm {
        .init(
            id: id,
            domain: .source,
            sourceScope: "test",
            officialJapanese: japanese,
            japaneseForms: [japanese],
            canonicalEnglish: id,
            englishAliases: [],
            ambiguityClass: .fixed,
            provenance: ["fixture"],
            verifiedOn: "fixture",
            inclusionRule: "fixture",
            exclusionRule: "fixture",
            ambiguousJapaneseForms: []
        )
    }

    private func scope(
        candidatesByCueID: [String: [HighQualityGlossaryTerm]]
    ) -> HighQualityLexicalCorrectionScope {
        let cueLocal = candidatesByCueID.mapValues { Array(Set($0.map(\.id))).sorted() }
        let union = Array(Set(cueLocal.values.flatMap { $0 })).sorted()
        return .init(
            evidence: .init(
                projectMetadataTermIDs: [],
                sourceMetadataTermIDs: [],
                cueLocalSelectedTermIDsByCueID: cueLocal,
                unionTermIDs: union,
                unionTermIDsByCueID: cueLocal
            ),
            candidatesByCueID: candidatesByCueID
        )
    }

    private func policy(
        maximumScoringOperationsPerCue: Int
    ) -> HighQualityLexicalCorrectionPolicy {
        .init(
            version: "test",
            minimumScore: 0.75,
            ambiguityMargin: 0.08,
            minimumFormCharacters: 4,
            maximumEditDistance: 1,
            maximumScoringOperationsPerCue: maximumScoringOperationsPerCue
        )
    }

    private func gunzippedData(at url: URL) throws -> Data {
        guard url.pathExtension == "gz" else { return try Data(contentsOf: url) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func writeLatencyEvidence(
        to output: URL,
        corpus: String,
        turns: [HighQualityTranslationTurn],
        scope: HighQualityLexicalCorrectionScope
    ) throws {
        let clock = ContinuousClock()
        _ = HighQualityLexicalCorrection.apply(to: turns, scope: scope)
        var samples: [Double] = []
        var changeCounts: [Int] = []
        for _ in 0..<5 {
            let start = clock.now
            let result = HighQualityLexicalCorrection.apply(to: turns, scope: scope)
            let components = start.duration(to: clock.now).components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            samples.append((milliseconds * 1_000_000).rounded() / 1_000_000)
            changeCounts.append(result.evidence.changes.count)
        }
        let sorted = samples.sorted()
        let artifact = LexicalLatencyArtifact(
            schemaVersion: 1,
            ticket: 119,
            corpus: corpus,
            status: "measured",
            operation: "HighQualityLexicalCorrection.apply",
            method: "ContinuousClock wall time around apply only; one warm-up then five serial measured iterations",
            buildConfiguration: "debug",
            warmupIterations: 1,
            measuredIterations: samples.count,
            turnCount: turns.count,
            unionTermCount: scope.evidence.unionTermIDs.count,
            changeCounts: changeCounts,
            samplesMilliseconds: samples,
            medianMilliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted.last ?? 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(artifact).write(to: output, options: .atomic)
    }
}

private struct LexicalExperimentArtifact: Codable {
    let schemaVersion: Int
    let ticket: Int
    let corpus: String
    let sourceArtifact: String
    let selection: HighQualityGlossarySelection
    let correction: HighQualityLexicalCorrectionEvidence
    let baselineTurns: [HighQualityTranslationTurn]
    let correctedTurns: [HighQualityTranslationTurn]
}

private struct LexicalLatencyArtifact: Codable {
    let schemaVersion: Int
    let ticket: Int
    let corpus: String
    let status: String
    let operation: String
    let method: String
    let buildConfiguration: String
    let warmupIterations: Int
    let measuredIterations: Int
    let turnCount: Int
    let unionTermCount: Int
    let changeCounts: [Int]
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
}
