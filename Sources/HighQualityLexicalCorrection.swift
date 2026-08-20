import Foundation

struct HighQualityLexicalCorrectionPolicy: Codable, Equatable, Sendable {
    static let developmentV1 = Self(
        version: "ja-closed-v1",
        minimumScore: 0.75,
        ambiguityMargin: 0.08,
        minimumFormCharacters: 4,
        maximumEditDistance: 1,
        maximumScoringOperationsPerCue: 512
    )

    let version: String
    let minimumScore: Double
    let ambiguityMargin: Double
    let minimumFormCharacters: Int
    let maximumEditDistance: Int
    let maximumScoringOperationsPerCue: Int
}

struct HighQualityLexicalCorrectionScopeEvidence: Codable, Equatable, Sendable {
    let projectMetadataTermIDs: [String]
    let sourceMetadataTermIDs: [String]
    let cueLocalSelectedTermIDsByCueID: [String: [String]]
    let unionTermIDs: [String]
    let unionTermIDsByCueID: [String: [String]]
}

struct HighQualityLexicalCorrectionScope: Equatable, Sendable {
    let evidence: HighQualityLexicalCorrectionScopeEvidence
    let candidatesByCueID: [String: [HighQualityGlossaryTerm]]
}

struct HighQualityLexicalCorrectionChange: Codable, Equatable, Sendable {
    let cueID: String
    let originalText: String
    let correctedText: String
    let canonicalTermID: String
    let canonicalJapanese: String
    let matchedForm: String
    let score: Double
    let reason: String
}

struct HighQualityLexicalCorrectionEvidence: Codable, Equatable, Sendable {
    let policy: HighQualityLexicalCorrectionPolicy
    let scope: HighQualityLexicalCorrectionScopeEvidence
    let scoringOperations: Int
    let changes: [HighQualityLexicalCorrectionChange]
}

struct HighQualityLexicalCorrectionResult: Equatable, Sendable {
    let turns: [HighQualityTranslationTurn]
    let evidence: HighQualityLexicalCorrectionEvidence
}

enum HighQualityLexicalCorrection {
    enum ScopeError: Error, Equatable {
        case budgetExceeded(cueID: String)
    }

    static func closedScope(
        turns: [HighQualityTranslationTurn],
        selection: HighQualityGlossarySelection
    ) throws -> HighQualityLexicalCorrectionScope {
        let projectMetadata = selection.decisions.filter { decision in
            decision.signals.contains { $0.source == .projectMetadata }
        }
        let sourceMetadata = selection.decisions.filter { decision in
            decision.signals.contains {
                $0.source == .title || $0.source == .channel || $0.source == .description
            }
        }
        let cueLocalByCueID = Dictionary(uniqueKeysWithValues: turns.map { turn in
            (turn.id, selection.decisions.filter { $0.selectedCueIDs.contains(turn.id) })
        })
        var candidatesByCueID: [String: [HighQualityGlossaryTerm]] = [:]
        var unionTermIDsByCueID: [String: [String]] = [:]
        for turn in turns {
            let cueLocal = cueLocalByCueID[turn.id, default: []]
            var encodedBytes = 0
            var selected: [HighQualityGlossaryTerm] = []
            let union = projectMetadata + sourceMetadata + cueLocal
            for decision in union.sorted(by: candidateOrder) {
                guard !selected.contains(where: { $0.id == decision.term.id }) else { continue }
                let size = (try? JSONEncoder().encode(decision.term.japaneseForms).count) ?? .max
                guard selected.count < selection.budget.maxEntries,
                      encodedBytes + size <= selection.budget.maxEncodedBytes else {
                    throw ScopeError.budgetExceeded(cueID: turn.id)
                }
                selected.append(decision.term)
                encodedBytes += size
            }
            candidatesByCueID[turn.id] = selected
            unionTermIDsByCueID[turn.id] = selected.map(\.id).sorted()
        }
        let projectMetadataTermIDs = Array(Set(projectMetadata.map { $0.term.id })).sorted()
        let sourceMetadataTermIDs = Array(Set(sourceMetadata.map { $0.term.id })).sorted()
        let cueLocalSelectedTermIDsByCueID = cueLocalByCueID.compactMapValues { decisions in
            let ids = Array(Set(decisions.map { $0.term.id })).sorted()
            return ids.isEmpty ? nil : ids
        }
        let unionTermIDs = Array(Set(
            projectMetadataTermIDs + sourceMetadataTermIDs
                + cueLocalSelectedTermIDsByCueID.values.flatMap { $0 }
        )).sorted()
        return .init(
            evidence: .init(
                projectMetadataTermIDs: projectMetadataTermIDs,
                sourceMetadataTermIDs: sourceMetadataTermIDs,
                cueLocalSelectedTermIDsByCueID: cueLocalSelectedTermIDsByCueID,
                unionTermIDs: unionTermIDs,
                unionTermIDsByCueID: unionTermIDsByCueID
            ),
            candidatesByCueID: candidatesByCueID
        )
    }

