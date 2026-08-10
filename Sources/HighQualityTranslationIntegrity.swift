import Foundation

enum HighQualityTranslationIntegrityVerdictKind: String, Codable, Sendable {
    case pass
    case suspect
    case hardFailure = "hard-failure"
}

enum HighQualityTranslationIntegritySeverity: String, Codable, Sendable {
    case suspect
    case hardFailure = "hard-failure"
}

enum HighQualityTranslationIntegrityReasonCode: String, Codable, CaseIterable, Sendable {
    case emptyOutput = "empty-output"
    case residualJapanese = "residual-japanese"
    case controlScaffolding = "control-scaffolding"
    case criticalGlossaryViolation = "critical-glossary-violation"
    case truncatedOutput = "truncated-output"
    case degenerateRepetition = "degenerate-repetition"
    case pathologicalLength = "pathological-length"
    case copiedNeighbour = "copied-neighbour"
}

struct HighQualityTranslationIntegrityReason: Codable, Equatable, Sendable {
    let code: HighQualityTranslationIntegrityReasonCode
    let severity: HighQualityTranslationIntegritySeverity
    let matchedEvidence: [String]
}

struct HighQualityTranslationIntegrityGlossaryOpportunity: Codable, Equatable, Sendable {
    let id: String
    let matchedJapaneseForms: [String]
    let acceptedEnglishForms: [String]
    let critical: Bool
    let satisfied: Bool
}

struct HighQualityTranslationIntegrityVerdict: Codable, Equatable, Sendable {
    let cueID: String
    let testedSource: String
    let generatedOutput: String
    let verdict: HighQualityTranslationIntegrityVerdictKind
    let reasons: [HighQualityTranslationIntegrityReason]
    let thresholdVersion: String
    let glossaryOpportunities: [HighQualityTranslationIntegrityGlossaryOpportunity]
}

struct HighQualityTranslationIntegrityThresholds: Codable, Equatable, Sendable {
    let version: String
    let minimumLengthRatio: Double
    let maximumLengthRatio: Double
    let copiedOutputSimilarity: Double
    let correspondingSourceSimilarity: Double
    let minimumCopiedOutputWords: Int
    let repetitionCount: Int

    static let developmentV1 = Self(
        version: "translation-integrity-dev-v1",
        minimumLengthRatio: 0.5,
        maximumLengthRatio: 6,
        copiedOutputSimilarity: 0.8,
        correspondingSourceSimilarity: 0.2,
        minimumCopiedOutputWords: 3,
        repetitionCount: 4
    )
}

struct HighQualityTranslationIntegrityGlossaryTerm: Equatable, Sendable {
    let id: String
    let japaneseForms: [String]
    let acceptedEnglishForms: [String]
    let critical: Bool

    init(_ term: HighQualityGlossaryTerm) {
        id = term.id
        japaneseForms = term.japaneseForms
        acceptedEnglishForms = [term.canonicalEnglish] + term.englishAliases
        critical = term.domain != .conversation
    }

    init(_ term: HighQualityGlossaryPromptTerm, critical: Bool) {
        id = term.id
        japaneseForms = term.japanese
        acceptedEnglishForms = [term.english] + term.englishAliases
        self.critical = critical
    }
}

enum HighQualityTranslationIntegrityValidator {
    private struct ValidationInput {
        let turn: HighQualityTranslationTurn
        let output: String
        let finishReason: String?
    }

