import Foundation
import CWhisper

enum WhisperDecodingStrategy: String, Sendable {
    case greedy
    case beam5
}

final class TranscriptionService: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    /// Serial queue to ensure only one whisper_full() runs at a time (ctx is not thread-safe).
    private let whisperQueue = DispatchQueue(label: "com.whisperasr.whisper", qos: .userInitiated)
    private let realtimeLock = NSLock()
    private var realtimeSessionActive = false

    var isRealtimeSessionActive: Bool {
        realtimeLock.withLock { realtimeSessionActive }
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func shutdown() {
        // Serialize with any in-flight whisper_full; if the process exits before
        // this runs the OS reclaims the context anyway.
        whisperQueue.async {
            if let ctx = self.ctx {
                whisper_free(ctx)
                self.ctx = nil
                self.loadedModelPath = nil
            }
        }
    }

    /// Release the resident Whisper context when another exclusive local
    /// English prototype is selected. Serialized with inference so a model is
    /// never freed while whisper_full is using it.
    func unloadModel() async {
        await withCheckedContinuation { continuation in
            whisperQueue.async {
                if let ctx = self.ctx {
                    whisper_free(ctx)
                    self.ctx = nil
                    self.loadedModelPath = nil
                }
                continuation.resume()
            }
        }
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    modelPath: String? = nil,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        guard !isRealtimeSessionActive else { throw TranscriptionError.modelBusy }
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        guard !isRealtimeSessionActive else { throw TranscriptionError.modelBusy }

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
                let ctx: OpaquePointer
                do {
                    ctx = try self.ensureModelLoaded(modelPath: modelPath)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var (params, langCStr) = self.makeBaseParams(language: language, translate: translate)
                defer { free(langCStr) }

                // Progress callback
                let progressPtr = Unmanaged.passRetained(ProgressBox(handler: onProgress)).toOpaque()
                params.progress_callback_user_data = progressPtr
                params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, progress: Int32, userData: UnsafeMutableRawPointer?) in
                    guard let userData else { return }
                    let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
                    let value = Double(progress) / 100.0
                    DispatchQueue.main.async {
                        box.handler(value)
                    }
                }

                // Run transcription
                let result = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }

                // Release progress box
                Unmanaged<ProgressBox>.fromOpaque(progressPtr).release()

                if result != 0 {
                    continuation.resume(throwing: TranscriptionError.processFailed("whisper_full returned error \(result)"))
                    return
                }

                // Extract segments
                let nSegments = whisper_full_n_segments(ctx)
                var segments: [TranscriptionSegment] = []
                var fullText = ""

                for i in 0..<nSegments {
                    let t0 = whisper_full_get_segment_t0(ctx, i)  // centiseconds (10ms units)
                    let t1 = whisper_full_get_segment_t1(ctx, i)
                    let text: String
                    if let cStr = whisper_full_get_segment_text(ctx, i) {
                        text = String(cString: cStr)
                    } else {
                        text = ""
                    }

                    segments.append(TranscriptionSegment(
                        start: Double(t0) / 100.0,  // convert centiseconds → seconds
                        end: Double(t1) / 100.0,
                        text: text
                    ))
                    fullText += text
                }

                // Whisper's auto-detected language for the audio.
                var detected: String? = nil
                let langId = whisper_full_lang_id(ctx)
                if langId >= 0, let langPtr = whisper_lang_str(langId) {
                    detected = String(cString: langPtr)
                }

                continuation.resume(returning: TranscriptionResult(
                    text: fullText,
                    segments: segments,
                    detectedLanguage: detected
                ))
            }
        }
    }

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// This reuses the already-loaded whisper model and runs on a background queue.
    func transcribeChunk(samples: [Float],
                         language: String? = nil,
                         translate: Bool = false,
                         modelPath: String? = nil,
                         decoding: WhisperDecodingStrategy = .greedy) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
                let ctx: OpaquePointer
                do {
                    ctx = try self.ensureModelLoaded(modelPath: modelPath)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let liveThreads = min(4, max(1, Int32(ProcessInfo.processInfo.activeProcessorCount)))
                let (params, langCStr) = self.makeBaseParams(
                    threadCount: liveThreads,
                    language: language,
                    translate: translate,
                    decoding: decoding
                )
                defer { free(langCStr) }

                let result = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }

                if result != 0 {
                    continuation.resume(throwing: TranscriptionError.processFailed("whisper_full returned error \(result)"))
                    return
                }

                let nSegments = whisper_full_n_segments(ctx)
                var segments: [TranscriptionSegment] = []
                var fullText = ""

                for i in 0..<nSegments {
                    let t0 = whisper_full_get_segment_t0(ctx, i)
                    let t1 = whisper_full_get_segment_t1(ctx, i)
                    let text: String
                    if let cStr = whisper_full_get_segment_text(ctx, i) {
                        text = String(cString: cStr)
                    } else {
                        text = ""
                    }

                    segments.append(TranscriptionSegment(
                        start: Double(t0) / 100.0,
                        end: Double(t1) / 100.0,
                        text: text
                    ))
                    fullText += text
                }

                var detected: String? = nil
                let langId = whisper_full_lang_id(ctx)
                if langId >= 0, let langPtr = whisper_lang_str(langId) {
                    detected = String(cString: langPtr)
                }

                continuation.resume(returning: TranscriptionResult(
                    text: fullText,
                    segments: segments,
                    detectedLanguage: detected
                ))
            }
        }
    }

    /// Load the selected model without blocking the caller's executor.
    func preloadModel(
        modelPath: String? = nil,
        requireEnglishTranslation: Bool = false
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            whisperQueue.async {
                do {
                    let ctx = try self.ensureModelLoaded(modelPath: modelPath)
                    if requireEnglishTranslation {
                        try self.validateEnglishTranslationModel(ctx)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reserve the single Whisper context for live work after all earlier work has drained.
    func beginRealtimeSession(
        modelPath: String? = nil,
        requireEnglishTranslation: Bool
    ) async throws {
        let acquired = realtimeLock.withLock { () -> Bool in
            guard !realtimeSessionActive else { return false }
            realtimeSessionActive = true
            return true
        }
        guard acquired else { throw TranscriptionError.modelBusy }
        do {
            try await preloadModel(
                modelPath: modelPath,
                requireEnglishTranslation: requireEnglishTranslation
            )
        } catch {
            endRealtimeSession()
            throw error
        }
    }

    func endRealtimeSession() {
        realtimeLock.withLock { realtimeSessionActive = false }
    }

    // MARK: - Params Configuration

    /// Create base whisper params. `language` nil/empty means auto-detect; when
    /// `translate` is true whisper translates the audio to English.
    /// Caller must free the returned C string pointer after whisper_full completes.
    private func makeBaseParams(threadCount: Int32? = nil,
                                language: String? = nil,
                                translate: Bool = false,
                                decoding: WhisperDecodingStrategy = .greedy) -> (whisper_full_params, UnsafeMutablePointer<CChar>?) {
        var params = whisper_full_default_params(
            decoding == .beam5 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        )
        if decoding == .beam5 { params.beam_search.beam_size = 5 }
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.n_threads = threadCount ?? max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
        params.translate = translate
        params.no_context = true
        params.audio_ctx = 0
        // Live captions must be deterministic. The whisper.cpp default may
        // retry hotter temperatures after a decode failure, which produced
        // repeated Japanese text in the earlier short-clip benchmark.
        params.temperature = 0
        params.temperature_inc = 0

        let lang = (language?.isEmpty == false) ? language! : "auto"
        let langCStr = strdup(lang)
        params.language = UnsafePointer(langCStr)

        return (params, langCStr)
    }

    /// Returns all languages supported by the loaded whisper.cpp library.
    static func availableLanguages() -> [(code: String, name: String)] {
        var langs: [(code: String, name: String)] = []
        let maxId = Int(whisper_lang_max_id())
        for i in 0...maxId {
            if let codePtr = whisper_lang_str(Int32(i)),
               let namePtr = whisper_lang_str_full(Int32(i)) {
                langs.append((code: String(cString: codePtr), name: String(cString: namePtr)))
            }
        }
        return langs
    }

    // MARK: - Model Management

    static var appSupportModelPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models/ggml-model.bin").path
    }

    /// Check whether a usable model file exists at any known location.
    static func modelExists() -> Bool {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path),
           files.contains(where: { $0.hasSuffix(".bin") }) {
            return true
        }
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return true
        }
        if FileManager.default.fileExists(atPath: appSupportModelPath) {
            return true
        }
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        let projectRoot = (sourcesDir as NSString).deletingLastPathComponent
        let projectPath = (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
        return FileManager.default.fileExists(atPath: projectPath)
    }

    /// Load (or re-load, when the resolved path changed) the model and return the context.
    /// MUST run on `whisperQueue`: reloading frees the previous context, which would
    /// crash a whisper_full running concurrently on the queue if done anywhere else.
    @discardableResult
    private func ensureModelLoaded(modelPath: String? = nil) throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(whisperQueue))
        let path = modelPath ?? resolveModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.modelNotFound(
                "Model not found at: \(path)\n\n" +
                "Download a model in Settings → Speech Recognition Models."
            )
        }
        if loadedModelPath != path {
            if let ctx { whisper_free(ctx) }
            ctx = nil
            loadedModelPath = nil

            var cparams = whisper_context_default_params()
            cparams.use_gpu = true  // Metal GPU acceleration
            cparams.flash_attn = true

            ctx = path.withCString { whisper_init_from_file_with_params($0, cparams) }
            guard ctx != nil else {
                throw TranscriptionError.processFailed("Failed to load whisper model from: \(path)")
            }
            loadedModelPath = path
        }
        guard let ctx else {
            throw TranscriptionError.processFailed("Model not loaded")
        }
        return ctx
    }

    private func validateEnglishTranslationModel(_ ctx: OpaquePointer) throws {
        let path = loadedModelPath ?? resolveModelPath()
        if let model = ModelCatalog.model(fileName: URL(fileURLWithPath: path).lastPathComponent),
           !model.supportsEnglishTranslation {
            throw TranscriptionError.modelIncompatible(
                "\(model.displayName) cannot translate speech to English. Select Whisper Medium, Small, Base, or Tiny."
            )
        }
        let readable = whisper_model_type_readable(ctx).map { String(cString: $0).lowercased() } ?? ""
        guard whisper_is_multilingual(ctx) != 0, !readable.contains("turbo") else {
            throw TranscriptionError.modelIncompatible(
                "The selected Whisper model cannot translate speech to English. Select Whisper Medium, Small, Base, or Tiny."
            )
        }
    }

    private func resolveModelPath() -> String {
        // Explicitly selected downloaded model (set via Settings or the toolbar picker)
        if let selected = UserDefaults.standard.string(forKey: "selectedModelFile"),
           !selected.isEmpty {
            let selectedPath = ModelCatalog.modelDirectory.appendingPathComponent(selected).path
            if FileManager.default.fileExists(atPath: selectedPath) {
                return selectedPath
            }
        }

        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        // Check App Support path (where auto-download saves the model)
        let appSupportPath = Self.appSupportModelPath
        if FileManager.default.fileExists(atPath: appSupportPath) {
            return appSupportPath
        }

        // Fallback to project-relative path (development)
        let projectRoot = resolveProjectRoot()
        return (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
    }

    private func resolveProjectRoot() -> String {
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        return (sourcesDir as NSString).deletingLastPathComponent
    }
}

// Box for passing progress handler through C callback
private class ProgressBox {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
}
