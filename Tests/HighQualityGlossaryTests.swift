import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityGlossaryTests: XCTestCase {
    func testBuiltInCatalogCoversEveryDeclaredDomainWithRulesAndProvenance() {
        XCTAssertEqual(HighQualityGlossaryCatalog.schemaVersion, 2)
        XCTAssertEqual(HighQualityGlossaryCatalog.catalogVersion, "2026-08-10")
        XCTAssertEqual(
            Set(HighQualityGlossaryCatalog.terms.map(\.domain)),
            [.anime, .vtuber, .gaming, .conversation]
        )
        XCTAssertEqual(HighQualityGlossaryCatalog.terms.count, 35)
        let ids = HighQualityGlossaryCatalog.terms.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        var forms = Set<String>()
        for term in HighQualityGlossaryCatalog.terms {
            XCTAssertTrue(term.japaneseForms.contains(term.officialJapanese))
            XCTAssertFalse(term.japaneseForms.isEmpty)
            XCTAssertFalse(term.canonicalEnglish.isEmpty)
            XCTAssertFalse(term.sourceScope.isEmpty)
            XCTAssertNotEqual(term.sourceScope, term.canonicalEnglish)
            XCTAssertFalse(term.provenance.isEmpty)
            XCTAssertTrue(term.provenance.allSatisfy { URL(string: $0)?.scheme == "https" })
            XCTAssertNotNil(ISO8601DateFormatter().date(from: "\(term.verifiedOn)T00:00:00Z"))
            XCTAssertFalse(term.inclusionRule.isEmpty)
            XCTAssertFalse(term.exclusionRule.isEmpty)
            XCTAssertTrue(Set(term.ambiguousJapaneseForms).isSubset(of: term.japaneseForms))
            if term.ambiguityClass == .commonWord {
                XCTAssertTrue(term.inclusionRule.contains("metadata"))
                XCTAssertTrue(term.inclusionRule.contains("unambiguous full form"))
            }
            for form in term.japaneseForms {
                XCTAssertTrue(forms.insert(normalized(form)).inserted, form)
            }
        }
        XCTAssertTrue(HighQualityGlossaryCatalog.coverageLimit.contains("not universal"))
    }

    func testEveryExpandedEntryIsSelectableWithinBudgetAndSafeWhenIrrelevant() throws {
        let expandedIDs = [
            "chainsaw-man", "frieren", "oshi-no-ko", "one-piece",
            "yano-kuromu", "shirayuki-reid", "tachikawa", "akuma",
            "demon-raid", "modern-controls", "drive-impact", "burnout",
            "mirage", "apex-ring", "keyboard-and-mouse", "hajimemashite",
            "ohayo-gozaimasu", "gochisosama", "ittekimasu",
        ]

        for id in expandedIDs {
            let term = try XCTUnwrap(HighQualityGlossaryCatalog.terms.first { $0.id == id })
            let selected = HighQualityGlossarySelector.select(
                source: source(title: term.officialJapanese),
                turns: turns(term.officialJapanese)
            )
            XCTAssertTrue(selected.promptTerms(for: "cue-0001").contains { $0.id == id }, id)
            XCTAssertLessThanOrEqual(selected.promptTerms.count, selected.budget.maxEntries, id)
            XCTAssertLessThanOrEqual(selected.encodedSize, selected.budget.maxEncodedBytes, id)

            let irrelevant = HighQualityGlossarySelector.select(
                source: source(fileName: "unrelated.wav"),
                turns: turns(term.ambiguousJapaneseForms.first
                    ?? "今日は静かな一日です。")
            )
            XCTAssertFalse(irrelevant.promptTerms.contains { $0.id == id }, id)
        }
    }

    func testExpandedCatalogSelectsCorpusTermsWithoutChangingBudgets() {
        let selection = HighQualityGlossarySelector.select(
            source: source(fileName: "offline-corpus"),
            turns: [
                turn("cue-0001", "豪鬼がOD百鬼襲から前に詰めます。"),
                turn("cue-0002", "ドライブインパクトを打つとバーンアウトになります。"),
                turn("cue-0003", "キーマウを試します。"),
            ]
        )

        XCTAssertEqual(
            Set(selection.promptTerms.map(\.id)),
            ["akuma", "demon-raid", "drive-impact", "burnout", "keyboard-and-mouse"]
        )
        XCTAssertLessThanOrEqual(selection.promptTerms.count, selection.budget.maxEntries)
        XCTAssertTrue(selection.tokenShareByCueID.values.allSatisfy {
            $0 <= selection.budget.maxInputTokenShare
        })
    }

    func testExpandedCatalogRejectsAmbiguousCommonFormsWithoutDomainEvidence() {
        let selection = HighQualityGlossarySelector.select(
            source: source(fileName: "plain.wav"),
            turns: turns("立川でミラージュを見ました。リングもあります。")
        )

        XCTAssertTrue(selection.promptTerms.isEmpty)
        XCTAssertTrue(["tachikawa", "mirage", "apex-ring"].allSatisfy { id in
            selection.decisions.first { $0.term.id == id }?.reason
                == "false-correction-risk budget"
        })

        let gaming = HighQualityGlossarySelector.select(
            source: source(title: "Mirage — Apex Legends"),
            turns: turns("ミラージュを選びます。")
        )
        XCTAssertEqual(gaming.promptTerms.map(\.id), ["mirage"])
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

    func testHistoricalDevelopmentReportRemainsDecodable() throws {
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
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.corpusID, manifest.corpusID)
        XCTAssertEqual(
            report.referenceSHA256,
            manifest.source.references.first { $0.label == "bilingual-reference" }?.sha256
        )
        XCTAssertEqual(report.selectedTermIDs, ["amayui-moka"])
        XCTAssertEqual(report.falseSelectedTermCount, 0)
        XCTAssertEqual(report.metrics.falseCorrectionRisk, 0)
        XCTAssertTrue(report.expectedTermIDs.isSubset(of:
            Set(HighQualityGlossaryCatalog.terms.map(\.id))))
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

    func testHistoricalE12SelectionEvidenceRemainsDecodable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidenceDirectory = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/E12"
        )
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let split = corpusID == "qudu2fx3ncc" ? "development" : "holdout"
            let evidenceURL = evidenceDirectory.appendingPathComponent(
                "\(split)-glossary-selection.json"
            )
            let checkedIn = try JSONDecoder().decode(
                HighQualityGlossarySelectionEvidence.self,
                from: Data(contentsOf: evidenceURL)
            )
            XCTAssertEqual(checkedIn.schemaVersion, 1)
            XCTAssertEqual(checkedIn.ticket, 53)
            XCTAssertEqual(checkedIn.corpusID, corpusID)
            XCTAssertEqual(checkedIn.selection.decisions.count, 16)
        }
    }

    func testCheckedInE13EvidenceAndCoverageMatchExpandedCatalog() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidenceDirectory = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/E13"
        )
        var opportunityCounts: [String: Int] = [:]
        var maximumPromptEntries: [String: Int] = [:]
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let split = corpusID == "qudu2fx3ncc" ? "development" : "holdout"
            let evidenceURL = evidenceDirectory.appendingPathComponent(
                "\(split)-glossary-selection.json"
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let shouldWrite = ProcessInfo.processInfo.environment[
                "WHISPERASR_WRITE_E13_GLOSSARY_EVIDENCE"
            ] == "1"
            let input: (HighQualitySourceProvenance, [HighQualityTranslationTurn])
            if shouldWrite {
                let key = "WHISPERASR_E13_\(split.uppercased())_BASELINE"
                let path = try XCTUnwrap(ProcessInfo.processInfo.environment[key], key)
                let baseline = try decoder.decode(
                    HighQualityTranslationEvidence.self,
                    from: Data(contentsOf: URL(fileURLWithPath: path))
                )
                let source = baseline.request.source
                input = (HighQualitySourceProvenance(
                    path: "docs/japanese-live/corpora/\(corpusID)/manifest.json",
                    fileName: source.fileName,
                    byteCount: source.byteCount,
                    modifiedAt: source.modifiedAt,
                    sourceURL: source.sourceURL,
                    youtube: source.youtube
                ), baseline.request.turns)
            } else {
                let checkedIn = try decoder.decode(
                    HighQualityExpandedGlossaryEvidence.self,
                    from: Data(contentsOf: evidenceURL)
                )
                input = (checkedIn.source, checkedIn.turns)
            }
            let selection = HighQualityGlossarySelector.select(
                source: input.0,
                turns: input.1
            )
            opportunityCounts[split] = selection.decisions.reduce(0) {
                $0 + $1.selectedCueIDs.count
            }
            maximumPromptEntries[split] = input.1.map {
                selection.promptTerms(for: $0.id).count
            }.max() ?? 0
            let expected = HighQualityExpandedGlossaryEvidence(
                schemaVersion: HighQualityGlossaryCatalog.schemaVersion,
                catalogVersion: HighQualityGlossaryCatalog.catalogVersion,
                ticket: 54,
                corpusID: corpusID,
                source: input.0,
                turns: input.1,
                selection: selection,
                validationOpportunityTermIDsByCueID: Dictionary(
                    uniqueKeysWithValues: input.1.map {
                        ($0.id, selection.promptTerms(for: $0.id).map(\.id))
                    }
                )
            )
            if shouldWrite {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(expected).write(to: evidenceURL, options: .atomic)
            }
            let checkedIn = try decoder.decode(
                HighQualityExpandedGlossaryEvidence.self,
                from: Data(contentsOf: evidenceURL)
            )
            XCTAssertEqual(checkedIn, expected, split)
        }

        let report = try JSONDecoder().decode(
            HighQualityExpandedGlossaryReport.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "docs/high-quality-glossary-e13.json"
            ))
        )
        XCTAssertEqual(report.ticket, 54)
        XCTAssertEqual(report.catalog.entries, HighQualityGlossaryCatalog.terms.count)
        XCTAssertEqual(Set(report.coverage.map(\.domain)),
                       [.anime, .vtuber, .gaming, .conversation])
        XCTAssertEqual(Set(report.coverage.filter {
            !$0.hasAuthoritativeLocalReference
        }.map(\.domain)), [.anime])
        XCTAssertEqual(report.development.falseInsertions, 0)
        XCTAssertEqual(report.holdout.falseInsertions, 0)
        XCTAssertEqual(report.development.canonicalOrAliasAccuracy, 1.0 / 3.0)
        XCTAssertNil(report.holdout.canonicalOrAliasAccuracy)
        XCTAssertEqual(report.development.applicableOpportunities,
                       opportunityCounts["development"])
        XCTAssertEqual(report.holdout.applicableOpportunities,
                       opportunityCounts["holdout"])
        XCTAssertEqual(report.development.maximumPromptEntries,
                       maximumPromptEntries["development"])
        XCTAssertEqual(report.holdout.maximumPromptEntries,
                       maximumPromptEntries["holdout"])
        XCTAssertGreaterThan(report.development.COMET, 0)
        XCTAssertGreaterThan(report.holdout.chrFPlusPlus, 0)
        XCTAssertLessThanOrEqual(report.development.maximumPromptEntries,
                                 HighQualityGlossaryBudget.standard.maxEntries)
        XCTAssertLessThanOrEqual(report.holdout.maximumPromptEntries,
                                 HighQualityGlossaryBudget.standard.maxEntries)
        for artifact in report.development.rawArtifacts + report.holdout.rawArtifacts {
            let url = root.appendingPathComponent(artifact.path)
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: url), artifact.sha256)
        }
        XCTAssertFalse(report.promoted)
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

    private func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
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

private struct HighQualityExpandedGlossaryEvidence: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let ticket: Int
    let corpusID: String
    let source: HighQualitySourceProvenance
    let turns: [HighQualityTranslationTurn]
    let selection: HighQualityGlossarySelection
    let validationOpportunityTermIDsByCueID: [String: [String]]
}

private struct HighQualityExpandedGlossaryReport: Decodable {
    struct Catalog: Decodable {
        let entries: Int
    }

    struct Coverage: Decodable {
        let domain: HighQualityGlossaryDomain
        let hasAuthoritativeLocalReference: Bool
    }

    struct Split: Decodable {
        struct Artifact: Decodable {
            let path: String
            let sha256: String
        }

        let applicableOpportunities: Int
        let canonicalOrAliasAccuracy: Double?
        let falseInsertions: Int
        let maximumPromptEntries: Int
        let COMET: Double
        let chrFPlusPlus: Double
        let rawArtifacts: [Artifact]
    }

    let ticket: Int
    let catalog: Catalog
    let coverage: [Coverage]
    let development: Split
    let holdout: Split
    let promoted: Bool
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
