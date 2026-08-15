import Foundation

enum HighQualityReadableSubtitleViolation: String, Codable, Equatable, Sendable {
    case lineLimit
    case maximumCharacters
    case minimumDuration
    case maximumDuration
    case readingSpeed
}

struct HighQualityReadableSubtitlePolicy: Codable, Equatable, Sendable {
    static let product = Self(
        version: "readable-cues-v2",
        maximumCharactersPerLine: 42,
        maximumLinesPerCue: 2,
        minimumDurationSeconds: 1,
        maximumDurationSeconds: 7,
        maximumCharactersPerSecond: 20,
        minimumJapanesePauseSeconds: 0.12
    )

    let version: String
    let maximumCharactersPerLine: Int
    let maximumLinesPerCue: Int
    let minimumDurationSeconds: TimeInterval
    let maximumDurationSeconds: TimeInterval
    let maximumCharactersPerSecond: Double
    let minimumJapanesePauseSeconds: TimeInterval
}

struct HighQualityReadableSubtitleMetrics: Codable, Equatable, Sendable {
    let cueCount: Int
    let readableCueCount: Int
    let lineLimitViolationCount: Int
    let overMaximumCharactersCount: Int
    let underMinimumDurationCount: Int
    let overMaximumDurationCount: Int
    let overMaximumCharactersPerSecondCount: Int
    let gapCount: Int
    let overlapCount: Int
}

struct HighQualityReadableSubtitleBoundaryEvidence: Codable, Equatable, Sendable {
    let seconds: TimeInterval
    let reasons: [String]
}

struct HighQualityReadableSubtitleDecision: Codable, Equatable, Sendable {
    let sourceCueID: String
    let outputCueIDs: [String]
    let boundaries: [HighQualityReadableSubtitleBoundaryEvidence]
    let unresolvedViolations: [HighQualityReadableSubtitleViolation]
}

struct HighQualityReadableSubtitleEvidence: Codable, Equatable, Sendable {
    let policy: HighQualityReadableSubtitlePolicy
    let baseline: HighQualityReadableSubtitleMetrics
    let candidate: HighQualityReadableSubtitleMetrics
    let decisions: [HighQualityReadableSubtitleDecision]
    let splitSourceCueCount: Int
    let unresolvedSourceCueCount: Int
    let exactNormalizedEnglishIdentity: Bool
    let exactWordOrder: Bool
    let exactTimingCoverage: Bool
    let exactInterCueGaps: Bool
    let speakerMetadataPreserved: Bool
    let noNewOverlap: Bool
    let integrityFallback: Bool

    var integrityPassed: Bool {
        !integrityFallback && exactNormalizedEnglishIdentity && exactWordOrder
            && exactTimingCoverage && exactInterCueGaps && speakerMetadataPreserved
            && noNewOverlap
    }
}

struct HighQualityReadableSubtitleResult: Sendable {
    let cues: [HighQualitySubtitleCue]
    let evidence: HighQualityReadableSubtitleEvidence
}

enum HighQualityReadableSubtitleReflow {
    private struct Boundary {
        let time: TimeInterval
        let progress: Double
        let reasons: [String]
        let strength: Int
    }

    private struct PathNode {
        let segments: Int
        let error: Double
        let previousBoundary: Int
        let previousWord: Int
    }

    private struct Split {
        let cues: [HighQualitySubtitleCue]
        let boundaries: [HighQualityReadableSubtitleBoundaryEvidence]
    }

