import Darwin
import CoreML
import FluidAudio
import Foundation
import XCTest
@testable import WhisperASRApp

private enum DiarizationBakeoffCandidate: String, Codable, CaseIterable {
    case lsEEND = "ls-eend-dihard3-step100"
    case sortformerFast = "sortformer-fast-v2.1-fp16"
    case sortformerBalanced = "sortformer-balanced-v2.1-fp16"

    init(environmentValue: String?) throws {
        let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = Self(rawValue: value ?? Self.lsEEND.rawValue) else {
            throw DiarizationBakeoffError.unknownCandidate(value ?? "")
        }
        self = candidate
    }

    var sortformerConfig: SortformerConfig? {
        switch self {
        case .lsEEND:
            return nil
        case .sortformerFast:
            var config = SortformerConfig.fastV2_1
            config.precision = .fp16
            return config
        case .sortformerBalanced:
            var config = SortformerConfig.balancedV2_1
            config.precision = .fp16
            return config
        }
    }
}

private struct DiarizationBenchmarkManifest: Decodable {
    struct Fixture: Decodable {
        let sampleRate: Int
        let sampleCount: Int
        let scoredRange: [Int]?
    }

    struct Annotations: Decodable {
        let status: String?
        let events: [Event]
        let negativeRanges: [NegativeRange]?
    }

    struct Event: Decodable {
        let eventID: String
        let previousSpeechEndSample: Int?
        let nextSpeechStartSample: Int
        let overlapStartSample: Int?
        let overlapEndSample: Int?
        let kind: String
        let acceptableBreakRange: [Int]

        var breakRange: ClosedRange<Int>? {
            guard acceptableBreakRange.count == 2,
                  acceptableBreakRange[0] <= acceptableBreakRange[1] else { return nil }
            return acceptableBreakRange[0]...acceptableBreakRange[1]
        }

        var isOverlap: Bool {
            overlapStartSample != nil
                || overlapEndSample != nil
                || kind == "overlap"
                || kind == "interruption"
        }
    }

    struct NegativeRange: Decodable {
        let range: [Int]
        let reason: String?

        var samples: ClosedRange<Int>? {
            guard range.count == 2, range[0] <= range[1] else { return nil }
            return range[0]...range[1]
        }
    }

    let schemaVersion: Int
    let corpusID: String
    let fixture: Fixture
    let annotations: Annotations

    func validate(sampleCount actualSampleCount: Int) throws {
        guard schemaVersion == 1 else {
            throw DiarizationBakeoffError.unsupportedManifestVersion(schemaVersion)
        }
        guard fixture.sampleRate == 16_000,
              fixture.sampleCount == actualSampleCount else {
            throw DiarizationBakeoffError.fixtureMismatch
        }
        guard annotations.events.allSatisfy({ $0.breakRange != nil }) else {
            throw DiarizationBakeoffError.invalidBreakRange
        }
    }
}

private struct DiarizationBenchmarkTransition: Codable, Equatable {
    let changeSample: Int
    let modelConfirmedAtSample: Int
    let observedThroughSample: Int
    let confidence: Float
    let wasArmedByOverlap: Bool
}

private struct DiarizationRawArgmaxTransition: Codable, Equatable {
    let fromSpeaker: Int
    let toSpeaker: Int
    let changeSample: Int
    let observedThroughSample: Int
    let confidence: Float
}

private struct DiarizationChunkDiagnostic: Codable, Equatable {
    let receivedEndSample: Int
    let startFrame: Int
    let finalizedFrameCount: Int
    let finalizedEndSample: Int
    let finalizedEndIsWithinReceivedAudio: Bool
    let futureDriftSamples: Int

    init(
        receivedEndSample: Int,
        startFrame: Int,
        finalizedFrameCount: Int,
        frameDurationSeconds: Double
    ) {
        self.receivedEndSample = receivedEndSample
        self.startFrame = startFrame
        self.finalizedFrameCount = finalizedFrameCount
        finalizedEndSample = Int(
            (Double(startFrame + finalizedFrameCount) * frameDurationSeconds * 16_000)
                .rounded()
        )
        finalizedEndIsWithinReceivedAudio = finalizedEndSample <= receivedEndSample
        futureDriftSamples = max(0, finalizedEndSample - receivedEndSample)
    }
}