    static func apply(
        to turns: [HighQualityTranslationTurn],
        scope: HighQualityLexicalCorrectionScope,
        policy: HighQualityLexicalCorrectionPolicy = .developmentV1
    ) -> HighQualityLexicalCorrectionResult {
        var operations = 0
        var changes: [HighQualityLexicalCorrectionChange] = []
        let corrected = turns.map { turn in
            let original = turn.japanese
            var cueOperations = 0
            let allowedTermIDs = Set(scope.evidence.unionTermIDsByCueID[turn.id, default: []])
            let candidates = Dictionary(
                scope.candidatesByCueID[turn.id, default: []]
                    .filter { allowedTermIDs.contains($0.id) }
                    .map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.id < $1.id }
            let matches = candidates.compactMap {
                closestMatch(
                    in: original,
                    term: $0,
                    policy: policy,
                    operations: &cueOperations,
                    limit: policy.maximumScoringOperationsPerCue
                )
            }
            operations += cueOperations
            let unambiguous = matches.filter { match in
                !matches.contains {
                    $0.term.id != match.term.id
                        && $0.range.overlaps(match.range)
                        && abs(match.score - $0.score) < policy.ambiguityMargin
                }
            }.sorted { matchOrder($1, $0) }
            var selected: [Match] = []
            for match in unambiguous where !selected.contains(where: {
                $0.range.overlaps(match.range)
            }) {
                selected.append(match)
            }
            selected = selected.filter {
                digits(in: $0.matchedForm) == digits(in: $0.term.officialJapanese)
            }
            guard !selected.isEmpty else { return turn }
            var text = original
            for match in selected.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                text.replaceSubrange(match.range, with: match.term.officialJapanese)
            }
            guard digits(in: text) == digits(in: original) else { return turn }
            changes += selected.sorted { $0.range.lowerBound < $1.range.lowerBound }.map {
                .init(
                    cueID: turn.id,
                    originalText: original,
                    correctedText: text,
                    canonicalTermID: $0.term.id,
                    canonicalJapanese: $0.term.officialJapanese,
                    matchedForm: $0.matchedForm,
                    score: $0.score,
                    reason: $0.reason
                )
            }
            return .init(
                id: turn.id,
                japanese: text,
                precedingJapanese: turn.precedingJapanese,
                followingJapanese: turn.followingJapanese,
                speakerLabel: turn.speakerLabel,
                sourceStart: turn.sourceStart,
                sourceEnd: turn.sourceEnd
            )
        }
        return .init(
            turns: corrected,
            evidence: .init(
                policy: policy,
                scope: scope.evidence,
                scoringOperations: operations,
                changes: changes
            )
        )
    }

    private static func candidateOrder(
        _ left: HighQualityGlossaryDecision,
        _ right: HighQualityGlossaryDecision
    ) -> Bool {
        if left.selected != right.selected { return left.selected }
        if left.score != right.score { return left.score > right.score }
        return left.term.id < right.term.id
    }

    private struct Match {
        let term: HighQualityGlossaryTerm
        let range: Range<String.Index>
        let matchedForm: String
        let score: Double
        let reason: String
    }

    private static func closestMatch(
        in text: String,
        term: HighQualityGlossaryTerm,
        policy: HighQualityLexicalCorrectionPolicy,
        operations: inout Int,
        limit: Int
    ) -> Match? {
        let normalizedText = normalizedPhonetic(text)
        if term.japaneseForms.contains(where: {
            normalizedText.contains(normalizedPhonetic($0))
        }) {
            return nil
        }
        let characters = Array(text)
        var best: Match?
        for form in term.japaneseForms where eligible(form, for: term, policy: policy) {
            let target = Array(normalizedPhonetic(form))
            let minimum = max(policy.minimumFormCharacters, target.count - policy.maximumEditDistance)
            // A longer window can consume an adjacent Japanese particle. Only tolerate
            // a missing character inside the closed term, never extra surrounding text.
            let maximum = min(characters.count, target.count)
            guard minimum <= maximum else { continue }
            for length in minimum...maximum {
                guard characters.count >= length else { continue }
                for start in 0...(characters.count - length) {
                    guard operations < limit else { return best }
                    operations += 1
                    let matched = String(characters[start..<(start + length)])
                    let normalized = Array(normalizedPhonetic(matched))
                    let distance = editDistance(normalized, target)
                    guard distance > 0, distance <= policy.maximumEditDistance else { continue }
                    let score = 1 - Double(distance) / Double(max(normalized.count, target.count))
                    guard score >= policy.minimumScore else { continue }
                    let lower = text.index(text.startIndex, offsetBy: start)
                    let upper = text.index(lower, offsetBy: length)
                    let candidate = Match(
                        term: term,
                        range: lower..<upper,
                        matchedForm: matched,
                        score: score,
                        reason: "unique-close-phonetic-match"
                    )
                    if best.map({ matchOrder($0, candidate) }) != false { best = candidate }
                }
            }
        }
        return best
    }

    private static func eligible(
        _ form: String,
        for term: HighQualityGlossaryTerm,
        policy: HighQualityLexicalCorrectionPolicy
    ) -> Bool {
        form.count >= policy.minimumFormCharacters
            && !term.ambiguousJapaneseForms.contains(form)
            && form.unicodeScalars.contains { !$0.isASCII }
    }

    private static func matchOrder(_ left: Match, _ right: Match) -> Bool {
        if left.score != right.score { return left.score < right.score }
        if left.matchedForm.count != right.matchedForm.count {
            return left.matchedForm.count > right.matchedForm.count
        }
        return left.term.id > right.term.id
    }

    private static func normalizedPhonetic(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        return normalized.applyingTransform(.hiraganaToKatakana, reverse: false) ?? normalized
    }

    private static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    min(current[rightIndex] + 1, previous[rightIndex + 1] + 1),
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func digits(in value: String) -> [Character] {
        value.filter(\.isNumber)
    }
}
