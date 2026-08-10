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

    var guidance: HighQualityGlossaryGuidance {
        domain == .conversation ? .soft : .hard
    }
}

enum HighQualityGlossaryGuidance: String, Codable, Sendable {
    case hard
    case soft
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
    let maxInputTokenShare: Double
    let maxScoringOperations: Int
    let maxFalseCorrectionRisk: Double

    init(
        maxEntries: Int,
        maxEncodedBytes: Int,
        maxInputTokenShare: Double,
        maxScoringOperations: Int,
        maxFalseCorrectionRisk: Double
    ) {
        self.maxEntries = maxEntries
        self.maxEncodedBytes = maxEncodedBytes
        self.maxInputTokenShare = maxInputTokenShare
        self.maxScoringOperations = maxScoringOperations
        self.maxFalseCorrectionRisk = maxFalseCorrectionRisk
    }

    private enum CodingKeys: String, CodingKey {
        case maxEntries, maxEncodedBytes, maxInputTokenShare, maxContextShare
        case maxScoringOperations, maxFalseCorrectionRisk
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxEntries = try values.decode(Int.self, forKey: .maxEntries)
        maxEncodedBytes = try values.decode(Int.self, forKey: .maxEncodedBytes)
        maxInputTokenShare = try values.decodeIfPresent(
            Double.self,
            forKey: .maxInputTokenShare
        ) ?? values.decode(Double.self, forKey: .maxContextShare)
        maxScoringOperations = try values.decode(Int.self, forKey: .maxScoringOperations)
        maxFalseCorrectionRisk = try values.decode(Double.self, forKey: .maxFalseCorrectionRisk)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maxEntries, forKey: .maxEntries)
        try values.encode(maxEncodedBytes, forKey: .maxEncodedBytes)
        try values.encode(maxInputTokenShare, forKey: .maxInputTokenShare)
        try values.encode(maxScoringOperations, forKey: .maxScoringOperations)
        try values.encode(maxFalseCorrectionRisk, forKey: .maxFalseCorrectionRisk)
    }

    static let standard = Self(
        maxEntries: 12,
        maxEncodedBytes: 2_048,
        maxInputTokenShare: 0.25,
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
            case .recognizedJapanese: 16
            }
        }
    }

    let source: Source
    let matchedForm: String
    let weight: Int
    let cueID: String?

    init(source: Source, matchedForm: String, weight: Int, cueID: String? = nil) {
        self.source = source
        self.matchedForm = matchedForm
        self.weight = weight
        self.cueID = cueID
    }
}

struct HighQualityGlossaryDecision: Codable, Equatable, Sendable {
    let term: HighQualityGlossaryTerm
    let signals: [HighQualityGlossarySignal]
    let score: Int
    let encodedSize: Int
    let falseCorrectionRisk: Double
    let guidance: HighQualityGlossaryGuidance
    let applicableCueIDs: [String]
    var selectedCueIDs: [String]
    var selected: Bool
    var reason: String

    private enum CodingKeys: String, CodingKey {
        case term, signals, score, encodedSize, falseCorrectionRisk, guidance
        case applicableCueIDs, selectedCueIDs, selected, reason
    }

    init(
        term: HighQualityGlossaryTerm,
        signals: [HighQualityGlossarySignal],
        score: Int,
        encodedSize: Int,
        falseCorrectionRisk: Double,
        guidance: HighQualityGlossaryGuidance,
        applicableCueIDs: [String],
        selectedCueIDs: [String] = [],
        selected: Bool,
        reason: String
    ) {
        self.term = term
        self.signals = signals
        self.score = score
        self.encodedSize = encodedSize
        self.falseCorrectionRisk = falseCorrectionRisk
        self.guidance = guidance
        self.applicableCueIDs = applicableCueIDs
        self.selectedCueIDs = selectedCueIDs
        self.selected = selected
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        term = try values.decode(HighQualityGlossaryTerm.self, forKey: .term)
        signals = try values.decode([HighQualityGlossarySignal].self, forKey: .signals)
        score = try values.decode(Int.self, forKey: .score)
        encodedSize = try values.decode(Int.self, forKey: .encodedSize)
        falseCorrectionRisk = try values.decode(Double.self, forKey: .falseCorrectionRisk)
        guidance = try values.decodeIfPresent(
            HighQualityGlossaryGuidance.self,
            forKey: .guidance
        ) ?? term.guidance
        applicableCueIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .applicableCueIDs
        ) ?? signals.compactMap(\.cueID)
        selected = try values.decode(Bool.self, forKey: .selected)
        selectedCueIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .selectedCueIDs
        ) ?? (selected ? applicableCueIDs : [])
        reason = try values.decode(String.self, forKey: .reason)
    }
}

