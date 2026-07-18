import Darwin
import Foundation
import MLX
import MLXAudioSTT
import Qwen3ASR
import SpeechVAD

private enum PrototypeModelID {
    static let qwen = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    static let qwenRevision = "e5450a26d1fd417c45fc9c405651ddc3180a27a6"
    static let fireRed = "aufklarer/FireRedVAD-CoreML"
    static let fireRedRevision = "1cb0565191fbdc630c2fe8f111ba31c392d05706"
    static let voxtral = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
    static let voxtralRevision = "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e"
    static let cohere = "beshkenadze/cohere-transcribe-03-2026-mlx-8bit"
    static let cohereRevision = "d1f843476f84846e6fe7aa58a6033f17882f0ec9"
    static let cohereQ6 = "beshkenadze/cohere-transcribe-03-2026-mlx-6bit"
    static let cohereQ6Revision = "c32249d0296705f198fc112b9232a2ba2b44ff11"
}

enum CoherePrototypeQuantization: String, Sendable {
    case q8
    case q6

    fileprivate var modelID: String {
        self == .q8 ? PrototypeModelID.cohere : PrototypeModelID.cohereQ6
    }

    fileprivate var revision: String {
        self == .q8 ? PrototypeModelID.cohereRevision : PrototypeModelID.cohereQ6Revision
    }
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
    case invalidModelChecksum(model: String, expected: String, actual: String)
    case invalidResponse
    case cursorMismatch(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let name): return "\(name) is not loaded."
        case .memoryLimit(let bytes):
            return "The selected pipeline used \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)), above the 10 GB safety limit."
        case .invalidDownload(let name): return "The configured \(name) revision no longer matches the audited revision."
        case .invalidModelChecksum(let model, let expected, let actual):
            return "\(model) failed SHA-256 verification (expected \(expected), got \(actual))."
        case .invalidResponse: return "The local speech pipeline returned an invalid response."
        case .cursorMismatch(let message): return message
        }
    }
}

