import Accelerate
import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

enum FirefoxCanonicalAudioAlignment {
    struct Anchor: Codable, Equatable {
        let canonicalSample: Int
        let firefoxSample: Int
        let coarseCorrelation: Double
        let sampleCorrelation: Double
        let residualSamples: Double
    }

    struct Result: Codable, Equatable {
        let sampleRate: Int
        let firefoxInterceptSamples: Double
        let firefoxSamplesPerCanonicalSample: Double
        let endToEndDriftSamples: Double
        let maximumResidualSamples: Double
        let anchors: [Anchor]

        func canonicalSample(forFirefoxSample sample: Int) -> Int {
            Int(((Double(sample) - firefoxInterceptSamples)
                / firefoxSamplesPerCanonicalSample).rounded())
        }
    }

    struct Configuration {
        var sampleRate = 16_000
        var anchorCount = 5
        var anchorSeconds = 2
        var sampleRefinementMilliseconds = 500
        var coarseHopSamples = 160
        var coarseSearchSeconds = 3
        var maximumDriftMilliseconds = 20
        var minimumCorrelation = 0.45
    }

    enum AlignmentError: Error, LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    static func align(
        canonical: [Float],
        firefox: [Float],
        configuration: Configuration = Configuration()
    ) throws -> Result {
        let config = configuration
        let anchorSamples = config.anchorSeconds * config.sampleRate
        guard config.anchorCount >= 3,
              config.coarseHopSamples > 0,
              anchorSamples > config.coarseHopSamples,
              canonical.count >= anchorSamples * 2,
              firefox.count >= anchorSamples else {
            throw AlignmentError.invalid("Audio is too short for multi-anchor alignment.")
        }

        let canonicalFeatures = energyEnvelope(canonical, hop: config.coarseHopSamples)
        let firefoxFeatures = energyEnvelope(firefox, hop: config.coarseHopSamples)
        let anchorFeatureCount = anchorSamples / config.coarseHopSamples
        let margin = anchorFeatureCount
        let span = canonicalFeatures.count - 2 * margin - anchorFeatureCount
        guard span >= 0 else {
            throw AlignmentError.invalid("Canonical audio has no usable anchor span.")
        }
        let canonicalFeatureStarts = (0..<config.anchorCount).map { index in
            margin + (config.anchorCount == 1 ? 0 : span * index / (config.anchorCount - 1))
        }

        var coarseMatches: [(canonical: Int, firefox: Int, score: Double)] = []
        for (index, canonicalStart) in canonicalFeatureStarts.enumerated() {
            let anchor = Array(
                canonicalFeatures[canonicalStart..<(canonicalStart + anchorFeatureCount)]
            )
            let search: ClosedRange<Int>
            if let first = coarseMatches.first {
                let expected = first.firefox + canonicalStart - first.canonical
                let radius = config.coarseSearchSeconds * config.sampleRate
                    / config.coarseHopSamples
                let lower = max(0, expected - radius)
                let upper = min(firefoxFeatures.count - anchorFeatureCount, expected + radius)
                guard lower <= upper else {
                    throw AlignmentError.invalid(
                        "Firefox audio does not contain all canonical anchors in order."
                    )
                }
                search = lower...upper
            } else {
                search = 0...(firefoxFeatures.count - anchorFeatureCount)
            }
            let match = try bestMatch(anchor: anchor, signal: firefoxFeatures, starts: search)
            guard match.score >= config.minimumCorrelation else {
                throw AlignmentError.invalid(
                    "Anchor \(index + 1) correlation \(match.score) is below "
                        + "\(config.minimumCorrelation)."
                )
            }
            coarseMatches.append((canonicalStart, match.start, match.score))
        }

        let refinementSamples = config.sampleRefinementMilliseconds * config.sampleRate / 1_000
        let refinementOffset = (anchorSamples - refinementSamples) / 2
        let refinementRadius = config.coarseHopSamples * 2
        let refinementHop = max(1, config.coarseHopSamples / 8)
        var rawAnchors: [(canonical: Int, firefox: Int, coarse: Double, sample: Double)] = []
        for match in coarseMatches {
            let canonicalStart = match.canonical * config.coarseHopSamples + refinementOffset
            let firefoxEstimate = match.firefox * config.coarseHopSamples + refinementOffset
            let lower = max(0, firefoxEstimate - refinementRadius)
            let upper = min(firefox.count - refinementSamples, firefoxEstimate + refinementRadius)
            guard lower <= upper else {
                throw AlignmentError.invalid("Refined anchor falls outside Firefox audio.")
            }
            let reference = energyEnvelope(
                Array(canonical[canonicalStart..<(canonicalStart + refinementSamples)]),
                hop: refinementHop
            )
            let searchEnd = upper + refinementSamples
            let search = energyEnvelope(Array(firefox[lower..<searchEnd]), hop: refinementHop)
            let refined = try bestMatch(
                anchor: reference,
                signal: search,
                starts: 0...((upper - lower) / refinementHop)
            )
            guard refined.score >= config.minimumCorrelation else {
                throw AlignmentError.invalid(
                    "Sample correlation \(refined.score) is below \(config.minimumCorrelation)."
                )
            }
            rawAnchors.append((
                canonicalStart,
                lower + refined.start * refinementHop,
                match.score,
                refined.score
            ))
        }
        guard zip(rawAnchors, rawAnchors.dropFirst()).allSatisfy({ pair in
            pair.0.firefox < pair.1.firefox
        }) else {
            throw AlignmentError.invalid("Firefox anchors are not monotonic.")
        }

        let fit = affineFit(rawAnchors.map { (Double($0.canonical), Double($0.firefox)) })
        let residuals = rawAnchors.map {
            Double($0.firefox) - (fit.intercept + fit.slope * Double($0.canonical))
        }
        let maximumResidual = residuals.map(abs).max() ?? 0
        let endToEndDrift = abs(fit.slope - 1) * Double(canonical.count)
        let tolerance = Double(config.maximumDriftMilliseconds * config.sampleRate / 1_000)
        guard maximumResidual <= tolerance, endToEndDrift <= tolerance else {
            throw AlignmentError.invalid(
                "Alignment drift exceeds \(config.maximumDriftMilliseconds) ms "
                    + "(end-to-end \(endToEndDrift) samples, residual \(maximumResidual) samples)."
            )
        }

        let anchors = zip(rawAnchors, residuals).map { anchor, residual in
            Anchor(
                canonicalSample: anchor.canonical,
                firefoxSample: anchor.firefox,
                coarseCorrelation: anchor.coarse,
                sampleCorrelation: anchor.sample,
                residualSamples: residual
            )
        }
        return Result(
            sampleRate: config.sampleRate,
            firefoxInterceptSamples: fit.intercept,
            firefoxSamplesPerCanonicalSample: fit.slope,
            endToEndDriftSamples: endToEndDrift,
            maximumResidualSamples: maximumResidual,
            anchors: anchors
        )
    }

    private static func energyEnvelope(_ samples: [Float], hop: Int) -> [Float] {
        samples.withUnsafeBufferPointer { buffer in
            (0..<(samples.count / hop)).map { frame in
                var energy: Float = 0
                vDSP_svesq(
                    buffer.baseAddress!.advanced(by: frame * hop), 1,
                    &energy, vDSP_Length(hop)
                )
                return log1p(sqrt(energy / Float(hop)))
            }
        }
    }

    private static func bestMatch(
        anchor: [Float],
        signal: [Float],
        starts: ClosedRange<Int>
    ) throws -> (start: Int, score: Double) {
        guard !anchor.isEmpty,
              starts.lowerBound >= 0,
              starts.upperBound + anchor.count <= signal.count else {
            throw AlignmentError.invalid("Invalid correlation search range.")
        }
        var mean: Float = 0
        vDSP_meanv(anchor, 1, &mean, vDSP_Length(anchor.count))
        let centered = anchor.map { $0 - mean }
        var anchorEnergy: Float = 0
        vDSP_svesq(centered, 1, &anchorEnergy, vDSP_Length(centered.count))
        guard anchorEnergy > 1e-8 else {
            throw AlignmentError.invalid("Correlation anchor has no signal variance.")
        }

        var bestStart = starts.lowerBound
        var bestScore = -Double.infinity
        centered.withUnsafeBufferPointer { anchorBuffer in
            signal.withUnsafeBufferPointer { signalBuffer in
                for start in starts {
                    let candidate = signalBuffer.baseAddress!.advanced(by: start)
                    var candidateMean: Float = 0
                    var candidateEnergy: Float = 0
                    var dot: Float = 0
                    vDSP_meanv(candidate, 1, &candidateMean, vDSP_Length(centered.count))
                    vDSP_svesq(candidate, 1, &candidateEnergy, vDSP_Length(centered.count))
                    vDSP_dotpr(
                        anchorBuffer.baseAddress!, 1, candidate, 1,
                        &dot, vDSP_Length(centered.count)
                    )
                    let variance = max(
                        0,
                        Double(candidateEnergy)
                            - Double(centered.count) * Double(candidateMean * candidateMean)
                    )
                    let score = variance > 1e-12
                        ? Double(dot) / sqrt(Double(anchorEnergy) * variance)
                        : -Double.infinity
                    if score > bestScore {
                        bestScore = score
                        bestStart = start
                    }
                }
            }
        }
        return (bestStart, bestScore)
    }

