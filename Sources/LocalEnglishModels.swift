import Darwin
import Foundation
import Qwen3ASR
import SpeechVAD

private enum PrototypeModelID {
    static let qwen = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    static let qwenRevision = "e5450a26d1fd417c45fc9c405651ddc3180a27a6"
    static let fireRed = "aufklarer/FireRedVAD-CoreML"
    static let fireRedRevision = "1cb0565191fbdc630c2fe8f111ba31c392d05706"
}

private enum PrototypeRevisionGate {
    static func verify(modelID: String, expectedRevision: String) async throws {
        let key = "verifiedPrototypeRevision.\(modelID)"
        let data: Data
        let response: URLResponse
        do {
            let url = URL(string: "https://huggingface.co/api/models/\(modelID)")!
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            // Once the exact revision was audited online, cached models remain
            // usable offline. A first install still requires the revision check.
            guard UserDefaults.standard.string(forKey: key) == expectedRevision else { throw error }
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["sha"] as? String,
              revision == expectedRevision else {
            throw LocalPrototypeError.invalidDownload(modelID)
        }
        UserDefaults.standard.set(expectedRevision, forKey: key)
    }
}

enum LocalPrototypeError: LocalizedError {
    case modelNotLoaded(String)
    case memoryLimit(UInt64)
    case invalidDownload(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let name): return "\(name) is not loaded."
        case .memoryLimit(let bytes):
            return "The selected pipeline used \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)), above the 10 GB safety limit."
        case .invalidDownload(let name): return "The downloaded \(name) failed its SHA-256 check."
        case .invalidResponse: return "The local speech pipeline returned an invalid response."
        }
    }
}

/// Each non-thread-safe speech-swift model owns its own actor so capture and
/// endpoint detection remain independent from final Qwen decoding.
private actor FireRedVADRuntime {
    private var model: FireRedVADModel?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: PrototypeModelID.fireRed,
            expectedRevision: PrototypeModelID.fireRedRevision
        )
        let loaded = try await FireRedVADModel.fromPretrained(
            modelId: PrototypeModelID.fireRed
        ) { fraction, message in
            progress(fraction, "FireRedVAD: \(message)")
        }
        loaded.speechThreshold = 0.4
        loaded.smoothWindowSize = 5
        loaded.minSpeechDuration = 0.1
        loaded.minSilenceDuration = 0.1
        model = loaded
    }

    func detectSpeech(audio: [Float], windowStart: Int) throws -> [SpeechSampleRange] {
        guard let model else { throw LocalPrototypeError.modelNotLoaded("FireRedVAD") }
        return model.detectSpeech(audio: audio, sampleRate: 16_000).map {
            SpeechSampleRange(
                start: windowStart + Int((Double($0.startTime) * 16_000).rounded()),
                end: windowStart + Int((Double($0.endTime) * 16_000).rounded())
            )
        }
    }

    func unload() { model = nil }
}

private actor QwenRuntime {
    private var model: Qwen3ASRModel?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: PrototypeModelID.qwen,
            expectedRevision: PrototypeModelID.qwenRevision
        )
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: PrototypeModelID.qwen,
            progressHandler: progress
        )
        _ = loaded.transcribe(
            audio: [Float](repeating: 0, count: 16_000),
            sampleRate: 16_000,
            language: "Japanese",
            maxTokens: 16
        )
        model = loaded
    }

    func transcribe(audio: [Float], language: String) throws -> String {
        guard let model else { throw LocalPrototypeError.modelNotLoaded("Qwen3-ASR") }
        return model.transcribe(
            audio: audio,
            sampleRate: 16_000,
            language: language,
            maxTokens: 448
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        model?.unload()
        model = nil
    }
}

@MainActor
@Observable
final class LocalEnglishModelManager {
    private(set) var phases: [LocalEnglishEngine: LocalModelPhase] = [:]
    private(set) var loadedEngine: LocalEnglishEngine?
    private(set) var memoryWarning: String?

    @ObservationIgnored private let vad = FireRedVADRuntime()
    @ObservationIgnored private let qwen = QwenRuntime()
    nonisolated init() {}

    func phase(for engine: LocalEnglishEngine) -> LocalModelPhase {
        phases[engine] ?? .absent
    }

    func prepare(_ engine: LocalEnglishEngine) async throws {
        if loadedEngine == engine, phase(for: engine).isReady { return }
        await unload()
        phases[engine] = .downloading(progress: 0, message: "Checking local models…")

        let update: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor in
                self?.phases[engine] = .downloading(progress: progress, message: message)
            }
        }
        do {
            try await vad.prepare(progress: update)
            switch engine {
            case .whisperTurboApple:
                break
            case .qwenApple:
                phases[engine] = .loading(message: "Loading Qwen3-ASR…")
                try await qwen.prepare { fraction, message in
                    update(fraction, "Qwen: \(message)")
                }
            }

            let resident = Self.residentMemoryBytes()
            if resident > 10 * 1_024 * 1_024 * 1_024 {
                await unload()
                throw LocalPrototypeError.memoryLimit(resident)
            }
            memoryWarning = resident > 5 * 1_024 * 1_024 * 1_024
                ? "Process memory is above the 5 GB prototype target."
                : nil
            loadedEngine = engine
            phases[engine] = .ready(residentBytes: resident)
        } catch {
            await unloadRuntimes()
            loadedEngine = nil
            memoryWarning = nil
            phases[engine] = .failed(error.localizedDescription)
            throw error
        }
    }

    func detectSpeech(audio: [Float], windowStart: Int) async throws -> [SpeechSampleRange] {
        try await vad.detectSpeech(audio: audio, windowStart: windowStart)
    }

    func transcribeQwen(audio: [Float], language: String) async throws -> String {
        try await qwen.transcribe(audio: audio, language: language)
    }
    func unload() async {
        await unloadRuntimes()
        if let loadedEngine { phases[loadedEngine] = .absent }
        loadedEngine = nil
        memoryWarning = nil
    }

    func shutdown() async {
        await unloadRuntimes()
        loadedEngine = nil
    }

    private func unloadRuntimes() async {
        await vad.unload()
        await qwen.unload()
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