private struct DiarizationReplayDiagnostic: Codable, Equatable {
    let nativeArgmaxThreshold: Float
    let chunks: [DiarizationChunkDiagnostic]
    let rawArgmaxTransitions: [DiarizationRawArgmaxTransition]
    let rawArgmaxTransitionsAbsent: Bool
    let confirmedTransitionCount: Int
    let confirmedTransitionsAbsent: Bool
    let rawTransitionsSuppressedByReducer: Bool
    let allFinalizedFramesWithinReceivedAudio: Bool
    let timelineDriftDetected: Bool
    let maximumFutureDriftSamples: Int

    init(
        nativeArgmaxThreshold: Float,
        chunks: [DiarizationChunkDiagnostic],
        rawArgmaxTransitions: [DiarizationRawArgmaxTransition],
        confirmedTransitionCount: Int
    ) {
        self.nativeArgmaxThreshold = nativeArgmaxThreshold
        self.chunks = chunks
        self.rawArgmaxTransitions = rawArgmaxTransitions
        rawArgmaxTransitionsAbsent = rawArgmaxTransitions.isEmpty
        self.confirmedTransitionCount = confirmedTransitionCount
        confirmedTransitionsAbsent = confirmedTransitionCount == 0
        rawTransitionsSuppressedByReducer = !rawArgmaxTransitions.isEmpty
            && confirmedTransitionCount == 0
        allFinalizedFramesWithinReceivedAudio = chunks.allSatisfy(
            \.finalizedEndIsWithinReceivedAudio
        )
        maximumFutureDriftSamples = chunks.map(\.futureDriftSamples).max() ?? 0
        timelineDriftDetected = !allFinalizedFramesWithinReceivedAudio
    }
}

private struct DiarizationRawArgmaxTracker {
    let threshold: Float
    private var lastSpeaker: Int?

    init(threshold: Float) {
        self.threshold = threshold
        self.lastSpeaker = nil
    }

    mutating func consume(
        predictions: [Float],
        frameCount: Int,
        startFrame: Int,
        speakerCount: Int,
        frameDurationSeconds: Double,
        observedThroughSample: Int
    ) -> [DiarizationRawArgmaxTransition] {
        guard frameCount > 0,
              speakerCount > 0,
              predictions.count >= frameCount * speakerCount else { return [] }

        var transitions: [DiarizationRawArgmaxTransition] = []
        for frameOffset in 0..<frameCount {
            let base = frameOffset * speakerCount
            let dominant = (0..<speakerCount)
                .filter { predictions[base + $0] >= threshold }
                .max { predictions[base + $0] < predictions[base + $1] }
            guard let dominant else { continue }
            if let previous = lastSpeaker, previous != dominant {
                let frame = startFrame + frameOffset
                transitions.append(.init(
                    fromSpeaker: previous,
                    toSpeaker: dominant,
                    changeSample: Int(
                        (Double(frame) * frameDurationSeconds * 16_000).rounded()
                    ),
                    observedThroughSample: observedThroughSample,
                    confidence: predictions[base + dominant]
                ))
            }
            lastSpeaker = dominant
        }
        return transitions
    }
}

private struct DiarizationBenchmarkScore: Codable, Equatable {
    struct Match: Codable, Equatable {
        let eventID: String
        let referenceStartSample: Int
        let predictedChangeSample: Int
        let observedThroughSample: Int
        let detectionLatencyMilliseconds: Double
    }

    let referenceCount: Int
    let predictedCount: Int
    let annotationStatus: String
    let isPromotionEligibleReference: Bool
    let truePositiveCount: Int
    let falsePositiveCount: Int
    let missedCount: Int
    let precision: Double
    let recall: Double
    let clearTurnRecall: Double
    let overlapRecall: Double
    let falseTransitionsPerMinute: Double
    let falseTransitionsInNegativeRanges: Int
    let detectionLatencyP95Milliseconds: Double?
    let matches: [Match]
    let missedEventIDs: [String]
    let unmatchedPredictionSamples: [Int]
}