    private static func affineFit(_ points: [(Double, Double)]) -> (intercept: Double, slope: Double) {
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        let slope = numerator / denominator
        return (meanY - slope * meanX, slope)
    }
}

enum ManyToManyTurnScorer {
    struct Turn: Codable, Equatable {
        let id: Int
        let confidence: String
        let startSample: Int
        let endSample: Int
        let japanese: String
        var overlap: Bool = false
    }

    struct Fragment: Codable, Equatable {
        let id: Int
        let startSample: Int
        let endSample: Int
        let text: String
    }

    struct Candidate: Codable, Equatable {
        let role: String
        let fragmentIDs: [Int]
        let text: String
        let hasUncoveredTurnGap: Bool
    }

    struct Group: Codable, Equatable {
        let id: Int
        let turnIDs: [Int]
        let highConfidenceTurnCount: Int
        let diagnosticTurnCount: Int
        let referenceJapanese: String
        let candidates: [Candidate]
    }

    static func groups(
        turns: [Turn],
        candidatesByRole: [String: [Fragment]]
    ) -> [Group] {
        let orderedTurns = turns.sorted { $0.startSample < $1.startSample }
        let orderedCandidates = candidatesByRole.mapValues { fragments in
            fragments.sorted { $0.startSample < $1.startSample }
        }
        var unvisited = Set(orderedTurns.indices)
        var groups: [Group] = []

        while let seed = unvisited.min() {
            var turnIndices: Set<Int> = [seed]
            var fragmentIndices = Dictionary(
                uniqueKeysWithValues: orderedCandidates.keys.map { ($0, Set<Int>()) }
            )
            var changed = true
            while changed {
                changed = false
                for (role, fragments) in orderedCandidates {
                    for index in fragments.indices where !fragmentIndices[role]!.contains(index) {
                        if turnIndices.contains(where: {
                            overlaps(orderedTurns[$0], fragments[index])
                        }) {
                            fragmentIndices[role]!.insert(index)
                            changed = true
                        }
                    }
                }
                for index in unvisited where !turnIndices.contains(index) {
                    if orderedCandidates.contains(where: { role, fragments in
                        fragmentIndices[role]!.contains(where: {
                            overlaps(orderedTurns[index], fragments[$0])
                        })
                    }) {
                        turnIndices.insert(index)
                        changed = true
                    }
                }
            }
            unvisited.subtract(turnIndices)
            let groupTurns = turnIndices.sorted().map { orderedTurns[$0] }
            let candidates = orderedCandidates.keys.sorted().map { role in
                let fragments = fragmentIndices[role]!.sorted().map { orderedCandidates[role]![$0] }
                var hasUncoveredTurnGap = false
                if var coveredThrough = fragments.first?.endSample {
                    for fragment in fragments.dropFirst() {
                        if fragment.startSample > coveredThrough,
                           groupTurns.contains(where: { turn in
                               max(turn.startSample, coveredThrough)
                                   < min(turn.endSample, fragment.startSample)
                           }) {
                            hasUncoveredTurnGap = true
                            break
                        }
                        coveredThrough = max(coveredThrough, fragment.endSample)
                    }
                }
                return Candidate(
                    role: role,
                    fragmentIDs: fragments.map(\.id),
                    text: fragments.map(\.text).joined(),
                    hasUncoveredTurnGap: hasUncoveredTurnGap
                )
            }
            groups.append(Group(
                id: groups.count + 1,
                turnIDs: groupTurns.map(\.id),
                highConfidenceTurnCount: groupTurns.filter {
                    $0.confidence == "high" && !$0.overlap
                }.count,
                diagnosticTurnCount: groupTurns.filter {
                    $0.confidence != "high" || $0.overlap
                }.count,
                referenceJapanese: groupTurns.map(\.japanese).joined(),
                candidates: candidates
            ))
        }
        return groups
    }

    /// Human review stays one item per annotated turn. A caption spanning
    /// turns is intentionally repeated in each affected item instead of
    /// joining all turns through a transitive fragment chain.
    static func reviewGroups(
        turns: [Turn],
        candidatesByRole: [String: [Fragment]]
    ) -> [Group] {
        turns.sorted { $0.startSample < $1.startSample }.map { turn in
            let candidates = candidatesByRole.keys.sorted().map { role in
                let fragments = candidatesByRole[role, default: []]
                    .filter { overlaps(turn, $0) }
                    .sorted { $0.startSample < $1.startSample }
                return Candidate(
                    role: role,
                    fragmentIDs: fragments.map(\.id),
                    text: fragments.map(\.text).joined(separator: "\n"),
                    hasUncoveredTurnGap: false
                )
            }
            return Group(
                id: turn.id,
                turnIDs: [turn.id],
                highConfidenceTurnCount: turn.confidence == "high" && !turn.overlap ? 1 : 0,
                diagnosticTurnCount: turn.confidence == "high" && !turn.overlap ? 0 : 1,
                referenceJapanese: turn.japanese,
                candidates: candidates
            )
        }
    }

    static func unmatchedFragments(
        candidatesByRole: [String: [Fragment]],
        groups: [Group]
    ) -> [String: [Fragment]] {
        Dictionary(uniqueKeysWithValues: candidatesByRole.map { role, fragments in
            let matched = Set(groups.flatMap { group in
                group.candidates.first(where: { $0.role == role })?.fragmentIDs ?? []
            })
            return (role, fragments.filter { !matched.contains($0.id) })
        })
    }

    private static func overlaps(_ turn: Turn, _ fragment: Fragment) -> Bool {
        max(turn.startSample, fragment.startSample) < min(turn.endSample, fragment.endSample)
    }
}

enum ContinuousJapaneseCER {
    struct Scope: Codable, Equatable {
        let turnCount: Int
        let referenceCharacterCount: Int
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let rateLowerBound: Double?
        let rateUpperBound: Double?
    }

    struct Overall: Codable, Equatable {
        let editDistance: Int
        let referenceCharacterCount: Int
        let hypothesisCharacterCount: Int
        let rate: Double?
    }

    struct Result: Codable, Equatable {
        let overall: Overall
        let highConfidence: Scope
        let diagnostic: Scope
        let ambiguousBoundaryInsertions: Int
        let note: String
    }

    private enum Owner { case high, diagnostic }
    private struct Counts {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
    }

