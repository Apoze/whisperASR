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

        let metadataOnly = HighQualityGlossarySelector.select(
            source: source(title: "エペ 配信"),
            turns: turns("今日は晴れです。")
        )
        XCTAssertFalse(metadataOnly.promptTerms.contains { $0.id == "apex-legends" })

        let disambiguated = HighQualityGlossarySelector.select(
            source: source(title: "エペ 配信"),
            turns: turns("エペを始めます。")
        )
        XCTAssertEqual(disambiguated.promptTerms.map(\.id), ["apex-legends"])

        let conflicting = HighQualityGlossarySelector.select(
            source: source(title: "VALORANT 配信"),
            turns: turns("エペを始めます。")
        )
        XCTAssertTrue(conflicting.promptTerms.isEmpty)

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
            maxInputTokenShare: 0.9,
            maxScoringOperations: 512,
            maxFalseCorrectionRisk: 0.5
        )
        let first = HighQualityGlossarySelector.select(
            source: mixedSource,
            turns: turns("星野ルナと鬼滅の刃とホロライブでエーペックスレジェンズ。よろしくお願いします。"),
            budget: mixedBudget
        )
        let second = HighQualityGlossarySelector.select(
            source: mixedSource,
            turns: turns("星野ルナと鬼滅の刃とホロライブでエーペックスレジェンズ。よろしくお願いします。"),
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

    func testCueLocalSelectionUsesExactFormsMetadataOnlyForDisambiguationAndOneCanonical() {
        let source = source(title: "VALORANT 配信")
        let selection = HighQualityGlossarySelector.select(
            source: source,
            turns: [
                turn("cue-0001", "エーペックスレジェンズを始めます。"),
                turn("cue-0002", "甘結もかが来ました。"),
                turn("cue-0003", "甘いモカが勝ちました。"),
                turn("cue-0004", "エペを取ります。"),
                turn("cue-0005", "お疲れ様。"),
            ]
        )

        XCTAssertEqual(selection.promptTerms(for: "cue-0001").map(\.id), ["apex-legends"])
        XCTAssertEqual(selection.promptTerms(for: "cue-0002").map(\.id), ["amayui-moka"])
        XCTAssertEqual(selection.promptTerms(for: "cue-0003").map(\.id), ["amayui-moka"])
        XCTAssertEqual(selection.promptTerms(for: "cue-0004").map(\.id), ["apex-legends"])
        XCTAssertEqual(selection.promptTerms(for: "cue-0005").map(\.id), ["otsukaresama"])
        XCTAssertFalse(selection.promptTerms.contains { $0.id == "valorant" })
        XCTAssertEqual(selection.terminologyRegister["amayui-moka"], "Amayui Moka")
        XCTAssertEqual(
            selection.decisions.first { $0.term.id == "amayui-moka" }?.guidance,
            .hard
        )
        XCTAssertEqual(
            selection.decisions.first { $0.term.id == "otsukaresama" }?.guidance,
            .soft
        )
        XCTAssertTrue(selection.tokenShareByCueID.values.allSatisfy {
            $0 <= selection.budget.maxInputTokenShare
        })
    }

    func testTerminologyRegisterDoesNotPropagateABudgetRejectedCanonical() {
        let selection = HighQualityGlossarySelector.select(
            source: source(),
            turns: [
                turn("cue-0001", "ホロライブで甘結もかを見ます。"),
                turn("cue-0002", "ホロを見ます。"),
                turn("cue-0003", "甘結もかが来ました。"),
                turn("cue-0004", "甘結もかが勝ちました。"),
            ],
            budget: .init(
                maxEntries: 1,
                maxEncodedBytes: 10_000,
                maxInputTokenShare: 0.9,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0
            )
        )

        XCTAssertTrue(selection.promptTerms(for: "cue-0001").allSatisfy {
            $0.id != "hololive"
        })
        XCTAssertTrue(selection.promptTerms(for: "cue-0002").allSatisfy {
            $0.id != "hololive"
        })
        XCTAssertNil(selection.terminologyRegister["hololive"])
    }

    func testMetadataDoesNotOutrankAnExactCueMatch() {
        let selection = HighQualityGlossarySelector.select(
            source: source(title: "ホロライブ配信"),
            turns: turns("エーペックスレジェンズとホロライブ。"),
            budget: .init(
                maxEntries: 1,
                maxEncodedBytes: 10_000,
                maxInputTokenShare: 0.9,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0
            )
        )

        XCTAssertEqual(selection.promptTerms.map(\.id), ["apex-legends"])
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
        XCTAssertTrue(standard.tokenShareByCueID.values.allSatisfy {
            $0 <= standard.budget.maxInputTokenShare
        })
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
                maxInputTokenShare: 0.9,
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
                maxInputTokenShare: 0.9,
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
                maxInputTokenShare: 0.0001,
                maxScoringOperations: 512,
                maxFalseCorrectionRisk: 0.5
            )
        )
        XCTAssertTrue(tinyContext.promptTerms.isEmpty)
        XCTAssertTrue(tinyContext.decisions.contains {
            $0.reason == "input-token-share budget"
        })

        let oneOperation = HighQualityGlossarySelector.select(
            source: source,
            turns: turns(allTerms),
            budget: .init(
                maxEntries: 16,
                maxEncodedBytes: 10_000,
                maxInputTokenShare: 0.9,
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

    func testE12ReportFreezesDevelopmentBudgetAndDoesNotPromoteEmptyHoldout() throws {
        let report = try JSONDecoder().decode(
            HighQualityCueGlossaryReport.self,
            from: Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("docs/high-quality-glossary-e12.json"))
        )

        XCTAssertEqual(report.ticket, 53)
        XCTAssertEqual(report.budget.maxEntries, HighQualityGlossaryBudget.standard.maxEntries)
        XCTAssertEqual(
            report.budget.maxInputTokenShare,
            HighQualityGlossaryBudget.standard.maxInputTokenShare
        )
        XCTAssertEqual(report.development.criticalTermAccuracy, 1)
        XCTAssertEqual(report.development.falseInsertions, 0)
        XCTAssertEqual(Set(report.developmentBudgetTuning.map(\.maxEntries)), [8, 10, 12])
        XCTAssertEqual(
            Set(report.developmentBudgetTuning.map(\.maxInputTokenShare)),
            [0.15, 0.2, 0.25]
        )
        XCTAssertTrue(report.developmentBudgetTuning.allSatisfy {
            $0.criticalTermAccuracy == 1 && $0.falseInsertions == 0
        })
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let development = try JapaneseBenchmarkSupport.loadManifest(
            at: root.appendingPathComponent(
                "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
            )
        )
        let turns = development.annotations.turns.map {
            turn(String(format: "cue-%04d", $0.id), $0.japanese)
        }
        for trial in report.developmentBudgetTuning {
            let selection = HighQualityGlossarySelector.select(
                source: source(fileName: development.corpusID),
                turns: turns,
                budget: .init(
                    maxEntries: trial.maxEntries,
                    maxEncodedBytes: 2_048,
                    maxInputTokenShare: trial.maxInputTokenShare,
                    maxScoringOperations: 512,
                    maxFalseCorrectionRisk: 0
                )
            )
            let selected = Set(selection.promptTerms.map(\.id))
            XCTAssertEqual(selected.count, trial.selectedTerms)
            XCTAssertEqual(selected.contains("amayui-moka") ? 1 : 0,
                           trial.criticalTermAccuracy)
            XCTAssertEqual(selected.subtracting(["amayui-moka"]).count,
                           trial.falseInsertions)
        }
        XCTAssertEqual(report.development.integrityGates.version,
                       HighQualityTranslationIntegrityThresholds.developmentV1.version)
        XCTAssertEqual(report.holdout.criticalOpportunities, 0)
        XCTAssertNil(report.holdout.criticalTermAccuracy)
        XCTAssertEqual(report.holdout.integrityGates,
                       report.development.integrityGates)
        for artifact in report.development.rawArtifacts + report.holdout.rawArtifacts {
            let data = try Data(contentsOf: root.appendingPathComponent(artifact.path))
            XCTAssertFalse(data.isEmpty, artifact.path)
            XCTAssertEqual(artifact.sha256.count, 64)
        }
        XCTAssertFalse(report.promoted)
        XCTAssertFalse(report.evidenceLimitation.isEmpty)
    }

    func testCheckedInE12SelectionEvidenceMatchesCurrentSelector() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidenceDirectory = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/E12"
        )
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let relativeManifest = "docs/japanese-live/corpora/\(corpusID)/manifest.json"
            let manifest = try JapaneseBenchmarkSupport.loadManifest(
                at: root.appendingPathComponent(relativeManifest)
            )
            let turns = manifest.annotations.turns.map {
                turn(String(format: "cue-%04d", $0.id), $0.japanese)
            }
            let selection = HighQualityGlossarySelector.select(
                source: HighQualitySourceProvenance(
                    path: relativeManifest,
                    fileName: corpusID,
                    byteCount: nil,
                    modifiedAt: nil,
                    sourceURL: nil,
                    youtube: nil
                ),
                turns: turns
            )
            let expected = HighQualityGlossarySelectionEvidence(
                schemaVersion: 1,
                ticket: 53,
                corpusID: corpusID,
                selection: selection,
                validationOpportunityTermIDsByCueID: Dictionary(
                    uniqueKeysWithValues: turns.map {
                        ($0.id, selection.promptTerms(for: $0.id).map(\.id))
                    }
                )
            )
            let split = corpusID == "qudu2fx3ncc" ? "development" : "holdout"
            let evidenceURL = evidenceDirectory.appendingPathComponent(
                "\(split)-glossary-selection.json"
            )
            if ProcessInfo.processInfo.environment[
                "WHISPERASR_WRITE_E12_GLOSSARY_EVIDENCE"
            ] == "1" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(expected).write(to: evidenceURL, options: .atomic)
            }
            let checkedIn = try JSONDecoder().decode(
                HighQualityGlossarySelectionEvidence.self,
                from: Data(contentsOf: evidenceURL)
            )
            XCTAssertEqual(checkedIn, expected, split)
        }
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
        [turn("cue-0001", japanese)]
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

private struct HighQualityGlossarySelectionEvidence: Codable, Equatable {
    let schemaVersion: Int
    let ticket: Int
    let corpusID: String
    let selection: HighQualityGlossarySelection
    let validationOpportunityTermIDsByCueID: [String: [String]]
}

private struct HighQualityCueGlossaryReport: Decodable {
    struct Budget: Decodable {
        let maxEntries: Int
        let maxInputTokenShare: Double
    }

    struct Split: Decodable {
        let criticalOpportunities: Int
        let criticalTermAccuracy: Double?
        let falseInsertions: Int
        let integrityGates: HighQualityTranslationIntegrityThresholds
        let rawArtifacts: [Artifact]
    }

    struct BudgetTrial: Decodable {
        let maxEntries: Int
        let maxInputTokenShare: Double
        let selectedTerms: Int
        let criticalTermAccuracy: Double
        let falseInsertions: Int
    }

    struct Artifact: Decodable {
        let path: String
        let sha256: String
    }

    let ticket: Int
    let budget: Budget
    let developmentBudgetTuning: [BudgetTrial]
    let development: Split
    let holdout: Split
    let promoted: Bool
    let evidenceLimitation: String
}
