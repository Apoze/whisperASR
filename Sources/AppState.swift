import Foundation
import NaturalLanguage
import Observation

private struct LocalTranslationJob: Sendable {
    let index: Int
    let source: TranscriptionSegment
    let decision: LocalEndpointDecision?
    let queueMilliseconds: Double
    let asrMilliseconds: Double
}

@Observable
class AppState {
    var items: [TranscriptionItem] = []
    var selectedItemID: UUID?

    // Live transcription state
    var liveSegments: [TranscriptionSegment] = []
    var isLiveTranscribing = false
    var enableLiveTranscription = true
    var liveStatusText = "Waiting for audio..."
    private(set) var liveStableSegmentCount = 0
    private(set) var isPreparingLiveModel = false
    private(set) var liveModelPreparationError: String?
    private(set) var localSourceLocales: [SpeechLocaleChoice] = []
    private(set) var isPreparingLocalResources = false
    private(set) var localResourceProgress = 0.0
    private(set) var localResourceError: String?
    private(set) var appleTranslationLowReady = false
    private(set) var appleTranslationHighReady = false
    private(set) var appleSpeechReady = false

    // Inline error banners surfaced in RecordingView. Nil when no error.
    var liveError: String?
    var liveTranslationError: String?
    var livePreviewError: String?

    /// A short-lived, auto-dismissing toast for translation errors in the main
    /// window (e.g. expired/invalid API key, failed API call). Deduplicated and
    /// rate-limited so a stream of identical failures can't spam the user.
    var transientToast: String?
    private var toastDismissTask: Task<Void, Never>?
    /// Monotonic-ish marker for the last toast shown, used to suppress repeats.
    private var lastToastText: String?

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = []
    private(set) var activeLiveCaptionMode: LiveCaptionMode?
    private var activeKeepOriginalTranscript = false
    /// Compatibility bridge for the existing `whisperasr://record?translate=` URL.
    var enableLiveTranslation: Bool {
        get { LiveCaptionMode.stored() != .original }
        set {
            UserDefaults.standard.set(
                (newValue ? LiveCaptionMode.api : LiveCaptionMode.original).rawValue,
                forKey: LiveCaptionMode.storageKey
            )
        }
    }
    /// User-controlled pause for live translation (e.g. the speaker switched to
    /// the listener's native language). Distinct from `translationAuthPaused`,
    /// which is an error-driven stop. While paused, no API calls are made; on
    /// resume, segments spoken during the pause are skipped so only new speech
    /// is translated.
    var liveTranslationPaused = false
    private var liveTranslatedSourceTexts: [String] = []  // tracks what text each translation was for
    /// Parallel to liveTranslatedSegments: number of consecutive chunks a segment's
    /// source text has been stable. Sealed (>= sealThreshold) segments are never retranslated.
    private var liveTranslatedSealCount: [Int] = []
    private static let sealThreshold = 3

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveModelPreparationTask: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    /// Single-slot queue: each snapshot supersedes the previous one (they are cumulative),
    /// so keeping a queue of old snapshots was pure wasted work.
    private var pendingTranslationSnapshot: [TranscriptionSegment]?
    private var isTranslationWorkerRunning = false
    private var translationFailureCount = 0
    /// Set when translation is paused due to an auth error; cleared on next start.
    private var translationAuthPaused = false
    private var lastAutoSaveTime: Date = .distantPast
    private var localCommittedSegments: [TranscriptionSegment] = []
    private var localSourceSegments: [TranscriptionSegment] = []
    private var localTranslationQueue: [LocalTranslationJob] = []
    private var localTranslationWorkerRunning = false
    private var activeLocalTranslationMode: AppleTranslationMode = .adaptive
    private var activeLocalEnglishEngine: LocalEnglishEngine = .whisperTurboApple
    private var activeLocalSourceLocale = ""
    private var localPreviewPlanner = LocalPreviewPlanner()
    private var localPreviewSegment: TranscriptionSegment?
    private var localPreviewTranslationTask: Task<Void, Never>?
    private var localPreviewSpeechFinalizeTask: Task<Void, Never>?
    private var localPreviewWorkerRunning = false
    private var localPreviewLastStartedUptimeNanoseconds: UInt64 = 0
    private var localPreviewRevision = 0
    private var localFinalWorkCount = 0
    private var localPreviewSentSampleCount = 0
    private var localPreviewSpeechStartSample: Int?
    private var localPreviewFeedStarted = false
    private var localPreviewLastForcedSample = 0
    private var localRecordingStartedUptimeNanoseconds: UInt64 = 0
    private var localPreviewRuntimeEnabled = false
    /// English has been validated through this absolute PCM sample.
    private var localCommittedSampleCount = 0
    /// Source ASR has finalized through this sample; it may be ahead of English.
    private var localSourceFinalizedSampleCount = 0
    private var localPipelineFailure: String?
    private var preparedLiveModelFileName: String?
    private var preparingLiveModelFileName: String?
    private var localModelPreparationTask: Task<Void, Never>?
    private var preparingLocalEnglishEngine: LocalEnglishEngine?
    private var preparingLocalTranslationMode: AppleTranslationMode?
    let localModelManager = LocalEnglishModelManager()
    @ObservationIgnored private let localMetricRecorder = LocalCaptionMetricRecorder()
    @ObservationIgnored private weak var activeLocalRecorder: AudioRecorder?
    @ObservationIgnored private var appleTranslationRuntime: Any?
    @ObservationIgnored private var applePreviewTranslationRuntime: Any?
    @ObservationIgnored private var appleSpeechRuntime: Any?

    var isLiveTranslationModelReady: Bool {
        preparedLiveModelFileName == liveModelSelectionKey
            && liveModelPreparationError == nil
            && !isPreparingLiveModel
    }

    @MainActor
    var isLocalEnglishReady: Bool {
        guard #available(macOS 26.4, *) else { return false }
        let defaults = UserDefaults.standard
        let source = defaults.string(forKey: LocalSpeechEngine.sourceLocaleKey) ?? ""
        let engine = LocalEnglishEngine.stored(in: defaults)
        let mode = AppleTranslationMode.stored(in: defaults)
        let translationReady = (!mode.requiresLowLatency || appleTranslationLowReady)
            && (!mode.requiresHighFidelity || appleTranslationHighReady)
        let previewReady = !mode.showsPreview || appleSpeechReady
        let whisperReady = engine != .whisperTurboApple || isLiveTranslationModelReady
        let sourceCode = Locale(identifier: source).language.languageCode?.identifier
        let sourceSupported = localSourceLocales.contains {
            Locale(identifier: $0.id).language.languageCode?.identifier == sourceCode
        }
        return !source.isEmpty
            && sourceSupported
            && translationReady
            && previewReady
            && whisperReady
            && localModelManager.phase(for: engine).isReady
            && localResourceError == nil
    }

    private var liveModelSelectionKey: String {
        let defaults = UserDefaults.standard
        return (defaults.string(forKey: "selectedModelFile") ?? "")
            + "|" + (defaults.string(forKey: "modelPath") ?? "")
    }

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30
    /// When speech runs continuously past this without a pause (12s at 16kHz), force a chunk cut at
    /// the live tail rather than waiting longer. Kept well under `maxChunkSamples` so the live tail
    /// is always transcribed and no audio is silently dropped.
    private static let forceChunkSamples = 16000 * 12