private enum DiarizationBenchmarkScorer {
    static func score(
        transitions: [DiarizationBenchmarkTransition],
        manifest: DiarizationBenchmarkManifest,
        sampleCount: Int
    ) -> DiarizationBenchmarkScore {
        let scoredRange = manifest.fixture.scoredRange.flatMap { range -> ClosedRange<Int>? in
            guard range.count == 2, range[0] <= range[1] else { return nil }
            return range[0]...range[1]
        } ?? 0...sampleCount
        let scoredTransitions = transitions.filter { scoredRange.contains($0.changeSample) }
        var unmatchedPredictions = Set(scoredTransitions.indices)
        var matches: [DiarizationBenchmarkScore.Match] = []
        var missed: [String] = []

        for event in manifest.annotations.events {
            guard let range = event.breakRange else {
                missed.append(event.eventID)
                continue
            }
            let midpoint = range.lowerBound + (range.upperBound - range.lowerBound) / 2
            let match = unmatchedPredictions
                .filter { range.contains(scoredTransitions[$0].changeSample) }
                .min {
                    abs(scoredTransitions[$0].changeSample - midpoint)
                        < abs(scoredTransitions[$1].changeSample - midpoint)
                }
            guard let match else {
                missed.append(event.eventID)
                continue
            }
            unmatchedPredictions.remove(match)
            let transition = scoredTransitions[match]
            matches.append(.init(
                eventID: event.eventID,
                referenceStartSample: event.nextSpeechStartSample,
                predictedChangeSample: transition.changeSample,
                observedThroughSample: transition.observedThroughSample,
                detectionLatencyMilliseconds: Double(
                    transition.observedThroughSample - event.nextSpeechStartSample
                ) / 16
            ))
        }

        let matchedIDs = Set(matches.map(\.eventID))
        let clearEvents = manifest.annotations.events.filter { !$0.isOverlap }
        let overlapEvents = manifest.annotations.events.filter(\.isOverlap)
        let falseSamples = unmatchedPredictions.map {
            scoredTransitions[$0].changeSample
        }.sorted()
        let negativeRanges = manifest.annotations.negativeRanges?.compactMap(\.samples) ?? []
        let truePositiveCount = matches.count
        let precisionDenominator = truePositiveCount + falseSamples.count
        let durationMinutes = Double(scoredRange.upperBound - scoredRange.lowerBound) / 16_000 / 60
        let latencies = matches.map(\.detectionLatencyMilliseconds)

        return DiarizationBenchmarkScore(
            referenceCount: manifest.annotations.events.count,
            predictedCount: scoredTransitions.count,
            annotationStatus: manifest.annotations.status ?? "unspecified",
            isPromotionEligibleReference: manifest.annotations.status == "complete",
            truePositiveCount: truePositiveCount,
            falsePositiveCount: falseSamples.count,
            missedCount: missed.count,
            precision: precisionDenominator > 0
                ? Double(truePositiveCount) / Double(precisionDenominator) : 0,
            recall: manifest.annotations.events.isEmpty
                ? 0 : Double(truePositiveCount) / Double(manifest.annotations.events.count),
            clearTurnRecall: recall(events: clearEvents, matchedIDs: matchedIDs),
            overlapRecall: recall(events: overlapEvents, matchedIDs: matchedIDs),
            falseTransitionsPerMinute: durationMinutes > 0
                ? Double(falseSamples.count) / durationMinutes : 0,
            falseTransitionsInNegativeRanges: falseSamples.filter { sample in
                negativeRanges.contains { $0.contains(sample) }
            }.count,
            detectionLatencyP95Milliseconds: percentile(latencies, 0.95),
            matches: matches.sorted { $0.referenceStartSample < $1.referenceStartSample },
            missedEventIDs: missed.sorted(),
            unmatchedPredictionSamples: falseSamples
        )
    }

    private static func recall(
        events: [DiarizationBenchmarkManifest.Event],
        matchedIDs: Set<String>
    ) -> Double {
        guard !events.isEmpty else { return 0 }
        return Double(events.filter { matchedIDs.contains($0.eventID) }.count)
            / Double(events.count)
    }

    static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }
}

private struct DiarizationBakeoffReport: Codable {
    struct Metadata: Codable {
        let candidate: DiarizationBakeoffCandidate
        let fluidAudioVersion: String
        let fluidAudioCommit: String
        let modelRepository: String
        let modelRevision: String
        let modelRevisionIsEnforcedByLoader: Bool
        let variant: String
        let precision: String
    }

    struct Replay: Codable {
        let index: Int
        let transitions: [DiarizationBenchmarkTransition]
        let discardedOutOfRangeTransitionCount: Int
        let overlapUpdateCount: Int
        let diagnostic: DiarizationReplayDiagnostic
        let processingP95Milliseconds: Double
        let processingWorstMilliseconds: Double
        let realTimeFactor: Double
        let residentBytes: UInt64
        let score: DiarizationBenchmarkScore?
    }

    let corpusID: String?
    let sampleCount: Int
    let blockSamples: Int
    let metadata: Metadata
    let replays: [Replay]
    let deterministicTransitionSamples: Bool
}

@MainActor
private enum DiarizationBakeoffRunner {
    static let blockSamples = 1_600
    static let fluidAudioCommit = "19600a485baa4998812e4654b70d2bab8f2c9949"
    static let sortformerRevisionObservedDuringImplementation =
        "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"

