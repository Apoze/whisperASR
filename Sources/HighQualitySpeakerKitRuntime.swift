import Foundation
import SpeakerKit

actor HighQualitySpeakerKitRuntime {
    static let modelID = "argmaxinc/speakerkit-coreml"
    static let revision = "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
    static let declaredPeakMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    private var speakerKit: SpeakerKit?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard speakerKit == nil else { return }
        progress(0, "Downloading SpeakerKit…")
        speakerKit = try await SpeakerKit(PyannoteConfig(
            modelRepo: Self.modelID,
            downloadRevision: Self.revision,
            load: true,
            verbose: false
        ))
        try Task.checkCancellation()
        progress(1, "SpeakerKit ready")
    }

    func diarize(samples: [Float]) async throws -> HighQualityDiarizationExchange {
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
                options: PyannoteDiarizationOptions(useExclusiveReconciliation: false)
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
            peakMemoryBytes: peakMemoryBytes
        )
    }

    func unload() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }
}
