import Foundation

enum HighQualityGlossaryDomain: String, Codable, CaseIterable, Sendable {
    case anime
    case vtuber
    case gaming
    case conversation
    case source
}

struct HighQualityGlossaryTerm: Codable, Equatable, Sendable {
    let id: String
    let domain: HighQualityGlossaryDomain
    let japaneseForms: [String]
    let canonicalEnglish: String
    let englishAliases: [String]
    let provenance: [String]
    let inclusionRule: String
    let exclusionRule: String
    let ambiguousJapaneseForms: [String]
}

struct HighQualityGlossaryPromptTerm: Codable, Equatable, Sendable {
    let id: String
    let japanese: [String]
    let english: String
    let englishAliases: [String]
}

private extension HighQualityGlossaryTerm {
    var promptTerm: HighQualityGlossaryPromptTerm {
        .init(
            id: id,
            japanese: japaneseForms,
            english: canonicalEnglish,
            englishAliases: englishAliases
        )
    }
}

struct HighQualityGlossaryBudget: Codable, Equatable, Sendable {
    let maxEntries: Int
    let maxEncodedBytes: Int
    let maxContextShare: Double
    let maxScoringOperations: Int
    let maxFalseCorrectionRisk: Double

    static let standard = Self(
        maxEntries: 12,
        maxEncodedBytes: 2_048,
        maxContextShare: 0.35,
        maxScoringOperations: 512,
        maxFalseCorrectionRisk: 0
    )
}

struct HighQualityGlossarySignal: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case title
        case channel
        case description
        case recognizedJapanese = "recognized-japanese"

        var weight: Int {
            switch self {
            case .title: 8
            case .channel: 6
            case .description: 4
            case .recognizedJapanese: 2
            }
        }
    }

    let source: Source
    let matchedForm: String
    let weight: Int
}

struct HighQualityGlossaryDecision: Codable, Equatable, Sendable {
    let term: HighQualityGlossaryTerm
    let signals: [HighQualityGlossarySignal]
    let score: Int
    let encodedSize: Int
    let falseCorrectionRisk: Double
    var selected: Bool
    var reason: String
}

struct HighQualityGlossarySelection: Codable, Equatable, Sendable {
    let budget: HighQualityGlossaryBudget
    let contextBytes: Int
    let encodedSize: Int
    let scoringOperations: Int
    let coverageLimit: String
    let decisions: [HighQualityGlossaryDecision]

    static let empty = Self(
        budget: .standard,
        contextBytes: 0,
        encodedSize: 0,
        scoringOperations: 0,
        coverageLimit: HighQualityGlossaryCatalog.coverageLimit,
        decisions: []
    )

    var promptTerms: [HighQualityGlossaryPromptTerm] {
        decisions.filter(\.selected).map(\.term.promptTerm)
    }
}

enum HighQualityGlossaryCatalog {
    static let coverageLimit = "Built-in seed terms only; source names, slang, new releases, and context-dependent translations may be absent."

