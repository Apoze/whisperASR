import Darwin
import Foundation
import WhisperKit

extension LocalPrototypeModelID {
    static let whisperKitRepository = "argmaxinc/whisperkit-coreml"
    static let whisperKitVariant = "openai_whisper-large-v3"
    static let whisperKitEvidenceModelID = "\(whisperKitRepository)/\(whisperKitVariant)"
    static let whisperKitModelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    static let whisperKitRuntimeVersion = "1.1.0"
}

actor WhisperKitRuntime {
    private var pipeline: WhisperKit?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard pipeline == nil else { return }
        let snapshot = try await HubApiWrapper(downloadBase: ModelCatalog.modelDirectory)
            .snapshot(
                from: .init(id: LocalPrototypeModelID.whisperKitRepository),
                revision: LocalPrototypeModelID.whisperKitModelRevision,
                matching: ["\(LocalPrototypeModelID.whisperKitVariant)/*"],
                progressHandler: {
                    progress($0.fractionCompleted * 0.9, "WhisperKit large-v3: downloading")
                }
            )
        try Task.checkCancellation()
        progress(0.9, "WhisperKit large-v3: loading")
        let loaded = try await WhisperKit(WhisperKitConfig(
            model: LocalPrototypeModelID.whisperKitVariant,
            downloadBase: ModelCatalog.modelDirectory,
            modelFolder: snapshot.appendingPathComponent(
                LocalPrototypeModelID.whisperKitVariant,
                isDirectory: true
            ).path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        do {
            try Task.checkCancellation()
        } catch {
            await loaded.unloadModels()
            throw error
        }
        pipeline = loaded
        progress(1, "WhisperKit large-v3: ready")
    }

    func transcribe(audio: [Float]) async throws -> String {
        guard let pipeline else {
            throw LocalPrototypeError.modelNotLoaded("WhisperKit large-v3")
        }
        try Task.checkCancellation()
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: DecodingOptions(task: .transcribe, language: "ja"),
            callback: { _ in !Task.isCancelled }
        )
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ")
    }

    func unload() async {
        await pipeline?.unloadModels()
        pipeline = nil
    }

    nonisolated static func currentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(max(0, info.phys_footprint)) : 0
    }
}
