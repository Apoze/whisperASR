import Foundation
import FluidAudio

extension LocalPrototypeModelID {
    static let parakeet = "FluidInference/parakeet-0.6b-ja-coreml"
    static let parakeetRevision = "2952296ff1da4a6d6a7aec545e226367db80c612"
}

actor ParakeetRuntime {
    private var manager: AsrManager?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard manager == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: LocalPrototypeModelID.parakeet,
            expectedRevision: LocalPrototypeModelID.parakeetRevision
        )
        let models = try await AsrModels.downloadAndLoad(version: .tdtJa) {
            progress($0.fractionCompleted, "Parakeet JA")
        }
        manager = AsrManager(models: models)
    }

    func transcribe(
        audio: [Float],
        preserveRawOutput: Bool = false,
        cancellable: Bool = false
    ) async throws -> String {
        try await transcribeWithEvidence(
            audio: audio,
            preserveRawOutput: preserveRawOutput,
            cancellable: cancellable
        ).rawTranscript
    }

    func transcribeWithEvidence(
        audio: [Float],
        preserveRawOutput: Bool = false,
        cancellable: Bool = false
    ) async throws -> HighQualityASRExchange {
        guard let manager else { throw LocalPrototypeError.modelNotLoaded("Parakeet JA") }
        if cancellable { try Task.checkCancellation() }
        var state = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(audio, decoderState: &state)
        if cancellable { try Task.checkCancellation() }
        let transcript = preserveRawOutput
            ? result.text
            : result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            rawTranscript: transcript,
            chunks: [],
            tokenTimings: result.tokenTimings.map { timings in
                timings.map {
                    .init(
                        text: $0.token,
                        tokenIDs: [$0.tokenId],
                        sourceStart: $0.startTime,
                        sourceEnd: $0.endTime,
                        confidence: Double($0.confidence)
                    )
                }
            },
            confidence: Double(result.confidence),
            diagnostics: .init(
                emptyOutput: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        )
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