    static let terms: [HighQualityGlossaryTerm] = [
        term("demon-slayer", .anime, ["鬼滅の刃", "鬼滅"], "Demon Slayer: Kimetsu no Yaiba", ["Demon Slayer"], "https://demonslayer-anime.com/", ambiguous: ["鬼滅"]),
        term("attack-on-titan", .anime, ["進撃の巨人", "進撃"], "Attack on Titan", [], "https://shingeki.tv/final/", ambiguous: ["進撃"]),
        term("my-hero-academia", .anime, ["僕のヒーローアカデミア", "ヒロアカ"], "My Hero Academia", [], "https://heroaca.com/"),
        term("jujutsu-kaisen", .anime, ["呪術廻戦", "呪術"], "JUJUTSU KAISEN", [], "https://jujutsukaisen.jp/", ambiguous: ["呪術"]),
        term("hololive", .vtuber, ["ホロライブ", "ホロ"], "hololive", ["hololive production"], "https://hololive.hololivepro.com/en/", ambiguous: ["ホロ"]),
        term("nijisanji", .vtuber, ["にじさんじ", "虹さんじ"], "NIJISANJI", [], "https://www.nijisanji.jp/en"),
        term("vspo", .vtuber, ["ぶいすぽっ！", "ぶいすぽ", "VSPO"], "VSPO!", [], "https://store.vspo.jp/en"),
        term("amayui-moka", .vtuber, ["甘結もか", "甘いモカ"], "Amayui Moka", ["Moka Amayui"], "https://vspo.jp/en/"),
        term("apex-legends", .gaming, ["エーペックスレジェンズ", "Apex Legends", "エペ"], "Apex Legends", [], "https://www.ea.com/ja-jp/games/apex-legends/about/frequently-asked-questions", ambiguous: ["エペ"]),
        term("valorant", .gaming, ["ヴァロラント", "VALORANT"], "VALORANT", [], "https://playvalorant.com/ja-jp/"),
        term("street-fighter-6", .gaming, ["ストリートファイター6", "ストロク"], "Street Fighter 6", ["SF6"], "https://www.streetfighter.com/6/ja-jp/", ambiguous: ["ストロク"]),
        term("minecraft", .gaming, ["マインクラフト", "マイクラ"], "Minecraft", [], "https://www.minecraft.net/ja-jp", ambiguous: ["マイクラ"]),
        term("otsukaresama", .conversation, ["お疲れさま", "お疲れ様"], "Thanks for your hard work", ["Good work"], "https://www.irodori.jpf.go.jp/assets/data/wordlist_X.pdf"),
        term("yoroshiku-onegaishimasu", .conversation, ["よろしくお願いします"], "Thank you in advance", ["Nice to meet you"], "https://www.irodori.jpf.go.jp/assets/data/Grammar_all.pdf"),
        term("itadakimasu", .conversation, ["いただきます"], "Let's eat", ["Thank you for the food"], "https://www.irodori.jpf.go.jp/assets/data/wordlist_X.pdf"),
        term("senpai", .conversation, ["先輩"], "senior", ["senpai"], "https://www.irodori.jpf.go.jp/assets/data/Grammar_all.pdf"),
    ]

    private static func term(
        _ id: String,
        _ domain: HighQualityGlossaryDomain,
        _ japaneseForms: [String],
        _ canonicalEnglish: String,
        _ englishAliases: [String],
        _ provenance: String,
        ambiguous: [String] = []
    ) -> HighQualityGlossaryTerm {
        HighQualityGlossaryTerm(
            id: id,
            domain: domain,
            japaneseForms: japaneseForms,
            canonicalEnglish: canonicalEnglish,
            englishAliases: englishAliases,
            provenance: [provenance],
            inclusionRule: "Select only when an exact Japanese or metadata form is present.",
            exclusionRule: ambiguous.isEmpty
                ? "Reject when no exact source relevance signal is present."
                : "Reject an ambiguous short form unless metadata or the full Japanese form confirms it.",
            ambiguousJapaneseForms: ambiguous
        )
    }
}