/// Each model owns its own actor so capture and endpoint detection remain
/// independent from final decoding.
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
    private var model: Qwen3ASR.Qwen3ASRModel?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: PrototypeModelID.qwen,
            expectedRevision: PrototypeModelID.qwenRevision
        )
        let loaded = try await Qwen3ASR.Qwen3ASRModel.fromPretrained(
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

struct VoxtralStreamUpdate: Equatable, Sendable {
    let delta: String
    let transcript: String
    let isFinished: Bool
}

/// Owns the stateful Voxtral session. Phrase boundaries stay in AppState so
/// this actor has no authority over PCM validation or reclamation.
private actor VoxtralRuntime {
    private var model: VoxtralRealtimeModel?
    private var session: VoxtralRealtimeStreamSession?
    private var completedParts: [String] = []
    private var transcriptionDelayMs = 960

    func prepare() async throws {
        guard model == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: PrototypeModelID.voxtral,
            expectedRevision: PrototypeModelID.voxtralRevision
        )
        let loaded = try await VoxtralRealtimeModel.fromPretrained(PrototypeModelID.voxtral)

        // Exercise the exact online path before enabling Record.
        let warmup = loaded.makeStreamSession(
            temperature: 0,
            maxTokens: 16,
            transcriptionDelayMs: transcriptionDelayMs
        )
        _ = warmup.step([Float](repeating: 0, count: 16_000))
        _ = warmup.finish()
        model = loaded
        Memory.clearCache()
    }

    @discardableResult
    func start(replay: [Float] = []) throws -> String {
        guard let model else { throw LocalPrototypeError.modelNotLoaded("Voxtral Realtime") }
        session = model.makeStreamSession(
            temperature: 0,
            maxTokens: 4_096,
            transcriptionDelayMs: transcriptionDelayMs
        )
        completedParts.removeAll(keepingCapacity: true)
        guard !replay.isEmpty else { return "" }
        _ = session?.step(replay)
        return transcript
    }

    func step(samples: [Float]) throws -> VoxtralStreamUpdate {
        guard !samples.isEmpty else {
            return VoxtralStreamUpdate(
                delta: "",
                transcript: transcript,
                isFinished: session?.isFinished ?? false
            )
        }
        if session == nil { _ = try start() }
        guard let session else { throw LocalPrototypeError.modelNotLoaded("Voxtral Realtime") }
        let delta = session.step(samples)
        let finished = session.isFinished
        if session.isFinished {
            appendCompleted(session.text)
            guard let model else { throw LocalPrototypeError.modelNotLoaded("Voxtral Realtime") }
            self.session = model.makeStreamSession(
                temperature: 0,
                maxTokens: 4_096,
                transcriptionDelayMs: transcriptionDelayMs
            )
        }
        return VoxtralStreamUpdate(
            delta: delta.text,
            transcript: transcript,
            isFinished: finished
        )
    }

    func finish() throws -> String {
        guard let session else { return transcript }
        _ = session.finish()
        appendCompleted(session.text)
        self.session = nil
        let result = transcript
        completedParts.removeAll(keepingCapacity: true)
        Memory.clearCache()
        return result
    }

    func unload() {
        session = nil
        completedParts.removeAll()
        model = nil
        Memory.clearCache()
    }

    func setTranscriptionDelay(_ milliseconds: Int) throws {
        guard session == nil, milliseconds == 480 || milliseconds == 960 else {
            throw LocalPrototypeError.invalidResponse
        }
        transcriptionDelayMs = milliseconds
    }

    private var transcript: String {
        let current = session?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (completedParts + (current.isEmpty ? [] : [current]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendCompleted(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            completedParts.append(normalized)
        }
    }
}

private actor CohereRuntime {
    private var model: CohereTranscribeModel?
    private var quantization: CoherePrototypeQuantization = .q8

    func prepare() async throws {
        guard model == nil else { return }
        try await PrototypeRevisionGate.verify(
            modelID: quantization.modelID,
            expectedRevision: quantization.revision
        )
        let loaded = try await CohereTranscribeModel.fromPretrained(quantization.modelID)
        _ = loaded.generate(
            audio: MLXArray([Float](repeating: 0, count: 16_000)),
            generationParameters: parameters(maxTokens: 16)
        )
        model = loaded
        Memory.clearCache()
    }

    func transcribe(audio: [Float], language: String) throws -> String {
        guard let model else { throw LocalPrototypeError.modelNotLoaded("Cohere Transcribe") }
        guard !audio.isEmpty else { throw LocalPrototypeError.invalidResponse }
        let output = model.generate(
            audio: MLXArray(audio),
            generationParameters: parameters(maxTokens: 448, language: language)
        )
        Memory.clearCache()
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    func select(_ quantization: CoherePrototypeQuantization) {
        guard self.quantization != quantization else { return }
        model = nil
        self.quantization = quantization
        Memory.clearCache()
    }

    private func parameters(maxTokens: Int, language: String = "ja") -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: maxTokens,
            temperature: 0,
            topP: 1,
            topK: 0,
            verbose: false,
            language: language,
            chunkDuration: 30,
            minChunkDuration: 0.25
        )
    }
}

@MainActor
@Observable
final class LocalEnglishModelManager {
    private(set) var phases: [LocalEnglishEngine: LocalModelPhase] = [:]
    private(set) var loadedEngine: LocalEnglishEngine?
    private(set) var memoryWarning: String?
    private(set) var cohereQuantization: CoherePrototypeQuantization = .q8
    private(set) var continuousVoxtralConfiguration: VoxtralContinuousConfiguration = .default

    @ObservationIgnored private let vad = FireRedVADRuntime()
    @ObservationIgnored private let qwen = QwenRuntime()
    @ObservationIgnored private let voxtral = VoxtralRuntime()
    @ObservationIgnored private let voxtralHelper = VoxtralHelperRuntime()
    @ObservationIgnored private let cohere = CohereRuntime()
    nonisolated init() {}

    func phase(for engine: LocalEnglishEngine) -> LocalModelPhase {
        phases[engine] ?? .absent
    }

    func prepare(_ engine: LocalEnglishEngine) async throws {
        if loadedEngine == engine, phase(for: engine).isReady {
            guard engine.usesContinuousVoxtral else { return }
            if await continuousVoxtralIsReady() { return }
        }
        await unload()
        Memory.peakMemory = 0
        phases[engine] = .downloading(progress: 0, message: "Checking local models…")

        let update: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor in
                self?.phases[engine] = .downloading(progress: progress, message: message)
            }
        }
        do {
            try await vad.prepare(progress: update)
            switch engine {
            case .whisperTurboApple, .whisperLargeV3Direct:
                break
            case .qwenApple:
                phases[engine] = .loading(message: "Loading Qwen3-ASR…")
                try await qwen.prepare { fraction, message in
                    update(fraction, "Qwen: \(message)")
                }
            case .voxtralApple, .voxtralTurboApple:
                phases[engine] = .loading(
                    message: "Loading and warming continuous Voxtral \(continuousVoxtralConfiguration.model.displayName)…"
                )
                try await voxtralHelper.prepare(
                    configuration: continuousVoxtralConfiguration,
                    progress: update
                )
            case .voxtralQwenApple:
                phases[engine] = .loading(
                    message: "Loading and warming continuous Voxtral \(continuousVoxtralConfiguration.model.displayName)…"
                )
                try await voxtralHelper.prepare(
                    configuration: continuousVoxtralConfiguration,
                    progress: update
                )
                phases[engine] = .loading(message: "Loading Qwen3-ASR final…")
                try await qwen.prepare { fraction, message in
                    update(fraction, "Qwen: \(message)")
                }
            case .voxtralCohereApple:
                phases[engine] = .loading(message: "Loading and warming Voxtral Q4…")
                try await voxtral.prepare()
                phases[engine] = .loading(message: "Loading and warming Cohere Q8…")
                try await cohere.prepare()
            case .cohereApple:
                phases[engine] = .loading(message: "Loading and warming Cohere Q8…")
                try await cohere.prepare()
            }

            let helperResident = engine.usesContinuousVoxtral
                ? await voxtralHelper.progress().helperRSSBytes ?? 0
                : 0
            let resident = Self.measuredMemoryBytes() + helperResident
            if resident > 10 * 1_024 * 1_024 * 1_024 {
                await unload()
                throw LocalPrototypeError.memoryLimit(resident)
            }
            memoryWarning = resident > 8 * 1_024 * 1_024 * 1_024
                ? "Process memory is above the 8 GB live-caption target."
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

    func startVoxtral(replay: [Float] = []) async throws -> String {
        try await voxtral.start(replay: replay)
    }

    func feedVoxtral(samples: [Float]) async throws -> VoxtralStreamUpdate {
        try await voxtral.step(samples: samples)
    }

    func finishVoxtral() async throws -> String {
        try await voxtral.finish()
    }

    func startContinuousVoxtral() async throws -> AsyncStream<VoxtralHelperEvent> {
        try await voxtralHelper.startSession(
            delayMilliseconds: continuousVoxtralConfiguration.delay.rawValue
        )
    }

    func recoverContinuousVoxtral() async throws -> AsyncStream<VoxtralHelperEvent> {
        let previousProcess = await voxtralHelper.progress().helperProcessIdentifier
        await voxtralHelper.shutdown()
        try await voxtralHelper.prepare(configuration: continuousVoxtralConfiguration)
        let replacementProcess = await voxtralHelper.progress().helperProcessIdentifier
        guard let replacementProcess,
              previousProcess == nil || replacementProcess != previousProcess else {
            throw VoxtralHelperError.serverUnavailable(
                "Voxtral recovery did not start a fresh helper process."
            )
        }
        return try await voxtralHelper.startSession(
            delayMilliseconds: continuousVoxtralConfiguration.delay.rawValue
        )
    }

    func feedContinuousVoxtral(samples: [Float], range: Range<Int>) async throws {
        try await voxtralHelper.append(samples: samples, range: range)
    }

    func finishContinuousVoxtral() async throws -> String {
        try await voxtralHelper.stopAndFlush()
    }

    func cancelContinuousVoxtral() async {
        await voxtralHelper.cancel()
    }

    func continuousVoxtralProgress() async -> VoxtralHelperProgress {
        await voxtralHelper.progress()
    }

    func continuousVoxtralIsReady() async -> Bool {
        let processIdentifier = await voxtralHelper.progress().helperProcessIdentifier
        let helperStatus = await voxtralHelper.currentStatus()
        let helperConfiguration = await voxtralHelper.currentConfiguration()
        return processIdentifier != nil
            && helperConfiguration == continuousVoxtralConfiguration
            && (helperStatus == .ready || helperStatus == .streaming)
    }

    func selectContinuousVoxtralConfiguration(
        _ configuration: VoxtralContinuousConfiguration
    ) async {
        guard continuousVoxtralConfiguration != configuration else { return }
        await unload()
        continuousVoxtralConfiguration = configuration
    }

    func setVoxtralTranscriptionDelay(_ milliseconds: Int) async throws {
        try await voxtral.setTranscriptionDelay(milliseconds)
    }

    func selectCohereQuantization(_ quantization: CoherePrototypeQuantization) async {
        guard cohereQuantization != quantization else { return }
        await unload()
        cohereQuantization = quantization
        await cohere.select(quantization)
    }

    func transcribeCohere(audio: [Float], language: String = "ja") async throws -> String {
        try await cohere.transcribe(audio: audio, language: language)
    }

    /// Includes Metal allocations owned by MLX. `MACH_TASK_BASIC_INFO` alone
    /// under-reports unified-memory model weights on Apple Silicon.
    func currentMemoryBytes() -> UInt64 {
        Self.measuredMemoryBytes()
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
        await voxtral.unload()
        await voxtralHelper.shutdown()
        await cohere.unload()
    }

    private static func measuredMemoryBytes() -> UInt64 {
        let mlx = Memory.snapshot()
        let mlxCurrent = UInt64(max(0, mlx.activeMemory + mlx.cacheMemory))
        let mlxPeak = UInt64(max(0, mlx.peakMemory))

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let physicalFootprint = status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        return max(physicalFootprint, mlxCurrent, mlxPeak)
    }
}
