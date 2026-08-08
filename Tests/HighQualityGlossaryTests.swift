import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityGlossaryTests: XCTestCase {
    func testBuiltInCatalogCoversEveryDeclaredDomainWithRulesAndProvenance() {
        XCTAssertEqual(
            Set(HighQualityGlossaryCatalog.terms.map(\.domain)),
            [.anime, .vtuber, .gaming, .conversation]
        )
        XCTAssertEqual(HighQualityGlossaryCatalog.terms.count, 16)
        for term in HighQualityGlossaryCatalog.terms {
            XCTAssertFalse(term.japaneseForms.isEmpty)
            XCTAssertFalse(term.canonicalEnglish.isEmpty)
            XCTAssertFalse(term.provenance.isEmpty)
            XCTAssertTrue(term.provenance.allSatisfy { URL(string: $0)?.scheme == "https" })
            XCTAssertFalse(term.inclusionRule.isEmpty)
            XCTAssertFalse(term.exclusionRule.isEmpty)
        }
        XCTAssertTrue(HighQualityGlossaryCatalog.coverageLimit.contains("may be absent"))
    }

    func testSelectionHandlesAmbiguityCrossDomainAndEmptyMetadataDeterministically() {
        let emptySource = source(fileName: "plain.wav")
        let empty = HighQualityGlossarySelector.select(
            source: emptySource,
            turns: turns("今日は晴れです。")
        )
        XCTAssertTrue(empty.promptTerms.isEmpty)

        let ambiguous = HighQualityGlossarySelector.select(
            source: emptySource,
            turns: turns("進撃します。")
        )
        let attack = ambiguous.decisions.first { $0.term.id == "attack-on-titan" }
        XCTAssertEqual(attack?.selected, false)
        XCTAssertEqual(attack?.reason, "false-correction-risk budget")

        let confirmedAmbiguous = HighQualityGlossarySelector.select(
            source: source(title: "エペ 配信"),
            turns: turns("今日は晴れです。")
        )
        XCTAssertTrue(confirmedAmbiguous.promptTerms.contains { $0.id == "apex-legends" })

        let commonEnglish = HighQualityGlossarySelector.select(
            source: source(title: "Apex Plumbing"),
            turns: turns("今日は晴れです。")
        )
        XCTAssertFalse(commonEnglish.promptTerms.contains { $0.id == "apex-legends" })

        let mixedSource = source(
            title: "星野ルナ (Hoshino Luna) 鬼滅の刃 x Apex Legends",
            channel: "hololive",
            description: "cross-domain fixture"
        )
        let mixedBudget = HighQualityGlossaryBudget(
            maxEntries: 12,
            maxEncodedBytes: 2_048,
            maxContextShare: 0.9,
            maxScoringOperations: 512,
            maxFalseCorrectionRisk: 0.5
        )
        let first = HighQualityGlossarySelector.select(
            source: mixedSource,
            turns: turns("よろしくお願いします。"),
            budget: mixedBudget
        )
        let second = HighQualityGlossarySelector.select(
            source: mixedSource,
            turns: turns("よろしくお願いします。"),
            budget: mixedBudget
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            Set(first.promptTerms.map(\.id)),
            [
                "demon-slayer", "apex-legends", "hololive",
                "yoroshiku-onegaishimasu", "source-hoshino-luna",
            ]
        )
        let sourceTerm = first.decisions.first { $0.term.id == "source-hoshino-luna" }
        XCTAssertEqual(sourceTerm?.term.domain, .source)
        XCTAssertEqual(sourceTerm?.term.provenance, ["https://youtu.be/fixture"])
    }

    func testSelectionEnforcesEveryDeclaredBudgetBoundary() {
        let allTerms = HighQualityGlossaryCatalog.terms
            .flatMap(\.japaneseForms)
            .joined(separator: " ")
        let source = source(title: allTerms)

        let standard = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms)
        )
        XCTAssertLessThanOrEqual(standard.promptTerms.count, standard.budget.maxEntries)
        XCTAssertLessThanOrEqual(standard.encodedSize, standard.budget.maxEncodedBytes)
        XCTAssertLessThanOrEqual(
            Double(standard.encodedSize) / Double(standard.contextBytes),
            standard.budget.maxContextShare
        )
        XCTAssertLessThanOrEqual(
            standard.scoringOperations,
            standard.budget.maxScoringOperations
        )

        let twoEntries = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms),
            budget: .init(
                maxEntries: 2,
                maxEncodedBytes: 10_000,
                maxContextShare: 0.9,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0.5
            )
        )
        XCTAssertEqual(twoEntries.promptTerms.count, 2)
        XCTAssertTrue(twoEntries.decisions.contains { $0.reason == "entry-count budget" })

        let oneByte = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms),
            budget: .init(
                maxEntries: 16,
                maxEncodedBytes: 1,
                maxContextShare: 0.9,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0.5
            )
        )
        XCTAssertTrue(oneByte.promptTerms.isEmpty)
        XCTAssertTrue(oneByte.decisions.contains { $0.reason == "encoded-size budget" })

        let tinyContext = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms),
            budget: .init(
                maxEntries: 16,
                maxEncodedBytes: 10_000,
                maxContextShare: 0.0001,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0.5
            )
        )
        XCTAssertTrue(tinyContext.promptTerms.isEmpty)
        XCTAssertTrue(tinyContext.decisions.contains { $0.reason == "context-share budget" })

        let oneOperation = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms),
            budget: .init(
                maxEntries: 16,
                maxEncodedBytes: 10_000,
                maxContextShare: 0.9,
                maxScoringOperations: 1,
                maxFalseCorrectionRisk: 0.5
            )
        )
        XCTAssertEqual(oneOperation.scoringOperations, 1)
        XCTAssertTrue(oneOperation.decisions.contains { $0.reason == "runtime-cost budget" })
    }

    func testDevelopmentMetricsReportTermQualityAndFalseCorrectionRisk() {
        let metrics = HighQualityGlossaryMetrics.measure(
            selectedTermIDs: ["apex", "reid", "extra"],
            expectedTermIDs: ["apex", "reid", "missing"],
            correctlyTranslatedTermIDs: ["apex"],
            evaluatedNegativeTermCount: 4,
            falseSelectedTermCount: 1
        )

        XCTAssertEqual(metrics.specializedTermPrecision, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.specializedTermRecall, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.specializedTermF1, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.glossaryAccuracy, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.falseCorrectionRisk, 0.25, accuracy: 0.0001)
    }

    func testCheckedInDevelopmentReportMatchesQuduCorpus() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = try JapaneseBenchmarkSupport.loadManifest(
            at: root.appendingPathComponent(
                "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
            )
        )
        let report = try JSONDecoder().decode(
            HighQualityGlossaryDevelopmentReport.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "docs/high-quality-glossary-development.json"
            ))
        )
        let turns = manifest.annotations.turns.map {
            HighQualityTranslationTurn(
                id: String(format: "cue-%04d", $0.id),
                japanese: $0.japanese,
                precedingJapanese: [],
                followingJapanese: [],
                speakerLabel: $0.speaker
            )
        }
        let selection = HighQualityGlossarySelector.select(
            source: .init(
                path: "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json",
                fileName: "qudu2fx3ncc",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: nil
            ),
            turns: turns
        )
        let selectedTermIDs = Set(selection.promptTerms.map(\.id))
        let correctTermIDs = Set(report.expectedTermIDs.filter { id in
            guard let term = HighQualityGlossaryCatalog.terms.first(where: { $0.id == id })
            else { return false }
            let matchingTurns = manifest.annotations.turns.filter { turn in
                term.japaneseForms.contains { turn.japanese.contains($0) }
            }
            let acceptedEnglish = [term.canonicalEnglish] + term.englishAliases
            return !matchingTurns.isEmpty && matchingTurns.allSatisfy { turn in
                guard let english = turn.english else { return false }
                return acceptedEnglish.contains {
                    english.localizedCaseInsensitiveContains($0)
                }
            }
        })
        let falseSelectedTermCount = selectedTermIDs
            .subtracting(report.expectedTermIDs).count
        let metrics = HighQualityGlossaryMetrics.measure(
            selectedTermIDs: selectedTermIDs,
            expectedTermIDs: report.expectedTermIDs,
            correctlyTranslatedTermIDs: correctTermIDs,
            evaluatedNegativeTermCount: report.negativeTermCount,
            falseSelectedTermCount: falseSelectedTermCount
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.corpusID, manifest.corpusID)
        XCTAssertEqual(
            report.referenceSHA256,
            manifest.source.references.first { $0.label == "bilingual-reference" }?.sha256
        )
        XCTAssertEqual(selectedTermIDs, report.selectedTermIDs)
        XCTAssertEqual(falseSelectedTermCount, report.falseSelectedTermCount)
        XCTAssertEqual(metrics, report.metrics)
        XCTAssertLessThanOrEqual(
            metrics.falseCorrectionRisk,
            selection.budget.maxFalseCorrectionRisk
        )
    }

    private func source(
        fileName: String = "source.wav",
        title: String = "",
        channel: String = "",
        description: String = ""
    ) -> HighQualitySourceProvenance {
        HighQualitySourceProvenance(
            path: "/tmp/\(fileName)",
            fileName: fileName,
            byteCount: nil,
            modifiedAt: nil,
            sourceURL: title.isEmpty ? nil : "https://youtu.be/fixture",
            youtube: title.isEmpty ? nil : .init(
                sourceURL: "https://youtu.be/fixture",
                title: title,
                channel: channel,
                description: description,
                ytDLPVersion: "fixture",
                diagnostics: "fixture"
            )
        )
    }

    private func turns(_ japanese: String) -> [HighQualityTranslationTurn] {
        [.init(
            id: "cue-0001",
            japanese: japanese,
            precedingJapanese: [],
            followingJapanese: [],
            speakerLabel: nil
        )]
    }
}

private struct HighQualityGlossaryDevelopmentReport: Decodable {
    let schemaVersion: Int
    let corpusID: String
    let referenceSHA256: String
    let expectedTermIDs: Set<String>
    let selectedTermIDs: Set<String>
    let negativeTermCount: Int
    let falseSelectedTermCount: Int
    let metrics: HighQualityGlossaryMetrics
}