enum HighQualityGlossarySelector {
    static func select(
        source: HighQualitySourceProvenance,
        turns: [HighQualityTranslationTurn],
        budget: HighQualityGlossaryBudget = .standard
    ) -> HighQualityGlossarySelection {
        let metadata: [(HighQualityGlossarySignal.Source, String)] = [
            (.title, source.youtube?.title ?? source.fileName),
            (.channel, source.youtube?.channel ?? ""),
            (.description, source.youtube?.description ?? ""),
        ]
        let recognizedJapanese = turns.map(\.japanese).joined(separator: "\n")
        var operations = 0
        var decisions: [String: HighQualityGlossaryDecision] = [:]
        let terms = HighQualityGlossaryCatalog.terms + sourceTerms(
            metadata: metadata,
            provenance: source.sourceURL ?? source.path,
            limit: min(8, budget.maxEntries)
        )

        // ponytail: bounded linear scan; add an index only if the catalog grows substantially.
        for term in terms {
            var signals: [HighQualityGlossarySignal] = []
            let metadataForms = term.japaneseForms + (term.domain == .conversation
                ? [] : [term.canonicalEnglish] + term.englishAliases)
            for (source, text) in metadata where !text.isEmpty {
                if let match = firstMatch(
                    in: text,
                    forms: metadataForms,
                    operations: &operations,
                    limit: budget.maxScoringOperations
                ) {
                    signals.append(.init(source: source, matchedForm: match, weight: source.weight))
                }
            }
            if let match = firstMatch(
                in: recognizedJapanese,
                forms: term.japaneseForms,
                operations: &operations,
                limit: budget.maxScoringOperations
            ) {
                signals.append(.init(
                    source: .recognizedJapanese,
                    matchedForm: match,
                    weight: HighQualityGlossarySignal.Source.recognizedJapanese.weight
                ))
            }
            let prompt = term.promptTerm
            let falseCorrectionRisk = signals.isEmpty ? 0 : Double(signals.filter {
                $0.source == .recognizedJapanese
                    && term.ambiguousJapaneseForms.contains($0.matchedForm)
            }.count) / Double(signals.count)
            let reason: String
            if operations >= budget.maxScoringOperations && signals.isEmpty {
                reason = "runtime-cost budget"
            } else if falseCorrectionRisk > budget.maxFalseCorrectionRisk {
                reason = "false-correction-risk budget"
            } else {
                reason = signals.isEmpty ? "no relevance signal" : "eligible"
            }
            decisions[term.id] = .init(
                term: term,
                signals: signals,
                score: signals.reduce(0) { $0 + $1.weight },
                encodedSize: encodedSize(prompt),
                falseCorrectionRisk: falseCorrectionRisk,
                selected: false,
                reason: reason
            )
        }

        let ranked = decisions.values.filter { $0.reason == "eligible" }.sorted {
            $0.score == $1.score ? $0.term.id < $1.term.id : $0.score > $1.score
        }
        var selectedPrompts: [HighQualityGlossaryPromptTerm] = []
        for candidate in ranked {
            var decision = candidate
            let nextPrompts = selectedPrompts + [candidate.term.promptTerm]
            let nextEncodedSize = encodedSize(nextPrompts)
            let nextContextBytes = encodedContextSize(
                source: source,
                turns: turns,
                glossary: nextPrompts
            )
            if selectedPrompts.count >= budget.maxEntries {
                decision.reason = "entry-count budget"
            } else if nextEncodedSize > budget.maxEncodedBytes {
                decision.reason = "encoded-size budget"
            } else if Double(nextEncodedSize) / Double(max(nextContextBytes, 1))
                > budget.maxContextShare {
                decision.reason = "context-share budget"
            } else {
                decision.selected = true
                decision.reason = "selected"
                selectedPrompts = nextPrompts
            }
            decisions[candidate.term.id] = decision
        }

        let totalEncodedSize = encodedSize(selectedPrompts)
        let contextBytes = encodedContextSize(
            source: source,
            turns: turns,
            glossary: selectedPrompts
        )
        return HighQualityGlossarySelection(
            budget: budget,
            contextBytes: contextBytes,
            encodedSize: totalEncodedSize,
            scoringOperations: operations,
            coverageLimit: HighQualityGlossaryCatalog.coverageLimit,
            decisions: decisions.values.sorted { $0.term.id < $1.term.id }
        )
    }