    static func apply(
        to sourceCues: [HighQualitySubtitleCue],
        units: [HighQualitySemanticUnitEvidence],
        fragments: [HighQualitySemanticFragmentEvidence],
        policy: HighQualityReadableSubtitlePolicy = .product
    ) throws -> HighQualityReadableSubtitleResult {
        let unitsByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let fragmentsByIndex = Dictionary(uniqueKeysWithValues: fragments.map { ($0.index, $0) })
        var candidate: [HighQualitySubtitleCue] = []
        var childrenBySourceID: [String: [HighQualitySubtitleCue]] = [:]
        var decisions: [HighQualityReadableSubtitleDecision] = []

        for source in sourceCues {
            try Task.checkCancellation()
            let sourceViolations = violations(source, policy: policy)
            let split: Split? = sourceViolations.isEmpty
                ? nil
                : unitsByID[source.id].flatMap { unit in
                    Self.split(
                        source,
                        unit: unit,
                        fragments: unit.sourceFragmentIndices.compactMap {
                            fragmentsByIndex[$0]
                        },
                        policy: policy
                    )
                }
            let outputs: [HighQualitySubtitleCue]
            if let split {
                outputs = split.cues
                decisions.append(.init(
                    sourceCueID: source.id,
                    outputCueIDs: outputs.map(\.id),
                    boundaries: split.boundaries,
                    unresolvedViolations: []
                ))
            } else {
                outputs = [withReadableLines(source, policy: policy)]
                if !sourceViolations.isEmpty {
                    decisions.append(.init(
                        sourceCueID: source.id,
                        outputCueIDs: [source.id],
                        boundaries: [],
                        unresolvedViolations: sourceViolations
                    ))
                }
            }
            candidate += outputs
            childrenBySourceID[source.id] = outputs
        }

        let sourceWords = sourceCues.flatMap { words($0.text) }
        let candidateWords = candidate.flatMap { words($0.text) }
        let exactWords = sourceWords == candidateWords
        let exactTiming = sourceCues.allSatisfy { source in
            guard let children = childrenBySourceID[source.id],
                  children.first?.start == source.start,
                  children.last?.end == source.end else { return false }
            return zip(children, children.dropFirst()).allSatisfy { $0.end == $1.start }
        }
        let speakerPreserved = sourceCues.allSatisfy { source in
            childrenBySourceID[source.id]?.allSatisfy {
                $0.speakerLabel == source.speakerLabel && $0.speakerName == source.speakerName
            } == true
        }
        let baselineMetrics = metrics(sourceCues, policy: policy)
        let candidateMetrics = metrics(candidate, policy: policy)
        let exactGaps = gapIntervals(sourceCues) == gapIntervals(candidate)
        let noNewOverlap = candidateMetrics.overlapCount <= baselineMetrics.overlapCount
        let evidence = HighQualityReadableSubtitleEvidence(
            policy: policy,
            baseline: baselineMetrics,
            candidate: candidateMetrics,
            decisions: decisions,
            splitSourceCueCount: decisions.filter { $0.outputCueIDs.count > 1 }.count,
            unresolvedSourceCueCount: decisions.filter { !$0.unresolvedViolations.isEmpty }.count,
            exactNormalizedEnglishIdentity: normalized(sourceWords) == normalized(candidateWords),
            exactWordOrder: exactWords,
            exactTimingCoverage: exactTiming,
            exactInterCueGaps: exactGaps,
            speakerMetadataPreserved: speakerPreserved,
            noNewOverlap: noNewOverlap,
            integrityFallback: false
        )
        guard evidence.integrityPassed else {
            let fallback = HighQualityReadableSubtitleEvidence(
                policy: policy,
                baseline: baselineMetrics,
                candidate: baselineMetrics,
                decisions: decisions,
                splitSourceCueCount: 0,
                unresolvedSourceCueCount: sourceCues.count,
                exactNormalizedEnglishIdentity: true,
                exactWordOrder: true,
                exactTimingCoverage: true,
                exactInterCueGaps: true,
                speakerMetadataPreserved: true,
                noNewOverlap: true,
                integrityFallback: true
            )
            return .init(cues: sourceCues, evidence: fallback)
        }
        return .init(cues: candidate, evidence: evidence)
    }

    static func metrics(
        _ cues: [HighQualitySubtitleCue],
        policy: HighQualityReadableSubtitlePolicy = .product
    ) -> HighQualityReadableSubtitleMetrics {
        let failures = cues.map { violations($0, policy: policy) }
        return .init(
            cueCount: cues.count,
            readableCueCount: failures.filter(\.isEmpty).count,
            lineLimitViolationCount: failures.filter { $0.contains(.lineLimit) }.count,
            overMaximumCharactersCount: failures.filter {
                $0.contains(.maximumCharacters)
            }.count,
            underMinimumDurationCount: failures.filter {
                $0.contains(.minimumDuration)
            }.count,
            overMaximumDurationCount: failures.filter {
                $0.contains(.maximumDuration)
            }.count,
            overMaximumCharactersPerSecondCount: failures.filter {
                $0.contains(.readingSpeed)
            }.count,
            gapCount: zip(cues, cues.dropFirst()).filter { $0.end < $1.start }.count,
            overlapCount: zip(cues, cues.dropFirst()).filter { $0.end > $1.start }.count
        )
    }