    static func run(
        candidate: DiarizationBakeoffCandidate,
        samples: [Float],
        replayCount: Int,
        manifest: DiarizationBenchmarkManifest?
    ) async throws -> DiarizationBakeoffReport {
        let replays: [DiarizationBakeoffReport.Replay]
        switch candidate {
        case .lsEEND:
            replays = try await runLSEEND(
                samples: samples,
                replayCount: replayCount,
                manifest: manifest
            )
        case .sortformerFast, .sortformerBalanced:
            replays = try await runSortformer(
                candidate: candidate,
                samples: samples,
                replayCount: replayCount,
                manifest: manifest
            )
        }

        let transitionSamples = replays.map { $0.transitions.map(\.changeSample) }
        return DiarizationBakeoffReport(
            corpusID: manifest?.corpusID,
            sampleCount: samples.count,
            blockSamples: blockSamples,
            metadata: metadata(for: candidate),
            replays: replays,
            deterministicTransitionSamples: Set(transitionSamples).count <= 1
        )
    }

    private static func runLSEEND(
        samples: [Float],
        replayCount: Int,
        manifest: DiarizationBenchmarkManifest?
    ) async throws -> [DiarizationBakeoffReport.Replay] {
        let modelStore = LocalDiarizationModelStore()
        let modelURL = try await modelStore.prepare()
        let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
        let diarizer = try LSEENDDiarizer(model: model)
        defer { diarizer.cleanup() }

        try warmUpLSEEND(diarizer, samples: samples)

        var result: [DiarizationBakeoffReport.Replay] = []
        for replay in 0..<replayCount {
            diarizer.reset()
            let resampler = PersistentDiarizationResampler()
            var reducer = LocalDiarizationReducer()
            var rawTracker = DiarizationRawArgmaxTracker(threshold: 0.50)
            var transitions: [DiarizationBenchmarkTransition] = []
            var rawTransitions: [DiarizationRawArgmaxTransition] = []
            var chunkDiagnostics: [DiarizationChunkDiagnostic] = []
            var overlapUpdateCount = 0
            var processingMilliseconds: [Double] = []
            let started = DispatchTime.now().uptimeNanoseconds

            for start in stride(from: 0, to: samples.count, by: blockSamples) {
                let end = min(samples.count, start + blockSamples)
                let blockStarted = DispatchTime.now().uptimeNanoseconds
                let downsampled = try resampler.append(Array(samples[start..<end]))
                if !downsampled.isEmpty,
                   let update = try diarizer.process(
                    samples: downsampled,
                    sourceSampleRate: nil
                   ) {
                    let batch = diagnose(
                        update,
                        diarizer: diarizer,
                        observedThroughSample: end,
                        reducer: &reducer,
                        rawTracker: &rawTracker
                    )
                    transitions.append(contentsOf: benchmarkTransitions(
                        batch.updates,
                        observedThroughSample: end
                    ))
                    rawTransitions.append(contentsOf: batch.rawTransitions)
                    chunkDiagnostics.append(batch.chunk)
                    overlapUpdateCount += batch.updates.filter {
                        !$0.overlappingSpeakers.isEmpty
                    }.count
                }
                processingMilliseconds.append(milliseconds(since: blockStarted))
            }
            let resamplerTail = try resampler.finish()
            if !resamplerTail.isEmpty,
               let update = try diarizer.process(
                samples: resamplerTail,
                sourceSampleRate: nil
               ) {
                let batch = diagnose(
                    update,
                    diarizer: diarizer,
                    observedThroughSample: samples.count,
                    reducer: &reducer,
                    rawTracker: &rawTracker
                )
                transitions.append(contentsOf: benchmarkTransitions(
                    batch.updates,
                    observedThroughSample: samples.count
                ))
                rawTransitions.append(contentsOf: batch.rawTransitions)
                chunkDiagnostics.append(batch.chunk)
                overlapUpdateCount += batch.updates.filter {
                    !$0.overlappingSpeakers.isEmpty
                }.count
            }
            if let update = try diarizer.finalizeSession() {
                let batch = diagnose(
                    update,
                    diarizer: diarizer,
                    observedThroughSample: samples.count,
                    reducer: &reducer,
                    rawTracker: &rawTracker
                )
                transitions.append(contentsOf: benchmarkTransitions(
                    batch.updates,
                    observedThroughSample: samples.count
                ))
                rawTransitions.append(contentsOf: batch.rawTransitions)
                chunkDiagnostics.append(batch.chunk)
                overlapUpdateCount += batch.updates.filter {
                    !$0.overlappingSpeakers.isEmpty
                }.count
            }
            result.append(replayReport(
                index: replay,
                samples: samples,
                started: started,
                transitions: transitions,
                rawTransitions: rawTransitions,
                nativeArgmaxThreshold: rawTracker.threshold,
                chunkDiagnostics: chunkDiagnostics,
                overlaps: overlapUpdateCount,
                processingMilliseconds: processingMilliseconds,
                manifest: manifest
            ))
        }
        return result
    }