    private static func sourceTerms(
        metadata: [(HighQualityGlossarySignal.Source, String)],
        provenance: String,
        limit: Int
    ) -> [HighQualityGlossaryTerm] {
        guard limit > 0 else { return [] }
        let pattern = #"([\p{Han}\p{Hiragana}\p{Katakana}ー・！!]{2,40})\s*[（(]\s*([A-Za-z][A-Za-z0-9 .&'’!-]{1,60})\s*[）)]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let builtInJapanese = Set(HighQualityGlossaryCatalog.terms.flatMap(\.japaneseForms))
        let builtInEnglish = Set(HighQualityGlossaryCatalog.terms.map {
            normalized($0.canonicalEnglish)
        })
        var ids = Set<String>()
        var terms: [HighQualityGlossaryTerm] = []
        for (_, text) in metadata where !text.isEmpty && terms.count < limit {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) where terms.count < limit {
                guard let japaneseRange = Range(match.range(at: 1), in: text),
                      let englishRange = Range(match.range(at: 2), in: text) else { continue }
                let japanese = String(text[japaneseRange])
                let english = String(text[englishRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let slug = english.lowercased().split {
                    !$0.isLetter && !$0.isNumber
                }.joined(separator: "-")
                let id = "source-\(slug)"
                guard !slug.isEmpty,
                      !builtInJapanese.contains(japanese),
                      !builtInEnglish.contains(normalized(english)),
                      ids.insert(id).inserted else { continue }
                terms.append(.init(
                    id: id,
                    domain: .source,
                    japaneseForms: [japanese],
                    canonicalEnglish: english,
                    englishAliases: [],
                    provenance: [provenance],
                    inclusionRule: "Select an exact bilingual pair supplied by source metadata.",
                    exclusionRule: "Reject unpaired or duplicate metadata text.",
                    ambiguousJapaneseForms: []
                ))
            }
        }
        return terms
    }

    private static func firstMatch(
        in text: String,
        forms: [String],
        operations: inout Int,
        limit: Int
    ) -> String? {
        let normalizedText = normalized(text)
        for form in forms.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            guard operations < limit else { return nil }
            operations += 1
            if contains(normalized(form), in: normalizedText) { return form }
        }
        return nil
    }

    private static func contains(_ form: String, in text: String) -> Bool {
        guard form.unicodeScalars.allSatisfy(\.isASCII) else {
            return text.contains(form)
        }
        var searchStart = text.startIndex
        while let range = text.range(of: form, range: searchStart..<text.endIndex) {
            let beforeIsWord = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isWholeNumberOrLetter
            let afterIsWord = range.upperBound < text.endIndex
                && text[range.upperBound].isWholeNumberOrLetter
            if !beforeIsWord && !afterIsWord { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func encodedSize<Value: Encodable>(_ value: Value) -> Int {
        (try? JSONEncoder().encode(value).count) ?? .max
    }

    private static func encodedContextSize(
        source: HighQualitySourceProvenance,
        turns: [HighQualityTranslationTurn],
        glossary: [HighQualityGlossaryPromptTerm]
    ) -> Int {
        encodedSize(HighQualityTranslationBatch(
            source: source,
            turns: turns,
            glossary: glossary
        ))
    }
}

private extension Character {
    var isWholeNumberOrLetter: Bool { isLetter || isNumber }
}

struct HighQualityGlossaryMetrics: Codable, Equatable, Sendable {
    let specializedTermPrecision: Double
    let specializedTermRecall: Double
    let specializedTermF1: Double
    let glossaryAccuracy: Double
    let falseCorrectionRisk: Double

    static func measure(
        selectedTermIDs: Set<String>,
        expectedTermIDs: Set<String>,
        correctlyTranslatedTermIDs: Set<String>,
        evaluatedNegativeTermCount: Int,
        falseSelectedTermCount: Int
    ) -> Self {
        let truePositives = selectedTermIDs.intersection(expectedTermIDs).count
        let precision = selectedTermIDs.isEmpty
            ? (expectedTermIDs.isEmpty ? 1 : 0)
            : Double(truePositives) / Double(selectedTermIDs.count)
        let recall = expectedTermIDs.isEmpty
            ? 1
            : Double(truePositives) / Double(expectedTermIDs.count)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let accuracy = expectedTermIDs.isEmpty
            ? 1
            : Double(correctlyTranslatedTermIDs.intersection(expectedTermIDs).count)
                / Double(expectedTermIDs.count)
        let falseCorrectionRisk = evaluatedNegativeTermCount == 0
            ? 0
            : Double(falseSelectedTermCount) / Double(evaluatedNegativeTermCount)
        return Self(
            specializedTermPrecision: precision,
            specializedTermRecall: recall,
            specializedTermF1: f1,
            glossaryAccuracy: accuracy,
            falseCorrectionRisk: falseCorrectionRisk
        )
    }
}