    static func score(
        turns: [ManyToManyTurnScorer.Turn],
        finalSourceFragments: [ManyToManyTurnScorer.Fragment]
    ) -> Result? {
        let orderedTurns = turns.sorted { $0.startSample < $1.startSample }
        let orderedFragments = finalSourceFragments.sorted { $0.startSample < $1.startSample }
        guard !orderedTurns.isEmpty,
              orderedFragments.allSatisfy({ !$0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty }) else { return nil }

        var reference: [Character] = []
        var owners: [Owner] = []
        for turn in orderedTurns {
            let normalized = JapaneseCER.normalized(turn.japanese)
            reference += normalized
            owners += Array(
                repeating: turn.confidence == "high" && !turn.overlap
                    ? .high : .diagnostic,
                count: normalized.count
            )
        }
        let hypothesisText = orderedFragments.map(\.text).joined()
        let hypothesis = JapaneseCER.normalized(hypothesisText)
        guard !reference.isEmpty else { return nil }

        var matrix = Array(
            repeating: Array(repeating: 0, count: hypothesis.count + 1),
            count: reference.count + 1
        )
        for index in 0...reference.count { matrix[index][0] = index }
        for index in 0...hypothesis.count { matrix[0][index] = index }
        for referenceIndex in reference.indices {
            for hypothesisIndex in hypothesis.indices {
                matrix[referenceIndex + 1][hypothesisIndex + 1] = min(
                    matrix[referenceIndex][hypothesisIndex + 1] + 1,
                    matrix[referenceIndex + 1][hypothesisIndex] + 1,
                    matrix[referenceIndex][hypothesisIndex]
                        + (reference[referenceIndex] == hypothesis[hypothesisIndex] ? 0 : 1)
                )
            }
        }

        var high = Counts()
        var diagnostic = Counts()
        var ambiguousInsertions = 0
        var referenceIndex = reference.count
        var hypothesisIndex = hypothesis.count

        func add(_ operation: WritableKeyPath<Counts, Int>, to owner: Owner) {
            switch owner {
            case .high: high[keyPath: operation] += 1
            case .diagnostic: diagnostic[keyPath: operation] += 1
            }
        }

        while referenceIndex > 0 || hypothesisIndex > 0 {
            if referenceIndex > 0, hypothesisIndex > 0,
               matrix[referenceIndex][hypothesisIndex]
                    == matrix[referenceIndex - 1][hypothesisIndex - 1]
                        + (reference[referenceIndex - 1] == hypothesis[hypothesisIndex - 1] ? 0 : 1) {
                if reference[referenceIndex - 1] != hypothesis[hypothesisIndex - 1] {
                    add(\.substitutions, to: owners[referenceIndex - 1])
                }
                referenceIndex -= 1
                hypothesisIndex -= 1
            } else if referenceIndex > 0,
                      matrix[referenceIndex][hypothesisIndex]
                        == matrix[referenceIndex - 1][hypothesisIndex] + 1 {
                add(\.deletions, to: owners[referenceIndex - 1])
                referenceIndex -= 1
            } else {
                let left = referenceIndex > 0 ? owners[referenceIndex - 1] : nil
                let right = referenceIndex < owners.count ? owners[referenceIndex] : nil
                if let owner = left ?? right, left == nil || right == nil || left == right {
                    add(\.insertions, to: owner)
                } else {
                    ambiguousInsertions += 1
                }
                hypothesisIndex -= 1
            }
        }

        let overall = JapaneseCER.score([(
            reference: orderedTurns.map(\.japanese).joined(),
            hypothesis: hypothesisText
        )])
        let highReferenceCount = owners.filter { $0 == .high }.count
        let diagnosticReferenceCount = owners.count - highReferenceCount
        let highErrors = high.substitutions + high.deletions + high.insertions
        let diagnosticErrors = diagnostic.substitutions
            + diagnostic.deletions + diagnostic.insertions
        guard highErrors + diagnosticErrors + ambiguousInsertions == overall.editDistance else {
            return nil
        }

        func scope(
            turnCount: Int,
            referenceCount: Int,
            counts: Counts
        ) -> Scope {
            let errors = counts.substitutions + counts.deletions + counts.insertions
            return Scope(
                turnCount: turnCount,
                referenceCharacterCount: referenceCount,
                substitutions: counts.substitutions,
                deletions: counts.deletions,
                insertions: counts.insertions,
                rateLowerBound: referenceCount > 0
                    ? Double(errors) / Double(referenceCount) : nil,
                rateUpperBound: referenceCount > 0
                    ? Double(errors + ambiguousInsertions) / Double(referenceCount) : nil
            )
        }

        return Result(
            overall: Overall(
                editDistance: overall.editDistance,
                referenceCharacterCount: overall.referenceCharacterCount,
                hypothesisCharacterCount: overall.hypothesisCharacterCount,
                rate: overall.rate
            ),
            highConfidence: scope(
                turnCount: orderedTurns.filter {
                    $0.confidence == "high" && !$0.overlap
                }.count,
                referenceCount: highReferenceCount,
                counts: high
            ),
            diagnostic: scope(
                turnCount: orderedTurns.filter {
                    $0.confidence != "high" || $0.overlap
                }.count,
                referenceCount: diagnosticReferenceCount,
                counts: diagnostic
            ),
            ambiguousBoundaryInsertions: ambiguousInsertions,
            note: "Overall CER includes every annotation and is diagnostic. The primary high-confidence scope excludes overlaps. With the fixed deterministic traceback, primary/diagnostic rates are bounds because insertions exactly between scopes have no character timestamp."
        )
    }
}

final class JapaneseOfflineEvaluationTests: XCTestCase {
    private struct Metric: Decodable {
        let kind: String
        let engine: String
        let rangeStart: Int
        let rangeEnd: Int
        let sourceText: String
        let englishText: String
        let revision: Int?
        let renderedUptimeNanoseconds: UInt64
        let previewLatencyMilliseconds: Double?
        let speechEndToRenderedMilliseconds: Double?
        let previewGeneration: Int?
        let isFirstEligibleInGeneration: Bool?
        let acceptedStart: Int?
        let stableThrough: Int?
        let committedThrough: Int?
        let finalSegmentIndex: Int?
    }

    private struct SessionReport: Decodable {
        struct Summary: Decodable {
            let sessionID: UUID
            let engine: String
            let translationMode: String
            let finalSampleCount: Int
            let pcmComplete: Bool
            let m4aDroppedSampleCount: Int
            let helperSentThrough: Int?
            let helperAcknowledgedThrough: Int?
            let endingHelperBacklogSamples: Int?
            let sourceStagedThrough: Int
            let englishValidatedThrough: Int
            let committedSampleCount: Int
            let sourceFinalizedThrough: Int?
            let endingEndpointFIFOCount: Int?
            let endingTranslationQueueCount: Int?
            let finalTranslationInFlight: Bool?
            let sourcePipelineFailure: String?
            let completionFailure: String?
            let sourceLocale: String?
            let captureTiming: AudioCaptureTiming?
            let capturedApplicationBundleIdentifier: String?
            let capturedApplicationProcessIdentifier: Int32?
            let microphoneIncluded: Bool?
        }
        struct VoxtralSession: Decodable {
            let startSample: Int
            let targetSample: Int?
            let endSample: Int
            let lastSpeechEndSample: Int?
            let helperProcessIdentifier: Int32?
            let acknowledgedThroughSample: Int?
            let endingBacklogSamples: Int
            let captureEnded: Bool
            let transcriptCharacterCount: Int
        }
        let summary: Summary
        let maximumCombinedResidentBytes: UInt64
        let maximumEndpointFIFOCount: Int?
        let metricsFile: String
        let metricsSHA256: String
        let canonicalPCMFile: String?
        let canonicalPCMSHA256: String?
        let whisperCandidate: String?
        let whisperModelID: String?
        let whisperModelRevision: String?
        let whisperModelFile: String?
        let whisperModelSHA256: String?
        let qwenModelID: String?
        let qwenModelRevision: String?
        let fireRedModelID: String?
        let fireRedModelRevision: String?
        let voxtralModelID: String?
        let voxtralModelRevision: String?
        let voxtralRuntimePatchSHA256: String?
        let voxtralDelayMilliseconds: Int?
        let transportBlockMilliseconds: Int?
        let voxtralSessions: [VoxtralSession]?
    }

    private struct Identity: Codable {
        let fileName: String
        let sha256: String
    }

    private struct Provenance: Codable {
        let session: Identity
        let manifest: Identity
        let canonicalAudio: Identity
        let firefoxAudio: Identity
        let metrics: Identity
        let oracle: Identity
    }

    private struct Coverage: Codable, Equatable {
        let turnCount: Int
        let highConfidenceTurnCount: Int
        let diagnosticTurnCount: Int
        let firstPreviewFragmentCount: Int
        let lastPreviewFragmentCount: Int
        let finalFragmentCount: Int
        let groupCount: Int
    }

    private struct FullReport: Codable {
        let schemaVersion: Int
        let status: String
        let note: String
        let corpusID: String
        let provenance: Provenance
        let alignment: FirefoxCanonicalAudioAlignment.Result
        let coverage: Coverage
        let productionJapaneseCER: ContinuousJapaneseCER.Result
        let lastSpeech: LastSpeechEvidence
        let runtime: RuntimeEvidence
        let groups: [ManyToManyTurnScorer.Group]
        let unmatchedFragmentsByRole: [String: [ManyToManyTurnScorer.Fragment]]
    }

    private struct LatencyEvidence: Codable {
        let count: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let worstMilliseconds: Double?
    }

    private struct RuntimeEvidence: Codable {
        let captureTiming: AudioCaptureTiming?
        let maximumCombinedResidentBytes: UInt64
        let maximumEndpointFIFOCount: Int?
        let endingEndpointFIFOCount: Int?
        let endingTranslationQueueCount: Int?
        let sourceFinalizedThrough: Int?
        let committedSampleCount: Int
        let previewFirstRevisionLatency: LatencyEvidence
        let finalSpeechEndToRendered: LatencyEvidence
        let slo: SLOAssessment
    }

    private struct PreviewCoverageEvidence: Codable {
        let coveredPrimaryTurns: Int
        let primaryTurnCount: Int
        let percent: Double
    }