struct HighQualityGlossarySelection: Codable, Equatable, Sendable {
    let budget: HighQualityGlossaryBudget
    let contextBytes: Int
    let encodedSize: Int
    let scoringOperations: Int
    let coverageLimit: String
    let decisions: [HighQualityGlossaryDecision]
    let terminologyRegister: [String: String]
    let tokenShareByCueID: [String: Double]

    static let empty = Self(
        budget: .standard,
        contextBytes: 0,
        encodedSize: 0,
        scoringOperations: 0,
        coverageLimit: HighQualityGlossaryCatalog.coverageLimit,
        decisions: [],
        terminologyRegister: [:],
        tokenShareByCueID: [:]
    )

    var promptTerms: [HighQualityGlossaryPromptTerm] {
        decisions.filter(\.selected).map(\.term.promptTerm)
    }

    func promptTerms(for cueID: String) -> [HighQualityGlossaryPromptTerm] {
        decisions.filter { $0.selectedCueIDs.contains(cueID) }.map(\.term.promptTerm)
    }

    private enum CodingKeys: String, CodingKey {
        case budget, contextBytes, encodedSize, scoringOperations, coverageLimit, decisions
        case terminologyRegister, tokenShareByCueID
    }

    init(
        budget: HighQualityGlossaryBudget,
        contextBytes: Int,
        encodedSize: Int,
        scoringOperations: Int,
        coverageLimit: String,
        decisions: [HighQualityGlossaryDecision],
        terminologyRegister: [String: String],
        tokenShareByCueID: [String: Double]
    ) {
        self.budget = budget
        self.contextBytes = contextBytes
        self.encodedSize = encodedSize
        self.scoringOperations = scoringOperations
        self.coverageLimit = coverageLimit
        self.decisions = decisions
        self.terminologyRegister = terminologyRegister
        self.tokenShareByCueID = tokenShareByCueID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        budget = try values.decode(HighQualityGlossaryBudget.self, forKey: .budget)
        contextBytes = try values.decode(Int.self, forKey: .contextBytes)
        encodedSize = try values.decode(Int.self, forKey: .encodedSize)
        scoringOperations = try values.decode(Int.self, forKey: .scoringOperations)
        coverageLimit = try values.decode(String.self, forKey: .coverageLimit)
        decisions = try values.decode([HighQualityGlossaryDecision].self, forKey: .decisions)
        terminologyRegister = try values.decodeIfPresent(
            [String: String].self,
            forKey: .terminologyRegister
        ) ?? Dictionary(uniqueKeysWithValues: decisions.filter(\.selected).map {
            ($0.term.id, $0.term.canonicalEnglish)
        })
        tokenShareByCueID = try values.decodeIfPresent(
            [String: Double].self,
            forKey: .tokenShareByCueID
        ) ?? [:]
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
        let cueOrder = Dictionary(uniqueKeysWithValues: turns.enumerated().map {
            ($0.element.id, $0.offset)
        })
        var operations = 0
        var decisions: [String: HighQualityGlossaryDecision] = [:]
        let terms = HighQualityGlossaryCatalog.terms + sourceTerms(
            metadata: metadata,
            provenance: source.sourceURL ?? source.path,
            limit: min(8, budget.maxEntries)
        )

        // ponytail: bounded linear scan; add an index only if the catalog grows substantially.
        for term in terms {
            var metadataSignals: [HighQualityGlossarySignal] = []
            let metadataForms = term.japaneseForms + (term.domain == .conversation
                ? [] : [term.canonicalEnglish] + term.englishAliases)
            for (source, text) in metadata where !text.isEmpty {
                if let match = firstMatch(
                    in: text,
                    forms: metadataForms,
                    operations: &operations,
                    limit: budget.maxScoringOperations
                ) {
                    metadataSignals.append(.init(
                        source: source,
                        matchedForm: match,
                        weight: source.weight
                    ))
                }
            }
            var recognizedSignals: [HighQualityGlossarySignal] = []
            if firstMatch(
                in: recognizedJapanese,
                forms: term.japaneseForms,
                operations: &operations,
                limit: budget.maxScoringOperations
            ) != nil {
                for turn in turns where !turn.japanese.isEmpty {
                    guard let match = matchedForm(in: turn.japanese, forms: term.japaneseForms)
                    else { continue }
                    recognizedSignals.append(.init(
                        source: .recognizedJapanese,
                        matchedForm: match,
                        weight: HighQualityGlossarySignal.Source.recognizedJapanese.weight,
                        cueID: turn.id
                    ))
                }
            }
            let signals = recognizedSignals + metadataSignals
            let firstUnambiguousCueIndex = recognizedSignals
                .filter { !term.ambiguousJapaneseForms.contains($0.matchedForm) }
                .compactMap { $0.cueID.flatMap { cueOrder[$0] } }
                .min()
            let applicableCueIDs: [String] = recognizedSignals.compactMap { signal in
                guard !term.ambiguousJapaneseForms.contains(signal.matchedForm)
                        || !metadataSignals.isEmpty
                        || signal.cueID.flatMap({ cueOrder[$0] }).map({ cue in
                            firstUnambiguousCueIndex.map { $0 < cue } ?? false
                        }) == true else { return nil }
                return signal.cueID
            }
            let prompt = term.promptTerm
            let rejectedAmbiguities = recognizedSignals.count - applicableCueIDs.count
            let falseCorrectionRisk = recognizedSignals.isEmpty ? 0
                : Double(rejectedAmbiguities) / Double(recognizedSignals.count)
            let reason: String
            if operations >= budget.maxScoringOperations && recognizedSignals.isEmpty {
                reason = "runtime-cost budget"
            } else if applicableCueIDs.isEmpty && !recognizedSignals.isEmpty {
                reason = "false-correction-risk budget"
            } else {
                reason = applicableCueIDs.isEmpty ? "no cue-local relevance signal" : "eligible"
            }
            decisions[term.id] = .init(
                term: term,
                signals: signals,
                score: recognizedSignals.reduce(0) { $0 + $1.weight },
                encodedSize: encodedSize(prompt),
                falseCorrectionRisk: falseCorrectionRisk,
                guidance: term.guidance,
                applicableCueIDs: applicableCueIDs,
                selected: false,
                reason: reason
            )
        }

        let ranked = decisions.values.filter { $0.reason == "eligible" }.sorted {
            $0.score == $1.score ? $0.term.id < $1.term.id : $0.score > $1.score
        }
        var selectedPromptsByCueID: [String: [HighQualityGlossaryPromptTerm]] = [:]
        var terminologyRegister: [String: String] = [:]
        for candidate in ranked {
            var decision = candidate
            var rejectedReasons = Set<String>()
            let metadataDisambiguates = candidate.signals.contains {
                $0.source != .recognizedJapanese
            }
            for cueID in candidate.applicableCueIDs.sorted(by: {
                cueOrder[$0, default: .max] < cueOrder[$1, default: .max]
            }) {
                let matchedForm = candidate.signals.first {
                    $0.source == .recognizedJapanese && $0.cueID == cueID
                }?.matchedForm
                if matchedForm.map(candidate.term.ambiguousJapaneseForms.contains) == true,
                   !metadataDisambiguates,
                   terminologyRegister[candidate.term.id] == nil {
                    rejectedReasons.insert("false-correction-risk budget")
                    continue
                }
                let current = selectedPromptsByCueID[cueID, default: []]
                let next = current + [candidate.term.promptTerm]
                if current.count >= budget.maxEntries {
                    rejectedReasons.insert("entry-count budget")
                } else if encodedSize(next) > budget.maxEncodedBytes {
                    rejectedReasons.insert("encoded-size budget")
                } else if tokenShare(next) > budget.maxInputTokenShare {
                    rejectedReasons.insert("input-token-share budget")
                } else {
                    selectedPromptsByCueID[cueID] = next
                    decision.selectedCueIDs.append(cueID)
                    terminologyRegister[candidate.term.id] = candidate.term.canonicalEnglish
                }
            }
            decision.selected = !decision.selectedCueIDs.isEmpty
            decision.reason = rejectedReasons.isEmpty
                ? "selected"
                : (decision.selected ? "partially selected: " : "")
                    + rejectedReasons.sorted().joined(separator: ", ")
            decisions[candidate.term.id] = decision
        }

        let selectedPrompts = decisions.values.filter(\.selected).map(\.term.promptTerm)
        let totalEncodedSize = encodedSize(selectedPrompts)
        let contextBytes = encodedContextSize(
            source: source,
            turns: turns,
            glossary: selectedPrompts
        )
        let tokenShareByCueID = Dictionary(uniqueKeysWithValues: turns.map {
            ($0.id, tokenShare(selectedPromptsByCueID[$0.id, default: []]))
        })
        return HighQualityGlossarySelection(
            budget: budget,
            contextBytes: contextBytes,
            encodedSize: totalEncodedSize,
            scoringOperations: operations,
            coverageLimit: HighQualityGlossaryCatalog.coverageLimit,
            decisions: decisions.values.sorted { $0.term.id < $1.term.id },
            terminologyRegister: terminologyRegister,
            tokenShareByCueID: tokenShareByCueID
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

    static func matchedForm(in text: String, forms: [String]) -> String? {
        let normalizedText = normalized(text)
        return forms.sorted(by: { $0.utf8.count > $1.utf8.count }).first {
            contains(normalized($0), in: normalizedText)
        }
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

    private static func tokenShare(_ glossary: [HighQualityGlossaryPromptTerm]) -> Double {
        guard let data = try? JSONEncoder().encode(glossary) else { return .infinity }
        let scalars = String(decoding: data, as: UTF8.self).unicodeScalars
        let nonASCII = scalars.filter { !$0.isASCII }.count
        let ascii = scalars.count - nonASCII
        return Double(nonASCII + (ascii + 3) / 4) / 2_048
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
