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
        var rawAnchors: [(canonical: Int, firefox: Int, coarse: Double, sample: Double)] = []
        for match in coarseMatches {
            let canonicalStart = match.canonical * config.coarseHopSamples + refinementOffset
            let firefoxEstimate = match.firefox * config.coarseHopSamples + refinementOffset
            let reference = Array(canonical[canonicalStart..<(canonicalStart + refinementSamples)])
            let lower = max(0, firefoxEstimate - refinementRadius)
            let upper = min(firefox.count - refinementSamples, firefoxEstimate + refinementRadius)
            guard lower <= upper else {
                throw AlignmentError.invalid("Refined anchor falls outside Firefox audio.")
            }
            let refined = try bestMatch(anchor: reference, signal: firefox, starts: lower...upper)
            guard refined.score >= config.minimumCorrelation else {
                throw AlignmentError.invalid(
                    "Sample correlation \(refined.score) is below \(config.minimumCorrelation)."
                )
            }
            rawAnchors.append((canonicalStart, refined.start, match.score, refined.score))
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
                highConfidenceTurnCount: groupTurns.filter { $0.confidence == "high" }.count,
                diagnosticTurnCount: groupTurns.filter { $0.confidence != "high" }.count,
                referenceJapanese: groupTurns.map(\.japanese).joined(),
                candidates: candidates
            ))
        }
        return groups
    }

    private static func overlaps(_ turn: Turn, _ fragment: Fragment) -> Bool {
        max(turn.startSample, fragment.startSample) < min(turn.endSample, fragment.endSample)
    }
}

final class JapaneseOfflineEvaluationTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Fixture: Decodable { let sha256: String; let sampleCount: Int }
        struct Annotations: Decodable { let turns: [Turn] }
        struct Turn: Decodable {
            let id: Int
            let startSample: Int
            let endSample: Int
            let japanese: String
            let confidence: String
        }
        let corpusID: String
        let fixture: Fixture
        let annotations: Annotations
    }

    private struct Metric: Decodable {
        let kind: String
        let rangeStart: Int
        let rangeEnd: Int
        let englishText: String
        let revision: Int?
        let renderedUptimeNanoseconds: UInt64
    }

    private struct SessionReport: Decodable {
        struct Summary: Decodable { let sessionID: UUID }
        let summary: Summary
        let metricsFile: String
        let metricsSHA256: String
        let canonicalPCMFile: String?
        let canonicalPCMSHA256: String?
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
        let groups: [ManyToManyTurnScorer.Group]
    }

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
            provenance: Provenance(
                session: identity,
                manifest: identity,
                canonicalAudio: identity,
                firefoxAudio: identity,
                metrics: identity
            ),
            coverage: coverage,
            groups: groups
        )
        XCTAssertEqual(blind.report.items.count, 59)
        XCTAssertEqual(blind.key.count, 177)
        XCTAssertNotEqual(blind.key["1:A"], blind.key["2:A"])
    }

    func testGeneratePreviewFinalBlindReportWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sessionPath = environment["WHISPERASR_JAPANESE_OFFLINE_SESSION"] else {
            throw XCTSkip("Run Scripts/run_japanese_offline_evaluation.sh with a benchmark session sidecar.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let corpus = URL(fileURLWithPath: environment["WHISPERASR_JAPANESE_OFFLINE_CORPUS"]
            ?? root.appendingPathComponent(".build/benchmarks/corpora/easy-japanese-1").path)
        let manifestURL = corpus.appendingPathComponent("manifest.json")
        let canonicalURL = corpus.appendingPathComponent("audio-16k-mono.wav")
        let sessionURL = URL(fileURLWithPath: sessionPath).standardizedFileURL
        let session = try JSONDecoder().decode(
            SessionReport.self, from: Data(contentsOf: sessionURL)
        )
        let metricsURL = try siblingArtifact(
            named: session.metricsFile,
            beside: sessionURL
        )
        guard let canonicalPCMFile = session.canonicalPCMFile,
              let canonicalPCMSHA256 = session.canonicalPCMSHA256 else {
            throw inputError("Benchmark session has no canonical ScreenCaptureKit PCM proof.")
        }
        let firefoxURL = try siblingArtifact(named: canonicalPCMFile, beside: sessionURL)
        guard try sha256(metricsURL) == session.metricsSHA256,
              try sha256(firefoxURL) == canonicalPCMSHA256 else {
            throw inputError("Benchmark artifacts no longer match their session sidecar.")
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL)
        )
        guard manifest.annotations.turns.count == 59,
              manifest.annotations.turns.filter({ $0.confidence == "high" }).count == 46,
              manifest.annotations.turns.filter({ $0.confidence != "high" }).count == 13 else {
            throw inputError("Expected the reviewed 59-turn corpus (46 primary + 13 diagnostic).")
        }
        guard try sha256(canonicalURL) == manifest.fixture.sha256 else {
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
        let metrics = try JSONDecoder().decode([Metric].self, from: Data(contentsOf: metricsURL))
        guard metrics.allSatisfy({
            $0.rangeStart >= 0 && $0.rangeEnd >= $0.rangeStart && $0.rangeEnd <= firefox.count
        }) else {
            throw inputError("Metric ranges exceed the matching Firefox audio.")
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
        guard !firstPreview.isEmpty, !lastPreview.isEmpty, !final.isEmpty else {
            throw inputError("Metrics must contain first preview, last preview and final records.")
        }
        let turns = manifest.annotations.turns.map {
            ManyToManyTurnScorer.Turn(
                id: $0.id,
                confidence: $0.confidence,
                startSample: $0.startSample,
                endSample: $0.endSample,
                japanese: $0.japanese
            )
        }
        let groups = ManyToManyTurnScorer.groups(
            turns: turns,
            candidatesByRole: [
                "firstPreview": firstPreview,
                "lastPreview": lastPreview,
                "final": final,
            ]
        )
        let reportCoverage = coverage(groups: groups)
        guard reportCoverage.turnCount == 59,
              reportCoverage.highConfidenceTurnCount == 46,
              reportCoverage.diagnosticTurnCount == 13 else {
            throw inputError("Many-to-many grouping lost annotated turns.")
        }
        guard groups.allSatisfy({ group in
            group.candidates.first(where: { $0.role == "final" })?
                .hasUncoveredTurnGap == false
        }) else {
            throw inputError("Final metric ranges contain a hidden gap or overlap.")
        }
        let provenance = Provenance(
            session: try identity(sessionURL),
            manifest: try identity(manifestURL),
            canonicalAudio: try identity(canonicalURL),
            firefoxAudio: try identity(firefoxURL),
            metrics: try identity(metricsURL)
        )
        let full = FullReport(
            schemaVersion: 1,
            status: "diagnostic-only",
            note: "Offline evidence only. Firefox ranges were accepted after five-anchor audio correlation with <=20 ms drift; this report does not promote a product baseline.",
            corpusID: manifest.corpusID,
            provenance: provenance,
            alignment: alignment,
            coverage: reportCoverage,
            groups: groups
        )
        let blind = blindArtifacts(
            corpusID: manifest.corpusID,
            provenance: provenance,
            coverage: reportCoverage,
            groups: groups
        )
        try write(
            full: full,
            blind: blind.report,
            key: blind.key,
            directory: sessionURL.deletingLastPathComponent(),
            stem: "local-captions-\(session.summary.sessionID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        )
    }

    private func fragments(
        from metrics: [Metric],
        alignment: FirefoxCanonicalAudioAlignment.Result,
        canonicalCount: Int
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
                text: metric.englishText
            )
        }
    }

    private func previewExtremes(_ metrics: [Metric]) -> (first: [Metric], last: [Metric]) {
        let groups = Dictionary(
            grouping: metrics.filter { $0.kind == "preview" },
            by: \.rangeStart
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

    private func coverage(groups: [ManyToManyTurnScorer.Group]) -> Coverage {
        Coverage(
            turnCount: groups.reduce(0) { $0 + $1.turnIDs.count },
            highConfidenceTurnCount: groups.reduce(0) { $0 + $1.highConfidenceTurnCount },
            diagnosticTurnCount: groups.reduce(0) { $0 + $1.diagnosticTurnCount },
            firstPreviewFragmentCount: groups.reduce(0) { total, group in
                total + (group.candidates.first {
                    $0.role == "firstPreview"
                }?.fragmentIDs.count ?? 0)
            },
            lastPreviewFragmentCount: groups.reduce(0) { total, group in
                total + (group.candidates.first {
                    $0.role == "lastPreview"
                }?.fragmentIDs.count ?? 0)
            },
            finalFragmentCount: groups.reduce(0) { total, group in
                total + (group.candidates.first { $0.role == "final" }?.fragmentIDs.count ?? 0)
            },
            groupCount: groups.count
        )
    }

    private func blindArtifacts(
        corpusID: String,
        provenance: Provenance,
        coverage: Coverage,
        groups: [ManyToManyTurnScorer.Group]
    ) -> (report: BlindReport, key: [String: String]) {
        var key: [String: String] = [:]
        let items = groups.map { group in
            let shift = (group.id - 1) % group.candidates.count
            let candidates = group.candidates.indices.map { index in
                let candidate = group.candidates[(index + shift) % group.candidates.count]
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
                schemaVersion: 1,
                corpusID: corpusID,
                note: "Judge first preview, last preview and final for fidelity and subtitle naturalness without opening the separate key. High-confidence turns are primary; the 13 other turns are diagnostics only.",
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
        Identity(fileName: url.lastPathComponent, sha256: try sha256(url))
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

    private func sha256(_ url: URL) throws -> String {
        digest(try Data(contentsOf: url, options: .mappedIfSafe))
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
