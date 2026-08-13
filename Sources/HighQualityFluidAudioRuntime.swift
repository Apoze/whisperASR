@preconcurrency import CoreML
import FluidAudio
import Foundation

actor HighQualityFluidAudioRuntime {
    static let modelID = "FluidInference/speaker-diarization-coreml/offline"
    static let repositoryID = "FluidInference/speaker-diarization-coreml"
    static let revision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
    static let runtimeRevision = "19600a485baa4998812e4654b70d2bab8f2c9949"
    static let declaredPeakMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    private let modelDirectory: URL
    private var manager: OfflineDiarizerManager?

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard manager == nil else { return }
        progress(0, "Preparing FluidAudio Offline diarization…")
        try await PrototypeRevisionGate.verify(
            modelID: Self.repositoryID,
            expectedRevision: Self.revision
        )
        let config = OfflineDiarizerConfig(
            clusteringThreshold: 0.60,
            segmentationStepRatio: 0.20,
            embeddingBatchSize: 32,
            embeddingExcludeOverlap: true,
            exclusiveSegments: false
        )
        let candidate = OfflineDiarizerManager(config: config)
        let coreML = MLModelConfiguration()
        coreML.computeUnits = .all
        try await candidate.prepareModels(directory: modelDirectory, configuration: coreML)
        try Task.checkCancellation()
        manager = candidate
        progress(1, "FluidAudio Offline ready")
    }

    func diarize(
        samples: [Float],
        useExclusiveReconciliation: Bool = false,
        speakerCountPolicy: HighQualitySpeakerCountPolicy = .automatic
    ) async throws -> HighQualityDiarizationExchange {
        guard let manager else {
            throw HighQualityJobError(
                stage: .diarization,
                message: "FluidAudio Offline is not loaded.",
                resultDirectory: nil
            )
        }
        guard speakerCountPolicy == .automatic, !useExclusiveReconciliation else {
            throw HighQualityJobError(
                stage: .diarization,
                message: "The frozen FluidAudio candidate requires automatic count and raw overlap.",
                resultDirectory: nil
            )
        }
        try Task.checkCancellation()
        let measured = try await HighQualityRuntimeMemorySampler.measure {
            try await manager.process(audio: samples)
        }
        let result: DiarizationResult = measured.value
        try Task.checkCancellation()
        return .init(
            spans: Self.spans(from: result.segments),
            modelID: Self.modelID,
            revision: Self.revision,
            peakMemoryBytes: measured.peakMemoryBytes,
            useExclusiveReconciliation: false,
            speakerCountPolicy: .automatic,
            configuration: [
                "engine": "fluid-audio-offline-vbx",
                "runtimeRevision": Self.runtimeRevision,
                "computeUnits": "all",
                "fbankComputeUnits": "cpuOnly",
                "clusteringThreshold": "0.6",
                "speakerCount": "automatic",
                "exclusiveSegments": "false",
                "embeddingExcludeOverlap": "true",
                "segmentationStepRatio": "0.2",
                "embeddingBatchSize": "32",
            ]
        )
    }

    func unload() {
        manager = nil
    }

    nonisolated static func spans(
        from segments: [TimedSpeakerSegment]
    ) -> [HighQualityDiarizationSpan] {
        let speakerIDs = Array(Set(segments.map(\.speakerId))).sorted()
        let indices = Dictionary(
            uniqueKeysWithValues: speakerIDs.enumerated().map { ($0.element, $0.offset) }
        )
        return segments.compactMap { segment in
            guard let speakerID = indices[segment.speakerId] else { return nil }
            return .init(
                speakerID: speakerID,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }
    }
}