    private static func runSortformer(
        candidate: DiarizationBakeoffCandidate,
        samples: [Float],
        replayCount: Int,
        manifest: DiarizationBenchmarkManifest?
    ) async throws -> [DiarizationBakeoffReport.Replay] {
        guard let config = candidate.sortformerConfig else {
            throw DiarizationBakeoffError.unknownCandidate(candidate.rawValue)
        }
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        timelineConfig.storeSegments = false
        timelineConfig.maxStoredFrames = 0
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        diarizer.initialize(models: models)
        defer { diarizer.cleanup() }

        try warmUpSortformer(diarizer, samples: samples)

        var result: [DiarizationBakeoffReport.Replay] = []
        for replay in 0..<replayCount {
            diarizer.reset()
            var reducer = LocalDiarizationReducer(
                speakerActivationThreshold: config.predScoreThreshold,
                speakerDeactivationThreshold: min(0.20, config.predScoreThreshold),
                newDominantThreshold: config.predScoreThreshold,
                dominanceMargin: 0.10
            )
            var rawTracker = DiarizationRawArgmaxTracker(
                threshold: config.predScoreThreshold
            )
            var transitions: [DiarizationBenchmarkTransition] = []
            var rawTransitions: [DiarizationRawArgmaxTransition] = []
            var chunkDiagnostics: [DiarizationChunkDiagnostic] = []
            var overlapUpdateCount = 0
            var processingMilliseconds: [Double] = []
            let started = DispatchTime.now().uptimeNanoseconds

            for start in stride(from: 0, to: samples.count, by: blockSamples) {
                let end = min(samples.count, start + blockSamples)
                let blockStarted = DispatchTime.now().uptimeNanoseconds
                if let update = try diarizer.process(
                    samples: samples[start..<end],
                    sourceSampleRate: nil
                ) {
                    let batch = diagnose(
                        update,
                        diarizer: diarizer,
                        observedThroughSample: end,
                        reducer: &reducer,
                        rawTracker: &rawTracker
                    )
                    transitions.append(contentsOf: benchmarkTransitions(
                        batch.updates,
                        observedThroughSample: end
                    ))
                    rawTransitions.append(contentsOf: batch.rawTransitions)
                    chunkDiagnostics.append(batch.chunk)
                    overlapUpdateCount += batch.updates.filter {
                        !$0.overlappingSpeakers.isEmpty
                    }.count
                }
                processingMilliseconds.append(milliseconds(since: blockStarted))
            }
            if let update = try diarizer.finalizeSession() {
                let batch = diagnose(
                    update,
                    diarizer: diarizer,
                    observedThroughSample: samples.count,
                    reducer: &reducer,
                    rawTracker: &rawTracker
                )
                transitions.append(contentsOf: benchmarkTransitions(
                    batch.updates,
                    observedThroughSample: samples.count
                ))
                rawTransitions.append(contentsOf: batch.rawTransitions)
                chunkDiagnostics.append(batch.chunk)
                overlapUpdateCount += batch.updates.filter {
                    !$0.overlappingSpeakers.isEmpty
                }.count
            }
            result.append(replayReport(
                index: replay,
                samples: samples,
                started: started,
                transitions: transitions,
                rawTransitions: rawTransitions,
                nativeArgmaxThreshold: rawTracker.threshold,
                chunkDiagnostics: chunkDiagnostics,
                overlaps: overlapUpdateCount,
                processingMilliseconds: processingMilliseconds,
                manifest: manifest
            ))
        }
        return result
    }

    private static func warmUpLSEEND(
        _ diarizer: LSEENDDiarizer,
        samples: [Float]
    ) throws {
        diarizer.reset()
        let resampler = PersistentDiarizationResampler()
        let count = min(samples.count, 32_000)
        for start in stride(from: 0, to: count, by: blockSamples) {
            let end = min(count, start + blockSamples)
            let downsampled = try resampler.append(Array(samples[start..<end]))
            if !downsampled.isEmpty {
                _ = try diarizer.process(samples: downsampled, sourceSampleRate: nil)
            }
        }
        let tail = try resampler.finish()
        if !tail.isEmpty {
            _ = try diarizer.process(samples: tail, sourceSampleRate: nil)
        }
        _ = try diarizer.finalizeSession()
        diarizer.reset()
    }