    private static func split(
        _ source: HighQualitySubtitleCue,
        unit: HighQualitySemanticUnitEvidence,
        fragments: [HighQualitySemanticFragmentEvidence],
        policy: HighQualityReadableSubtitlePolicy
    ) -> Split? {
        let sourceWords = words(source.text)
        guard sourceWords.count >= 2,
              unit.start == source.start,
              unit.end == source.end else { return nil }
        let boundaries = boundaries(
            for: source,
            unit: unit,
            fragments: fragments,
            policy: policy
        )
        guard boundaries.count > 2 else { return nil }

        let wordCount = sourceWords.count
        let prefixCharacters = (0...wordCount).map { end in
            normalized(Array(sourceWords[..<end])).count
        }
        let totalCharacters = max(prefixCharacters.last ?? 0, 1)
        var best = Array(
            repeating: Array<PathNode?>(repeating: nil, count: wordCount + 1),
            count: boundaries.count
        )
        best[0][0] = .init(
            segments: 0,
            error: 0,
            previousBoundary: -1,
            previousWord: -1
        )

        for boundaryIndex in 0..<(boundaries.count - 1) {
            for wordIndex in 0..<wordCount {
                guard let path = best[boundaryIndex][wordIndex] else { continue }
                for nextBoundaryIndex in (boundaryIndex + 1)..<boundaries.count {
                    let duration = boundaries[nextBoundaryIndex].time
                        - boundaries[boundaryIndex].time
                    if duration < policy.minimumDurationSeconds { continue }
                    if duration > policy.maximumDurationSeconds { break }
                    for nextWordIndex in (wordIndex + 1)...wordCount {
                        let text = normalized(Array(sourceWords[wordIndex..<nextWordIndex]))
                        if text.count > policy.maximumCharactersPerLine
                            * policy.maximumLinesPerCue { break }
                        guard Double(text.count) / duration
                                <= policy.maximumCharactersPerSecond,
                              lines(for: text, policy: policy) != nil else { continue }
                        let wordProgress = Double(prefixCharacters[nextWordIndex])
                            / Double(totalCharacters)
                        let boundary = boundaries[nextBoundaryIndex]
                        let alignmentError = nextBoundaryIndex == boundaries.count - 1
                            ? 0
                            : abs(wordProgress - boundary.progress)
                                - Double(boundary.strength) / 10_000
                        let proposal = PathNode(
                            segments: path.segments + 1,
                            error: path.error + alignmentError,
                            previousBoundary: boundaryIndex,
                            previousWord: wordIndex
                        )
                        if isBetter(proposal, than: best[nextBoundaryIndex][nextWordIndex]) {
                            best[nextBoundaryIndex][nextWordIndex] = proposal
                        }
                    }
                }
            }
        }

        var boundaryIndex = boundaries.count - 1
        var wordIndex = wordCount
        guard best[boundaryIndex][wordIndex] != nil else { return nil }
        var ranges: [(boundary: Range<Int>, words: Range<Int>)] = []
        while boundaryIndex > 0, let node = best[boundaryIndex][wordIndex] {
            ranges.append((
                node.previousBoundary..<boundaryIndex,
                node.previousWord..<wordIndex
            ))
            boundaryIndex = node.previousBoundary
            wordIndex = node.previousWord
        }
        guard boundaryIndex == 0, wordIndex == 0, ranges.count > 1 else { return nil }
        ranges.reverse()

        let cues = ranges.enumerated().map { offset, range in
            let text = normalized(Array(sourceWords[range.words]))
            return HighQualitySubtitleCue(
                id: "\(source.id)-readable-\(String(format: "%02d", offset + 1))",
                start: boundaries[range.boundary.lowerBound].time,
                end: boundaries[range.boundary.upperBound].time,
                text: text,
                speakerLabel: source.speakerLabel,
                speakerName: source.speakerName,
                renderedLines: lines(for: text, policy: policy)
            )
        }
        let usedBoundaries = ranges.dropLast().map { range in
            let boundary = boundaries[range.boundary.upperBound]
            return HighQualityReadableSubtitleBoundaryEvidence(
                seconds: boundary.time,
                reasons: boundary.reasons
            )
        }
        return .init(cues: cues, boundaries: usedBoundaries)
    }

