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
        guard let manager else { throw LocalPrototypeError.modelNotLoaded("Parakeet JA") }
        if cancellable { try Task.checkCancellation() }
        var state = try TdtDecoderState(decoderLayers: 2)
        let rawTranscript = try await manager.transcribe(audio, decoderState: &state).text
        if cancellable { try Task.checkCancellation() }
        return preserveRawOutput
            ? rawTranscript
            : rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