    private static func warmUpSortformer(
        _ diarizer: SortformerDiarizer,
        samples: [Float]
    ) throws {
        diarizer.reset()
        let count = min(samples.count, 32_000)
        for start in stride(from: 0, to: count, by: blockSamples) {
            let end = min(count, start + blockSamples)
            _ = try diarizer.process(
                samples: samples[start..<end],
                sourceSampleRate: nil
            )
        }
        _ = try diarizer.finalizeSession()
        diarizer.reset()
    }

    private static func diagnose(
        _ update: DiarizerTimelineUpdate,
        diarizer: any Diarizer,
        observedThroughSample: Int,
        reducer: inout LocalDiarizationReducer,
        rawTracker: inout DiarizationRawArgmaxTracker
    ) -> (
        updates: [LocalDiarizationUpdate],
        rawTransitions: [DiarizationRawArgmaxTransition],
        chunk: DiarizationChunkDiagnostic
    ) {
        let chunk = update.chunkResult
        let frameDuration = diarizer.modelFrameHz.map { 1.0 / $0 } ?? 0.08
        let speakerCount = diarizer.numSpeakers ?? 0
        let updates = reducer.consume(
            predictions: chunk.finalizedPredictions,
            frameCount: chunk.finalizedFrameCount,
            startFrame: chunk.startFrame,
            speakerCount: speakerCount,
            frameDurationSeconds: frameDuration
        )
        let rawTransitions = rawTracker.consume(
            predictions: chunk.finalizedPredictions,
            frameCount: chunk.finalizedFrameCount,
            startFrame: chunk.startFrame,
            speakerCount: speakerCount,
            frameDurationSeconds: frameDuration,
            observedThroughSample: observedThroughSample
        )
        return (
            updates,
            rawTransitions,
            DiarizationChunkDiagnostic(
                receivedEndSample: observedThroughSample,
                startFrame: chunk.startFrame,
                finalizedFrameCount: chunk.finalizedFrameCount,
                frameDurationSeconds: frameDuration
            )
        )
    }

    private static func benchmarkTransitions(
        _ updates: [LocalDiarizationUpdate],
        observedThroughSample: Int
    ) -> [DiarizationBenchmarkTransition] {
        updates.compactMap(\.transition).map {
            DiarizationBenchmarkTransition(
                changeSample: $0.changeSample,
                modelConfirmedAtSample: $0.confirmedAtSample,
                observedThroughSample: observedThroughSample,
                confidence: $0.confidence,
                wasArmedByOverlap: $0.wasArmedByOverlap
            )
        }
    }