    static func validate(
        turns: [HighQualityTranslationTurn],
        translations: [String: String] = [:],
        batches: [HighQualityLocalTranslationBatch],
        glossary: [HighQualityTranslationIntegrityGlossaryTerm],
        glossaryByCueID: [String: [HighQualityTranslationIntegrityGlossaryTerm]]? = nil,
        thresholds: HighQualityTranslationIntegrityThresholds = .developmentV1,
        japaneseAllowlist: [String] = []
    ) -> [HighQualityTranslationIntegrityVerdict] {
        // ponytail: bounded nested scan; pre-index cue IDs only if batches grow beyond translation-sized inputs.
        let items = turns.compactMap { turn -> ValidationInput? in
            let batch = batches.first { $0.cueIDs.contains(turn.id) }
            guard translations[turn.id] != nil || batch != nil else { return nil }
            let output = translations[turn.id]
                ?? (batch?.sanitizedOutput.isEmpty == false
                    ? batch?.sanitizedOutput
                    : batch?.nativeOutput)
                ?? ""
            return ValidationInput(turn: turn, output: output, finishReason: batch?.finishReason)
        }

        return items.enumerated().map { index, item in
            var reasons: [HighQualityTranslationIntegrityReason] = []
            let output = item.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty {
                reasons.append(reason(.emptyOutput, .hardFailure, ["trimmed-output-length=0"]))
            } else {
                let residue = japaneseResidue(in: output, allowlist: japaneseAllowlist)
                if !residue.isEmpty {
                    reasons.append(reason(.residualJapanese, .hardFailure, residue))
                }
                let scaffolding = scaffoldingMatches(in: output)
                if !scaffolding.isEmpty {
                    reasons.append(reason(.controlScaffolding, .hardFailure, scaffolding))
                }
            }

            let cueGlossary = glossaryByCueID?[item.turn.id] ?? glossary
            let opportunities = cueGlossary.compactMap { term -> HighQualityTranslationIntegrityGlossaryOpportunity? in
                let matches = term.japaneseForms.filter {
                    HighQualityGlossarySelector.matchedForm(
                        in: item.turn.japanese,
                        forms: [$0]
                    ) != nil
                }
                guard !matches.isEmpty else { return nil }
                let accepted = term.acceptedEnglishForms.filter {
                    containsAcceptedForm($0, in: output)
                }
                return .init(
                    id: term.id,
                    matchedJapaneseForms: matches,
                    acceptedEnglishForms: term.acceptedEnglishForms,
                    critical: term.critical,
                    satisfied: !accepted.isEmpty
                )
            }
            for opportunity in opportunities where opportunity.critical && !opportunity.satisfied {
                reasons.append(reason(
                    .criticalGlossaryViolation,
                    .hardFailure,
                    [
                        "term=\(opportunity.id)",
                        "source=\(opportunity.matchedJapaneseForms.joined(separator: "|"))",
                        "accepted=\(opportunity.acceptedEnglishForms.joined(separator: "|"))",
                    ]
                ))
            }

            if item.finishReason == "length" {
                reasons.append(reason(.truncatedOutput, .hardFailure, ["finish-reason=length"]))
            }
            if let repeated = repeatedPhrase(in: output, count: thresholds.repetitionCount) {
                reasons.append(reason(
                    .degenerateRepetition,
                    .hardFailure,
                    ["phrase=\(repeated)", "count>=\(thresholds.repetitionCount)"]
                ))
            }
            let sourceLength = semanticLength(item.turn.japanese)
            if sourceLength >= 2, !output.isEmpty {
                let ratio = Double(semanticLength(output)) / Double(sourceLength)
                if ratio < thresholds.minimumLengthRatio || ratio > thresholds.maximumLengthRatio {
                    reasons.append(reason(
                        .pathologicalLength,
                        .suspect,
                        [
                            "ratio=\(decimal(ratio))",
                            "allowed=\(decimal(thresholds.minimumLengthRatio))...\(decimal(thresholds.maximumLengthRatio))",
                        ]
                    ))
                }
            }
            var copiedEvidence: [String] = []
            if index > 0,
               let evidence = copiedNeighbourEvidence(
                neighbour: items[index - 1],
                current: item,
                thresholds: thresholds
               ) {
                copiedEvidence += evidence
            }
            if index + 1 < items.count,
               let evidence = copiedNeighbourEvidence(
                neighbour: items[index + 1],
                current: item,
                thresholds: thresholds
               ) {
                copiedEvidence += evidence
            }
            if !copiedEvidence.isEmpty {
                reasons.append(reason(.copiedNeighbour, .suspect, copiedEvidence))
            }

            let verdict: HighQualityTranslationIntegrityVerdictKind
            if reasons.contains(where: { $0.severity == .hardFailure }) {
                verdict = .hardFailure
            } else if reasons.isEmpty {
                verdict = .pass
            } else {
                verdict = .suspect
            }
            return .init(
                cueID: item.turn.id,
                testedSource: item.turn.japanese,
                generatedOutput: item.output,
                verdict: verdict,
                reasons: reasons,
                thresholdVersion: thresholds.version,
                glossaryOpportunities: opportunities
            )
        }
    }