    private struct SLOAssessment: Codable {
        let previewCoverage: PreviewCoverageEvidence
        let previewCoveragePass: Bool
        let previewP50Pass: Bool
        let previewP95Pass: Bool
        let previewWorstPass: Bool
        let finalP95Pass: Bool
        let finalImmutabilityPass: Bool
        let finalImmutabilityEvidence: String
        let allRuntimeSLOsPass: Bool
    }

    private typealias LastSpeechEvidence = JapaneseBenchmarkSupport.LastSpeechEvidence

    private struct BlindCandidate: Codable {
        let alias: String
        let english: String
        let fidelityScore1To5: Int?
        let subtitleNaturalnessScore1To5: Int?
        let criticalError: String?
        let preferred: Bool?
        let judge: String?
    }

    private struct BlindItem: Codable {
        let groupID: Int
        let turnIDs: [Int]
        let highConfidenceTurnCount: Int
        let diagnosticTurnCount: Int
        let referenceJapanese: String
        let candidates: [BlindCandidate]
    }

    private struct BlindReport: Codable {
        let schemaVersion: Int
        let corpusID: String
        let note: String
        let provenance: Provenance
        let coverage: Coverage
        let items: [BlindItem]
    }

    private struct KeyReport: Codable {
        let schemaVersion: Int
        let blindSHA256: String
        let aliases: [String: String]
    }

    func testMultiAnchorAlignmentRecoversOffsetAndSmallDrift() throws {
        let sampleRate = 4_000
        let canonical = syntheticSignal(count: sampleRate * 20)
        let offset = 2_000
        let scale = 1.001
        let firefox = resampled(canonical, offset: offset, scale: scale, trailing: 1_000)
        var configuration = FirefoxCanonicalAudioAlignment.Configuration()
        configuration.sampleRate = sampleRate
        configuration.anchorSeconds = 1
        configuration.sampleRefinementMilliseconds = 250
        configuration.coarseHopSamples = 40
        configuration.maximumDriftMilliseconds = 20
        let result = try FirefoxCanonicalAudioAlignment.align(
            canonical: canonical,
            firefox: firefox,
            configuration: configuration
        )
        XCTAssertEqual(result.firefoxInterceptSamples, Double(offset), accuracy: 4)
        XCTAssertEqual(result.firefoxSamplesPerCanonicalSample, scale, accuracy: 0.0002)
        XCTAssertLessThanOrEqual(result.maximumResidualSamples, 4)
        XCTAssertEqual(result.anchors.count, 5)
    }

    func testManyToManyGroupingConsumesSplitAndMergedFragmentsOnce() {
        let turns = [
            ManyToManyTurnScorer.Turn(
                id: 1, confidence: "high", startSample: 0, endSample: 100, japanese: "一"
            ),
            ManyToManyTurnScorer.Turn(
                id: 2, confidence: "medium", startSample: 100, endSample: 200, japanese: "二"
            ),
            ManyToManyTurnScorer.Turn(
                id: 3, confidence: "high", startSample: 200, endSample: 300, japanese: "三"
            ),
        ]
        let groups = ManyToManyTurnScorer.groups(turns: turns, candidatesByRole: [
            "firstPreview": [
                .init(id: 1, startSample: 0, endSample: 40, text: "a"),
                .init(id: 2, startSample: 40, endSample: 100, text: "b"),
            ],
            "lastPreview": [
                .init(id: 3, startSample: 100, endSample: 200, text: "c"),
            ],
            "final": [
                .init(id: 1, startSample: 0, endSample: 200, text: "abc"),
            ],
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].turnIDs, [1, 2])
        XCTAssertEqual(groups[0].referenceJapanese, "一二")
        XCTAssertEqual(groups[0].candidates.first(where: { $0.role == "firstPreview" })?.text, "ab")
        XCTAssertEqual(groups[0].candidates.first(where: { $0.role == "lastPreview" })?.text, "c")
        XCTAssertEqual(groups[0].candidates.first(where: { $0.role == "final" })?.fragmentIDs, [1])
        XCTAssertFalse(groups[0].candidates.first(where: {
            $0.role == "firstPreview"
        })?.hasUncoveredTurnGap ?? true)
        XCTAssertEqual(groups[1].turnIDs, [3])
        XCTAssertTrue(groups[1].candidates.allSatisfy { $0.text.isEmpty })
    }

    func testManyToManyGroupingReportsHiddenFinalRangeGap() {
        let groups = ManyToManyTurnScorer.groups(
            turns: [.init(
                id: 1, confidence: "high", startSample: 0, endSample: 100,
                japanese: "一"
            )],
            candidatesByRole: ["final": [
                .init(id: 1, startSample: 0, endSample: 40, text: "a"),
                .init(id: 2, startSample: 60, endSample: 100, text: "b"),
            ]]
        )
        XCTAssertTrue(groups[0].candidates[0].hasUncoveredTurnGap)
    }

    func testManyToManyGroupingAcceptsIntentionalFinalOverlap() {
        let groups = ManyToManyTurnScorer.groups(
            turns: [.init(
                id: 1, confidence: "high", startSample: 0, endSample: 120,
                japanese: "一"
            )],
            candidatesByRole: ["final": [
                .init(id: 1, startSample: 0, endSample: 100, text: "a"),
                .init(id: 2, startSample: 20, endSample: 30, text: "b"),
                .init(id: 3, startSample: 90, endSample: 120, text: "c"),
            ]]
        )
        XCTAssertFalse(groups[0].candidates[0].hasUncoveredTurnGap)
    }

    func testHumanReviewDoesNotFollowTransitiveFragmentChains() {
        let turns = (1...3).map { id in
            ManyToManyTurnScorer.Turn(
                id: id,
                confidence: "high",
                startSample: (id - 1) * 100,
                endSample: id * 100,
                japanese: "参照\(id)"
            )
        }
        let fragments = [
            ManyToManyTurnScorer.Fragment(
                id: 1, startSample: 0, endSample: 150, text: "one"
            ),
            ManyToManyTurnScorer.Fragment(
                id: 2, startSample: 150, endSample: 300, text: "two"
            ),
        ]

        let audit = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: ["final": fragments]
        )
        let review = ManyToManyTurnScorer.reviewGroups(
            turns: turns,
            candidatesByRole: ["final": fragments]
        )