    private static func replayReport(
        index: Int,
        samples: [Float],
        started: UInt64,
        transitions: [DiarizationBenchmarkTransition],
        rawTransitions: [DiarizationRawArgmaxTransition],
        nativeArgmaxThreshold: Float,
        chunkDiagnostics: [DiarizationChunkDiagnostic],
        overlaps: Int,
        processingMilliseconds: [Double],
        manifest: DiarizationBenchmarkManifest?
    ) -> DiarizationBakeoffReport.Replay {
        let audioSeconds = Double(samples.count) / 16_000
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - started)
            / 1_000_000_000
        let validTransitions = transitions.filter {
            (0..<samples.count).contains($0.changeSample)
        }
        return .init(
            index: index,
            transitions: validTransitions,
            discardedOutOfRangeTransitionCount: transitions.count - validTransitions.count,
            overlapUpdateCount: overlaps,
            diagnostic: DiarizationReplayDiagnostic(
                nativeArgmaxThreshold: nativeArgmaxThreshold,
                chunks: chunkDiagnostics,
                rawArgmaxTransitions: rawTransitions,
                confirmedTransitionCount: transitions.count
            ),
            processingP95Milliseconds: DiarizationBenchmarkScorer.percentile(
                processingMilliseconds,
                0.95
            ) ?? 0,
            processingWorstMilliseconds: processingMilliseconds.max() ?? 0,
            realTimeFactor: audioSeconds > 0 ? elapsedSeconds / audioSeconds : .infinity,
            residentBytes: currentPhysicalFootprint(),
            score: manifest.map {
                DiarizationBenchmarkScorer.score(
                    transitions: validTransitions,
                    manifest: $0,
                    sampleCount: samples.count
                )
            }
        )
    }

    private static func metadata(
        for candidate: DiarizationBakeoffCandidate
    ) -> DiarizationBakeoffReport.Metadata {
        switch candidate {
        case .lsEEND:
            return .init(
                candidate: candidate,
                fluidAudioVersion: LocalDiarizationModelManifest.fluidAudioVersion,
                fluidAudioCommit: fluidAudioCommit,
                modelRepository: LocalDiarizationModelManifest.repository,
                modelRevision: LocalDiarizationModelManifest.revision,
                modelRevisionIsEnforcedByLoader: true,
                variant: "DIHARD3 step100",
                precision: "compiled Core ML"
            )
        case .sortformerFast, .sortformerBalanced:
            return .init(
                candidate: candidate,
                fluidAudioVersion: LocalDiarizationModelManifest.fluidAudioVersion,
                fluidAudioCommit: fluidAudioCommit,
                modelRepository: "FluidInference/diar-streaming-sortformer-coreml",
                modelRevision: sortformerRevisionObservedDuringImplementation,
                modelRevisionIsEnforcedByLoader: false,
                variant: candidate == .sortformerFast ? "fastV2_1" : "balancedV2_1",
                precision: "fp16"
            )
        }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func currentPhysicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

private enum DiarizationBakeoffError: LocalizedError {
    case unknownCandidate(String)
    case unsupportedManifestVersion(Int)
    case invalidBreakRange
    case fixtureMismatch

    var errorDescription: String? {
        switch self {
        case .unknownCandidate(let value):
            return "Unknown diarization candidate: \(value)"
        case .unsupportedManifestVersion(let version):
            return "Unsupported diarization manifest schema version: \(version)"
        case .invalidBreakRange:
            return "Every diarization annotation needs a valid two-sample acceptableBreakRange"
        case .fixtureMismatch:
            return "The diarization manifest does not describe the selected 16 kHz PCM fixture"
        }
    }
}

final class DiarizationBakeoffTests: XCTestCase {
    func testRawArgmaxDiagnosticPreservesSpeakerAcrossSilence() {
        var tracker = DiarizationRawArgmaxTracker(threshold: 0.50)

        let transitions = tracker.consume(
            predictions: [
                0.80, 0.10,
                0.10, 0.10,
                0.20, 0.75,
            ],
            frameCount: 3,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1,
            observedThroughSample: 6_400
        )

        XCTAssertEqual(transitions, [DiarizationRawArgmaxTransition(
            fromSpeaker: 0,
            toSpeaker: 1,
            changeSample: 3_200,
            observedThroughSample: 6_400,
            confidence: 0.75
        )])
    }

    func testDiagnosticMakesTimelineDriftAndRawAbsenceExplicit() {
        let chunk = DiarizationChunkDiagnostic(
            receivedEndSample: 15_000,
            startFrame: 10,
            finalizedFrameCount: 2,
            frameDurationSeconds: 0.08
        )
        let diagnostic = DiarizationReplayDiagnostic(
            nativeArgmaxThreshold: 0.25,
            chunks: [chunk],
            rawArgmaxTransitions: [],
            confirmedTransitionCount: 0
        )

        XCTAssertEqual(chunk.finalizedEndSample, 15_360)
        XCTAssertFalse(chunk.finalizedEndIsWithinReceivedAudio)
        XCTAssertEqual(chunk.futureDriftSamples, 360)
        XCTAssertFalse(diagnostic.allFinalizedFramesWithinReceivedAudio)
        XCTAssertTrue(diagnostic.timelineDriftDetected)
        XCTAssertEqual(diagnostic.maximumFutureDriftSamples, 360)
        XCTAssertTrue(diagnostic.rawArgmaxTransitionsAbsent)
        XCTAssertTrue(diagnostic.confirmedTransitionsAbsent)
        XCTAssertFalse(diagnostic.rawTransitionsSuppressedByReducer)
    }

    func testScorerMatchesEachPredictionAtMostOnceAndCountsFalseChanges() throws {
        let manifestData = Data(#"""
        {
          "schemaVersion": 1,
          "corpusID": "unit",
          "fixture": {"sampleRate": 16000, "sampleCount": 960000},
          "annotations": {
            "events": [
              {"eventID":"a", "nextSpeechStartSample":1000, "kind":"gapless", "acceptableBreakRange":[900,1100]},
              {"eventID":"b", "nextSpeechStartSample":3000, "overlapStartSample":2900, "kind":"overlap", "acceptableBreakRange":[2800,3200]}
            ],
            "negativeRanges": [{"range":[7000,9000], "reason":"music"}]
          }
        }
        """#.utf8)
        let manifest = try JSONDecoder().decode(
            DiarizationBenchmarkManifest.self,
            from: manifestData
        )
        let transitions = [
            DiarizationBenchmarkTransition(
                changeSample: 1_000,
                modelConfirmedAtSample: 1_100,
                observedThroughSample: 2_600,
                confidence: 0.9,
                wasArmedByOverlap: false
            ),
            DiarizationBenchmarkTransition(
                changeSample: 3_100,
                modelConfirmedAtSample: 3_200,
                observedThroughSample: 4_600,
                confidence: 0.8,
                wasArmedByOverlap: true
            ),
            DiarizationBenchmarkTransition(
                changeSample: 8_000,
                modelConfirmedAtSample: 8_100,
                observedThroughSample: 9_600,
                confidence: 0.7,
                wasArmedByOverlap: false
            ),
        ]

        let score = DiarizationBenchmarkScorer.score(
            transitions: transitions,
            manifest: manifest,
            sampleCount: 960_000
        )

        XCTAssertEqual(score.truePositiveCount, 2)
        XCTAssertEqual(score.falsePositiveCount, 1)
        XCTAssertEqual(score.missedCount, 0)
        XCTAssertEqual(score.precision, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.recall, 1)
        XCTAssertEqual(score.clearTurnRecall, 1)
        XCTAssertEqual(score.overlapRecall, 1)
        XCTAssertEqual(score.falseTransitionsPerMinute, 1)
        XCTAssertEqual(score.falseTransitionsInNegativeRanges, 1)
        XCTAssertEqual(score.detectionLatencyP95Milliseconds, 100)
    }

    func testCandidateNamesAreExplicitAndBalancedIsNotTheDefault() throws {
        XCTAssertEqual(
            try DiarizationBakeoffCandidate(environmentValue: nil),
            .lsEEND
        )
        XCTAssertEqual(
            try DiarizationBakeoffCandidate(environmentValue: "sortformer-fast-v2.1-fp16"),
            .sortformerFast
        )
        XCTAssertThrowsError(
            try DiarizationBakeoffCandidate(environmentValue: "sortformer")
        )
    }

    @MainActor
    func testOptInReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let wavPath = environment["WHISPERASR_DIARIZATION_BENCHMARK_WAV"],
              !wavPath.isEmpty else {
            throw XCTSkip("Set WHISPERASR_DIARIZATION_BENCHMARK_WAV to run the shadow bakeoff")
        }
        let candidate = try DiarizationBakeoffCandidate(
            environmentValue: environment["WHISPERASR_DIARIZATION_CANDIDATE"]
        )
        let replayCount = max(
            1,
            Int(environment["WHISPERASR_DIARIZATION_REPLAY_COUNT"] ?? "1") ?? 1
        )
        let samples = try await AudioLoader.loadSamples(
            url: URL(fileURLWithPath: wavPath)
        )
        let manifest: DiarizationBenchmarkManifest?
        if let path = environment["WHISPERASR_DIARIZATION_BENCHMARK_MANIFEST"],
           !path.isEmpty {
            manifest = try JSONDecoder().decode(
                DiarizationBenchmarkManifest.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
            try manifest?.validate(sampleCount: samples.count)
        } else {
            manifest = nil
        }

        let report = try await DiarizationBakeoffRunner.run(
            candidate: candidate,
            samples: samples,
            replayCount: replayCount,
            manifest: manifest
        )
        let output = environment["WHISPERASR_DIARIZATION_BENCHMARK_OUTPUT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    ".build/benchmarks/diarization-\(candidate.rawValue)-"
                        + "\(URL(fileURLWithPath: wavPath).deletingPathExtension().lastPathComponent).json"
                )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)

        XCTAssertEqual(report.replays.count, replayCount)
        XCTAssertEqual(report.sampleCount, samples.count)
        XCTAssertTrue(report.replays.allSatisfy { $0.realTimeFactor.isFinite })
        let diagnostic = report.replays[0].diagnostic
        print(
            "Diarization \(candidate.rawValue): "
                + "\(diagnostic.confirmedTransitionCount) confirmed, "
                + "\(diagnostic.rawArgmaxTransitions.count) raw, "
                + "future drift \(diagnostic.maximumFutureDriftSamples) samples; "
                + output.path
        )
    }
}