    private static func boundaries(
        for source: HighQualitySubtitleCue,
        unit: HighQualitySemanticUnitEvidence,
        fragments: [HighQualitySemanticFragmentEvidence],
        policy: HighQualityReadableSubtitlePolicy
    ) -> [Boundary] {
        guard fragments.count >= 2 else { return [
            .init(time: source.start, progress: 0, reasons: ["source-start"], strength: 0),
            .init(time: source.end, progress: 1, reasons: ["source-end"], strength: 0),
        ] }
        let totalCharacters = max(fragments.reduce(0) { $0 + $1.text.count }, 1)
        var consumedCharacters = 0
        var internalBoundaries: [Boundary] = []
        for index in 0..<(fragments.count - 1) {
            let current = fragments[index]
            let next = fragments[index + 1]
            consumedCharacters += current.text.count
            guard let currentItem = current.alignmentItemIndex,
                  let nextItem = next.alignmentItemIndex,
                  currentItem != nextItem else { continue }
            var reasons: [String] = []
            if next.start - current.end >= policy.minimumJapanesePauseSeconds {
                reasons.append("japanese-pause")
            }
            if current.text.last.map({ "、。！？!?｡，,；;：:".contains($0) }) == true {
                reasons.append("japanese-punctuation")
            }
            if current.sourceCueID != next.sourceCueID {
                reasons.append("source-cue-boundary")
            }
            guard !reasons.isEmpty,
                  next.start > source.start,
                  next.start < source.end else { continue }
            internalBoundaries.append(.init(
                time: next.start,
                progress: Double(consumedCharacters) / Double(totalCharacters),
                reasons: reasons,
                strength: reasons.contains("source-cue-boundary") ? 3
                    : reasons.contains("japanese-punctuation") ? 2 : 1
            ))
        }
        let deduplicated = Dictionary(grouping: internalBoundaries, by: \.time).values.map {
            $0.max { $0.strength < $1.strength }!
        }.sorted { $0.time < $1.time }
        return [
            .init(time: source.start, progress: 0, reasons: ["source-start"], strength: 0),
        ] + deduplicated + [
            .init(time: source.end, progress: 1, reasons: ["source-end"], strength: 0),
        ]
    }

    private static func isBetter(_ proposal: PathNode, than current: PathNode?) -> Bool {
        guard let current else { return true }
        return proposal.segments < current.segments
            || (proposal.segments == current.segments && proposal.error < current.error)
    }

    private static func withReadableLines(
        _ cue: HighQualitySubtitleCue,
        policy: HighQualityReadableSubtitlePolicy
    ) -> HighQualitySubtitleCue {
        .init(
            id: cue.id,
            start: cue.start,
            end: cue.end,
            text: cue.text,
            speakerLabel: cue.speakerLabel,
            speakerName: cue.speakerName,
            renderedLines: lines(for: normalized(words(cue.text)), policy: policy)
        )
    }

    private static func violations(
        _ cue: HighQualitySubtitleCue,
        policy: HighQualityReadableSubtitlePolicy
    ) -> [HighQualityReadableSubtitleViolation] {
        let text = normalized(words(cue.text))
        let duration = cue.end - cue.start
        var result: [HighQualityReadableSubtitleViolation] = []
        if lines(for: text, policy: policy) == nil { result.append(.lineLimit) }
        if text.count > policy.maximumCharactersPerLine * policy.maximumLinesPerCue {
            result.append(.maximumCharacters)
        }
        if duration < policy.minimumDurationSeconds { result.append(.minimumDuration) }
        if duration > policy.maximumDurationSeconds { result.append(.maximumDuration) }
        if duration <= 0 || Double(text.count) / duration
            > policy.maximumCharactersPerSecond { result.append(.readingSpeed) }
        return result
    }

    private static func lines(
        for text: String,
        policy: HighQualityReadableSubtitlePolicy
    ) -> [String]? {
        let values = words(text)
        guard !values.isEmpty,
              values.allSatisfy({ $0.count <= policy.maximumCharactersPerLine }) else {
            return nil
        }
        if text.count <= policy.maximumCharactersPerLine { return [text] }
        guard policy.maximumLinesPerCue == 2 else { return nil }
        return (1..<values.count).compactMap { split -> [String]? in
            let first = normalized(Array(values[..<split]))
            let second = normalized(Array(values[split...]))
            return first.count <= policy.maximumCharactersPerLine
                    && second.count <= policy.maximumCharactersPerLine
                ? [first, second] : nil
        }.min {
            abs($0[0].count - $0[1].count) < abs($1[0].count - $1[1].count)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func gapIntervals(_ cues: [HighQualitySubtitleCue]) -> [[TimeInterval]] {
        zip(cues, cues.dropFirst()).compactMap {
            $0.end < $1.start ? [$0.end, $1.start] : nil
        }
    }
}