    init() {
        let defaults = UserDefaults.standard
        // Persist the migrated value once so AppStorage and backups see one source of truth.
        defaults.set(LiveCaptionMode.stored(in: defaults).rawValue, forKey: LiveCaptionMode.storageKey)
        items = TranscriptionStore.loadAll()
        selectedItemID = items.first?.id
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
        // Share the single loaded model with the OpenAI-compatible API server and
        // start it if the user left it enabled.
        Task { @MainActor [service] in
            APIServer.shared.attach(service: service)
            if UserDefaults.standard.bool(forKey: APIServer.enabledKey) {
                APIServer.shared.start()
            }
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    func addFile(url: URL) {
        guard !items.contains(where: { $0.fileURL == url }) else {
            selectedItemID = items.first { $0.fileURL == url }?.id
            return
        }

        let item = TranscriptionItem(fileURL: url)
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        enqueueTranscription(for: item)
    }

    @MainActor
    func retranscribe(_ item: TranscriptionItem) {
        if item.translateToEnglish, item.localSourceLocale != nil {
            retryLocalEnglishTranslation(item)
            return
        }
        item.segments = []
        item.fullText = ""
        item.progress = 0
        item.translatedSegments = []
        item.translationLanguage = nil
        enqueueTranscription(for: item)
    }

    @MainActor
    private func retryLocalEnglishTranslation(_ item: TranscriptionItem) {
        guard #available(macOS 26.4, *), let locale = item.localSourceLocale else {
            item.status = .failed("Local Apple translation requires macOS 26.4 or later.")
            return
        }
        let mode = item.localTranslationMode ?? .adaptive
        item.status = .transcribing
        item.progress = 0
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                var sources = item.segments
                if sources.isEmpty {
                    guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
                        throw TranscriptionError.processFailed("The source transcript and audio are missing")
                    }
                    let language = Locale(identifier: locale).language.languageCode?.identifier
                    let result = try await self.service.transcribe(
                        fileURL: item.fileURL,
                        language: language,
                        translate: false
                    ) { progress in
                        Task { @MainActor [weak item] in item?.progress = progress * 0.5 }
                    }
                    sources = result.segments
                }
                try await self.appleTranslationService().configure(
                    sourceLocale: locale,
                    mode: mode
                )
                var english: [TranscriptionSegment] = []
                for (index, source) in sources.enumerated() {
                    let text = try await self.translateStableSource(source.text, mode: mode)
                    english.append(TranscriptionSegment(
                        start: source.start,
                        end: source.end,
                        text: text
                    ))
                    item.progress = 0.5 + 0.5 * Double(index + 1) / Double(max(1, sources.count))
                }
                if item.discardOriginalAfterRetry {
                    item.segments = english
                    item.fullText = english.map(\.text).joined()
                    item.translatedSegments = []
                    item.translationLanguage = nil
                } else {
                    item.segments = sources
                    item.fullText = sources.map(\.text).joined()
                    item.translatedSegments = english.map(\.text)
                    item.translationLanguage = "en"
                }
                item.translateToEnglish = false
                item.progress = 1
                item.status = .completed
                TranscriptionStore.save(item)
            } catch {
                item.status = .failed("English translation is incomplete: \(error.localizedDescription)")
                TranscriptionStore.save(item)
            }
        }
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Preserve the file extension
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"

        // Rename the actual file on disk; only adopt the new URL if the move
        // succeeded (moveItem also fails when the destination already exists).
        // Items without an audio file (e.g. recovered transcripts) just get a
        // new display name.
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        if newURL != item.fileURL, FileManager.default.fileExists(atPath: item.fileURL.path) {
            do {
                try FileManager.default.moveItem(at: item.fileURL, to: newURL)
            } catch {
                Task { @MainActor in
                    self.showToast("Couldn't rename \"\(item.fileName)\": \(error.localizedDescription)")
                }
                return
            }
            item.fileURL = newURL
        }
        item.fileName = nameWithExt
        TranscriptionStore.save(item)
    }

    /// Add a file with pre-existing live transcription results (skip re-transcription).
    @discardableResult
    func addFileWithLiveResults(url: URL, segments: [TranscriptionSegment], fullText: String,
                                translatedSegments: [String] = [], translationLanguage: String? = nil) -> TranscriptionItem {
        let item = TranscriptionItem(fileURL: url)
        item.segments = segments
        item.fullText = fullText
        item.translatedSegments = translatedSegments
        item.translationLanguage = translationLanguage
        item.status = .completed
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        return item
    }

    /// Stop live transcription and the recorder, then file the finished recording.
    /// Shared by the Finish Recording button and the Zoom meeting-ended flow.
    /// If the audio file failed to save but live transcription produced a
    /// transcript, the transcript is kept as an audio-less item instead of
    /// being silently dropped with the recording.
    @MainActor
    func finishRecording(recorder: AudioRecorder) async {
        let captionMode = activeLiveCaptionMode ?? LiveCaptionMode.stored()
        let keepOriginal = activeKeepOriginalTranscript
        let apiTranslationWasPaused = liveTranslationPaused
        liveStatusText = captionMode == .localEnglish
            ? "Finalizing the last English subtitles..." : "Saving recording..."
        let url = await recorder.stopRecording()
        defer { recorder.state = .idle }
        if captionMode == .localEnglish, #available(macOS 26.4, *) {
            await stopLocalPreviewRuntime()
        }
        await awaitLiveTasks()

        var localFailure: String?
        var segments: [TranscriptionSegment]
        if captionMode == .localEnglish {
            service.endRealtimeSession()
            await finishLocalTranslationQueue()
            segments = localCommittedSegments
            let sourceMismatch = localCommittedSegments.count != localSourceSegments.count
            let uncommittedSourceAudio = localCommittedSampleCount < localSourceFinalizedSampleCount
            if !localTranslationQueue.isEmpty
                || sourceMismatch
                || uncommittedSourceAudio
                || localPipelineFailure != nil {
                localFailure = localFailure
                    ?? "English translation is incomplete. The PCM/audio and valid English subtitles were kept for retry."
            }
            _ = try? await localMetricRecorder.writeOptInReport()
        } else {
            segments = liveSegments
            service.endRealtimeSession()
        }

        do {
            if let canonical = try CanonicalBenchmarkCorpus.writeIfRequested(
                samples: recorder.getAccumulatedSamples()
            ) {
                print("[Benchmark] Canonical PCM saved to \(canonical.path)")
            }
        } catch {
            showToast("Couldn't save the canonical benchmark PCM: \(error.localizedDescription)")
        }
        recorder.discardAccumulatedSamples()
        let fullText = segments.map(\.text).joined()
        var translations = liveTranslatedSegments
        let translatedSourceTexts = liveTranslatedSourceTexts
        let hadLiveResults = !segments.isEmpty || !localSourceSegments.isEmpty

        guard hadLiveResults || captionMode == .localEnglish else {
            if let url { addFile(url: url) }
            resetLiveState()
            return
        }

        var storedSegments = segments
        var storedText = fullText
        var storedTranslations: [String] = []
        var storedTranslationLanguage: String?

        if captionMode == .localEnglish {
            if keepOriginal || localFailure != nil {
                storedSegments = localSourceSegments
                storedText = localSourceSegments.map(\.text).joined()
                storedTranslations = localCommittedSegments.map(\.text)
                if storedTranslations.count < storedSegments.count {
                    storedTranslations += Array(
                        repeating: "",
                        count: storedSegments.count - storedTranslations.count
                    )
                }
                storedTranslationLanguage = "en"
            }
        } else if captionMode == .api {
            let defaults = UserDefaults.standard
            let targetLanguage = defaults.string(forKey: "targetLanguage").flatMap { $0.isEmpty ? nil : $0 } ?? "en"
            defaults.set(targetLanguage, forKey: "targetLanguage")
            var finalized = true
            if !apiTranslationWasPaused {
                do {
                    translations = try await finalizeAPITranslations(
                        segments: segments,
                        currentTranslations: translations,
                        translatedSourceTexts: translatedSourceTexts,
                        targetLanguage: targetLanguage
                    )
                } catch {
                    finalized = false
                    showToast("Couldn't finish the API translation. The original transcript was kept: \(error.localizedDescription)")
                }
            }

            if keepOriginal || !finalized {
                storedTranslations = translations
                storedTranslationLanguage = translations.contains(where: { !$0.isEmpty }) ? targetLanguage : nil
            } else {
                let translatedSegments = Self.primarySegments(from: segments, translations: translations)
                if translatedSegments.isEmpty {
                    showToast("The translation was empty, so the original transcript was kept.")
                } else {
                    storedSegments = translatedSegments
                    storedText = translatedSegments.map(\.text).joined()
                }
            }
        }

        let itemURL = url ?? URL(fileURLWithPath: "/unsaved-recording-\(UUID().uuidString)")
        let item = addFileWithLiveResults(
            url: itemURL,
            segments: storedSegments,
            fullText: storedText,
            translatedSegments: storedTranslations,
            translationLanguage: storedTranslationLanguage
        )
        item.translateToEnglish = captionMode == .localEnglish && localFailure != nil
        if captionMode == .localEnglish {
            item.localSourceLocale = activeLocalSourceLocale
            item.localTranslationMode = activeLocalTranslationMode
            item.discardOriginalAfterRetry = !keepOriginal
        }

        if let localFailure {
            item.status = .failed(localFailure + " The audio was kept; use Retry English translation.")
        }

        if url == nil {
            item.fileName = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)) (audio not saved)"
            TranscriptionStore.save(item)
        } else if localFailure != nil || captionMode == .localEnglish {
            TranscriptionStore.save(item)
        }
        resetLiveState()
    }

    private func awaitLiveTasks() async {
        let transcriptionTask = liveTranscriptionTask
        liveTranscriptionTask = nil
        // Local-English capture observes recorder.state and performs its tail
        // drain without cancellation. Cancelling here would propagate into
        // Qwen/Whisper/TranslationSession and could lose the final utterance.
        if activeLiveCaptionMode != .localEnglish {
            transcriptionTask?.cancel()
        }
        await transcriptionTask?.value

        let translationTask = liveTranslationTask
        if activeLiveCaptionMode == .localEnglish {
            await translationTask?.value
        } else {
            liveTranslationTask = nil
            translationTask?.cancel()
            await translationTask?.value
        }
    }

    @MainActor
    private func finishLocalTranslationQueue() async {
        await liveTranslationTask?.value
        guard #available(macOS 26.4, *) else { return }
        var retries = 0
        while !localTranslationQueue.isEmpty, retries < 2 {
            liveTranslationError = nil
            startLocalTranslationWorkerIfNeeded()
            await liveTranslationTask?.value
            retries += 1
        }
    }

    private func finalizeAPITranslations(
        segments: [TranscriptionSegment],
        currentTranslations: [String],
        translatedSourceTexts: [String],
        targetLanguage: String
    ) async throws -> [String] {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        var translations = Array(currentTranslations.prefix(texts.count))
        if translations.count < texts.count {
            translations += Array(repeating: "", count: texts.count - translations.count)
        }

        let firstDirty = texts.indices.first { index in
            index >= translatedSourceTexts.count || translatedSourceTexts[index] != texts[index]
        } ?? texts.count
        guard firstDirty < texts.count else { return translations }

        let contextStart = max(0, firstDirty - 2)
        let context: [(original: String, translated: String)] = (contextStart..<firstDirty).compactMap { index in
            guard !texts[index].isEmpty, !translations[index].isEmpty else { return nil }
            return (texts[index], translations[index])
        }
        let suffix = try await TranslationService.translateSegmentsWithOpenAI(
            segmentTexts: Array(texts.dropFirst(firstDirty)),
            targetLanguage: targetLanguage,
            previousTranslations: context
        )
        return Array(translations.prefix(firstDirty)) + suffix
    }

    static func primarySegments(
        from sourceSegments: [TranscriptionSegment],
        translations: [String]
    ) -> [TranscriptionSegment] {
        sourceSegments.enumerated().compactMap { index, segment in
            guard index < translations.count else { return nil }
            let text = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptionSegment(start: segment.start, end: segment.end, text: text)
        }
    }

    // MARK: - Translate Completed Transcription

    /// Show a transient, auto-dismissing toast. Repeats of the same message are
    /// ignored (the timer just restarts) so a continuously-failing translation
    /// queue surfaces the problem once rather than flickering on every retry.
    @MainActor
    func showToast(_ text: String, duration: Duration = .seconds(6)) {
        transientToast = text
        lastToastText = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if it's still the same message we scheduled.
                if self?.lastToastText == text { self?.transientToast = nil }
            }
        }
    }

    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        // @MainActor: `item` is observed by SwiftUI, so every mutation below must
        // land on the main actor; only the translation API calls suspend off it.
        Task { @MainActor in
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let batchSize = 20
            var transientFailures = 0

            batchLoop: for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                do {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch let err as TranslationError {
                    print("[Translation] batch error: \(err)")
                    switch err {
                    case .authFailed, .invalidEndpoint, .unavailable:
                        // Not retriable — stop hammering the API and report it once.
                        self.showToast(err.errorDescription ?? "Translation failed")
                        break batchLoop
                    default:
                        transientFailures += 1
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                    transientFailures += 1
                }
            }

            // Some batches failed transiently (network/server/rate-limit) but we
            // kept going; let the user know the result is incomplete.
            if transientFailures > 0 {
                self.showToast("Translation incomplete — \(transientFailures) section\(transientFailures == 1 ? "" : "s") couldn't be translated. Check your network or API settings.")
            }

            item.isTranslating = false
            TranscriptionStore.save(item)
        }
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        TranscriptionStore.save(item)
    }

    func shutdown() {
        service.shutdown()
        Task { await localModelManager.shutdown() }
    }

    @MainActor
    func prepareLiveTranslationModel() {
        let engine = LocalEnglishEngine.stored()
        guard LiveCaptionMode.stored() == .localEnglish,
              engine == .whisperTurboApple else {
            liveModelPreparationTask?.cancel()
            liveModelPreparationTask = nil
            isPreparingLiveModel = false
            preparedLiveModelFileName = nil
            preparingLiveModelFileName = nil
            return
        }

        guard let turbo = ModelCatalog.model(id: "large-v3-turbo"),
              ModelManager.shared.isDownloaded(turbo) else {
            liveModelPreparationError = "Download Whisper Large v3 Turbo in Settings before using the reference pipeline."
            preparedLiveModelFileName = nil
            return
        }
        if ModelManager.shared.selectedFileName != turbo.fileName {
            ModelManager.shared.selectedFileName = turbo.fileName
        }

        let selected = liveModelSelectionKey
        guard preparedLiveModelFileName != selected,
              preparingLiveModelFileName != selected else { return }
        liveModelPreparationTask?.cancel()
        isPreparingLiveModel = true
        preparingLiveModelFileName = selected
        liveModelPreparationError = nil
        liveModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.preloadModel(requireEnglishTranslation: false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.preparedLiveModelFileName = selected
                    self.preparingLiveModelFileName = nil
                    self.isPreparingLiveModel = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.liveModelPreparationError = error.localizedDescription
                    self.preparingLiveModelFileName = nil
                    self.isPreparingLiveModel = false
                }
            }
        }
    }

    @MainActor
    func loadLocalEnglishCapabilities() {
        guard #available(macOS 26.4, *) else {
            localResourceError = "Local Apple translation requires macOS 26.4 or later."
            return
        }
        guard localSourceLocales.isEmpty else {
            prepareLocalEnglishResources()
            return
        }
        isPreparingLocalResources = true
        localResourceError = nil
        let mode = AppleTranslationMode.stored()
        Task { [weak self] in
            let locales = mode.showsPreview
                ? await AppleSpeechService.supportedSourceLocales(
                    requireHighFidelity: mode.requiresHighFidelity
                )
                : await AppleTranslationService.supportedSourceLocales()
            await MainActor.run {
                guard let self else { return }
                self.localSourceLocales = locales
                self.isPreparingLocalResources = false
                if locales.isEmpty {
                    self.localResourceError = "No local Apple speech and translation language is available for this subtitle mode."
                } else {
                    let defaults = UserDefaults.standard
                    let selected = defaults.string(forKey: LocalSpeechEngine.sourceLocaleKey) ?? ""
                    let selectedCode = Locale(identifier: selected).language.languageCode?.identifier
                    if !selected.isEmpty,
                       !locales.contains(where: { $0.id == selected }),
                       let equivalent = locales.first(where: {
                           Locale(identifier: $0.id).language.languageCode?.identifier == selectedCode
                       }) {
                        defaults.set(equivalent.id, forKey: LocalSpeechEngine.sourceLocaleKey)
                    }
                    self.prepareLocalEnglishResources()
                }
            }
        }
    }

    @MainActor
    func reloadLocalEnglishCapabilities() {
        localSourceLocales = []
        loadLocalEnglishCapabilities()
    }

    @MainActor
    func resetAppleTranslationPreparation() {
        appleTranslationLowReady = false
        appleTranslationHighReady = false
        appleSpeechReady = false
        localResourceError = nil
    }

    @MainActor
    func deactivateLocalEnglishResources() {
        localModelPreparationTask?.cancel()
        localModelPreparationTask = nil
        liveModelPreparationTask?.cancel()
        liveModelPreparationTask = nil
        preparingLocalEnglishEngine = nil
        preparingLocalTranslationMode = nil
        preparingLiveModelFileName = nil
        preparedLiveModelFileName = nil
        isPreparingLiveModel = false
        isPreparingLocalResources = false
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        Task {
            if #available(macOS 26.0, *), let speech = appleSpeechRuntime as? AppleSpeechService {
                await speech.cancel()
            }
            if #available(macOS 26.4, *), let preview = applePreviewTranslationRuntime as? AppleTranslationService {
                await preview.cancel()
            }
            await localModelManager.unload()
            await service.unloadModel()
        }
    }

    @MainActor
    func reportAppleTranslationPreparation(
        highFidelity: Bool,
        ready: Bool,
        error: String?
    ) {
        if highFidelity {
            appleTranslationHighReady = ready
        } else {
            appleTranslationLowReady = ready
        }
        if let error { localResourceError = error }
    }

    @MainActor
    func prepareLocalEnglishResources() {
        guard LiveCaptionMode.stored() == .localEnglish else { return }
        guard #available(macOS 26.4, *) else {
            localResourceError = "Local Apple translation requires macOS 26.4 or later."
            return
        }
        let defaults = UserDefaults.standard
        let locale = defaults.string(forKey: LocalSpeechEngine.sourceLocaleKey) ?? ""
        guard !locale.isEmpty else {
            localResourceProgress = 0
            localResourceError = nil
            return
        }
        let engine = LocalEnglishEngine.stored(in: defaults)
        let mode = AppleTranslationMode.stored(in: defaults)
        if preparingLocalEnglishEngine == engine,
           preparingLocalTranslationMode == mode { return }
        let speechReady = !mode.showsPreview || appleSpeechReady
        if localModelManager.phase(for: engine).isReady, speechReady {
            isPreparingLocalResources = false
            localResourceProgress = 1
            localResourceError = nil
            if engine == .whisperTurboApple { prepareLiveTranslationModel() }
            return
        }

        localModelPreparationTask?.cancel()
        preparingLocalEnglishEngine = engine
        preparingLocalTranslationMode = mode
        isPreparingLocalResources = true
        localResourceProgress = 0
        localResourceError = nil
        localModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if mode.showsPreview {
                    try await self.appleSpeechService().prepare(
                        localeIdentifier: locale
                    ) { progress in
                        Task { @MainActor [weak self] in
                            self?.localResourceProgress = progress
                        }
                    }
                    await MainActor.run { self.appleSpeechReady = true }
                }
                if engine != .whisperTurboApple {
                    await self.service.unloadModel()
                    await MainActor.run {
                        self.preparedLiveModelFileName = nil
                        self.preparingLiveModelFileName = nil
                    }
                }
                if !self.localModelManager.phase(for: engine).isReady {
                    try await self.localModelManager.prepare(engine)
                }
                if engine == .whisperTurboApple {
                    await MainActor.run { self.prepareLiveTranslationModel() }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isPreparingLocalResources = false
                    self.localResourceProgress = 1
                    self.preparingLocalEnglishEngine = nil
                    self.preparingLocalTranslationMode = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isPreparingLocalResources = false
                    self.localResourceError = error.localizedDescription
                    self.preparingLocalEnglishEngine = nil
                    self.preparingLocalTranslationMode = nil
                }
            }
        }
    }

    @available(macOS 26.4, *)
    private func appleTranslationService() -> AppleTranslationService {
        if let service = appleTranslationRuntime as? AppleTranslationService { return service }
        let service = AppleTranslationService()
        appleTranslationRuntime = service
        return service
    }

    @available(macOS 26.4, *)
    private func applePreviewTranslationService() -> AppleTranslationService {
        if let service = applePreviewTranslationRuntime as? AppleTranslationService { return service }
        let service = AppleTranslationService()
        applePreviewTranslationRuntime = service
        return service
    }

    @available(macOS 26.0, *)
    private func appleSpeechService() -> AppleSpeechService {
        if let service = appleSpeechRuntime as? AppleSpeechService { return service }
        let service = AppleSpeechService()
        appleSpeechRuntime = service
        return service
    }

    func removeItem(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    private func enqueueTranscription(for item: TranscriptionItem) {
        item.status = .pending
        if !isTranscribing {
            startNextTranscription()
        }
    }

    private func startNextTranscription() {
        guard !service.isRealtimeSessionActive else {
            isTranscribing = false
            return
        }
        guard let item = items.first(where: { $0.status == .pending }) else {
            isTranscribing = false
            return
        }
        isTranscribing = true
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()

        Task.detached { [service] in
            do {
                let result = try await service.transcribe(
                    fileURL: item.fileURL,
                    translate: item.translateToEnglish
                ) { progress in
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    if item.translateToEnglish,
                       Self.isClearlyNonEnglishTranslation(result.text) {
                        item.status = .failed("Whisper returned the source language instead of English.")
                        TranscriptionStore.save(item)
                        return
                    }
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                    TranscriptionStore.save(item)
                }
            } catch {
                await MainActor.run {
                    item.status = .failed(error.localizedDescription)
                    TranscriptionStore.save(item)
                }
            }
            await MainActor.run { [weak self] in
                self?.startNextTranscription()
            }
        }
    }

    // MARK: - Live Transcription During Recording

    /// Start live captions. Local English has its own FIFO pipeline; original/API retain
    /// their existing rolling transcription behavior.
    @MainActor
    func startLiveTranscription(recorder: AudioRecorder) {
        let captionMode = LiveCaptionMode.stored()
        let defaults = UserDefaults.standard
        let localMode = AppleTranslationMode.stored(in: defaults)
        let localEngine = LocalEnglishEngine.stored(in: defaults)
        let sourceLocale = defaults.string(forKey: LocalSpeechEngine.sourceLocaleKey) ?? ""
        activeLiveCaptionMode = captionMode
        activeKeepOriginalTranscript = defaults.bool(forKey: LiveCaptionMode.keepOriginalKey)
        activeLocalTranslationMode = localMode
        activeLocalEnglishEngine = localEngine
        activeLocalSourceLocale = sourceLocale
        activeLocalRecorder = recorder
        liveSegments = []
        liveStableSegmentCount = 0
        localCommittedSegments = []
        localSourceSegments = []
        localTranslationQueue = []
        localTranslationWorkerRunning = false
        localPreviewPlanner = LocalPreviewPlanner()
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        localPreviewWorkerRunning = false
        localPreviewLastStartedUptimeNanoseconds = 0
        localPreviewRevision = 0
        localFinalWorkCount = 0
        localPreviewSentSampleCount = 0
        localPreviewSpeechStartSample = nil
        localPreviewFeedStarted = false
        localPreviewLastForcedSample = 0
        localRecordingStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        localPreviewRuntimeEnabled = false
        localCommittedSampleCount = 0
        localSourceFinalizedSampleCount = 0
        localPipelineFailure = nil
        liveError = nil
        liveTranslationError = nil
        livePreviewError = nil
        liveTranslatedSealCount = []
        translationFailureCount = 0
        translationAuthPaused = false
        liveTranslationPaused = false
        liveStatusText = captionMode == .localEnglish
            ? "Preparing local speech and translation…" : "Preparing Whisper model..."
        isLiveTranscribing = true
        Task { await localMetricRecorder.reset() }

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            if captionMode == .localEnglish {
                guard #available(macOS 26.4, *), !sourceLocale.isEmpty else {
                    await MainActor.run {
                        self.liveError = "Choose a supported spoken language before recording."
                        self.isLiveTranscribing = false
                    }
                    return
                }
                await self.runLocalEnglishCaptions(
                    recorder: recorder,
                    engine: localEngine,
                    sourceLocale: sourceLocale
                )
            } else {
                await self.localModelManager.unload()
                do {
                    try await self.service.beginRealtimeSession(requireEnglishTranslation: false)
                } catch {
                    await MainActor.run {
                        self.liveError = error.localizedDescription
                        self.liveStatusText = "Whisper model unavailable"
                        self.isLiveTranscribing = false
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { self.liveStatusText = "Listening..." }
                await self.runStandardLiveCaptions(recorder: recorder, captionMode: captionMode)
            }
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func runLocalEnglishCaptions(
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String
    ) async {
        do {
            guard localModelManager.loadedEngine == engine,
                  localModelManager.phase(for: engine).isReady else {
                throw LocalPrototypeError.modelNotLoaded(engine.label)
            }
            let finalMode: AppleTranslationMode = activeLocalTranslationMode.finalUsesHighFidelity
                ? .highFidelityOnly : .lowLatencyOnly
            try await appleTranslationService().configure(
                sourceLocale: sourceLocale,
                mode: finalMode
            )
            if activeLocalTranslationMode.showsPreview {
                do {
                    try await applePreviewTranslationService().configure(
                        sourceLocale: sourceLocale,
                        mode: .lowLatencyOnly
                    )
                    try await appleSpeechService().start(
                        localeIdentifier: sourceLocale,
                        onUpdate: { [weak self] update in
                            self?.receiveLocalPreviewSource(update)
                        },
                        onFailure: { [weak self] error in
                            self?.disableLocalPreview(error)
                        }
                    )
                    localPreviewRuntimeEnabled = true
                } catch {
                    livePreviewError = "Live preview unavailable: \(error.localizedDescription) Stable subtitles will continue."
                    localPreviewRuntimeEnabled = false
                }
            }
            await MainActor.run { self.liveStatusText = "Listening…" }
            if engine == .whisperTurboApple {
                try await service.beginRealtimeSession(requireEnglishTranslation: false)
            }
            await runEndpointedPrototypeCaptions(
                recorder: recorder,
                engine: engine,
                sourceLocale: sourceLocale
            )
            await stopLocalPreviewRuntime()
        } catch {
            await stopLocalPreviewRuntime()
            await MainActor.run {
                self.localPipelineFailure = error.localizedDescription
                self.liveError = error.localizedDescription
                self.liveStatusText = "Local translation unavailable"
            }
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func receiveLocalPreviewSource(_ update: LiveSourceUpdate) {
        guard localPreviewRuntimeEnabled,
              activeLocalTranslationMode.showsPreview,
              localFinalWorkCount == 0,
              !update.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        localPreviewPlanner.submit(update)
        startLocalPreviewWorkerIfNeeded()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func startLocalPreviewWorkerIfNeeded() {
        guard localPreviewRuntimeEnabled,
              localFinalWorkCount == 0,
              !localPreviewWorkerRunning,
              localPreviewPlanner.pending != nil else { return }
        localPreviewWorkerRunning = true
        localPreviewTranslationTask = Task { @MainActor [weak self] in
            await self?.drainLocalPreviewQueue()
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func drainLocalPreviewQueue() async {
        defer { localPreviewWorkerRunning = false }
        let refreshNanoseconds: UInt64 = 500_000_000

        while !Task.isCancelled, localPreviewRuntimeEnabled, localFinalWorkCount == 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            if localPreviewLastStartedUptimeNanoseconds > 0,
               now - localPreviewLastStartedUptimeNanoseconds < refreshNanoseconds {
                let remaining = refreshNanoseconds - (now - localPreviewLastStartedUptimeNanoseconds)
                try? await Task.sleep(nanoseconds: remaining)
                guard !Task.isCancelled else { return }
            }
            guard let work = localPreviewPlanner.takeLatest() else { return }
            let source = work.update.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }

            localPreviewLastStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let translationStarted = localPreviewLastStartedUptimeNanoseconds
            do {
                let translated = try await applePreviewTranslationService().translate(
                    source,
                    highFidelity: false
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled,
                      localFinalWorkCount == 0,
                      localPreviewPlanner.accepts(work),
                      !translated.isEmpty,
                      !EnglishSubtitleValidator.containsSourceScript(translated)
                else { continue }

                localPreviewRevision += 1
                localPreviewSegment = TranscriptionSegment(
                    start: work.update.segment.start,
                    end: work.update.segment.end,
                    text: translated
                )
                livePreviewError = nil
                publishLocalCaptions()

                let rendered = DispatchTime.now().uptimeNanoseconds
                let rangeStart = max(0, Int((work.update.segment.start * 16_000).rounded()))
                let rangeEnd = max(rangeStart, Int(((work.update.segment.end ?? work.update.segment.start) * 16_000).rounded()))
                let sourceEndUptime = localRecordingStartedUptimeNanoseconds
                    + UInt64(rangeEnd) * 1_000_000_000 / 16_000
                let speechStart = localPreviewSpeechStartSample ?? rangeStart
                let sourceStartUptime = localRecordingStartedUptimeNanoseconds
                    + UInt64(max(0, speechStart)) * 1_000_000_000 / 16_000
                await localMetricRecorder.append(LocalCaptionMetric(
                    kind: .preview,
                    engine: activeLocalEnglishEngine.rawValue,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    speechEnd: rangeEnd,
                    endpointDetectedAt: -1,
                    vadOnlyEndpointAt: -1,
                    queueMilliseconds: 0,
                    asrMilliseconds: work.receivedUptimeNanoseconds > sourceEndUptime
                        ? Double(work.receivedUptimeNanoseconds - sourceEndUptime) / 1_000_000 : 0,
                    translationMilliseconds: Self.elapsedMilliseconds(since: translationStarted),
                    renderedUptimeNanoseconds: rendered,
                    sourceText: source,
                    englishText: translated,
                    revision: localPreviewRevision,
                    previewLatencyMilliseconds: rendered > sourceStartUptime
                        ? Double(rendered - sourceStartUptime) / 1_000_000 : 0
                ))
            } catch {
                guard !Task.isCancelled else { return }
                disableLocalPreview(error)
                return
            }
        }
    }

    @MainActor
    private func suspendLocalPreview(for decision: LocalEndpointDecision) {
        guard activeLocalTranslationMode.showsPreview else { return }
        localFinalWorkCount += 1
        localPreviewPlanner.suspend(through: decision.stableThrough)
        localPreviewTranslationTask?.cancel()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func completeLocalFinalWork(through sample: Int) {
        guard activeLocalTranslationMode.showsPreview else { return }
        localFinalWorkCount = max(0, localFinalWorkCount - 1)
        localPreviewSegment = nil
        guard localFinalWorkCount == 0, localPreviewRuntimeEnabled else { return }
        localPreviewPlanner.resume(through: sample)
        startLocalPreviewWorkerIfNeeded()
    }

    @MainActor
    private func disableLocalPreview(_ error: Error) {
        localPreviewRuntimeEnabled = false
        localPreviewPlanner.suspend(through: localCommittedSampleCount)
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        livePreviewError = "Live preview unavailable: \(error.localizedDescription) Stable subtitles will continue."
        publishLocalCaptions()
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 26.0, *) { await self.appleSpeechService().cancel() }
            if #available(macOS 26.4, *) { await self.applePreviewTranslationService().cancel() }
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func stopLocalPreviewRuntime() async {
        localPreviewRuntimeEnabled = false
        localPreviewPlanner.suspend(through: localCommittedSampleCount)
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        await localPreviewTranslationTask?.value
        localPreviewTranslationTask = nil
        localPreviewWorkerRunning = false
        await appleSpeechService().cancel()
        await applePreviewTranslationService().cancel()
        publishLocalCaptions()
    }

    /// SpeechAnalyzer waits until it has consumed the requested timestamp.
    /// Keep that wait outside the PCM producer so capture can continue feeding it.
    @available(macOS 26.4, *)
    @MainActor
    private func startLocalPreviewSpeechFinalization(through sample: Int) {
        guard localPreviewSpeechFinalizeTask == nil else { return }
        localPreviewLastForcedSample = sample
        localPreviewSpeechFinalizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.appleSpeechService().finalizeAvailableAudio()
                guard !Task.isCancelled else { return }
                self.localPreviewSpeechFinalizeTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.localPreviewSpeechFinalizeTask = nil
                self.disableLocalPreview(error)
            }
        }
    }

    /// Shared stable path for both engines. FireRedVAD remains the only final
    /// boundary source; the independent preview path cannot validate PCM.
    @available(macOS 26.4, *)
    @MainActor
    private func runEndpointedPrototypeCaptions(
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String
    ) async {
        let fifo = LocalEndpointFIFO()

        async let producerError: Error? = producePrototypeEndpoints(
            recorder: recorder,
            fifo: fifo
        )
        async let consumer: Void = consumePrototypeEndpoints(
            recorder: recorder,
            engine: engine,
            sourceLocale: sourceLocale,
            fifo: fifo
        )

        let error = await producerError
        await consumer
        if let error {
            localPipelineFailure = error.localizedDescription
            liveError = error.localizedDescription
        }
    }

    /// Capture/VAD producer. It never waits for final ASR or Apple
    /// translation, so every captured sample remains observable in real time.
    @available(macOS 26.4, *)
    @MainActor
    private func producePrototypeEndpoints(
        recorder: AudioRecorder,
        fifo: LocalEndpointFIFO
    ) async -> Error? {
        var vadAnalyzedEnd = 0

        do {
            while recorder.state == .recording, !Task.isCancelled {
                let total = recorder.accumulatedSampleCount
                guard total - vadAnalyzedEnd >= 1_600 else {
                    try await Task.sleep(for: .milliseconds(40))
                    continue
                }
                let earliestRetained = max(
                    0,
                    localCommittedSampleCount - LocalEndpointPlanner.forcedOverlap
                )
                let windowStart = max(earliestRetained, total - 16_000 * 3)
                let window = recorder.getSamples(from: windowStart, upTo: total)
                guard !window.isEmpty else {
                    try await Task.sleep(for: .milliseconds(40))
                    continue
                }
                let speech = try await localModelManager.detectSpeech(
                    audio: window,
                    windowStart: windowStart
                )
                if let firstSpeech = speech.first(where: {
                    $0.end > localPreviewLastForcedSample
                }) {
                    if !localPreviewFeedStarted {
                        localPreviewFeedStarted = true
                        localPreviewSentSampleCount = max(
                            localPreviewSentSampleCount,
                            firstSpeech.start - LocalEndpointPlanner.preRoll
                        )
                        localPreviewLastForcedSample = max(
                            localPreviewLastForcedSample,
                            firstSpeech.start
                        )
                    }
                    if localPreviewSpeechStartSample == nil {
                        localPreviewSpeechStartSample = max(
                            localPreviewLastForcedSample,
                            firstSpeech.start
                        )
                    }
                }
                if localPreviewRuntimeEnabled,
                   localPreviewFeedStarted,
                   total > localPreviewSentSampleCount {
                    let start = localPreviewSentSampleCount
                    let samples = recorder.getSamples(from: start, upTo: total)
                    if !samples.isEmpty {
                        do {
                            try await appleSpeechService().send(
                                samples: samples,
                                startSample: start
                            )
                            localPreviewSentSampleCount = total
                        } catch {
                            disableLocalPreview(error)
                        }
                    }
                }
                if localPreviewRuntimeEnabled,
                   localPreviewFeedStarted,
                   localPreviewSpeechStartSample != nil,
                   localFinalWorkCount == 0,
                   localPreviewSpeechFinalizeTask == nil {
                    let target = total
                    if target - localPreviewLastForcedSample >= 24_000 {
                        startLocalPreviewSpeechFinalization(through: target)
                    }
                }
                vadAnalyzedEnd = total
                if let decision = await fifo.observe(
                    totalSample: total,
                    speech: speech
                ) {
                    suspendLocalPreview(for: decision)
                    localPreviewSpeechStartSample = nil
                    localPreviewLastForcedSample = max(
                        localPreviewLastForcedSample,
                        decision.stableThrough
                    )
                }
                let queuedPhrases = await fifo.pendingCount()
                if queuedPhrases > 1 {
                    liveStatusText = "Catching up — \(queuedPhrases - 1) phrase\(queuedPhrases == 2 ? "" : "s") queued"
                }
            }

            let finalTotal = recorder.accumulatedSampleCount
            let earliestRetained = max(
                0,
                localCommittedSampleCount - LocalEndpointPlanner.forcedOverlap
            )
            let windowStart = max(earliestRetained, finalTotal - 16_000 * 3)
            let window = recorder.getSamples(from: windowStart, upTo: finalTotal)
            let speech = window.isEmpty ? [] : try await localModelManager.detectSpeech(
                audio: window,
                windowStart: windowStart
            )
            if let decision = await fifo.observe(
                totalSample: finalTotal,
                speech: speech,
                finishing: true
            ) {
                suspendLocalPreview(for: decision)
            }
            await fifo.finishProducing()
            return nil
        } catch {
            await fifo.finishProducing()
            return error
        }
    }

    /// Oldest-first final worker. A failed range remains at the head of the
    /// FIFO and no PCM cursor advances past it.
    @available(macOS 26.4, *)
    @MainActor
    private func consumePrototypeEndpoints(
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String,
        fifo: LocalEndpointFIFO
    ) async {
        var attempts = 0
        while !Task.isCancelled {
            guard let entry = await fifo.next() else {
                if await fifo.isDrained() { return }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let decision = entry.decision

            do {
                try await processPrototypeDecision(
                    decision,
                    recorder: recorder,
                    engine: engine,
                    sourceLocale: sourceLocale,
                    queueMilliseconds: Self.elapsedMilliseconds(
                        since: entry.stagedUptimeNanoseconds
                    )
                )
                await fifo.accept(entry)
                localSourceFinalizedSampleCount = max(
                    localSourceFinalizedSampleCount,
                    decision.stableThrough
                )
                localPipelineFailure = nil
                attempts = 0
            } catch {
                attempts += 1
                localPipelineFailure = error.localizedDescription
                liveTranslationError = error.localizedDescription
                liveStatusText = "Audio retained — retrying oldest phrase…"
                guard attempts < 2 else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func processPrototypeDecision(
        _ decision: LocalEndpointDecision,
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String,
        queueMilliseconds: Double
    ) async throws {
        let audio = recorder.getSamples(from: decision.audioStart, upTo: decision.audioEnd)
        guard !audio.isEmpty else { throw LocalPrototypeError.invalidResponse }
        liveStatusText = "Finalizing source…"
        let asrStart = DispatchTime.now().uptimeNanoseconds

        let sourceText: String
        switch engine {
        case .whisperTurboApple:
            let result = try await service.transcribeChunk(
                samples: audio,
                language: Self.languageCode(for: sourceLocale),
                translate: false
            )
            sourceText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .qwenApple:
            sourceText = try await localModelManager.transcribeQwen(
                audio: audio,
                language: Self.languageName(for: sourceLocale)
            )
        }
        guard !sourceText.isEmpty else { throw LocalPrototypeError.invalidResponse }
        let source = TranscriptionSegment(
            start: Double(max(localSourceFinalizedSampleCount, decision.audioStart)) / 16_000,
            end: Double(decision.speechEnd) / 16_000,
            text: sourceText
        )
        let queued = enqueueLocalSource(
            source,
            decision: decision,
            queueMilliseconds: queueMilliseconds,
            asrMilliseconds: Self.elapsedMilliseconds(since: asrStart)
        )
        if !queued {
            completeLocalFinalWork(through: decision.stableThrough)
            publishLocalCaptions()
        }
    }

    private static func languageCode(for localeIdentifier: String) -> String {
        Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? localeIdentifier
    }

    private static func languageName(for localeIdentifier: String) -> String {
        let code = languageCode(for: localeIdentifier)
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    private func runStandardLiveCaptions(
        recorder: AudioRecorder,
        captionMode: LiveCaptionMode
    ) async {
        var sealedSegments: [TranscriptionSegment] = []
        var sealedSampleCount = 0
        var sealedClean = true
        var lastTranscribedTotal = 0
        let frameSamples = 1600
        let silenceThreshold: Float = 0.001
        let contextSamples = 16000

        while !Task.isCancelled {
            let total = recorder.accumulatedSampleCount
            let tailCount = total - sealedSampleCount
            guard tailCount >= 8000, total - lastTranscribedTotal >= 4800 else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard recorder.rmsEnergy(from: sealedSampleCount, count: tailCount) > silenceThreshold else {
                sealedSampleCount = total
                sealedClean = true
                lastTranscribedTotal = total
                recorder.trimSamples(upTo: max(0, total - contextSamples))
                let snapshot = sealedSegments
                await MainActor.run {
                    self.liveSegments = snapshot
                    self.liveStableSegmentCount = snapshot.count
                    self.liveStatusText = "Listening..."
                    self.throttledAutoSave()
                }
                continue
            }

            let useOverlap = !sealedClean
            let tailStart = useOverlap ? max(0, sealedSampleCount - contextSamples) : sealedSampleCount
            guard total - tailStart <= Self.maxChunkSamples else {
                await MainActor.run {
                    self.liveError = "Transcription is falling behind. Finish the recording to process the saved audio."
                }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let chunk = recorder.getSamples(from: tailStart, upTo: total)
            guard !chunk.isEmpty else { continue }
            lastTranscribedTotal = total

            do {
                await MainActor.run { self.liveStatusText = "Transcribing..." }
                let result = try await Self.withTimeout(
                    seconds: max(60, Double(chunk.count) / 4000.0)) {
                    try await self.service.transcribeChunk(samples: chunk)
                }
                guard !Task.isCancelled else { break }
                let tail = Self.offsetSegments(result.segments, by: Double(tailStart) / 16000.0)
                var combined = sealedSegments.filter { $0.start < Double(tailStart) / 16000.0 }
                for segment in tail {
                    var text = segment.text
                    if useOverlap, let previous = combined.last?.text {
                        text = Self.trimOverlap(previous: previous, current: text)
                    }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        combined.append(TranscriptionSegment(
                            start: segment.start, end: segment.end, text: text))
                    }
                }

                let silenceCut = recorder.lastSilenceCut(
                    searchFrom: sealedSampleCount, searchTo: total,
                    frameSamples: frameSamples, silenceThreshold: silenceThreshold,
                    minSilenceFrames: 3)
                var sealAdvanced = false
                if let cut = silenceCut, cut - sealedSampleCount >= 8000 {
                    sealedSegments = combined.filter { $0.start < Double(cut) / 16000.0 }
                    sealedSampleCount = cut
                    sealedClean = true
                    sealAdvanced = true
                    recorder.trimSamples(upTo: cut)
                } else if tailCount >= Self.forceChunkSamples {
                    sealedSegments = combined
                    sealedSampleCount = total
                    sealedClean = false
                    sealAdvanced = true
                    recorder.trimSamples(upTo: max(0, total - contextSamples))
                }

                let snapshot = combined
                let stableCount = sealedSegments.count
                let shouldTranslate = sealAdvanced && captionMode == .api && !snapshot.isEmpty
                await MainActor.run {
                    self.liveSegments = snapshot
                    self.liveStableSegmentCount = stableCount
                    self.liveStatusText = "Listening..."
                    self.throttledAutoSave()
                    if shouldTranslate {
                        let target = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
                        if !target.isEmpty { self.enqueueLiveTranslation(snapshot) }
                    }
                }
            } catch {
                print("[AppState] live transcription chunk error: \(error)")
            }
        }
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLiveTranscription() {
        localPreviewRuntimeEnabled = false
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        if #available(macOS 26.4, *) {
            Task { [weak self] in
                guard let self else { return }
                await self.appleSpeechService().cancel()
                await self.applePreviewTranslationService().cancel()
            }
        }
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        if #available(macOS 26.4, *), let translation = appleTranslationRuntime as? AppleTranslationService {
            Task { await translation.cancel() }
        }
        service.endRealtimeSession()
        resetLiveState()
    }

    private func resetLiveState() {
        pendingTranslationSnapshot = nil
        isTranslationWorkerRunning = false
        translationFailureCount = 0
        translationAuthPaused = false
        isLiveTranscribing = false
        liveStatusText = "Waiting for audio..."
        liveError = nil
        liveTranslationError = nil
        livePreviewError = nil
        liveSegments = []
        liveStableSegmentCount = 0
        liveTranslatedSegments = []
        liveTranslatedSourceTexts = []
        liveTranslatedSealCount = []
        activeLiveCaptionMode = nil
        activeKeepOriginalTranscript = false
        liveTranslationPaused = false
        localCommittedSegments = []
        localSourceSegments = []
        localTranslationQueue = []
        localTranslationWorkerRunning = false
        localPreviewPlanner = LocalPreviewPlanner()
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        localPreviewWorkerRunning = false
        localPreviewLastStartedUptimeNanoseconds = 0
        localPreviewRevision = 0
        localFinalWorkCount = 0
        localPreviewSentSampleCount = 0
        localPreviewSpeechStartSample = nil
        localPreviewFeedStarted = false
        localPreviewLastForcedSample = 0
        localRecordingStartedUptimeNanoseconds = 0
        localPreviewRuntimeEnabled = false
        localCommittedSampleCount = 0
        localSourceFinalizedSampleCount = 0
        localPipelineFailure = nil
        activeLocalRecorder = nil
        removeLiveRecoveryFile()
        if !isTranscribing, items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
    }

    @MainActor
    private func enqueueLocalSource(
        _ source: TranscriptionSegment,
        decision: LocalEndpointDecision? = nil,
        queueMilliseconds: Double = 0,
        asrMilliseconds: Double = 0
    ) -> Bool {
        var text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let previous = localSourceSegments.last {
            if abs(previous.start - source.start) < 0.01,
               abs((previous.end ?? previous.start) - (source.end ?? source.start)) < 0.01,
               previous.text == text {
                return false
            }
            if source.start < (previous.end ?? previous.start) {
                let trimmed = Self.trimOverlap(previous: previous.text, current: text)
                // Repeated dialogue is valid. Only drop a prefix when temporal
                // overlap proves it came from the retained 800 ms boundary.
                if !trimmed.isEmpty { text = trimmed }
            }
        }
        guard !text.isEmpty else { return false }
        let normalized = TranscriptionSegment(
            start: source.start,
            end: source.end,
            text: text
        )
        let index = localSourceSegments.count
        localSourceSegments.append(normalized)
        localTranslationQueue.append(LocalTranslationJob(
            index: index,
            source: normalized,
            decision: decision,
            queueMilliseconds: queueMilliseconds,
            asrMilliseconds: asrMilliseconds
        ))
        startLocalTranslationWorkerIfNeeded()
        return true
    }

    @MainActor
    private func startLocalTranslationWorkerIfNeeded() {
        guard !localTranslationWorkerRunning, !localTranslationQueue.isEmpty else { return }
        guard #available(macOS 26.4, *) else { return }
        localTranslationWorkerRunning = true
        liveTranslationTask = Task { @MainActor [weak self] in
            await self?.drainLocalTranslationQueue()
        }
    }

    @MainActor
    @available(macOS 26.4, *)
    private func drainLocalTranslationQueue() async {
        defer { localTranslationWorkerRunning = false }
        while !Task.isCancelled, let job = localTranslationQueue.first {
            liveStatusText = "Translating to English…"
            do {
                let translationStart = DispatchTime.now().uptimeNanoseconds
                let text = try await translateStableSource(
                    job.source.text,
                    mode: activeLocalTranslationMode
                )
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty,
                      !EnglishSubtitleValidator.containsSourceScript(normalized) else {
                    throw LocalPrototypeError.invalidResponse
                }
                guard localTranslationQueue.first?.index == job.index else { continue }
                localTranslationQueue.removeFirst()
                let translated = TranscriptionSegment(
                    start: job.source.start,
                    end: job.source.end,
                    text: normalized
                )
                if job.index < localCommittedSegments.count {
                    localCommittedSegments[job.index] = translated
                } else {
                    localCommittedSegments.append(translated)
                }
                if let decision = job.decision {
                    localCommittedSampleCount = max(
                        localCommittedSampleCount,
                        decision.stableThrough
                    )
                    activeLocalRecorder?.trimSamples(upTo: max(
                        0, localCommittedSampleCount - LocalEndpointPlanner.forcedOverlap
                    ))
                    completeLocalFinalWork(through: decision.stableThrough)
                }
                liveTranslationError = nil
                publishLocalCaptions()
                if let decision = job.decision {
                    await localMetricRecorder.append(LocalCaptionMetric(
                        kind: .final,
                        engine: activeLocalEnglishEngine.rawValue,
                        rangeStart: decision.audioStart,
                        rangeEnd: decision.audioEnd,
                        speechEnd: decision.speechEnd,
                        endpointDetectedAt: decision.endpointDetectedAt,
                        vadOnlyEndpointAt: decision.vadOnlyEndpointAt,
                        queueMilliseconds: job.queueMilliseconds,
                        asrMilliseconds: job.asrMilliseconds,
                        translationMilliseconds: Self.elapsedMilliseconds(since: translationStart),
                        renderedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        sourceText: job.source.text,
                        englishText: normalized,
                        revision: nil,
                        previewLatencyMilliseconds: nil
                    ))
                }
            } catch {
                liveTranslationError = error.localizedDescription
                liveStatusText = "English translation waiting to retry…"
                return
            }
        }
        publishLocalCaptions()
    }

    @available(macOS 26.4, *)
    private func translateStableSource(
        _ text: String,
        mode: AppleTranslationMode = .highFidelityOnly
    ) async throws -> String {
        try await appleTranslationService().translate(
            text,
            highFidelity: mode.finalUsesHighFidelity
        )
    }

    @MainActor
    private func publishLocalCaptions() {
        liveStableSegmentCount = localCommittedSegments.count
        liveSegments = localCommittedSegments
        if let localPreviewSegment { liveSegments.append(localPreviewSegment) }
        liveStatusText = "Listening..."
        throttledAutoSave()
    }

    static func offsetSegments(
        _ segments: [TranscriptionSegment],
        by offset: Double
    ) -> [TranscriptionSegment] {
        segments.map {
            TranscriptionSegment(
                start: $0.start + offset,
                end: $0.end.map { $0 + offset },
                text: $0.text)
        }
    }

    /// Punctuation/whitespace whisper sprinkles at chunk edges; ignored when matching an overlap.
    private static let overlapTrimChars = CharacterSet(
        charactersIn: "，。、！？；：「」『』（）()【】［］…—~,.!?;:'\" \t\n")

    /// Non-Latin source scripts are unambiguously not an English translation, even for one word.
    /// NaturalLanguage handles longer Latin-script output where script alone cannot distinguish it.
    static func isClearlyNonEnglishTranslation(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.contains(where: { !isLatinLetter($0.value) }) { return true }
        let letterCount = letters.count
        guard letterCount >= 8 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let strongest = hypotheses.max(by: { $0.value < $1.value }) else { return false }
        return strongest.key != .english
            && strongest.value >= 0.8
            && (hypotheses[.english] ?? 0) < 0.2
    }

    private static func isLatinLetter(_ value: UInt32) -> Bool {
        (0x0041...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
    }

    /// Trim the leading portion of `current` that duplicates the trailing portion of `previous`.
    /// Produced when a forced chunk re-transcribes the 1s context overlap. The match floor is a
    /// single character (Mandarin is dense — the previous 4-char floor missed most overlaps) and
    /// boundary punctuation/whitespace is stripped so a comma/period whisper added at the cut can't
    /// block the match.
    static func trimOverlap(previous: String, current: String) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let maxCheck = min(source.count, target.count)
        guard maxCheck >= 1 else { return current }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if target.hasPrefix(String(source.suffix(len))) {
                var remainder = target.dropFirst(len)
                while let first = remainder.unicodeScalars.first,
                      overlapTrimChars.contains(first) {
                    remainder = remainder.dropFirst()
                }
                return String(remainder)
            }
        }
        return current
    }

    // MARK: - Live Transcription Auto-Save (crash recovery)

    private static var liveRecoveryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("live_recovery.json")
    }

    private struct LiveRecoveryData: Codable {
        let segments: [TranscriptionSegment]
        let fullText: String
        let translatedSegments: [String]
        let translationLanguage: String?
        let localSourceLocale: String?
        let localTranslationMode: AppleTranslationMode?
        let discardOriginalAfterRetry: Bool?
        let savedAt: Date
    }

    /// Only auto-save at most every 15 seconds to avoid JSON serialization overhead.
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveTime) >= 15 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    /// Persist current live transcription to a recovery file so data survives a hang or crash.
    @MainActor
    private func autoSaveLiveTranscription() {
        let isLocalEnglish = activeLiveCaptionMode == .localEnglish
        let segments = isLocalEnglish ? localSourceSegments : liveSegments
        let text = segments.map { $0.text }.joined()
        let translations = isLocalEnglish
            ? localCommittedSegments.map(\.text) : liveTranslatedSegments
        let lang: String? = isLocalEnglish
            ? "en"
            : (!translations.isEmpty
                ? UserDefaults.standard.string(forKey: "targetLanguage") : nil)
        let sourceLocale = isLocalEnglish ? activeLocalSourceLocale : nil
        let translationMode = isLocalEnglish ? activeLocalTranslationMode : nil
        let discardOriginal = isLocalEnglish ? !activeKeepOriginalTranscript : nil

        // Write on a background queue to avoid blocking the main thread
        Task.detached(priority: .utility) {
            let data = LiveRecoveryData(
                segments: segments, fullText: text,
                translatedSegments: translations, translationLanguage: lang,
                localSourceLocale: sourceLocale,
                localTranslationMode: translationMode,
                discardOriginalAfterRetry: discardOriginal,
                savedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(data) else { return }
            let url = AppState.liveRecoveryURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: Self.liveRecoveryURL.path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = Self.liveRecoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: recovery.savedAt))"))
        item.segments = recovery.segments
        item.fullText = recovery.fullText
        item.translatedSegments = recovery.translatedSegments
        item.translationLanguage = recovery.translationLanguage
        item.localSourceLocale = recovery.localSourceLocale
        item.localTranslationMode = recovery.localTranslationMode
        item.discardOriginalAfterRetry = recovery.discardOriginalAfterRetry ?? false
        item.translateToEnglish = recovery.localSourceLocale != nil
        item.status = recovery.localSourceLocale == nil
            ? .completed
            : .failed("Recovered local subtitles may be incomplete. Use Retry English translation to finish the saved source segments.")
        item.fileName = "Recovered \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        removeLiveRecoveryFile()
    }

    // MARK: - Live Translation

    /// Queue the latest translation snapshot. Since each snapshot is cumulative
    /// (contains all segments so far), a newer one always supersedes an older one,
    /// so we keep only the most recent. A single worker drains this slot.
    /// Pause or resume live translation on demand. When resuming, everything
    /// spoken during the pause is marked as already handled (sealed) so the
    /// dirty-scan won't retroactively translate the skipped (native-language)
    /// portion — only segments transcribed from here on get translated.
    @MainActor
    func setLiveTranslationPaused(_ paused: Bool) {
        guard liveTranslationPaused != paused else { return }
        liveTranslationPaused = paused
        if paused {
            // Stop calling the API immediately by dropping any queued snapshot.
            pendingTranslationSnapshot = nil
        } else {
            // Seal the current segments so they're not retranslated on resume.
            let texts = liveSegments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let n = texts.count
            if liveTranslatedSegments.count < n {
                liveTranslatedSegments += Array(repeating: "", count: n - liveTranslatedSegments.count)
            }
            liveTranslatedSourceTexts = texts
            liveTranslatedSealCount = Array(repeating: Self.sealThreshold, count: n)
            // Kick the worker so subsequent segments resume translating.
            if isLiveTranscribing { enqueueLiveTranslation(liveSegments) }
        }
    }

    @MainActor
    private func enqueueLiveTranslation(_ segments: [TranscriptionSegment]) {
        guard !translationAuthPaused, !liveTranslationPaused else { return }
        pendingTranslationSnapshot = segments
        guard !isTranslationWorkerRunning else { return }
        isTranslationWorkerRunning = true
        liveTranslationTask = Task { [weak self] in
            await self?.drainTranslationQueue()
        }
    }

    private func drainTranslationQueue() async {
        while !Task.isCancelled {
            let next: [TranscriptionSegment]? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                if let snapshot = self.pendingTranslationSnapshot {
                    self.pendingTranslationSnapshot = nil
                    return snapshot
                }
                self.isTranslationWorkerRunning = false
                return nil
            }
            guard let segments = next else { return }
            if segments.isEmpty { continue }
            let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
            guard !targetLang.isEmpty else { continue }
            await translateLiveSegments(segments, targetLang: targetLang)
        }
        await MainActor.run { self.isTranslationWorkerRunning = false }
    }

    private func translateLiveSegments(_ segments: [TranscriptionSegment], targetLang: String) async {
        guard !Task.isCancelled else { return }

        // Exponential backoff on repeated failures (500ms, 1s, 2s, ..., capped at 30s).
        let failureCount = await MainActor.run { self.translationFailureCount }
        if failureCount > 0 {
            let delayMs = min(30_000, 500 * Int(pow(2.0, Double(failureCount - 1))))
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
        }

        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let (existing, existingSourceTexts, sealCounts) = await MainActor.run {
            (self.liveTranslatedSegments, self.liveTranslatedSourceTexts, self.liveTranslatedSealCount)
        }

        // Find the first index where the segment text changed or has no translation.
        // Segments in the overlap zone may be re-transcribed with different text,
        // so we need to re-translate from the first divergent segment onward.
        var firstDirtyIndex = min(existing.count, texts.count)
        for i in 0..<min(existing.count, existingSourceTexts.count, texts.count) {
            if texts[i] != existingSourceTexts[i] || existing[i].isEmpty {
                firstDirtyIndex = i
                break
            }
        }

        // Sealed segments are never retranslated — bounds the cascade when whisper's
        // overlap zone shifts an early segment's text yet again after it has stabilized.
        let firstUnsealedIndex: Int = {
            for i in 0..<sealCounts.count {
                if sealCounts[i] < Self.sealThreshold { return i }
            }
            return sealCounts.count
        }()
        let dirtyIndex = max(firstDirtyIndex, firstUnsealedIndex)

        let textsToTranslate = Array(texts.dropFirst(dirtyIndex))
        guard !textsToTranslate.isEmpty else {
            // Nothing to translate, but still need to update seal counts for stable suffix.
            await MainActor.run { self.updateSealCounts(newSourceTexts: texts) }
            return
        }

        // Use up to 2 clean translations before the dirty range as context
        let contextStart = max(0, dirtyIndex - 2)
        let contextPairs: [(original: String, translated: String)] = (contextStart..<dirtyIndex).compactMap { i in
            guard i < texts.count, i < existing.count,
                  !texts[i].isEmpty, !existing[i].isEmpty else { return nil }
            return (original: texts[i], translated: existing[i])
        }

        do {
            let newTranslations = try await TranslationService.translateSegmentsWithOpenAI(
                segmentTexts: textsToTranslate, targetLanguage: targetLang,
                previousTranslations: contextPairs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.liveTranslatedSegments = Array(existing.prefix(dirtyIndex)) + newTranslations
                self.liveTranslatedSourceTexts = Array(texts.prefix(dirtyIndex)) + textsToTranslate
                self.updateSealCounts(newSourceTexts: texts)
                self.translationFailureCount = 0
                self.liveTranslationError = nil
            }
        } catch let err as TranslationError {
            print("[Translation] OpenAI error: \(err)")
            await MainActor.run {
                switch err {
                case .authFailed, .invalidEndpoint:
                    // Pause translation entirely — retrying only wastes quota.
                    self.translationAuthPaused = true
                    self.liveTranslationError = err.errorDescription
                    self.pendingTranslationSnapshot = nil
                default:
                    self.translationFailureCount += 1
                    if self.translationFailureCount >= 3 {
                        self.liveTranslationError = err.errorDescription
                    }
                }
                // Pad source-text tracking so next cycle can detect segments still needing translation.
                if self.liveTranslatedSegments.count < texts.count {
                    self.liveTranslatedSegments += Array(repeating: "", count: texts.count - self.liveTranslatedSegments.count)
                    self.liveTranslatedSourceTexts += texts.suffix(texts.count - self.liveTranslatedSourceTexts.count)
                }
            }
        } catch {
            print("[Translation] error: \(error)")
            await MainActor.run {
                self.translationFailureCount += 1
                if self.translationFailureCount >= 3 {
                    self.liveTranslationError = error.localizedDescription
                }
            }
        }
    }

    /// Increment seal count for each segment whose source text matches last cycle; reset on change.
    @MainActor
    private func updateSealCounts(newSourceTexts: [String]) {
        var updated: [Int] = []
        updated.reserveCapacity(newSourceTexts.count)
        for i in 0..<newSourceTexts.count {
            if i < liveTranslatedSealCount.count, i < liveTranslatedSourceTexts.count,
               liveTranslatedSourceTexts[i] == newSourceTexts[i] {
                updated.append(min(Self.sealThreshold, liveTranslatedSealCount[i] + 1))
            } else {
                updated.append(1)
            }
        }
        liveTranslatedSealCount = updated
    }

    // MARK: - Timeout helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