        XCTAssertEqual(audit.map(\.turnIDs), [[1, 2, 3]])
        XCTAssertEqual(review.map(\.turnIDs), [[1], [2], [3]])
        XCTAssertEqual(review[0].candidates[0].fragmentIDs, [1])
        XCTAssertEqual(review[1].candidates[0].fragmentIDs, [1, 2])
        XCTAssertEqual(review[1].candidates[0].text, "one\ntwo")
        XCTAssertEqual(review[2].candidates[0].fragmentIDs, [2])
    }

    func testAuditRetainsUnmatchedFragments() {
        let turns = [ManyToManyTurnScorer.Turn(
            id: 1, confidence: "high", startSample: 0, endSample: 100, japanese: "参照"
        )]
        let fragments = [
            ManyToManyTurnScorer.Fragment(
                id: 1, startSample: 0, endSample: 100, text: "matched"
            ),
            ManyToManyTurnScorer.Fragment(
                id: 2, startSample: 120, endSample: 140, text: "between turns"
            ),
        ]
        let groups = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: ["final": fragments]
        )

        XCTAssertEqual(
            ManyToManyTurnScorer.unmatchedFragments(
                candidatesByRole: ["final": fragments],
                groups: groups
            )["final"]?.map(\.id),
            [2]
        )
    }

    func testContinuousJapaneseCERIgnoresProductClauseBoundaries() throws {
        let turns = [
            ManyToManyTurnScorer.Turn(
                id: 1, confidence: "high", startSample: 0, endSample: 100,
                japanese: "みなさん"
            ),
            ManyToManyTurnScorer.Turn(
                id: 2, confidence: "medium", startSample: 100, endSample: 200,
                japanese: "こんにちは"
            ),
        ]
        let fragments = [
            ManyToManyTurnScorer.Fragment(
                id: 1, startSample: 0, endSample: 70, text: "みな"
            ),
            ManyToManyTurnScorer.Fragment(
                id: 2, startSample: 70, endSample: 200, text: "さんこんにちは"
            ),
        ]
        let result = try XCTUnwrap(ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: fragments
        ))
        XCTAssertEqual(result.overall.editDistance, 0)
        XCTAssertEqual(result.highConfidence.turnCount, 1)
        XCTAssertEqual(result.diagnostic.turnCount, 1)
    }

    func testContinuousJapaneseCERKeepsHighConfidenceOverlapDiagnostic() throws {
        let result = try XCTUnwrap(ContinuousJapaneseCER.score(
            turns: [
                .init(
                    id: 1, confidence: "high", startSample: 0, endSample: 100,
                    japanese: "甲"
                ),
                .init(
                    id: 2, confidence: "high", startSample: 100, endSample: 200,
                    japanese: "乙", overlap: true
                ),
            ],
            finalSourceFragments: [.init(
                id: 1, startSample: 0, endSample: 200, text: "甲丙"
            )]
        ))

        XCTAssertEqual(result.highConfidence.turnCount, 1)
        XCTAssertEqual(result.highConfidence.substitutions, 0)
        XCTAssertEqual(result.diagnostic.turnCount, 1)
        XCTAssertEqual(result.diagnostic.substitutions, 1)
    }

    func testLastSpeechEvidenceRequiresHalfTheReferenceInOrder() {
        let turn = ManyToManyTurnScorer.Turn(
            id: 9, confidence: "high", startSample: 100, endSample: 200,
            japanese: "最後の言葉です"
        )
        let missing = lastSpeechEvidence(
            turn: turn,
            fragments: [.init(
                id: 1, startSample: 100, endSample: 200, text: "前の話"
            )]
        )
        let present = lastSpeechEvidence(
            turn: turn,
            fragments: [.init(
                id: 1, startSample: 100, endSample: 200, text: "最後の言葉です"
            )]
        )

        XCTAssertFalse(missing.heuristicPresent)
        XCTAssertTrue(present.heuristicPresent)
        XCTAssertEqual(present.referenceCoveragePercent, 100)
    }

    func testFinalImmutabilityRequiresAppendOnlySegmentIndices() {
        XCTAssertFalse(finalSegmentIndicesProveAppendOnly([]))
        XCTAssertFalse(finalSegmentIndicesProveAppendOnly([nil]))
        XCTAssertTrue(finalSegmentIndicesProveAppendOnly([0, 1, 2]))
        XCTAssertFalse(finalSegmentIndicesProveAppendOnly([0, 2]))
        XCTAssertFalse(finalSegmentIndicesProveAppendOnly([0, 1, 1]))
    }

    func testContinuousJapaneseCERKeepsCrossScopeInsertionsAmbiguous() throws {
        let turns = [
            ManyToManyTurnScorer.Turn(
                id: 1, confidence: "high", startSample: 0, endSample: 100,
                japanese: "あ"
            ),
            ManyToManyTurnScorer.Turn(
                id: 2, confidence: "medium", startSample: 100, endSample: 200,
                japanese: "い"
            ),
        ]
        let result = try XCTUnwrap(ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: [.init(
                id: 1, startSample: 0, endSample: 200, text: "あうい"
            )]
        ))
        XCTAssertEqual(result.overall.editDistance, 1)
        XCTAssertEqual(result.ambiguousBoundaryInsertions, 1)
        XCTAssertEqual(result.highConfidence.rateLowerBound, 0)
        XCTAssertEqual(result.highConfidence.rateUpperBound, 1)
        XCTAssertEqual(result.diagnostic.rateLowerBound, 0)
        XCTAssertEqual(result.diagnostic.rateUpperBound, 1)
    }

    func testContinuousJapaneseCERCountsUnmatchedAndEmptySource() throws {
        let turns = [ManyToManyTurnScorer.Turn(
            id: 1, confidence: "high", startSample: 0, endSample: 100,
            japanese: "あ"
        )]
        let unmatched = ManyToManyTurnScorer.Fragment(
            id: 1, startSample: 120, endSample: 140, text: "い"
        )
        let result = try XCTUnwrap(ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: [unmatched]
        ))
        XCTAssertEqual(result.overall.editDistance, 1)
        let empty = try XCTUnwrap(ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: []
        ))
        XCTAssertEqual(empty.overall.editDistance, 1)
        XCTAssertEqual(empty.overall.hypothesisCharacterCount, 0)
        XCTAssertEqual(empty.highConfidence.deletions, 1)
        XCTAssertEqual(empty.highConfidence.rateLowerBound, 1)
        XCTAssertEqual(empty.highConfidence.rateUpperBound, 1)
    }

    func testMultiAnchorAlignmentRejectsDriftBeyond20Milliseconds() {
        let sampleRate = 4_000
        let canonical = syntheticSignal(count: sampleRate * 20)
        let firefox = resampled(canonical, offset: 2_000, scale: 1.0011, trailing: 1_000)
        var configuration = FirefoxCanonicalAudioAlignment.Configuration()
        configuration.sampleRate = sampleRate
        configuration.anchorSeconds = 1
        configuration.sampleRefinementMilliseconds = 250
        configuration.coarseHopSamples = 40
        configuration.maximumDriftMilliseconds = 20
        XCTAssertThrowsError(try FirefoxCanonicalAudioAlignment.align(
            canonical: canonical,
            firefox: firefox,
            configuration: configuration
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("drift exceeds"))
        }
    }

    func testBlindArtifactsCoverAllPrimaryAndDiagnosticTurns() throws {
        let turns = (1...59).map { id in
            ManyToManyTurnScorer.Turn(
                id: id,
                confidence: id <= 46 ? "high" : "medium",
                startSample: (id - 1) * 100,
                endSample: id * 100,
                japanese: "参照\(id)"
            )
        }
        let fragments = turns.map {
            ManyToManyTurnScorer.Fragment(
                id: $0.id,
                startSample: $0.startSample,
                endSample: $0.endSample,
                text: "candidate\($0.id)"
            )
        }
        let groups = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: [
                "firstPreview": fragments,
                "lastPreview": fragments,
                "final": fragments,
            ]
        )
        let coverage = coverage(groups: groups)
        XCTAssertEqual(coverage.turnCount, 59)
        XCTAssertEqual(coverage.highConfidenceTurnCount, 46)
        XCTAssertEqual(coverage.diagnosticTurnCount, 13)
        let identity = Identity(fileName: "fixture", sha256: "fixture")
        let blind = blindArtifacts(
            corpusID: "fixture",
            seed: "fixture",
            provenance: Provenance(
                session: identity,
                manifest: identity,
                canonicalAudio: identity,
                firefoxAudio: identity,
                metrics: identity,
                oracle: identity
            ),
            coverage: coverage,
            groups: groups
        )
        XCTAssertEqual(blind.report.items.count, 59)
        XCTAssertEqual(blind.key.count, 177)
        for itemID in 1...59 {
            let roles = Set(blind.key.compactMap { entry in
                entry.key.hasPrefix("\(itemID):") ? entry.value : nil
            })
            XCTAssertEqual(roles, Set(["firstPreview", "lastPreview", "final"]))
        }
    }

    func testBlindArtifactsAcceptStableFinalOnly() {
        let turns = [ManyToManyTurnScorer.Turn(
            id: 1,
            confidence: "high",
            startSample: 0,
            endSample: 100,
            japanese: "参照"
        )]
        let groups = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: ["final": [.init(
                id: 1,
                startSample: 0,
                endSample: 100,
                text: "final"
            )]]
        )
        let identity = Identity(fileName: "fixture", sha256: "fixture")
        let blind = blindArtifacts(
            corpusID: "fixture",
            seed: "fixture",
            provenance: Provenance(
                session: identity,
                manifest: identity,
                canonicalAudio: identity,
                firefoxAudio: identity,
                metrics: identity,
                oracle: identity
            ),
            coverage: coverage(groups: groups),
            groups: groups
        )

        XCTAssertEqual(blind.report.items.first?.candidates.count, 1)
        XCTAssertEqual(blind.key["1:A"], "final")
    }

    func testGeneratePreviewFinalBlindReportWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sessionPath = environment["WHISPERASR_JAPANESE_OFFLINE_SESSION"] else {
            throw XCTSkip("Run Scripts/run_japanese_offline_evaluation.sh with a benchmark session sidecar.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = URL(
            fileURLWithPath: environment["WHISPERASR_JAPANESE_BENCHMARK_MANIFEST"]
                ?? root.appendingPathComponent(
                    "docs/japanese-live/corpora/easy-japanese-1/manifest.json"
                ).path
        )
        let sessionURL = URL(fileURLWithPath: sessionPath).standardizedFileURL
        let session = try JSONDecoder().decode(
            SessionReport.self, from: Data(contentsOf: sessionURL)
        )
        guard !session.summary.engine.lowercased().contains("voxtral")
                || session.summary.sourceStagedThrough
                    == session.summary.englishValidatedThrough else {
            throw inputError(
                "Source and English validation cursors differ; final metrics would hide staged Japanese."
            )
        }
        let metricsURL = try siblingArtifact(
            named: session.metricsFile,
            beside: sessionURL
        )
        guard let canonicalPCMFile = session.canonicalPCMFile,
              let canonicalPCMSHA256 = session.canonicalPCMSHA256 else {
            throw inputError("Benchmark session has no canonical ScreenCaptureKit PCM proof.")
        }
        let firefoxURL = try siblingArtifact(named: canonicalPCMFile, beside: sessionURL)
        guard try JapaneseBenchmarkSupport.sha256(at: metricsURL) == session.metricsSHA256,
              try JapaneseBenchmarkSupport.sha256(at: firefoxURL) == canonicalPCMSHA256 else {
            throw inputError("Benchmark artifacts no longer match their session sidecar.")
        }
        let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
        let canonicalURL = try JapaneseBenchmarkSupport.fixtureURL(
            for: manifest,
            workspaceRoot: root
        )
        guard !manifest.annotations.turns.isEmpty else {
            throw inputError("The corpus manifest contains no annotated turns.")
        }
        guard try JapaneseBenchmarkSupport.sha256(at: canonicalURL) == manifest.fixture.sha256 else {
            throw inputError("Canonical WAV no longer matches its manifest.")
        }
        let canonical = try await AudioLoader.loadSamples(url: canonicalURL)
        let firefox = try await AudioLoader.loadSamples(url: firefoxURL)
        guard canonical.count == manifest.fixture.sampleCount else {
            throw inputError("Canonical sample count no longer matches its manifest.")
        }
        let alignment = try FirefoxCanonicalAudioAlignment.align(
            canonical: canonical,
            firefox: firefox
        )
        if ["qudu2fx3ncc", "md62mmdz0m"].contains(manifest.corpusID) {
            guard session.summary.pcmComplete,
                  ["whisperTurboApple", "voxtralApple", "qwenApple"].contains(
                      session.summary.engine
                  ),
                  session.summary.translationMode == "adaptive",
                  session.summary.finalSampleCount == firefox.count,
                  session.summary.endingEndpointFIFOCount == 0,
                  session.summary.endingTranslationQueueCount == 0,
                  session.summary.finalTranslationInFlight == false,
                  session.summary.sourcePipelineFailure == nil,
                  session.summary.completionFailure == nil,
                  session.summary.sourceLocale?.hasPrefix("ja") == true,
                  (session.summary.capturedApplicationBundleIdentifier.map {
                    ["com.google.Chrome", "org.mozilla.nightly", "org.mozilla.nightlyunofficial"]
                        .contains($0)
                  }) == true,
                  (session.summary.capturedApplicationProcessIdentifier ?? 0) > 0,
                  session.summary.microphoneIncluded == false else {
                throw inputError("The L7 session did not finish with a complete, drained Firefox pipeline.")
            }
            guard let timing = session.summary.captureTiming,
                  timing.callbackCount > 0,
                  timing.firstPresentationUptimeNanoseconds != nil,
                  timing.firstBufferUptimeNanoseconds != nil,
                  timing.firstPresentationSample48k != nil,
                  timing.lastPresentationEndSample48k != nil,
                  timing.invalidPresentationTimestampCount == 0,
                  timing.gapCount == 0,
                  timing.overlapCount == 0,
                  timing.restartCount == 0 else {
                throw inputError("ScreenCaptureKit PTS continuity was not proven for the L7 session.")
            }
            let baselinePlusTwentyPercent: UInt64 = 5_022_375_945
            guard session.maximumCombinedResidentBytes < 10 * 1_024 * 1_024 * 1_024,
                  session.summary.engine == "qwenApple"
                    || session.maximumCombinedResidentBytes <= baselinePlusTwentyPercent else {
                throw inputError("Observed resident memory exceeds the L7 gate.")
            }
            if session.summary.engine == "qwenApple" {
                guard session.qwenModelID == LocalPrototypeModelID.qwen,
                      session.qwenModelRevision == LocalPrototypeModelID.qwenRevision,
                      session.fireRedModelID == LocalPrototypeModelID.fireRed,
                      session.fireRedModelRevision == LocalPrototypeModelID.fireRedRevision else {
                    throw inputError("The Qwen or FireRed revision is not pinned in the E1 sidecar.")
                }
            } else if session.summary.engine == "voxtralApple" {
                guard session.voxtralModelID == VoxtralHelperManifest.modelID,
                      session.voxtralModelRevision
                        == VoxtralHelperManifest.modelRevision,
                      session.voxtralRuntimePatchSHA256
                        == VoxtralHelperManifest.runtimePatchSHA256,
                      session.voxtralDelayMilliseconds
                        == VoxtralHelperManifest.transcriptionDelayMilliseconds,
                      session.transportBlockMilliseconds
                        == VoxtralHelperManifest.transportBlockMilliseconds,
                      session.summary.helperSentThrough
                        == session.summary.finalSampleCount,
                      session.summary.helperAcknowledgedThrough
                        == session.summary.finalSampleCount,
                      session.summary.endingHelperBacklogSamples == 0,
                      let sessions = session.voxtralSessions,
                      sessions.count >= 2,
                      sessions.first?.startSample == 0,
                      sessions.last?.endSample == session.summary.finalSampleCount,
                      sessions.last?.captureEnded == true,
                      sessions.last?.targetSample == nil,
                      sessions.allSatisfy({
                          $0.helperProcessIdentifier != nil
                              && $0.endSample > $0.startSample
                              && $0.transcriptCharacterCount > 0
                      }),
                      Set(sessions.compactMap(\.helperProcessIdentifier)).count == 1,
                      zip(sessions, sessions.dropFirst()).allSatisfy({
                          $0.endSample == $1.startSample
                      }),
                      sessions.dropLast().allSatisfy({ item in
                          guard let target = item.targetSample,
                                let lastSpeechEnd = item.lastSpeechEndSample else {
                              return false
                          }
                          return item.captureEnded == false
                              && target == item.startSample
                                  + AppState.continuousVoxtralRotationTargetSamples
                              && item.endSample >= target
                              && item.endSample - lastSpeechEnd
                                  >= LocalEndpointPlanner.postRoll
                      }),
                      sessions.allSatisfy({
                          $0.acknowledgedThroughSample == $0.endSample
                              && $0.endingBacklogSamples == 0
                      }) else {
                    throw inputError(
                        "The Voxtral model or rotated PCM sessions are not pinned and complete."
                    )
                }
            } else {
                guard let candidate = session.whisperCandidate,
                      let modelID = session.whisperModelID,
                      let revision = session.whisperModelRevision,
                      let modelSHA256 = session.whisperModelSHA256,
                      session.whisperModelFile?.isEmpty == false else {
                    throw inputError(
                        "The final Whisper model is not pinned in the L7 sidecar."
                    )
                }
                let expectedModel: (id: String, revision: String, sha256: String)
                switch candidate {
                case "turbo":
                    expectedModel = (
                        "large-v3-turbo",
                        "5359861c739e955e79d9a303bcbc70fb988958b1",
                        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
                    )
                case "kotoba-q5":
                    expectedModel = (
                        LocalWhisperModelSelection.kotobaModelID,
                        LocalWhisperModelSelection.kotobaRevision,
                        LocalWhisperModelSelection.kotobaSHA256
                    )
                default:
                    throw inputError(
                        "Unexpected L7 Whisper candidate: \(candidate)."
                    )
                }
                guard modelID == expectedModel.id,
                      revision == expectedModel.revision,
                      modelSHA256 == expectedModel.sha256 else {
                    throw inputError(
                        "The L7 model identity differs from its pinned candidate."
                    )
                }
            }
            guard let finalizedThrough = session.summary.sourceFinalizedThrough,
                  let lastAnnotatedSample = manifest.annotations.turns.map(\.endSample).max(),
                  alignment.canonicalSample(forFirefoxSample: finalizedThrough)
                    >= lastAnnotatedSample,
                  alignment.canonicalSample(
                    forFirefoxSample: session.summary.committedSampleCount
                  ) >= lastAnnotatedSample else {
                throw inputError("The final Japanese or English cursor does not cover the last annotated speech.")
            }
        }
        let metrics = try JSONDecoder().decode([Metric].self, from: Data(contentsOf: metricsURL))
        guard metrics.allSatisfy({
            $0.rangeStart >= 0 && $0.rangeEnd >= $0.rangeStart && $0.rangeEnd <= firefox.count
        }) else {
            throw inputError("Metric ranges exceed the matching Firefox audio.")
        }
        if ["qudu2fx3ncc", "md62mmdz0m"].contains(manifest.corpusID),
           !metrics.allSatisfy({ $0.engine == session.summary.engine }) {
            throw inputError("L7 metric engines differ from the attested session engine.")
        }
        let previews = previewExtremes(metrics)
        let firstPreview = fragments(
            from: previews.first,
            alignment: alignment, canonicalCount: canonical.count
        )
        let lastPreview = fragments(
            from: previews.last,
            alignment: alignment, canonicalCount: canonical.count
        )
        let final = fragments(
            from: metrics.filter { $0.kind == "final" },
            alignment: alignment, canonicalCount: canonical.count
        )
        let finalSource = fragments(
            from: metrics.filter { $0.kind == "final" },
            alignment: alignment,
            canonicalCount: canonical.count,
            text: \.sourceText
        )
        guard !final.isEmpty else {
            throw inputError("Metrics must contain final records.")
        }
        guard firstPreview.count == lastPreview.count else {
            throw inputError("Preview metrics must contain both first and last revisions.")
        }
        if ["qudu2fx3ncc", "md62mmdz0m"].contains(manifest.corpusID) {
            let previewMetrics = metrics.filter { $0.kind == "preview" }
            guard previewMetrics.allSatisfy({
                $0.previewGeneration != nil && $0.isFirstEligibleInGeneration != nil
            }), Dictionary(grouping: previewMetrics, by: \.previewGeneration).values
                .allSatisfy({ revisions in
                    let ordered = revisions.sorted {
                        $0.renderedUptimeNanoseconds < $1.renderedUptimeNanoseconds
                    }
                    let flagged = ordered.indices.filter {
                        ordered[$0].isFirstEligibleInGeneration == true
                    }
                    return flagged.count <= 1 && (flagged.first == nil || flagged.first == 0)
                }) else {
                throw inputError("L7 preview metrics do not carry their phrase generation identity.")
            }
        }
        let turns = manifest.annotations.turns.map {
            ManyToManyTurnScorer.Turn(
                id: $0.id,
                confidence: $0.confidence.rawValue,
                startSample: $0.startSample,
                endSample: $0.endSample,
                japanese: $0.japanese,
                overlap: $0.overlap ?? false
            )
        }
        let finalMetrics = metrics.filter { $0.kind == "final" }.sorted {
            ($0.acceptedStart ?? Int.max) < ($1.acceptedStart ?? Int.max)
        }
        guard finalMetrics.allSatisfy({ metric in
            guard let acceptedStart = metric.acceptedStart,
                  let stableThrough = metric.stableThrough,
                  let committedThrough = metric.committedThrough else { return false }
            return acceptedStart >= 0
                && stableThrough > acceptedStart
                && committedThrough == stableThrough
        }), zip(finalMetrics, finalMetrics.dropFirst()).allSatisfy({ pair in
            pair.0.stableThrough == pair.1.acceptedStart
        }), finalMetrics.last?.stableThrough == session.summary.committedSampleCount,
        finalMetrics.last?.stableThrough == session.summary.sourceFinalizedThrough else {
            throw inputError("Accepted final cursors are missing, non-monotone, or contain a PCM hole.")
        }
        if let firstTurn = manifest.annotations.turns.min(by: { $0.startSample < $1.startSample }),
           let firstAccepted = finalMetrics.first?.acceptedStart,
           alignment.canonicalSample(forFirefoxSample: firstAccepted) > firstTurn.startSample {
            throw inputError("The accepted final cursor starts after the first annotated speech.")
        }
        let lastTurn = try XCTUnwrap(
            turns.max(by: { $0.endSample < $1.endSample })
        )
        let lastSpeech = lastSpeechEvidence(turn: lastTurn, fragments: finalSource)
        guard let productionJapaneseCER = ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: finalSource
        ) else {
            throw inputError("Final source metrics cannot produce an honest continuous Japanese CER.")
        }
        var candidatesByRole = ["final": final]
        if !firstPreview.isEmpty {
            candidatesByRole["firstPreview"] = firstPreview
            candidatesByRole["lastPreview"] = lastPreview
        }
        let auditGroups = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: candidatesByRole
        )
        let sourceFragmentCounts = candidatesByRole.mapValues(\.count)
        let auditCoverage = coverage(
            groups: auditGroups,
            sourceFragmentCounts: sourceFragmentCounts
        )
        let expectedHighCount = manifest.annotations.turns.filter {
            $0.confidence == .high && $0.overlap != true
        }.count
        guard auditCoverage.turnCount == manifest.annotations.turns.count,
              auditCoverage.highConfidenceTurnCount == expectedHighCount,
              auditCoverage.diagnosticTurnCount
                == manifest.annotations.turns.count - expectedHighCount else {
            throw inputError("Many-to-many grouping lost annotated turns.")
        }
        // ASR ranges are VAD windows and may omit silence inside a human turn.
        // The accepted cursor chain above proves PCM continuity; keeping the VAD
        // ranges here preserves honest transcript scoring and review grouping.
        let reviewGroups = ManyToManyTurnScorer.reviewGroups(
            turns: turns,
            candidatesByRole: candidatesByRole
        )
        let reviewCoverage = coverage(
            groups: reviewGroups,
            sourceFragmentCounts: sourceFragmentCounts
        )
        let unmatched = ManyToManyTurnScorer.unmatchedFragments(
            candidatesByRole: candidatesByRole,
            groups: auditGroups
        )
        let provenance = Provenance(
            session: try identity(sessionURL),
            manifest: try identity(manifestURL),
            canonicalAudio: try identity(canonicalURL),
            firefoxAudio: try identity(firefoxURL),
            metrics: try identity(metricsURL),
            oracle: try identity(URL(fileURLWithPath: #filePath))
        )
        let firstPreviewMetrics = previews.first
        let previewLatency = latencyEvidence(
            firstPreviewMetrics,
            value: \.previewLatencyMilliseconds
        )
        let finalLatency = latencyEvidence(
            finalMetrics,
            value: \.speechEndToRenderedMilliseconds
        )
        let previewCoverage = previewCoverage(
            turns: turns,
            fragments: firstPreview
        )
        let previewCoveragePass = previewCoverage.percent >= 95
        let previewP50Pass = previewLatency.p50Milliseconds.map { $0 <= 1_000 } ?? false
        let previewP95Pass = previewLatency.p95Milliseconds.map { $0 <= 1_800 } ?? false
        let previewWorstPass = previewLatency.worstMilliseconds.map { $0 <= 3_000 } ?? false
        let finalP95Pass = finalLatency.p95Milliseconds.map { $0 <= 1_500 } ?? false
        let finalImmutabilityPass = finalSegmentIndicesProveAppendOnly(
            finalMetrics.map(\.finalSegmentIndex)
        )
        let slo = SLOAssessment(
            previewCoverage: previewCoverage,
            previewCoveragePass: previewCoveragePass,
            previewP50Pass: previewP50Pass,
            previewP95Pass: previewP95Pass,
            previewWorstPass: previewWorstPass,
            finalP95Pass: finalP95Pass,
            finalImmutabilityPass: finalImmutabilityPass,
            finalImmutabilityEvidence: finalImmutabilityPass
                ? "proven-append-only-final-segment-indices" : "not-proven",
            allRuntimeSLOsPass: previewCoveragePass && previewP50Pass
                && previewP95Pass && previewWorstPass && finalP95Pass
                && finalImmutabilityPass
        )
        let full = FullReport(
            schemaVersion: 5,
            status: "diagnostic-only",
            note: "Diagnostic evidence only: Firefox audio is correlated with five anchors and L7 sessions additionally require continuous ScreenCaptureKit PTS, drained cursors, pinned models and append-only final indices. Last-speech matching remains a heuristic until annotations are human-reviewed.",
            corpusID: manifest.corpusID,
            provenance: provenance,
            alignment: alignment,
            coverage: auditCoverage,
            productionJapaneseCER: productionJapaneseCER,
            lastSpeech: lastSpeech,
            runtime: RuntimeEvidence(
                captureTiming: session.summary.captureTiming,
                maximumCombinedResidentBytes: session.maximumCombinedResidentBytes,
                maximumEndpointFIFOCount: session.maximumEndpointFIFOCount,
                endingEndpointFIFOCount: session.summary.endingEndpointFIFOCount,
                endingTranslationQueueCount: session.summary.endingTranslationQueueCount,
                sourceFinalizedThrough: session.summary.sourceFinalizedThrough,
                committedSampleCount: session.summary.committedSampleCount,
                previewFirstRevisionLatency: previewLatency,
                finalSpeechEndToRendered: finalLatency,
                slo: slo
            ),
            groups: auditGroups,
            unmatchedFragmentsByRole: unmatched
        )
        let blind = blindArtifacts(
            corpusID: manifest.corpusID,
            seed: UUID().uuidString,
            provenance: provenance,
            coverage: reviewCoverage,
            groups: reviewGroups
        )
        try write(
            full: full,
            blind: blind.report,
            key: blind.key,
            directory: sessionURL.deletingLastPathComponent(),
            stem: try outputStem(
                environment["WHISPERASR_JAPANESE_OFFLINE_OUTPUT_STEM"],
                sessionID: session.summary.sessionID
            )
        )
    }

    private func fragments(
        from metrics: [Metric],
        alignment: FirefoxCanonicalAudioAlignment.Result,
        canonicalCount: Int,
        text: KeyPath<Metric, String> = \.englishText
    ) -> [ManyToManyTurnScorer.Fragment] {
        metrics.enumerated().compactMap { index, metric in
            let start = min(canonicalCount, max(0,
                alignment.canonicalSample(forFirefoxSample: metric.rangeStart)))
            let end = min(canonicalCount, max(0,
                alignment.canonicalSample(forFirefoxSample: metric.rangeEnd)))
            guard end > start else { return nil }
            return .init(
                id: index + 1,
                startSample: start,
                endSample: end,
                text: metric[keyPath: text]
            )
        }
    }

    private func previewExtremes(_ metrics: [Metric]) -> (first: [Metric], last: [Metric]) {
        let groups = Dictionary(
            grouping: metrics.filter { $0.kind == "preview" },
            by: { $0.previewGeneration ?? $0.rangeStart }
        ).values.map { revisions in
            revisions.sorted {
                ($0.renderedUptimeNanoseconds, $0.revision ?? 0)
                    < ($1.renderedUptimeNanoseconds, $1.revision ?? 0)
            }
        }.sorted { $0[0].rangeStart < $1[0].rangeStart }
        return (
            groups.compactMap(\.first),
            groups.compactMap(\.last)
        )
    }

    private func lastSpeechEvidence(
        turn: ManyToManyTurnScorer.Turn,
        fragments: [ManyToManyTurnScorer.Fragment]
    ) -> LastSpeechEvidence {
        JapaneseBenchmarkSupport.lastSpeechEvidence(turn: turn, fragments: fragments)
    }

    private func finalSegmentIndicesProveAppendOnly(_ indices: [Int?]) -> Bool {
        !indices.isEmpty && indices.enumerated().allSatisfy {
            $0.element == $0.offset
        }
    }

    private func latencyEvidence(
        _ metrics: [Metric],
        value: KeyPath<Metric, Double?>
    ) -> LatencyEvidence {
        let values = metrics.compactMap { $0[keyPath: value] }.sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let rank = max(0, min(values.count - 1, Int(ceil(fraction * Double(values.count))) - 1))
            return values[rank]
        }
        return LatencyEvidence(
            count: values.count,
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            worstMilliseconds: values.last
        )
    }

    private func previewCoverage(
        turns: [ManyToManyTurnScorer.Turn],
        fragments: [ManyToManyTurnScorer.Fragment]
    ) -> PreviewCoverageEvidence {
        let primary = turns.filter { $0.confidence == "high" && !$0.overlap }
        let covered = primary.filter { turn in
            fragments.contains { fragment in
                !fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && max(turn.startSample, fragment.startSample)
                        < min(turn.endSample, fragment.endSample)
            }
        }.count
        return PreviewCoverageEvidence(
            coveredPrimaryTurns: covered,
            primaryTurnCount: primary.count,
            percent: primary.isEmpty ? 0 : 100 * Double(covered) / Double(primary.count)
        )
    }

    private func outputStem(_ requested: String?, sessionID: UUID) throws -> String {
        guard let requested, !requested.isEmpty else {
            return "local-captions-\(sessionID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        }
        guard requested == URL(fileURLWithPath: requested).lastPathComponent,
              requested.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw inputError("The requested report stem is not a safe local file name.")
        }
        return requested
    }

    private func coverage(
        groups: [ManyToManyTurnScorer.Group],
        sourceFragmentCounts: [String: Int] = [:]
    ) -> Coverage {
        Coverage(
            turnCount: groups.reduce(0) { $0 + $1.turnIDs.count },
            highConfidenceTurnCount: groups.reduce(0) { $0 + $1.highConfidenceTurnCount },
            diagnosticTurnCount: groups.reduce(0) { $0 + $1.diagnosticTurnCount },
            firstPreviewFragmentCount: sourceFragmentCounts["firstPreview"] ?? groups.reduce(0) { total, group in
                total + (group.candidates.first {
                    $0.role == "firstPreview"
                }?.fragmentIDs.count ?? 0)
            },
            lastPreviewFragmentCount: sourceFragmentCounts["lastPreview"] ?? groups.reduce(0) { total, group in
                total + (group.candidates.first {
                    $0.role == "lastPreview"
                }?.fragmentIDs.count ?? 0)
            },
            finalFragmentCount: sourceFragmentCounts["final"] ?? groups.reduce(0) { total, group in
                total + (group.candidates.first { $0.role == "final" }?.fragmentIDs.count ?? 0)
            },
            groupCount: groups.count
        )
    }

    private func blindArtifacts(
        corpusID: String,
        seed: String,
        provenance: Provenance,
        coverage: Coverage,
        groups: [ManyToManyTurnScorer.Group]
    ) -> (report: BlindReport, key: [String: String]) {
        var key: [String: String] = [:]
        let items = groups.map { group in
            let ordered = JapaneseBenchmarkSupport.blindOrder(
                group.candidates,
                seed: seed,
                itemID: group.id,
                identity: { $0.role }
            )
            let candidates = ordered.enumerated().map { index, candidate in
                let alias = String(UnicodeScalar(65 + index)!)
                key["\(group.id):\(alias)"] = candidate.role
                return BlindCandidate(
                    alias: alias,
                    english: candidate.text,
                    fidelityScore1To5: nil,
                    subtitleNaturalnessScore1To5: nil,
                    criticalError: nil,
                    preferred: nil,
                    judge: nil
                )
            }
            return BlindItem(
                groupID: group.id,
                turnIDs: group.turnIDs,
                highConfidenceTurnCount: group.highConfidenceTurnCount,
                diagnosticTurnCount: group.diagnosticTurnCount,
                referenceJapanese: group.referenceJapanese,
                candidates: candidates
            )
        }
        return (
            BlindReport(
                schemaVersion: 2,
                corpusID: corpusID,
                note: "Candidate identities are randomized independently per source-aware item with a secret stored only in the separate key. Judge fidelity and subtitle naturalness separately without opening the key. A caption crossing turns is repeated in every affected item; newlines separate fragments. High-confidence turns are primary; the other turns are diagnostics only.",
                provenance: provenance,
                coverage: coverage,
                items: items
            ),
            key
        )
    }

    private func write(
        full: FullReport,
        blind: BlindReport,
        key: [String: String],
        directory: URL,
        stem: String
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fullData = try encoder.encode(full)
        let blindData = try encoder.encode(blind)
        let keyData = try encoder.encode(KeyReport(
            schemaVersion: 1,
            blindSHA256: digest(blindData),
            aliases: key
        ))
        for (name, data) in [
            ("\(stem)-evaluation-full.json", fullData),
            ("\(stem)-evaluation-blind.json", blindData),
            ("\(stem)-evaluation-key.json", keyData),
        ] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            print("[JapaneseOfflineEvaluation] wrote \(url.path)")
        }
    }

    private func identity(_ url: URL) throws -> Identity {
        Identity(
            fileName: url.lastPathComponent,
            sha256: try JapaneseBenchmarkSupport.sha256(at: url)
        )
    }

    private func siblingArtifact(named name: String, beside sessionURL: URL) throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent else {
            throw inputError("Benchmark sidecar contains a non-local artifact path.")
        }
        let url = sessionURL.deletingLastPathComponent()
            .appendingPathComponent(name)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw inputError("Missing benchmark artifact: \(name)")
        }
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func syntheticSignal(count: Int) -> [Float] {
        var state: UInt32 = 0x1234_5678
        var amplitude: Float = 1
        return (0..<count).map { index in
            if index.isMultiple(of: 40) {
                state = state &* 1_664_525 &+ 1_013_904_223
                amplitude = 0.1 + 0.9 * Float(state & 0xffff) / Float(UInt16.max)
            }
            return amplitude * (
                sin(Float(index) * 0.071) + 0.4 * sin(Float(index) * 0.013)
            )
        }
    }

    private func resampled(
        _ source: [Float],
        offset: Int,
        scale: Double,
        trailing: Int
    ) -> [Float] {
        let count = offset + Int(Double(source.count) * scale) + trailing
        return (0..<count).map { index in
            let sourcePosition = (Double(index - offset)) / scale
            guard sourcePosition >= 0, sourcePosition < Double(source.count - 1) else { return 0 }
            let lower = Int(sourcePosition)
            let fraction = Float(sourcePosition - Double(lower))
            return source[lower] * (1 - fraction) + source[lower + 1] * fraction
        }
    }

    private func inputError(_ message: String) -> NSError {
        NSError(
            domain: "JapaneseOfflineEvaluation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