    private static func reason(
        _ code: HighQualityTranslationIntegrityReasonCode,
        _ severity: HighQualityTranslationIntegritySeverity,
        _ evidence: [String]
    ) -> HighQualityTranslationIntegrityReason {
        .init(code: code, severity: severity, matchedEvidence: evidence)
    }

    private static func japaneseResidue(in output: String, allowlist: [String]) -> [String] {
        let tested = allowlist.filter { !$0.isEmpty }.reduce(output) {
            $0.replacingOccurrences(of: $1, with: "")
        }
        var matches: [String] = []
        for scalar in tested.unicodeScalars where isJapanese(scalar) {
            let value = String(scalar)
            if !matches.contains(value) { matches.append(value) }
        }
        return matches
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x323AF:
            true
        default:
            false
        }
    }

    private static func scaffoldingMatches(in output: String) -> [String] {
        let lower = output.lowercased()
        let contained = [
            "```", "speaker_id:", "context_before:", "context_after:",
            "<<<current:", "<<<end_current:", "\"source_lang_code\"",
            "\"target_lang_code\"", "\"role\":", "**option 1",
        ].filter { lower.contains($0) }
        let prefixed = [
            "here is the translation", "here's the translation",
            "translation:", "english translation:",
        ].filter { lower.hasPrefix($0) }
        return prefixed + contained
    }

    private static func repeatedPhrase(in output: String, count: Int) -> String? {
        let words = words(in: output)
        guard count >= 2, words.count >= count else { return nil }
        // ponytail: cubic on bounded model output; use rolling hashes only if output limits grow.
        for size in 1...(words.count / count) {
            for start in 0...(words.count - size * count) {
                let phrase = Array(words[start..<(start + size)])
                if (1..<count).allSatisfy({ repetition in
                    Array(words[(start + size * repetition)..<(start + size * (repetition + 1))]) == phrase
                }) {
                    return phrase.joined(separator: " ")
                }
            }
        }
        return nil
    }

    private static func copiedNeighbourEvidence(
        neighbour: ValidationInput,
        current: ValidationInput,
        thresholds: HighQualityTranslationIntegrityThresholds
    ) -> [String]? {
        let neighbourWords = words(in: neighbour.output)
        let currentWords = words(in: current.output)
        let neighbourSource = semanticScalars(neighbour.turn.japanese)
        let currentSource = semanticScalars(current.turn.japanese)
        guard neighbourWords.count >= thresholds.minimumCopiedOutputWords,
              currentWords.count >= thresholds.minimumCopiedOutputWords,
              neighbourSource.count >= 4,
              currentSource.count >= 4 else { return nil }

        let outputSimilarity = neighbourWords == currentWords
            ? 1
            : jaccard(ngrams(neighbourWords, size: 3), ngrams(currentWords, size: 3))
        let sourceSimilarity = jaccard(
            ngrams(neighbourSource, size: 2),
            ngrams(currentSource, size: 2)
        )
        guard outputSimilarity >= thresholds.copiedOutputSimilarity,
              sourceSimilarity < thresholds.correspondingSourceSimilarity else { return nil }
        return [
            "neighbour=\(neighbour.turn.id)",
            "output-similarity=\(decimal(outputSimilarity))",
            "source-similarity=\(decimal(sourceSimilarity))",
        ]
    }

    private static func semanticLength(_ text: String) -> Int {
        semanticScalars(text).count
    }

    private static func semanticScalars(_ text: String) -> [String] {
        text.unicodeScalars.compactMap {
            CharacterSet.alphanumerics.contains($0) ? String($0).lowercased() : nil
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func containsAcceptedForm(_ accepted: String, in output: String) -> Bool {
        let acceptedWords = words(in: accepted)
        let outputWords = words(in: output)
        guard !acceptedWords.isEmpty, acceptedWords.count <= outputWords.count else { return false }
        return (0...(outputWords.count - acceptedWords.count)).contains { start in
            outputWords[start..<(start + acceptedWords.count)].elementsEqual(acceptedWords)
        }
    }

    private static func ngrams(_ values: [String], size: Int) -> Set<String> {
        guard values.count >= size else { return [] }
        return Set((0...(values.count - size)).map {
            values[$0..<($0 + size)].joined(separator: "\u{1F}")
        })
    }

    private static func jaccard(_ first: Set<String>, _ second: Set<String>) -> Double {
        let union = first.union(second)
        guard !union.isEmpty else { return 0 }
        return Double(first.intersection(second).count) / Double(union.count)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
