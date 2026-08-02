import XCTest
@testable import WhisperASRApp

final class JapaneseGlossaryTests: XCTestCase {
    func testLongestExactEntryWins() {
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "東京", canonical: "とうきょう"),
            .init(recognized: "東京大学", canonical: "東大"),
        ])

        XCTAssertEqual(glossary.applying(to: "東京大学です。"), "東大です。")
    }

    func testReplacementIsNonRecursive() {
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "配給", canonical: "ハイキュー"),
            .init(recognized: "ハイキュー", canonical: "排球"),
        ])

        XCTAssertEqual(glossary.applying(to: "配給が好き。"), "ハイキューが好き。")
    }

    func testFirstNormalizedDuplicateWinsDeterministically() {
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "ハ\u{3099}イ", canonical: "最初"),
            .init(recognized: "バイ", canonical: "二番目"),
        ])

        XCTAssertEqual(glossary.applying(to: "バイ"), "最初")
    }

    func testSimilarAndAlreadyCanonicalTermsAreNotFalsePositives() {
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "配給", canonical: "ハイキュー"),
        ])

        XCTAssertEqual(glossary.applying(to: "配球とハイキュー"), "配球とハイキュー")
    }

    func testNFCAndTransportControlsAreHandledOnTranslationCopyOnly() {
        let raw = "ハ\u{3099}\u{0000}イキューが好き。"
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "バイキュー", canonical: "ハイキュー"),
        ])

        XCTAssertEqual(glossary.applying(to: raw), "ハイキューが好き。")
        XCTAssertEqual(raw, "ハ\u{3099}\u{0000}イキューが好き。")
    }

    func testEmptyGlossaryIsStrictIdentity() {
        let raw = "ハ\u{3099}\u{0000}イキュー"

        XCTAssertEqual(JapaneseGlossary(entries: []).applying(to: raw), raw)
    }

    func testEmptyEntriesCannotDeleteSourceText() {
        let glossary = JapaneseGlossary(entries: [
            .init(recognized: "", canonical: "ハイキュー"),
            .init(recognized: "配給", canonical: ""),
        ])

        XCTAssertEqual(glossary.applying(to: "配給"), "配給")
    }

    func testRulesUseOnlyExactEqualsSeparatedPairs() {
        let glossary = JapaneseGlossary(rules: "配給 = ハイキュー\ninvalid\n猫=ねこ")

        XCTAssertEqual(
            glossary.applying(to: "配給と配球と猫"),
            "ハイキューと配球とねこ"
        )
    }

    func testFingerprintIsStableAndAbsentWhenEmpty() {
        let first = JapaneseGlossary(rules: "猫=ねこ\n配給=ハイキュー")
        let second = JapaneseGlossary(rules: "配給=ハイキュー\n猫=ねこ")

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNil(JapaneseGlossary.empty.fingerprint)
    }

    func testDecodedRecoveryEntriesAreValidated() throws {
        let data = Data(#"{"entries":[{"recognized":"","canonical":"ハイキュー"},{"recognized":"配給","canonical":"ハイキュー"}]}"#.utf8)
        let glossary = try JSONDecoder().decode(JapaneseGlossary.self, from: data)

        XCTAssertEqual(glossary.applying(to: "配給です。"), "ハイキューです。")
    }

    func testVSPOProfileBuildsAppleAndTranslationInputs() {
        let glossary = JapaneseContextLibrary.defaultLibrary.activeGlossary(
            selection: JapaneseContextLibrary.vspoID
        )

        XCTAssertEqual(glossary.contextualTermCount, 49)
        XCTAssertTrue(glossary.appleContextualStrings.contains("甘結もか"))
        XCTAssertTrue(glossary.appleContextualStrings.contains("梅園ジュノ"))
        XCTAssertEqual(
            glossary.applying(to: "続いて甘いモカ、そして立川。"),
            "続いて甘結もか、そして立川。"
        )
    }

    func testOffSelectionDisablesAllContextAndCorrections() {
        let glossary = JapaneseContextLibrary.defaultLibrary.activeGlossary(
            selection: JapaneseContextLibrary.offSelection
        )

        XCTAssertTrue(glossary.isEmpty)
        XCTAssertEqual(glossary.applying(to: "甘いモカ"), "甘いモカ")
    }

    func testSelectedProfileWinsAliasConflict() {
        let library = JapaneseContextLibrary(profiles: [
            .init(
                id: JapaneseContextLibrary.generalID,
                name: "General",
                terms: [.init(canonical: "一般", aliases: ["同音"])]
            ),
            .init(
                id: "topic",
                name: "Topic",
                terms: [.init(canonical: "専門", aliases: ["同音"])]
            ),
        ])

        XCTAssertEqual(
            library.activeGlossary(selection: "topic").applying(to: "同音"),
            "専門"
        )
    }

    func testLegacyRulesMigrateOnceIntoGeneralProfile() {
        let suite = "JapaneseContextMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: JapaneseGlossary.enabledKey)
        defaults.set("甘いモカ=甘結もか", forKey: JapaneseGlossary.rulesKey)

        let first = JapaneseContextLibrary.stored(in: defaults)
        let second = JapaneseContextLibrary.stored(in: defaults)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            defaults.string(forKey: JapaneseContextLibrary.selectionKey),
            JapaneseContextLibrary.generalID
        )
        XCTAssertEqual(
            JapaneseGlossary.stored(in: defaults).applying(to: "甘いモカ"),
            "甘結もか"
        )
    }

    func testAppleContextUsesAtMostOneHundredTerms() {
        let terms = (0..<101).map {
            JapaneseContextTerm(id: "\($0)", canonical: "用語\($0)")
        }
        let library = JapaneseContextLibrary(profiles: [
            .init(id: JapaneseContextLibrary.generalID, name: "General", terms: terms),
        ])

        XCTAssertEqual(
            library.activeGlossary(selection: JapaneseContextLibrary.generalID)
                .appleContextualStrings.count,
            100
        )
    }

    func testContextSnapshotRoundTripsAndPreservesRawWhitespace() throws {
        let original = JapaneseContextLibrary.defaultLibrary.activeGlossary(
            selection: JapaneseContextLibrary.vspoID
        )
        let restored = try JSONDecoder().decode(
            JapaneseGlossary.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.applying(to: "  甘いモカ  "), "  甘結もか  ")
        XCTAssertEqual(restored.fingerprint, original.fingerprint)
    }

}
