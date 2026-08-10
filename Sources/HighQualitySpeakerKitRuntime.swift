import Foundation
import SpeakerKit

actor HighQualitySpeakerKitRuntime {
    enum Precision: String, Sendable {
        case quantized
        case full

        var segmenterVariant: String { self == .quantized ? "W8A16" : "W32A32" }
        var embedderVariant: String { self == .quantized ? "W8A16" : "W16A16" }
    }

    static let modelID = "argmaxinc/speakerkit-coreml"
    static let revision = "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
    static let declaredPeakMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    private let precision: Precision
    private let downloadBase: String?
    private var speakerKit: SpeakerKit?

    init(precision: Precision = .quantized, downloadBase: String? = nil) {
        self.precision = precision
        self.downloadBase = downloadBase
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard speakerKit == nil else { return }
        progress(
            0,
            "Downloading SpeakerKit segmenter \(precision.segmenterVariant) "
                + "and embedder \(precision.embedderVariant)…"
        )
        let config = PyannoteConfig(
            downloadBase: downloadBase,
            modelRepo: Self.modelID,
            downloadRevision: Self.revision,
            load: true,
            verbose: false
        )
        config.diarizer = SpeakerKitDiarizer.pyannote(
            config: config,
            segmenterModelInfo: .segmenter(variant: precision.segmenterVariant),
            embedderModelInfo: .embedder(variant: precision.embedderVariant)
        )
        speakerKit = try await SpeakerKit(config)
        try Task.checkCancellation()
        progress(
            1,
            "SpeakerKit ready: segmenter \(precision.segmenterVariant), "
                + "embedder \(precision.embedderVariant)"
        )
    }

    func diarize(
        samples: [Float],
        useExclusiveReconciliation: Bool = false
    ) async throws -> HighQualityDiarizationExchange {
        guard let speakerKit else {
            throw HighQualityJobError(
                stage: .diarization,
                message: "SpeakerKit is not loaded.",
                resultDirectory: nil
            )
        }
        let memorySampler = Task {
            var peak = WhisperKitRuntime.currentMemoryBytes()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                peak = max(peak, WhisperKitRuntime.currentMemoryBytes())
            }
            return max(peak, WhisperKitRuntime.currentMemoryBytes())
        }
        let result: DiarizationResult
        do {
            result = try await speakerKit.diarize(
                audioArray: samples,
                options: PyannoteDiarizationOptions(
                    useExclusiveReconciliation: useExclusiveReconciliation
                )
            )
        } catch {
            memorySampler.cancel()
            _ = await memorySampler.value
            throw error
        }
        memorySampler.cancel()
        let peakMemoryBytes = await memorySampler.value
        try Task.checkCancellation()
        return .init(
            spans: result.segments.flatMap { segment in
                segment.speaker.speakerIds.map {
                    .init(
                        speakerID: $0,
                        start: TimeInterval(segment.startTime),
                        end: TimeInterval(segment.endTime)
                    )
                }
            },
            modelID: Self.modelID,
            revision: Self.revision,
            peakMemoryBytes: peakMemoryBytes,
            useExclusiveReconciliation: useExclusiveReconciliation
        )
    }

    func unload() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }
}
