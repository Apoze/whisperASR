import Foundation
import NaturalLanguage
import Observation

enum LocalFinalTranslationFailureDisposition: Equatable, Sendable {
    case retry(after: Duration)
    case retain
}

enum LocalEnglishRetrySourceStrategy: Equatable, Sendable {
    case savedComplete
    case retranscribeAudio
    case savedPartial

    static func resolve(
        sourceComplete: Bool,
        hasSavedSource: Bool,
        hasAudio: Bool
    ) -> Self? {
        if !sourceComplete {
            if hasAudio { return .retranscribeAudio }
            return hasSavedSource ? .savedPartial : nil
        }
        if hasSavedSource { return .savedComplete }
        return hasAudio ? .retranscribeAudio : nil
    }

    static func afterAudioFailure(
        hasSavedSource: Bool,
        hasAudio: Bool
    ) -> (strategy: Self, retainsAudioRetry: Bool)? {
        guard hasSavedSource else { return nil }
        return (.savedPartial, hasAudio)
    }

    static func acceptsAudioRetranscription(
        _ candidate: [TranscriptionSegment],
        over saved: [TranscriptionSegment]
    ) -> Bool {
        guard let candidateRange = coverage(of: candidate) else { return false }
        guard let savedRange = coverage(of: saved) else { return true }
        let tolerance = 0.02
        return candidateRange.lowerBound <= savedRange.lowerBound + tolerance
            && candidateRange.upperBound + tolerance >= savedRange.upperBound
    }

    private static func coverage(
        of segments: [TranscriptionSegment]
    ) -> ClosedRange<Double>? {
        guard let start = segments.map(\.start).min(),
              let end = segments.map({ $0.end ?? $0.start }).max()
        else { return nil }
        return start...max(start, end)
    }
}

enum LocalFinalTranslationErrorClassification: String, Codable, Sendable {
    case timedOut
    case empty
    case invalidResponse
    case assetsUnavailable
    case cancelled
    case cursorMismatch
    case configuration
    case framework

    var isRetryable: Bool {
        switch self {
        case .timedOut, .empty, .framework: return true
        case .invalidResponse, .assetsUnavailable, .cancelled, .cursorMismatch, .configuration:
            return false
        }
    }
}

enum LocalFinalTranslationRetryPolicy {
    static let maximumAttempts = 3

    static func backoffMilliseconds(afterAttempt attempt: Int) -> Int64? {
        switch attempt {
        case 1: return 250
        case 2: return 1_000
        default: return nil
        }
    }

    static func classification(for error: Error) -> LocalFinalTranslationErrorClassification {
        if error is CancellationError { return .cancelled }
        if let appleError = error as? AppleLiveError {
            switch appleError {
            case .translationTimedOut: return .timedOut
            case .emptyTranslation: return .empty
            case .translationAssetsUnavailable: return .assetsUnavailable
            case .unsupportedLanguage,
                 .speechAssetsUnavailable,
                 .speechFormatUnavailable:
                return .configuration
            }
        }
        if let prototypeError = error as? LocalPrototypeError {
            switch prototypeError {
            case .invalidResponse: return .invalidResponse
            case .cursorMismatch: return .cursorMismatch
            case .modelNotLoaded,
                 .memoryLimit,
                 .invalidDownload,
                 .invalidModelChecksum:
                return .configuration
            }
        }
        return .framework
    }

    static func disposition(
        for error: Error,
        afterAttempt attempt: Int
    ) -> LocalFinalTranslationFailureDisposition {
        guard classification(for: error).isRetryable,
              let backoff = backoffMilliseconds(afterAttempt: attempt)
        else { return .retain }
        return .retry(after: .milliseconds(backoff))
    }
}

struct LocalFinalTranslationAttemptFailure: Equatable, Sendable {
    let classification: LocalFinalTranslationErrorClassification
    let disposition: LocalFinalTranslationFailureDisposition
}

struct LocalFinalTranslationAttemptState: Equatable, Sendable {
    private(set) var count = 0
    private(set) var exhausted = false
    private(set) var lastError: String?

    mutating func begin() -> Int {
        count += 1
        return count
    }

    mutating func record(_ error: Error) -> LocalFinalTranslationAttemptFailure {
        lastError = error.localizedDescription
        let failure = LocalFinalTranslationAttemptFailure(
            classification: LocalFinalTranslationRetryPolicy.classification(for: error),
            disposition: LocalFinalTranslationRetryPolicy.disposition(
                for: error,
                afterAttempt: count
            )
        )
        if failure.disposition == .retain { exhausted = true }
        return failure
    }
}

struct LocalCaptionCompletionAssessment: Equatable, Sendable {
    let sourceFailure: String?
    let englishFailure: String?

    var sourceTranscriptComplete: Bool { sourceFailure == nil }
    var failure: String? { sourceFailure ?? englishFailure }
}

enum LocalFinalTranslationState: Equatable, Sendable {
    case idle
    case queued
    case translating(attempt: Int)
    case retrying(nextAttempt: Int)
    case failedRetained

    var statusText: String? {
        switch self {
        case .idle: return nil
        case .queued: return "Final queued"
        case .translating(let attempt):
            return "Translating final — \(attempt)/\(LocalFinalTranslationRetryPolicy.maximumAttempts)"
        case .retrying(let nextAttempt):
            return "Retrying final — \(nextAttempt)/\(LocalFinalTranslationRetryPolicy.maximumAttempts)"
        case .failedRetained: return "Final failed — audio retained"
        }
    }

    mutating func noteEnqueued(isOnlyJob: Bool) {
        guard isOnlyJob, self != .failedRetained else { return }
        self = .queued
    }
}

enum LocalFinalInput: Equatable, Sendable {
    case japaneseSource(TranscriptionSegment)
    case directEnglish(TranscriptionSegment)

    var segment: TranscriptionSegment {
        switch self {
        case .japaneseSource(let segment), .directEnglish(let segment): return segment
        }
    }

    var requiresAppleTranslation: Bool {
        if case .japaneseSource = self { return true }
        return false
    }
}

private struct LocalTranslationJob: Sendable {
    let index: Int
    let input: LocalFinalInput
    let decision: LocalEndpointDecision?
    let queueMilliseconds: Double
    let asrMilliseconds: Double
    let enqueuedUptimeNanoseconds: UInt64
    var attempts = LocalFinalTranslationAttemptState()

    var source: TranscriptionSegment { input.segment }
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
    private var localFinalTranslationInFlight = false
    private var localFinalTranslationState: LocalFinalTranslationState = .idle
    private var activeLocalTranslationMode: AppleTranslationMode = .adaptive
    private var activeLocalEnglishEngine: LocalEnglishEngine = .whisperTurboApple
    private var activeLocalSourceLocale = ""
    private var localPreviewPlanner = LocalPreviewPlanner()
    private var localPreviewSegment: TranscriptionSegment?
    private var localPreviewTranslationTask: Task<Void, Never>?
    private var localPreviewSpeechFinalizeTask: Task<Void, Never>?
    private var localPreviewWorkerRunning = false
    private var localPreviewWaitingForThrottle = false
    private var localPreviewLastStartedUptimeNanoseconds: UInt64 = 0
    private var localPreviewRevision = 0
    private var localAppleSpeechFeed = LocalAppleSpeechFeedState()
    private var localPreviewSentSampleCount = 0
    private var localPreviewSpeechStartSample: Int?
    private var localPreviewFeedStarted = false
    private var localVoxtralPreviewSourceText = ""
    private var localVoxtralClausePlanner = VoxtralClausePlanner()
    private var localContinuousVoxtralAcknowledgedSampleCount = 0
    private var localContinuousVoxtralTranscript = ""
    private var localContinuousVoxtralFailure: String?
    private var localContinuousVoxtralCatchUpThrough: Int?
    private var localContinuousVoxtralBoundaryQueue: [VoxtralClauseBoundary] = []
    private var localContinuousVoxtralBoundaryDrainActive = false
    private var localContinuousVoxtralLastStagedGeneration = -1
    private var localDiarizationGeneration: UInt64 = 0
    private var localDiarizationPreparationFinished = false
    private var localDiarizationAssistActive = false
    private var localVoxtralSpeakerMarkersAreAuthoritative = false
    private var localVoxtralMarkerCalibration: VoxtralMarkerCalibration?
    private var localVoxtralReplayDeduplicator: VoxtralReplayDeduplicator?
    private var localPreviewLastForcedSample = 0
    private var localRecordingStartedUptimeNanoseconds: UInt64 = 0
    private var localPreviewRuntimeEnabled = false
    /// English has been validated through this absolute PCM sample.
    private var localCommittedSampleCount = 0
    /// Source ASR has finalized through this sample; it may be ahead of English.
    private var localSourceFinalizedSampleCount = 0
    private var localSourcePipelineFailure: String?
    private var preparedLiveModelFileName: String?
    private var preparingLiveModelFileName: String?
    private var verifiedWhisperModelChecksums: Set<String> = []
    private var localModelPreparationTask: Task<Void, Never>?
    private var preparingLocalEnglishEngine: LocalEnglishEngine?
    private var preparingLocalTranslationMode: AppleTranslationMode?
    let localModelManager = LocalEnglishModelManager()
    @ObservationIgnored private let localMetricRecorder = LocalCaptionMetricRecorder()
    @ObservationIgnored private let localDiarizationShadow = LocalDiarizationShadow()
    @ObservationIgnored private let localDiarizationJournal = LocalDiarizationShadowJournal()
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
        let translationReady = (!engine.requiresAppleLowLatency(for: mode) || appleTranslationLowReady)
            && (!engine.requiresAppleHighFidelity(for: mode) || appleTranslationHighReady)
        let previewReady = !mode.showsPreview
            || !engine.usesAppleSpeechPreview
            || appleSpeechReady
        let diarizationReady = !engine.usesContinuousVoxtral
            || !LocalDiarizationShadowConfiguration.isEnabled
            || localDiarizationPreparationFinished
        let whisperReady = !engine.usesWhisperFinal || isLiveTranslationModelReady
        let sourceCode = Locale(identifier: source).language.languageCode?.identifier
        let sourceSupported = localSourceLocales.contains {
            Locale(identifier: $0.id).language.languageCode?.identifier == sourceCode
        }
        return !source.isEmpty
            && sourceSupported
            && translationReady
            && previewReady
            && diarizationReady
            && whisperReady
            && localModelManager.phase(for: engine).isReady
            && localResourceError == nil
    }

    private var liveModelSelectionKey: String {
        let engine = LocalEnglishEngine.stored()
        guard let modelID = engine.whisperModelID,
              let model = ModelCatalog.model(id: modelID) else { return "" }
        return "\(engine.rawValue)|\(ModelCatalog.path(for: model).path)"
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
                var retainedAudioRetryFailure: Error?
                let hasAudio = FileManager.default.fileExists(atPath: item.fileURL.path)
                guard var sourceStrategy = LocalEnglishRetrySourceStrategy.resolve(
                    sourceComplete: item.localSourceTranscriptComplete,
                    hasSavedSource: !sources.isEmpty,
                    hasAudio: hasAudio
                ) else {
                    throw TranscriptionError.processFailed(
                        "No saved Japanese clauses or retained audio are available"
                    )
                }
                if sourceStrategy == .retranscribeAudio {
                    let savedSources = sources
                    let language = Locale(identifier: locale).language.languageCode?.identifier
                    do {
                        let result = try await self.service.transcribe(
                            fileURL: item.fileURL,
                            language: language,
                            translate: false
                        ) { progress in
                            Task { @MainActor [weak item] in item?.progress = progress * 0.5 }
                        }
                        guard LocalEnglishRetrySourceStrategy.acceptsAudioRetranscription(
                            result.segments,
                            over: savedSources
                        ) else {
                            throw TranscriptionError.processFailed(
                                "The retained audio did not cover all saved source clauses"
                            )
                        }
                        sources = result.segments
                    } catch {
                        guard let fallback = LocalEnglishRetrySourceStrategy.afterAudioFailure(
                            hasSavedSource: !sources.isEmpty,
                            hasAudio: hasAudio
                        ) else { throw error }
                        sourceStrategy = fallback.strategy
                        if fallback.retainsAudioRetry { retainedAudioRetryFailure = error }
                    }
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
                if sourceStrategy == .savedPartial {
                    // A crash can preserve source clauses even when its audio tail is unavailable.
                    // Keep those clauses beside their English so the partial scope stays explicit.
                    item.segments = sources
                    item.fullText = sources.map(\.text).joined()
                    item.translatedSegments = english.map(\.text)
                    item.translationLanguage = "en"
                } else if item.discardOriginalAfterRetry {
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
                item.localSourceTranscriptComplete = sourceStrategy != .savedPartial
                item.progress = 1
                if let retainedAudioRetryFailure {
                    item.translateToEnglish = true
                    item.status = .failed(
                        "Saved Japanese clauses were translated, but the retained audio still needs retry: \(retainedAudioRetryFailure.localizedDescription)"
                    )
                    self.showToast(
                        "Recovered the saved clauses. The retained audio remains available for another retry."
                    )
                } else {
                    item.translateToEnglish = false
                    item.status = .completed
                }
                if sourceStrategy == .savedPartial, retainedAudioRetryFailure == nil {
                    item.fileName = "Recovered partial subtitles — audio tail unavailable"
                    self.showToast(
                        "Recovered only the saved Japanese clauses; the unavailable audio tail could not be recovered."
                    )
                }
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
        var localSourceTranscriptComplete = true
        var segments: [TranscriptionSegment]
        if captionMode == .localEnglish {
            service.endRealtimeSession()
            await finishLocalTranslationQueue()
            segments = localCommittedSegments
            let isDirectEnglish = activeLocalEnglishEngine.producesDirectEnglish
            let sourceMismatch = !isDirectEnglish
                && localCommittedSegments.count != localSourceSegments.count
            let uncommittedSourceAudio = localCommittedSampleCount < localSourceFinalizedSampleCount
            let pendingVoxtralSource = activeLocalEnglishEngine.usesContinuousVoxtral
                && !localVoxtralClausePlanner.pendingSourceText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sourceFailure = localContinuousVoxtralFailure
                ?? localSourcePipelineFailure
                ?? (pendingVoxtralSource ? "The final Voxtral source suffix was not drained." : nil)

            let englishFailure: String?
            if localFinalTranslationInFlight {
                englishFailure = "An English final is still being translated."
            } else if let failedJob = localTranslationQueue.first,
                      failedJob.attempts.exhausted {
                let operation = failedJob.input.requiresAppleTranslation
                    ? "Apple final translation" : "Direct English final"
                englishFailure = "\(operation) failed after \(failedJob.attempts.count) attempt\(failedJob.attempts.count == 1 ? "" : "s"): \(failedJob.attempts.lastError ?? "Unknown finalization error.")"
            } else if !localTranslationQueue.isEmpty {
                englishFailure = "An English final is waiting for retry."
            } else if activeLocalEnglishEngine.usesContinuousVoxtral,
                      localVoxtralClausePlanner.pendingValidationCount != 0 {
                englishFailure = "One or more staged Voxtral clauses were not validated in English."
            } else if activeLocalEnglishEngine.usesContinuousVoxtral,
                      localVoxtralClausePlanner.englishValidatedThrough
                        != localVoxtralClausePlanner.sourceStagedThrough {
                englishFailure = "The Voxtral source and English validation cursors do not match."
            } else if sourceMismatch {
                englishFailure = "Some finalized source clauses do not have valid English subtitles."
            } else if uncommittedSourceAudio {
                englishFailure = "Source audio was staged but its English translation was not validated."
            } else {
                englishFailure = nil
            }
            let completion = LocalCaptionCompletionAssessment(
                sourceFailure: sourceFailure,
                englishFailure: englishFailure
            )
            localFailure = completion.failure
            localSourceTranscriptComplete = completion.sourceTranscriptComplete
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
            if !activeLocalEnglishEngine.producesDirectEnglish,
               keepOriginal || localFailure != nil {
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
        let directEnglish = captionMode == .localEnglish
            && activeLocalEnglishEngine.producesDirectEnglish
        item.translateToEnglish = captionMode == .localEnglish
            && localFailure != nil
            && !directEnglish
        if captionMode == .localEnglish {
            if !directEnglish {
                item.localSourceLocale = activeLocalSourceLocale
                item.localTranslationMode = activeLocalTranslationMode
                item.discardOriginalAfterRetry = !keepOriginal
                item.localSourceTranscriptComplete = localSourceTranscriptComplete
            }
        }

        if let localFailure {
            let retryDetail: String
            if directEnglish {
                retryDetail = url == nil
                    ? " The audio was not saved; only valid English finals were kept."
                    : " The audio was kept for another model run."
            } else {
                retryDetail = url == nil
                    ? " The audio was not saved; Retry can recover only the saved Japanese clauses."
                    : " The audio was kept; use Retry English translation."
            }
            item.status = .failed(localFailure + retryDetail)
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
        guard #available(macOS 26.4, *) else { return }
        startLocalTranslationWorkerIfNeeded()
        await liveTranslationTask?.value
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
        Task {
            await localModelManager.shutdown()
            await localDiarizationShadow.shutdown()
        }
    }

    @MainActor
    func prepareLiveTranslationModel() {
        let engine = LocalEnglishEngine.stored()
        guard LiveCaptionMode.stored() == .localEnglish,
              engine.usesWhisperFinal else {
            let previousPreparation = liveModelPreparationTask
            previousPreparation?.cancel()
            liveModelPreparationTask = Task { [weak self] in
                await previousPreparation?.value
                guard let self else { return }
                await self.service.unloadModel()
            }
            isPreparingLiveModel = false
            preparedLiveModelFileName = nil
            preparingLiveModelFileName = nil
            return
        }

        guard let modelID = engine.whisperModelID,
              let model = ModelCatalog.model(id: modelID),
              ModelManager.shared.isDownloaded(model) else {
            let previousPreparation = liveModelPreparationTask
            previousPreparation?.cancel()
            liveModelPreparationTask = Task { [weak self] in
                await previousPreparation?.value
                guard let self else { return }
                await self.service.unloadModel()
            }
            liveModelPreparationError = "Download the required Whisper model in Settings before using \(engine.label)."
            preparedLiveModelFileName = nil
            preparingLiveModelFileName = nil
            isPreparingLiveModel = false
            return
        }

        let selected = liveModelSelectionKey
        let modelPath = ModelCatalog.path(for: model).path
        guard preparedLiveModelFileName != selected,
              preparingLiveModelFileName != selected else { return }
        let previousPreparation = liveModelPreparationTask
        previousPreparation?.cancel()
        isPreparingLiveModel = true
        preparingLiveModelFileName = selected
        liveModelPreparationError = nil
        liveModelPreparationTask = Task { [weak self] in
            await previousPreparation?.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                if let expectedSHA256 = model.sha256,
                   !self.verifiedWhisperModelChecksums.contains(model.fileName) {
                    let modelURL = URL(fileURLWithPath: modelPath)
                    let actualSHA256 = try await Task.detached(priority: .utility) {
                        try ModelDownloader.sha256(of: modelURL)
                    }.value
                    guard !Task.isCancelled else { return }
                    guard actualSHA256 == expectedSHA256 else {
                        throw LocalPrototypeError.invalidModelChecksum(
                            model: model.displayName,
                            expected: expectedSHA256,
                            actual: actualSHA256
                        )
                    }
                    self.verifiedWhisperModelChecksums.insert(model.fileName)
                }
                guard !Task.isCancelled else { return }
                try await self.service.preloadModel(
                    modelPath: modelPath,
                    requireEnglishTranslation: engine.producesDirectEnglish
                )
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
        let engine = LocalEnglishEngine.stored()
        Task { [weak self] in
            let discoveredLocales: [SpeechLocaleChoice]
            if engine.producesDirectEnglish, !mode.showsPreview {
                discoveredLocales = TranscriptionService.availableLanguages()
                    .filter { $0.code != "en" }
                    .map {
                        SpeechLocaleChoice(
                            id: $0.code,
                            label: $0.name.capitalized
                        )
                    }
                    .sorted {
                        $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    }
            } else if mode.showsPreview, engine.usesAppleSpeechPreview {
                discoveredLocales = await AppleSpeechService.supportedSourceLocales(
                    requireHighFidelity: engine.requiresAppleHighFidelity(for: mode)
                )
            } else {
                discoveredLocales = await AppleTranslationService.supportedSourceLocales()
            }
            let locales = engine == .cohereApple
                ? discoveredLocales.filter {
                    Locale(identifier: $0.id).language.languageCode?.identifier == "ja"
                }
                : discoveredLocales
            await MainActor.run {
                guard let self else { return }
                guard LocalEnglishEngine.stored() == engine,
                      AppleTranslationMode.stored() == mode else { return }
                self.localSourceLocales = locales
                self.isPreparingLocalResources = false
                if locales.isEmpty {
                    self.localResourceError = engine.producesDirectEnglish
                        ? "No spoken language is available for this direct model."
                        : "No local Apple speech and translation language is available for this subtitle mode."
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
        localDiarizationPreparationFinished = false
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
            await localDiarizationShadow.shutdown()
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
        let speechReady = !mode.showsPreview
            || !engine.usesAppleSpeechPreview
            || appleSpeechReady
        let diarizationReady = !engine.usesContinuousVoxtral
            || !LocalDiarizationShadowConfiguration.isEnabled
            || localDiarizationPreparationFinished
        if localModelManager.phase(for: engine).isReady,
           speechReady,
           diarizationReady {
            isPreparingLocalResources = false
            localResourceProgress = 1
            localResourceError = nil
            if engine.usesWhisperFinal { prepareLiveTranslationModel() }
            return
        }

        let previousPreparation = localModelPreparationTask
        previousPreparation?.cancel()
        preparingLocalEnglishEngine = engine
        preparingLocalTranslationMode = mode
        isPreparingLocalResources = true
        localResourceProgress = 0
        localResourceError = nil
        localModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            await previousPreparation?.value
            guard !Task.isCancelled else { return }
            do {
                if mode.showsPreview, engine.usesAppleSpeechPreview {
                    try await self.appleSpeechService().prepare(
                        localeIdentifier: locale
                    ) { progress in
                        Task { @MainActor [weak self] in
                            self?.localResourceProgress = progress
                        }
                    }
                    await MainActor.run { self.appleSpeechReady = true }
                }
                if !engine.usesWhisperFinal {
                    let previousWhisperPreparation = self.liveModelPreparationTask
                    previousWhisperPreparation?.cancel()
                    await previousWhisperPreparation?.value
                    guard !Task.isCancelled else { return }
                    await self.service.unloadModel()
                    await MainActor.run {
                        self.preparedLiveModelFileName = nil
                        self.preparingLiveModelFileName = nil
                    }
                }
                if !engine.usesContinuousVoxtral {
                    await self.localDiarizationShadow.shutdown()
                    await MainActor.run {
                        self.localDiarizationPreparationFinished = false
                    }
                }
                if !self.localModelManager.phase(for: engine).isReady {
                    try await self.localModelManager.prepare(engine)
                }
                if LocalDiarizationShadowConfiguration.isEnabled,
                   engine.usesContinuousVoxtral {
                    await self.localDiarizationShadow.prepare()
                    let status = await self.localDiarizationShadow.status()
                    await MainActor.run {
                        self.localDiarizationPreparationFinished = true
                        if LocalDiarizationShadowConfiguration
                            .isAssistRequestedButUnpromoted {
                            self.livePreviewError = "Speaker changes are in shadow mode only: no tested diarizer met the promotion thresholds. Punctuation and pauses remain authoritative."
                        } else if let reason = status.failureReason {
                            self.livePreviewError = "Speaker-change assistance unavailable: \(reason) Punctuation and pauses remain active."
                        }
                    }
                }
                if engine.usesWhisperFinal {
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
        localFinalTranslationInFlight = false
        localFinalTranslationState = .idle
        localPreviewPlanner = LocalPreviewPlanner()
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        localPreviewWorkerRunning = false
        localPreviewWaitingForThrottle = false
        localPreviewLastStartedUptimeNanoseconds = 0
        localPreviewRevision = 0
        localAppleSpeechFeed = LocalAppleSpeechFeedState()
        localPreviewSentSampleCount = 0
        localPreviewSpeechStartSample = nil
        localPreviewFeedStarted = false
        localVoxtralPreviewSourceText = ""
        localVoxtralClausePlanner = VoxtralClausePlanner()
        localContinuousVoxtralAcknowledgedSampleCount = 0
        localContinuousVoxtralTranscript = ""
        localContinuousVoxtralFailure = nil
        localContinuousVoxtralCatchUpThrough = nil
        localContinuousVoxtralBoundaryQueue = []
        localContinuousVoxtralBoundaryDrainActive = false
        localContinuousVoxtralLastStagedGeneration = -1
        localVoxtralReplayDeduplicator = nil
        localPreviewLastForcedSample = 0
        localRecordingStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        localPreviewRuntimeEnabled = false
        localCommittedSampleCount = 0
        localSourceFinalizedSampleCount = 0
        localSourcePipelineFailure = nil
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
            if engine.usesAppleFinalTranslation {
                let finalMode: AppleTranslationMode = activeLocalTranslationMode.finalUsesHighFidelity
                    ? .highFidelityOnly : .lowLatencyOnly
                try await appleTranslationService().configure(
                    sourceLocale: sourceLocale,
                    mode: finalMode
                )
                try await appleTranslationService().warmup(
                    highFidelity: activeLocalTranslationMode.finalUsesHighFidelity
                )
            }
            if activeLocalTranslationMode.showsPreview {
                do {
                    try await applePreviewTranslationService().configure(
                        sourceLocale: sourceLocale,
                        mode: .lowLatencyOnly
                    )
                    try await applePreviewTranslationService().warmup(
                        highFidelity: false
                    )
                    if engine.usesAppleSpeechPreview {
                        try await appleSpeechService().start(
                            localeIdentifier: sourceLocale,
                            priority: engine.usesVoxtralStreaming ? .utility : .userInitiated,
                            onUpdate: { [weak self] update in
                                self?.receiveLocalPreviewSource(update)
                            },
                            onFailure: { [weak self] error in
                                self?.disableLocalPreview(error)
                            }
                        )
                    }
                    localPreviewRuntimeEnabled = true
                } catch {
                    livePreviewError = "Live preview unavailable: \(error.localizedDescription) Stable subtitles will continue."
                    localPreviewRuntimeEnabled = false
                }
            }
            await MainActor.run { self.liveStatusText = "Listening…" }
            if engine.usesWhisperFinal {
                try await service.beginRealtimeSession(
                    modelPath: try Self.whisperModelPath(for: engine),
                    requireEnglishTranslation: engine.producesDirectEnglish
                )
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
                self.localSourcePipelineFailure = error.localizedDescription
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
              !update.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        localPreviewPlanner.submit(update)
        if localPreviewWaitingForThrottle,
           localPreviewPlanner.pending?.bypassesThrottle == true {
            localPreviewTranslationTask?.cancel()
        }
        startLocalPreviewWorkerIfNeeded()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func startLocalPreviewWorkerIfNeeded() {
        guard localPreviewRuntimeEnabled,
              !localPreviewIsBlockedByFinal,
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
        defer {
            localPreviewWaitingForThrottle = false
            localPreviewWorkerRunning = false
            startLocalPreviewWorkerIfNeeded()
        }
        let refreshNanoseconds: UInt64 = 500_000_000

        while !Task.isCancelled, localPreviewRuntimeEnabled, !localPreviewIsBlockedByFinal {
            let now = DispatchTime.now().uptimeNanoseconds
            if localPreviewPlanner.pending?.bypassesThrottle != true,
               localPreviewLastStartedUptimeNanoseconds > 0,
               now - localPreviewLastStartedUptimeNanoseconds < refreshNanoseconds {
                let remaining = refreshNanoseconds - (now - localPreviewLastStartedUptimeNanoseconds)
                localPreviewWaitingForThrottle = true
                do {
                    try await Task.sleep(nanoseconds: remaining)
                } catch {
                    localPreviewWaitingForThrottle = false
                    return
                }
                localPreviewWaitingForThrottle = false
            }
            guard !localPreviewIsBlockedByFinal else { return }
            guard let work = localPreviewPlanner.takeLatest() else { return }
            let source = work.update.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }

            localPreviewLastStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let translationStarted = localPreviewLastStartedUptimeNanoseconds
            do {
                let response = try await applePreviewTranslationService().translate(
                    source,
                    highFidelity: false
                )
                let translationCompleted = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled,
                      localPreviewPlanner.accepts(work),
                      let translated = EnglishSubtitleValidator.normalizedEnglish(response),
                      translated != localPreviewSegment?.text
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
                    boundaryKind: nil,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    speechEnd: rangeEnd,
                    endpointDetectedAt: -1,
                    vadOnlyEndpointAt: -1,
                    queueMilliseconds: translationStarted > work.receivedUptimeNanoseconds
                        ? Double(translationStarted - work.receivedUptimeNanoseconds) / 1_000_000 : 0,
                    asrMilliseconds: work.receivedUptimeNanoseconds > sourceEndUptime
                        ? Double(work.receivedUptimeNanoseconds - sourceEndUptime) / 1_000_000 : 0,
                    translationMilliseconds: translationCompleted > translationStarted
                        ? Double(translationCompleted - translationStarted) / 1_000_000 : 0,
                    renderedUptimeNanoseconds: rendered,
                    sourceText: source,
                    englishText: translated,
                    revision: localPreviewRevision,
                    previewLatencyMilliseconds: rendered > sourceStartUptime
                        ? Double(rendered - sourceStartUptime) / 1_000_000 : 0,
                    firstLexicalUptimeNanoseconds: work.firstLexicalUptimeNanoseconds,
                    sourceEligibleUptimeNanoseconds: work.receivedUptimeNanoseconds,
                    translationStartedUptimeNanoseconds: translationStarted,
                    translationCompletedUptimeNanoseconds: translationCompleted
                ))
            } catch {
                guard !Task.isCancelled else { return }
                if case AppleLiveError.translationAssetsUnavailable = error {
                    disableLocalPreview(error)
                    return
                }
                livePreviewError = "Live preview delayed: \(error.localizedDescription) Retrying with the next update."
            }
        }
    }

    @MainActor
    private func suspendLocalPreview(for decision: LocalEndpointDecision) {
        guard activeLocalTranslationMode.showsPreview else { return }
        localPreviewPlanner.advanceBoundary(through: decision.stableThrough)
        if localPreviewWaitingForThrottle {
            localPreviewTranslationTask?.cancel()
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func completeLocalFinalWork(through sample: Int) {
        guard activeLocalTranslationMode.showsPreview else { return }
        if LocalPreviewRangePolicy.shouldClear(
            preview: localPreviewSegment,
            finalizedThrough: sample
        ) {
            localPreviewSegment = nil
        }
        guard localPreviewRuntimeEnabled else { return }
        startLocalPreviewWorkerIfNeeded()
    }

    @MainActor
    private var localPreviewIsBlockedByFinal: Bool {
        localFinalTranslationInFlight
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
        await appleSpeechService().cancel()
        await applePreviewTranslationService().cancel()
        await localPreviewTranslationTask?.value
        localPreviewTranslationTask = nil
        localPreviewWorkerRunning = false
        publishLocalCaptions()
    }

    /// SpeechAnalyzer waits until it has consumed the requested timestamp.
    /// Keep that wait outside the PCM producer so capture can continue feeding it.
    @available(macOS 26.4, *)
    @MainActor
    private func startLocalPreviewSpeechFinalization() {
        guard localPreviewSpeechFinalizeTask == nil else { return }
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
        if engine.usesContinuousVoxtral {
            await runContinuousVoxtralAppleCaptions(
                recorder: recorder,
                engine: engine,
                sourceLocale: sourceLocale
            )
            return
        }
        let fifo = LocalEndpointFIFO()

        async let producerError: Error? = producePrototypeEndpoints(
            recorder: recorder,
            engine: engine,
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
            localSourcePipelineFailure = error.localizedDescription
            liveError = error.localizedDescription
        }
    }

    /// The production Voxtral path owns one helper session for the complete
    /// recording. Logical subtitle boundaries only stage text for Apple; they
    /// never finish, reset, or replay the ASR stream.
    @available(macOS 26.4, *)
    @MainActor
    private func runContinuousVoxtralAppleCaptions(
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String
    ) async {
        let fifo = LocalEndpointFIFO()
        let markerCalibration = VoxtralMarkerCalibration.fromEnvironment(
            ProcessInfo.processInfo.environment
        )
        localVoxtralMarkerCalibration = markerCalibration
        let diarizationReady: Bool
        if LocalDiarizationShadowConfiguration.isEnabled {
            diarizationReady = await localDiarizationShadow.status().isReady
        } else {
            diarizationReady = false
        }
        localDiarizationAssistActive = LocalDiarizationShadowConfiguration.canInfluenceBoundaries
            && diarizationReady
            && markerCalibration?.permitsSpeakerBoundaries == true
        localVoxtralSpeakerMarkersAreAuthoritative = localDiarizationAssistActive
        localVoxtralClausePlanner = VoxtralClausePlanner(
            // Shadow mode must remain byte-for-byte and timing-equivalent to
            // the baseline. Calibration affects boundaries only in assist.
            markerCalibration: localDiarizationAssistActive ? markerCalibration : nil
        )
        localContinuousVoxtralAcknowledgedSampleCount = 0
        localContinuousVoxtralTranscript = ""
        localContinuousVoxtralFailure = nil
        localContinuousVoxtralCatchUpThrough = nil
        localContinuousVoxtralBoundaryQueue = []
        localContinuousVoxtralBoundaryDrainActive = false
        localContinuousVoxtralLastStagedGeneration = -1
        localVoxtralReplayDeduplicator = nil
        localPreviewSentSampleCount = 0
        localVoxtralPreviewSourceText = ""
        if LocalDiarizationShadowConfiguration.isAssistRequestedButUnpromoted {
            livePreviewError = "Speaker changes are in shadow mode only: no tested diarizer met the promotion thresholds. Punctuation and pauses remain authoritative."
        } else if LocalDiarizationShadowConfiguration.canInfluenceBoundaries,
           !localDiarizationAssistActive {
            livePreviewError = diarizationReady
                ? "Speaker changes are being measured only: a validated Voxtral marker calibration is required before they may split subtitles."
                : "Speaker changes are unavailable; punctuation and pauses remain active."
        }

        var diarizationTask: Task<Void, Never>?
        if LocalDiarizationShadowConfiguration.isEnabled {
            localDiarizationGeneration &+= 1
            let generation = localDiarizationGeneration
            await localDiarizationShadow.reset()
            await localDiarizationJournal.reset()
            if await localDiarizationShadow.status().isReady {
                diarizationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.produceDiarizationShadow(
                        recorder: recorder,
                        generation: generation,
                        fifo: fifo
                    )
                }
            }
        }

        async let consumer: Void = consumePrototypeEndpoints(
            recorder: recorder,
            engine: engine,
            sourceLocale: sourceLocale,
            fifo: fifo
        )
        var restartCount = 0

        while !Task.isCancelled {
            let voxtralEvents: AsyncStream<VoxtralHelperEvent>
            do {
                if restartCount == 0 {
                    voxtralEvents = try await localModelManager.startContinuousVoxtral()
                } else {
                    voxtralEvents = try await localModelManager.recoverContinuousVoxtral()
                }
            } catch {
                localContinuousVoxtralFailure = "Voxtral helper could not start: \(error.localizedDescription)"
                localSourcePipelineFailure = localContinuousVoxtralFailure
                liveError = localContinuousVoxtralFailure
                break
            }

            let eventTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await event in voxtralEvents {
                    guard !Task.isCancelled else { return }
                    if await self.handleContinuousVoxtralEvent(event, fifo: fifo) {
                        return
                    }
                }
            }
            let producerError = await produceContinuousVoxtralAudio(
                recorder: recorder,
                fifo: fifo
            )

            if producerError == nil {
                await eventTask.value
                break
            }

            eventTask.cancel()
            await eventTask.value
            await localModelManager.cancelContinuousVoxtral()
            guard restartCount == 0,
                  recorder.state == .recording || recorder.state == .saving,
                  !Task.isCancelled else {
                localContinuousVoxtralFailure = producerError?.localizedDescription
                localSourcePipelineFailure = localContinuousVoxtralFailure
                liveError = localContinuousVoxtralFailure
                break
            }

            restartCount += 1
            let previousTranscript = localContinuousVoxtralTranscript
            let previousLiveCursor = localPreviewSentSampleCount
            let replayStart = max(
                0,
                localVoxtralClausePlanner.sourceStagedThrough
                    - VoxtralClausePlanner.stabilityGuard
            )
            localVoxtralReplayDeduplicator = VoxtralReplayDeduplicator(
                previousTranscript: previousTranscript
            )
            // Replay marker offsets are relative to the restarted helper's
            // raw transcript, not to the deduplicated application transcript.
            // Keep diarization observational for the rest of this recording.
            await disableDiarizationAssist(
                reason: "voxtralHelperRestart",
                observedThrough: localContinuousVoxtralAcknowledgedSampleCount
            )
            localPreviewSentSampleCount = replayStart
            localContinuousVoxtralAcknowledgedSampleCount = replayStart
            localContinuousVoxtralTranscript = ""
            localContinuousVoxtralFailure = nil
            localContinuousVoxtralCatchUpThrough = previousLiveCursor
            localSourcePipelineFailure = nil
            liveError = nil
            setLocalStatus("Restarting the local Voxtral stream…")
        }
        await fifo.finishProducing()
        await consumer
        if let diarizationTask {
            do {
                try await withAsyncDeadline(
                    .seconds(2),
                    operationName: "LS-EEND shadow shutdown"
                ) {
                    await diarizationTask.value
                }
            } catch {
                localDiarizationGeneration &+= 1
                diarizationTask.cancel()
                await disableDiarizationAssist(
                    reason: "diarizationShutdownTimeout",
                    observedThrough: recorder.accumulatedSampleCount
                )
            }
        }
    }

    /// Optional LS-EEND observer. It owns no subtitle or PCM cursor and is
    /// deliberately scheduled independently from the critical Voxtral feed.
    @available(macOS 26.4, *)
    @MainActor
    private func produceDiarizationShadow(
        recorder: AudioRecorder,
        generation: UInt64,
        fifo: LocalEndpointFIFO
    ) async {
        let block = 1_600 // 100 ms at 16 kHz
        var sent = 0
        while !Task.isCancelled, generation == localDiarizationGeneration {
            let total = recorder.accumulatedSampleCount
            if total - sent > VoxtralClausePlanner.maximumDiarizationLag {
                await disableDiarizationAssist(
                    reason: "diarizationBacklog",
                    observedThrough: total
                )
            }
            let captureEnded = recorder.state != .recording
            if sent >= total {
                if captureEnded { break }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let end = captureEnded ? min(total, sent + block) : sent + block
            guard end <= total else {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let samples = recorder.getSamples(from: sent, upTo: end)
            guard samples.count == end - sent else {
                await disableDiarizationAssist(
                    reason: "diarizationPCMUnavailable",
                    observedThrough: total
                )
                break
            }
            let updates = await localDiarizationShadow.append(
                samples: samples,
                range: sent..<end
            )
            guard !Task.isCancelled,
                  generation == localDiarizationGeneration else { return }
            let capturedThrough = recorder.accumulatedSampleCount
            await localDiarizationJournal.append(
                updates,
                observedThrough: capturedThrough
            )
            sent = end
            await applyDiarizationUpdates(
                updates,
                capturedThrough: capturedThrough,
                fifo: fifo
            )
            let status = await localDiarizationShadow.status()
            if !status.isReady {
                await disableDiarizationAssist(
                    reason: status.failureReason.map {
                        "diarizationUnavailable:\($0)"
                    } ?? "diarizationUnavailable",
                    observedThrough: sent
                )
                break
            }
        }
        guard !Task.isCancelled,
              generation == localDiarizationGeneration else { return }
        let updates = await localDiarizationShadow.finish()
        guard !Task.isCancelled,
              generation == localDiarizationGeneration else { return }
        let capturedThrough = recorder.accumulatedSampleCount
        await localDiarizationJournal.append(
            updates,
            observedThrough: capturedThrough
        )
        await applyDiarizationUpdates(
            updates,
            capturedThrough: capturedThrough,
            fifo: fifo
        )
        _ = try? await localDiarizationJournal.writeOptInReport()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func applyDiarizationUpdates(
        _ updates: [LocalDiarizationUpdate],
        capturedThrough: Int,
        fifo: LocalEndpointFIFO
    ) async {
        guard localDiarizationAssistActive,
              localVoxtralSpeakerMarkersAreAuthoritative else { return }
        for update in updates {
            guard let transition = update.transition else { continue }
            let lag = max(0, capturedThrough - transition.confirmedAtSample)
            guard lag <= VoxtralClausePlanner.maximumDiarizationLag else {
                await disableDiarizationAssist(
                    reason: "diarizationLagFallback",
                    observedThrough: capturedThrough
                )
                return
            }
            if let boundary = localVoxtralClausePlanner.observe(
                fedThrough: localContinuousVoxtralAcknowledgedSampleCount,
                speakerTransitions: [transition]
            ) {
                await stageContinuousVoxtralBoundary(boundary, fifo: fifo)
            }
        }
        publishContinuousVoxtralPreview()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func disableDiarizationAssist(
        reason: String,
        observedThrough: Int
    ) async {
        let wasActive = localDiarizationAssistActive
            || localVoxtralSpeakerMarkersAreAuthoritative
        localDiarizationAssistActive = false
        localVoxtralSpeakerMarkersAreAuthoritative = false
        localVoxtralClausePlanner.discardSpeakerEvidence()
        guard wasActive else { return }
        await localDiarizationJournal.appendAssistDisabled(
            reason: reason,
            observedThrough: observedThrough
        )
        livePreviewError = "Speaker-change assistance is unavailable (\(reason)); punctuation and pauses remain active."
    }

    @available(macOS 26.4, *)
    @MainActor
    private func produceContinuousVoxtralAudio(
        recorder: AudioRecorder,
        fifo: LocalEndpointFIFO
    ) async -> Error? {
        var vadAnalyzedEnd = 0
        let catchUpDeadline = DispatchTime.now().uptimeNanoseconds
            + 30_000_000_000

        do {
            while recorder.state == .recording, !Task.isCancelled {
                if let failure = localContinuousVoxtralFailure {
                    throw VoxtralHelperError.protocolFailure(failure)
                }
                let total = recorder.accumulatedSampleCount
                guard total - vadAnalyzedEnd >= 1_600 else {
                    try await Task.sleep(for: .milliseconds(40))
                    continue
                }

                try await feedContinuousVoxtralSamples(
                    recorder: recorder,
                    through: total,
                    completeBlocksOnly: true
                )

                let earliestRetained = max(
                    0,
                    localCommittedSampleCount - VoxtralClausePlanner.stabilityGuard
                )
                let windowStart = max(earliestRetained, total - 16_000 * 3)
                let window = recorder.getSamples(from: windowStart, upTo: total)
                if !window.isEmpty {
                    let speech = try await localModelManager.detectSpeech(
                        audio: window,
                        windowStart: windowStart
                    )
                    noteContinuousVoxtralSpeech(speech)
                    if let boundary = localVoxtralClausePlanner.observe(
                        fedThrough: localContinuousVoxtralAcknowledgedSampleCount,
                        speech: speech
                    ) {
                        await stageContinuousVoxtralBoundary(boundary, fifo: fifo)
                    }
                    publishContinuousVoxtralPreview()
                }
                vadAnalyzedEnd = total

                let progress = await localModelManager.continuousVoxtralProgress()
                if let catchUpThrough = localContinuousVoxtralCatchUpThrough {
                    if (progress.acknowledgedThrough ?? 0) >= catchUpThrough {
                        localContinuousVoxtralCatchUpThrough = nil
                    } else if DispatchTime.now().uptimeNanoseconds >= catchUpDeadline {
                        throw VoxtralHelperError.serverUnavailable(
                            "Voxtral could not catch up after its one automatic restart. Audio was retained."
                        )
                    }
                }
                let combinedResident = localModelManager.currentMemoryBytes()
                    + (progress.helperRSSBytes ?? 0)
                if combinedResident >= 10 * 1_024 * 1_024 * 1_024 {
                    throw LocalPrototypeError.memoryLimit(combinedResident)
                }
                if combinedResident > 8 * 1_024 * 1_024 * 1_024,
                   livePreviewError == nil {
                    livePreviewError = "Voxtral is above the 8 GB memory target; the 10 GB safety limit remains enforced."
                }
            }

            let finalTotal = recorder.accumulatedSampleCount
            try await feedContinuousVoxtralSamples(
                recorder: recorder,
                through: finalTotal,
                completeBlocksOnly: false
            )
            _ = try await localModelManager.finishContinuousVoxtral()
            return nil
        } catch {
            localContinuousVoxtralFailure = error.localizedDescription
            localSourcePipelineFailure = localContinuousVoxtralFailure
            liveError = localContinuousVoxtralFailure
            await localModelManager.cancelContinuousVoxtral()
            return error
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func feedContinuousVoxtralSamples(
        recorder: AudioRecorder,
        through target: Int,
        completeBlocksOnly: Bool
    ) async throws {
        let block = VoxtralClausePlanner.sampleRate
            * VoxtralHelperManifest.transportBlockMilliseconds / 1_000
        while localPreviewSentSampleCount < target {
            let remaining = target - localPreviewSentSampleCount
            if completeBlocksOnly, remaining < block { return }
            let start = localPreviewSentSampleCount
            let end = min(target, start + block)
            let samples = recorder.getSamples(from: start, upTo: end)
            guard samples.count == end - start else {
                throw VoxtralHelperError.invalidAudioRange(
                    expected: start,
                    actual: start..<end,
                    sampleCount: samples.count
                )
            }
            try await localModelManager.feedContinuousVoxtral(
                samples: samples,
                range: start..<end
            )
            localPreviewSentSampleCount = end
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func handleContinuousVoxtralEvent(
        _ event: VoxtralHelperEvent,
        fifo: LocalEndpointFIFO
    ) async -> Bool {
        switch event {
        case .ready:
            return false
        case .emissionMarker(let marker):
            if LocalDiarizationShadowConfiguration.isEnabled {
                let calibratedEnd = localVoxtralMarkerCalibration.map {
                    $0.calibratedEndSample(for: marker)
                }
                await localDiarizationJournal.appendMarker(
                    marker,
                    calibratedEndSample: calibratedEnd
                )
            }
            guard localDiarizationAssistActive,
                  localVoxtralSpeakerMarkersAreAuthoritative else { return false }
            if let boundary = localVoxtralClausePlanner.observe(
                fedThrough: localContinuousVoxtralAcknowledgedSampleCount,
                emissionMarkers: [marker]
            ) {
                await stageContinuousVoxtralBoundary(boundary, fifo: fifo)
            }
            publishContinuousVoxtralPreview()
            return false
        case .acknowledged(let through):
            localContinuousVoxtralAcknowledgedSampleCount = max(
                localContinuousVoxtralAcknowledgedSampleCount,
                through
            )
            if let boundary = localVoxtralClausePlanner.observe(
                fedThrough: localContinuousVoxtralAcknowledgedSampleCount
            ) {
                await stageContinuousVoxtralBoundary(boundary, fifo: fifo)
            }
            publishContinuousVoxtralPreview()
            return false
        case .delta(let rawDelta, let sentThrough):
            let delta: String
            if var replay = localVoxtralReplayDeduplicator {
                localContinuousVoxtralTranscript += rawDelta
                guard let replayDelta = replay.ingest(localContinuousVoxtralTranscript) else {
                    localContinuousVoxtralFailure = "Voxtral replay could not be deduplicated safely; its audio remains available for retry."
                    localSourcePipelineFailure = localContinuousVoxtralFailure
                    liveError = localContinuousVoxtralFailure
                    return true
                }
                localVoxtralReplayDeduplicator = replay
                delta = replayDelta
            } else {
                localContinuousVoxtralTranscript += rawDelta
                delta = rawDelta
            }
            if let boundary = localVoxtralClausePlanner.observe(
                delta: delta,
                fedThrough: localContinuousVoxtralAcknowledgedSampleCount,
                sourceUpdateThrough: sentThrough
            ) {
                await stageContinuousVoxtralBoundary(boundary, fifo: fifo)
            }
            publishContinuousVoxtralPreview()
            return false
        case .completed(let transcript, let sentThrough):
            let finalDelta: String
            if var replay = localVoxtralReplayDeduplicator {
                guard let replayDelta = replay.ingest(transcript, finishing: true) else {
                    localContinuousVoxtralFailure = "Voxtral final replay could not be deduplicated safely. The audio was retained."
                    localSourcePipelineFailure = localContinuousVoxtralFailure
                    liveError = localContinuousVoxtralFailure
                    return true
                }
                localVoxtralReplayDeduplicator = replay
                finalDelta = replayDelta
            } else if transcript.hasPrefix(localContinuousVoxtralTranscript) {
                finalDelta = String(
                    transcript.dropFirst(localContinuousVoxtralTranscript.count)
                )
            } else if localContinuousVoxtralTranscript.isEmpty {
                finalDelta = transcript
            } else {
                localContinuousVoxtralFailure = "Voxtral final source differed from its append-only stream. The audio was retained."
                localSourcePipelineFailure = localContinuousVoxtralFailure
                liveError = localContinuousVoxtralFailure
                return true
            }
            localContinuousVoxtralTranscript = transcript
            let finalThrough = max(
                localContinuousVoxtralAcknowledgedSampleCount,
                sentThrough ?? localPreviewSentSampleCount
            )
            if let tail = localVoxtralClausePlanner.finish(
                delta: finalDelta,
                fedThrough: finalThrough
            ) {
                await stageContinuousVoxtralBoundary(tail, fifo: fifo)
            }
            return true
        case .failed(let message):
            localContinuousVoxtralFailure = "Voxtral helper failed: \(message)"
            localSourcePipelineFailure = localContinuousVoxtralFailure
            liveError = localSourcePipelineFailure
            return true
        }
    }

    @MainActor
    private func noteContinuousVoxtralSpeech(_ speech: [SpeechSampleRange]) {
        guard let first = speech.first(where: {
            $0.end > localVoxtralClausePlanner.sourceStagedThrough
        }) else { return }
        localPreviewFeedStarted = true
        if localPreviewSpeechStartSample == nil {
            localPreviewSpeechStartSample = max(
                localVoxtralClausePlanner.sourceStagedThrough,
                first.start
            )
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func stageContinuousVoxtralBoundary(
        _ boundary: VoxtralClauseBoundary,
        fifo: LocalEndpointFIFO
    ) async {
        localContinuousVoxtralBoundaryQueue.append(boundary)
        if !localContinuousVoxtralBoundaryDrainActive {
            localContinuousVoxtralBoundaryDrainActive = true
            defer { localContinuousVoxtralBoundaryDrainActive = false }

            while !localContinuousVoxtralBoundaryQueue.isEmpty {
                let next = localContinuousVoxtralBoundaryQueue.removeFirst()
                await stageContinuousVoxtralBoundaryNow(next, fifo: fifo)
                localContinuousVoxtralLastStagedGeneration = max(
                    localContinuousVoxtralLastStagedGeneration,
                    next.generation
                )
            }
        }

        // A second producer can enqueue while the first caller is suspended in
        // fifo.stage. Do not let that caller finish (especially at shutdown)
        // until its own generation has actually reached the FIFO.
        while localContinuousVoxtralLastStagedGeneration < boundary.generation {
            await Task.yield()
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func stageContinuousVoxtralBoundaryNow(
        _ boundary: VoxtralClauseBoundary,
        fifo: LocalEndpointFIFO
    ) async {
        let kind: LocalEndpointDecision.Kind
        switch boundary.kind {
        case .semantic: kind = .semantic
        case .speaker: kind = .speaker
        case .pause: kind = .pause
        case .forced: kind = .forced
        case .finish: kind = .finish
        }
        let speechEnd = boundary.kind == .pause
            ? max(
                boundary.sampleRange.lowerBound,
                boundary.endpointDetectedAt - VoxtralClausePlanner.vadSilence
            )
            : boundary.sampleRange.upperBound
        let decision = LocalEndpointDecision(
            kind: kind,
            audioStart: boundary.sampleRange.lowerBound,
            audioEnd: boundary.sampleRange.upperBound,
            speechEnd: speechEnd,
            endpointDetectedAt: boundary.endpointDetectedAt,
            vadOnlyEndpointAt: boundary.kind == .pause
                ? boundary.endpointDetectedAt : -1,
            stableThrough: boundary.sampleRange.upperBound,
            cleanBreak: boundary.kind != .forced
        )
        suspendLocalPreview(for: decision)
        localVoxtralPreviewSourceText = ""
        localPreviewSpeechStartSample = nil
        await fifo.stage(
            decision,
            voxtralText: boundary.sourceText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
        if LocalDiarizationShadowConfiguration.isEnabled {
            await localDiarizationJournal.appendBoundary(
                kind: boundary.kind.rawValue,
                detectedAt: boundary.endpointDetectedAt,
                stagedAt: boundary.stagedAt
            )
            switch boundary.speakerDecision {
            case .applied(let transition):
                await localDiarizationJournal.appendSpeakerDecision(
                    accepted: true,
                    transition: transition,
                    reason: "matchedEmissionGroup",
                    boundaryKind: boundary.kind.rawValue
                )
            case .markerTimedOut(let transition):
                await localDiarizationJournal.appendSpeakerDecision(
                    accepted: false,
                    transition: transition,
                    reason: "markerTimedOut",
                    boundaryKind: boundary.kind.rawValue
                )
            case .diarizationLagFallback(let transition):
                await localDiarizationJournal.appendSpeakerDecision(
                    accepted: false,
                    transition: transition,
                    reason: "diarizationLagFallback",
                    boundaryKind: boundary.kind.rawValue
                )
            case nil:
                break
            }
        }
        publishContinuousVoxtralPreview()
    }

    @available(macOS 26.4, *)
    @MainActor
    private func publishContinuousVoxtralPreview() {
        guard localPreviewRuntimeEnabled,
              activeLocalTranslationMode.showsPreview,
              let preview = localVoxtralClausePlanner.preview else { return }
        let source = preview.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source != localVoxtralPreviewSourceText,
              preview.sampleRange.upperBound > preview.sampleRange.lowerBound else { return }
        localVoxtralPreviewSourceText = source
        receiveLocalPreviewSource(LiveSourceUpdate(
            segment: TranscriptionSegment(
                start: Double(preview.sampleRange.lowerBound) / 16_000,
                end: Double(preview.sampleRange.upperBound) / 16_000,
                text: source
            ),
            isFinal: false,
            finalizedThroughSample: localSourceFinalizedSampleCount
        ))
    }

    /// Capture/VAD producer. It never waits for final ASR or Apple
    /// translation, so every captured sample remains observable in real time.
    @available(macOS 26.4, *)
    @MainActor
    private func producePrototypeEndpoints(
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        fifo: LocalEndpointFIFO
    ) async -> Error? {
        var vadAnalyzedEnd = 0

        do {
            if engine.usesVoxtralStreaming {
                _ = try await localModelManager.startVoxtral()
            }
            while recorder.state == .recording, !Task.isCancelled {
                let total = recorder.accumulatedSampleCount
                guard total - vadAnalyzedEnd >= 1_600 else {
                    try await Task.sleep(for: .milliseconds(40))
                    continue
                }
                if engine.usesAppleSpeechPreview, localPreviewRuntimeEnabled {
                    await feedAppleSpeechPreviewSamples(
                        recorder: recorder,
                        through: total
                    )
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
                let decision = await fifo.propose(
                    totalSample: total,
                    speech: speech
                )
                let feedThrough = decision?.audioEnd ?? total
                if engine.usesVoxtralStreaming {
                    try await feedVoxtralSamples(
                        recorder: recorder,
                        through: feedThrough,
                        completeBlocksOnly: decision == nil
                    )
                }
                if engine.usesAppleSpeechPreview,
                   localPreviewRuntimeEnabled,
                   localPreviewFeedStarted,
                   localPreviewSpeechStartSample != nil,
                   localPreviewSpeechFinalizeTask == nil {
                    let target = total
                    if localAppleSpeechFeed.requestFinalization(
                        through: target,
                        every: LocalAppleSpeechFeedState.progressiveFinalizationInterval
                    ) {
                        startLocalPreviewSpeechFinalization()
                    }
                }
                vadAnalyzedEnd = total
                if let decision {
                    let voxtralText: String?
                    if engine.usesVoxtralStreaming {
                        voxtralText = try await localModelManager.finishVoxtral()
                    } else {
                        voxtralText = nil
                    }
                    suspendLocalPreview(for: decision)
                    if engine.usesVoxtralStreaming {
                        try await startNextVoxtralPhrase(
                            after: decision,
                            recorder: recorder
                        )
                    } else {
                        localPreviewSpeechStartSample = nil
                        localPreviewLastForcedSample = max(
                            localPreviewLastForcedSample,
                            decision.stableThrough
                        )
                    }
                    await fifo.stage(decision, voxtralText: voxtralText)
                }
                let queuedPhrases = await fifo.pendingCount()
                if queuedPhrases > 1 {
                    setLocalStatus(
                        "Catching up — \(queuedPhrases - 1) phrase\(queuedPhrases == 2 ? "" : "s") queued"
                    )
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
            if let decision = await fifo.propose(
                totalSample: finalTotal,
                speech: speech,
                finishing: true
            ) {
                let voxtralText: String?
                if engine.usesVoxtralStreaming {
                    try await feedVoxtralSamples(
                        recorder: recorder,
                        through: decision.audioEnd,
                        completeBlocksOnly: false
                    )
                    voxtralText = try await localModelManager.finishVoxtral()
                } else {
                    voxtralText = nil
                }
                suspendLocalPreview(for: decision)
                await fifo.stage(decision, voxtralText: voxtralText)
            } else if engine.usesVoxtralStreaming {
                _ = try? await localModelManager.finishVoxtral()
            }
            await fifo.finishProducing()
            return nil
        } catch {
            await fifo.finishProducing()
            return error
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func feedAppleSpeechPreviewSamples(
        recorder: AudioRecorder,
        through target: Int
    ) async {
        guard let range = localAppleSpeechFeed.takeNewSamples(through: target) else { return }
        let samples = recorder.getSamples(from: range.lowerBound, upTo: range.upperBound)
        guard samples.count == range.count else {
            disableLocalPreview(LocalPrototypeError.invalidResponse)
            return
        }
        do {
            try await appleSpeechService().send(
                samples: samples,
                startSample: range.lowerBound
            )
        } catch {
            disableLocalPreview(error)
        }
    }

    /// Feeds one stateful Voxtral session in 320 ms blocks. At an endpoint the
    /// final partial block is also sent so `finish()` covers the full range.
    @available(macOS 26.4, *)
    @MainActor
    private func feedVoxtralSamples(
        recorder: AudioRecorder,
        through target: Int,
        completeBlocksOnly: Bool
    ) async throws {
        let block = 16_000 * 320 / 1_000
        while localPreviewSentSampleCount < target {
            let remaining = target - localPreviewSentSampleCount
            if completeBlocksOnly, remaining < block { return }
            let start = localPreviewSentSampleCount
            let end = min(target, start + block)
            let samples = recorder.getSamples(from: start, upTo: end)
            guard samples.count == end - start else {
                throw LocalPrototypeError.invalidResponse
            }
            let source = try await localModelManager.feedVoxtral(samples: samples).transcript
            localPreviewSentSampleCount = end
            publishVoxtralSourceIfChanged(source, through: end)
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func startNextVoxtralPhrase(
        after decision: LocalEndpointDecision,
        recorder: AudioRecorder
    ) async throws {
        localVoxtralPreviewSourceText = ""
        localPreviewLastForcedSample = max(
            localPreviewLastForcedSample,
            decision.stableThrough
        )
        if decision.kind == .forced {
            let replay = recorder.getSamples(
                from: decision.stableThrough,
                upTo: decision.audioEnd
            )
            guard replay.count == decision.audioEnd - decision.stableThrough else {
                throw LocalPrototypeError.invalidResponse
            }
            localPreviewFeedStarted = true
            localPreviewSentSampleCount = decision.audioEnd
            localPreviewSpeechStartSample = decision.stableThrough
            let source = try await localModelManager.startVoxtral(replay: replay)
            publishVoxtralSourceIfChanged(source, through: decision.audioEnd)
        } else {
            _ = try await localModelManager.startVoxtral()
            localPreviewFeedStarted = false
            localPreviewSentSampleCount = decision.audioEnd
            localPreviewSpeechStartSample = nil
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func publishVoxtralSourceIfChanged(_ source: String, through end: Int) {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localPreviewRuntimeEnabled,
              activeLocalEnglishEngine.usesVoxtralSourcePreview,
              !normalized.isEmpty,
              normalized != localVoxtralPreviewSourceText,
              let start = localPreviewSpeechStartSample,
              end > start else { return }
        localVoxtralPreviewSourceText = normalized
        receiveLocalPreviewSource(LiveSourceUpdate(
            segment: TranscriptionSegment(
                start: Double(start) / 16_000,
                end: Double(end) / 16_000,
                text: normalized
            ),
            isFinal: false,
            finalizedThroughSample: localSourceFinalizedSampleCount
        ))
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
                    entry,
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
                if localContinuousVoxtralFailure == nil {
                    localSourcePipelineFailure = nil
                }
                attempts = 0
            } catch {
                attempts += 1
                localSourcePipelineFailure = error.localizedDescription
                liveTranslationError = error.localizedDescription
                setLocalStatus("Audio retained — retrying oldest phrase…")
                guard attempts < 2 else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @available(macOS 26.4, *)
    @MainActor
    private func processPrototypeDecision(
        _ entry: LocalEndpointFIFO.Entry,
        recorder: AudioRecorder,
        engine: LocalEnglishEngine,
        sourceLocale: String,
        queueMilliseconds: Double
    ) async throws {
        let decision = entry.decision
        let audio = recorder.getSamples(from: decision.audioStart, upTo: decision.audioEnd)
        guard audio.count == decision.audioEnd - decision.audioStart else {
            throw LocalPrototypeError.invalidResponse
        }
        setLocalStatus("Finalizing source…")
        let asrStart = DispatchTime.now().uptimeNanoseconds

        let finalText: String
        switch engine {
        case .whisperTurboApple, .voxtralTurboApple:
            let result = try await service.transcribeChunk(
                samples: audio,
                language: Self.languageCode(for: sourceLocale),
                translate: false,
                modelPath: try Self.whisperModelPath(for: engine)
            )
            finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .qwenApple, .voxtralQwenApple:
            finalText = try await localModelManager.transcribeQwen(
                audio: audio,
                language: Self.languageName(for: sourceLocale)
            )
        case .voxtralApple:
            finalText = entry.voxtralText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .voxtralCohereApple:
            let cohere = try? await localModelManager.transcribeCohere(
                    audio: audio,
                    language: Self.languageCode(for: sourceLocale)
                )
            let selection = try LocalFinalSourceSelector.hybrid(
                cohere: cohere,
                voxtral: entry.voxtralText
            )
            finalText = selection.text
            if selection.degraded {
                livePreviewError = "Cohere final unavailable for one phrase; Voxtral was used instead."
            }
        case .whisperLargeV3Direct:
            let result = try await service.transcribeChunk(
                samples: audio,
                language: Self.languageCode(for: sourceLocale),
                translate: true,
                modelPath: try Self.whisperModelPath(for: engine)
            )
            finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cohereApple:
            finalText = try await localModelManager.transcribeCohere(
                audio: audio,
                language: Self.languageCode(for: sourceLocale)
            )
        }
        guard !finalText.isEmpty else { throw LocalPrototypeError.invalidResponse }
        let segment = TranscriptionSegment(
            start: Double(max(localSourceFinalizedSampleCount, decision.audioStart)) / 16_000,
            end: Double(decision.speechEnd) / 16_000,
            text: finalText
        )
        let asrMilliseconds = Self.elapsedMilliseconds(since: asrStart)
        let queued = engine.producesDirectEnglish
            ? enqueueDirectEnglish(
                segment,
                decision: decision,
                queueMilliseconds: queueMilliseconds,
                asrMilliseconds: asrMilliseconds
            )
            : enqueueLocalSource(
                segment,
                decision: decision,
                queueMilliseconds: queueMilliseconds,
                asrMilliseconds: asrMilliseconds
            )
        if !queued {
            if engine.usesContinuousVoxtral {
                throw LocalPrototypeError.cursorMismatch(
                    "A staged Voxtral clause could not be queued for English translation. Its PCM was retained."
                )
            }
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

    private static func whisperModelPath(for engine: LocalEnglishEngine) throws -> String {
        guard let modelID = engine.whisperModelID,
              let model = ModelCatalog.model(id: modelID) else {
            throw LocalPrototypeError.modelNotLoaded(engine.label)
        }
        let path = ModelCatalog.path(for: model).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalPrototypeError.modelNotLoaded(model.displayName)
        }
        return path
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
    @MainActor
    func stopLiveTranscription() {
        localPreviewRuntimeEnabled = false
        let previewTask = localPreviewTranslationTask
        previewTask?.cancel()
        localPreviewTranslationTask = nil
        let speechFinalizeTask = localPreviewSpeechFinalizeTask
        speechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        let transcriptionTask = liveTranscriptionTask
        transcriptionTask?.cancel()
        liveTranscriptionTask = nil
        let translationTask = liveTranslationTask
        translationTask?.cancel()
        liveTranslationTask = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if #available(macOS 26.4, *) {
                // Cancel the volatile lane first, then close the ASR helper so
                // no task can publish into state after reset.
                await self.appleSpeechService().cancel()
                await self.applePreviewTranslationService().cancel()
                await self.localModelManager.cancelContinuousVoxtral()
            }
            await previewTask?.value
            await speechFinalizeTask?.value
            await transcriptionTask?.value
            await translationTask?.value
            if #available(macOS 26.4, *),
               let translation = self.appleTranslationRuntime as? AppleTranslationService {
                await translation.cancel()
            }
            self.service.endRealtimeSession()
            self.resetLiveState()
        }
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
        localFinalTranslationInFlight = false
        localFinalTranslationState = .idle
        localPreviewPlanner = LocalPreviewPlanner()
        localPreviewSegment = nil
        localPreviewTranslationTask?.cancel()
        localPreviewTranslationTask = nil
        localPreviewSpeechFinalizeTask?.cancel()
        localPreviewSpeechFinalizeTask = nil
        localPreviewWorkerRunning = false
        localPreviewWaitingForThrottle = false
        localPreviewLastStartedUptimeNanoseconds = 0
        localPreviewRevision = 0
        localAppleSpeechFeed = LocalAppleSpeechFeedState()
        localPreviewSentSampleCount = 0
        localPreviewSpeechStartSample = nil
        localPreviewFeedStarted = false
        localVoxtralPreviewSourceText = ""
        localVoxtralClausePlanner = VoxtralClausePlanner()
        localContinuousVoxtralAcknowledgedSampleCount = 0
        localContinuousVoxtralTranscript = ""
        localContinuousVoxtralFailure = nil
        localContinuousVoxtralCatchUpThrough = nil
        localDiarizationAssistActive = false
        localVoxtralSpeakerMarkersAreAuthoritative = false
        localVoxtralMarkerCalibration = nil
        localVoxtralReplayDeduplicator = nil
        localPreviewLastForcedSample = 0
        localRecordingStartedUptimeNanoseconds = 0
        localPreviewRuntimeEnabled = false
        localCommittedSampleCount = 0
        localSourceFinalizedSampleCount = 0
        localSourcePipelineFailure = nil
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
        enqueueLocalFinal(
            .japaneseSource(normalized),
            index: index,
            decision: decision,
            queueMilliseconds: queueMilliseconds,
            asrMilliseconds: asrMilliseconds
        )
        return true
    }

    @MainActor
    private func enqueueDirectEnglish(
        _ segment: TranscriptionSegment,
        decision: LocalEndpointDecision? = nil,
        queueMilliseconds: Double = 0,
        asrMilliseconds: Double = 0
    ) -> Bool {
        var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let previous = localTranslationQueue.last?.source ?? localCommittedSegments.last
        if let previous {
            if abs(previous.start - segment.start) < 0.01,
               abs((previous.end ?? previous.start) - (segment.end ?? segment.start)) < 0.01,
               previous.text == text {
                return false
            }
            if segment.start < (previous.end ?? previous.start) {
                text = Self.trimEnglishOverlap(previous: previous.text, current: text)
            }
        }
        guard !text.isEmpty else { return false }
        let normalized = TranscriptionSegment(
            start: segment.start,
            end: segment.end,
            text: text
        )
        enqueueLocalFinal(
            .directEnglish(normalized),
            index: localCommittedSegments.count + localTranslationQueue.count,
            decision: decision,
            queueMilliseconds: queueMilliseconds,
            asrMilliseconds: asrMilliseconds
        )
        return true
    }

    @MainActor
    private func enqueueLocalFinal(
        _ input: LocalFinalInput,
        index: Int,
        decision: LocalEndpointDecision?,
        queueMilliseconds: Double,
        asrMilliseconds: Double
    ) {
        localTranslationQueue.append(LocalTranslationJob(
            index: index,
            input: input,
            decision: decision,
            queueMilliseconds: queueMilliseconds,
            asrMilliseconds: asrMilliseconds,
            enqueuedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
        localFinalTranslationState.noteEnqueued(
            isOnlyJob: localTranslationQueue.count == 1
        )
        setLocalStatus(liveStatusText)
        startLocalTranslationWorkerIfNeeded()
    }

    @MainActor
    private func startLocalTranslationWorkerIfNeeded() {
        guard !localTranslationWorkerRunning,
              let first = localTranslationQueue.first,
              !first.attempts.exhausted else { return }
        guard #available(macOS 26.4, *) else { return }
        localTranslationWorkerRunning = true
        liveTranslationTask = Task { @MainActor [weak self] in
            await self?.drainLocalTranslationQueue()
        }
    }

    @MainActor
    @available(macOS 26.4, *)
    private func drainLocalTranslationQueue() async {
        defer {
            localFinalTranslationInFlight = false
            localTranslationWorkerRunning = false
            startLocalPreviewWorkerIfNeeded()
        }
        while !Task.isCancelled, var job = localTranslationQueue.first {
            guard !job.attempts.exhausted else { return }
            let attempt = job.attempts.begin()
            localTranslationQueue[0] = job
            localFinalTranslationState = .translating(attempt: attempt)
            liveStatusText = localFinalTranslationState.statusText ?? liveStatusText
            localFinalTranslationInFlight = true
            let translationStart = DispatchTime.now().uptimeNanoseconds
            let finalQueueMilliseconds = translationStart > job.enqueuedUptimeNanoseconds
                ? Double(translationStart - job.enqueuedUptimeNanoseconds) / 1_000_000
                : 0
            do {
                let text: String
                switch job.input {
                case .japaneseSource(let source):
                    text = try await translateStableSource(
                        source.text,
                        mode: activeLocalTranslationMode
                    )
                case .directEnglish(let english):
                    text = try EnglishSubtitleValidator.requireEnglish(english.text)
                }
                let translationCompleted = DispatchTime.now().uptimeNanoseconds
                localFinalTranslationInFlight = false
                startLocalPreviewWorkerIfNeeded()
                let normalized = text
                guard localTranslationQueue.first?.index == job.index else { continue }
                if let decision = job.decision,
                   activeLocalEnglishEngine.usesContinuousVoxtral,
                   !localVoxtralClausePlanner.validate(through: decision.stableThrough) {
                    throw LocalPrototypeError.cursorMismatch(
                        "Voxtral English validation did not match the oldest staged PCM range. No audio was released."
                    )
                }
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
                    let retainedOverlap = activeLocalEnglishEngine.usesContinuousVoxtral
                        ? VoxtralClausePlanner.stabilityGuard
                        : LocalEndpointPlanner.forcedOverlap
                    let requestedTrim = max(
                        0, localCommittedSampleCount - retainedOverlap
                    )
                    activeLocalRecorder?.trimSamples(upTo: requestedTrim)
                    completeLocalFinalWork(through: decision.stableThrough)
                }
                localFinalTranslationState = localTranslationQueue.isEmpty ? .idle : .queued
                liveTranslationError = nil
                publishLocalCaptions()
                await recordLocalFinalTranslationAttempt(
                    job: job,
                    attempt: attempt,
                    outcome: "success",
                    classification: nil,
                    started: translationStart,
                    completed: translationCompleted,
                    backoffMilliseconds: nil,
                    englishText: normalized
                )
                if let decision = job.decision {
                    await localMetricRecorder.append(LocalCaptionMetric(
                        kind: .final,
                        engine: activeLocalEnglishEngine.rawValue,
                        boundaryKind: decision.kind.rawValue,
                        rangeStart: decision.audioStart,
                        rangeEnd: decision.audioEnd,
                        speechEnd: decision.speechEnd,
                        endpointDetectedAt: decision.endpointDetectedAt,
                        vadOnlyEndpointAt: decision.vadOnlyEndpointAt,
                        queueMilliseconds: job.queueMilliseconds + finalQueueMilliseconds,
                        asrMilliseconds: job.asrMilliseconds,
                        translationMilliseconds: translationCompleted > translationStart
                            ? Double(translationCompleted - translationStart) / 1_000_000 : 0,
                        renderedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        sourceText: job.source.text,
                        englishText: normalized,
                        revision: nil,
                        previewLatencyMilliseconds: nil,
                        firstLexicalUptimeNanoseconds: nil,
                        sourceEligibleUptimeNanoseconds: nil,
                        translationStartedUptimeNanoseconds: translationStart,
                        translationCompletedUptimeNanoseconds: translationCompleted
                    ))
                }
            } catch {
                let translationCompleted = DispatchTime.now().uptimeNanoseconds
                localFinalTranslationInFlight = false
                startLocalPreviewWorkerIfNeeded()
                guard localTranslationQueue.first?.index == job.index else { continue }
                var failedJob = localTranslationQueue[0]
                let failure = failedJob.attempts.record(error)
                localTranslationQueue[0] = failedJob
                switch failure.disposition {
                case .retry(let delay):
                    let backoffMilliseconds = LocalFinalTranslationRetryPolicy
                        .backoffMilliseconds(afterAttempt: attempt)
                    localFinalTranslationState = .retrying(
                        nextAttempt: attempt + 1
                    )
                    liveTranslationError = nil
                    liveStatusText = localFinalTranslationState.statusText ?? liveStatusText
                    await recordLocalFinalTranslationAttempt(
                        job: job,
                        attempt: attempt,
                        outcome: "retry",
                        classification: failure.classification,
                        started: translationStart,
                        completed: translationCompleted,
                        backoffMilliseconds: backoffMilliseconds.map { Double($0) },
                        englishText: ""
                    )
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                case .retain:
                    localFinalTranslationState = .failedRetained
                    liveTranslationError = "Final failed — audio retained: \(error.localizedDescription)"
                    liveStatusText = localFinalTranslationState.statusText ?? liveStatusText
                    await recordLocalFinalTranslationAttempt(
                        job: job,
                        attempt: attempt,
                        outcome: "retained",
                        classification: failure.classification,
                        started: translationStart,
                        completed: translationCompleted,
                        backoffMilliseconds: nil,
                        englishText: ""
                    )
                    return
                }
            }
        }
        publishLocalCaptions()
    }

    @MainActor
    private func recordLocalFinalTranslationAttempt(
        job: LocalTranslationJob,
        attempt: Int,
        outcome: String,
        classification: LocalFinalTranslationErrorClassification?,
        started: UInt64,
        completed: UInt64,
        backoffMilliseconds: Double?,
        englishText: String
    ) async {
        let decision = job.decision
        let rangeStart = decision?.audioStart
            ?? max(0, Int((job.source.start * 16_000).rounded()))
        let rangeEnd = decision?.audioEnd
            ?? max(rangeStart, Int(((job.source.end ?? job.source.start) * 16_000).rounded()))
        var metric = LocalCaptionMetric(
            kind: .finalAttempt,
            engine: activeLocalEnglishEngine.rawValue,
            boundaryKind: decision?.kind.rawValue,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            speechEnd: decision?.speechEnd ?? rangeEnd,
            endpointDetectedAt: decision?.endpointDetectedAt ?? -1,
            vadOnlyEndpointAt: decision?.vadOnlyEndpointAt ?? -1,
            queueMilliseconds: job.queueMilliseconds + (started > job.enqueuedUptimeNanoseconds
                ? Double(started - job.enqueuedUptimeNanoseconds) / 1_000_000 : 0),
            asrMilliseconds: job.asrMilliseconds,
            translationMilliseconds: completed > started
                ? Double(completed - started) / 1_000_000 : 0,
            renderedUptimeNanoseconds: completed,
            sourceText: job.source.text,
            englishText: englishText,
            revision: nil,
            previewLatencyMilliseconds: nil,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: nil,
            translationStartedUptimeNanoseconds: started,
            translationCompletedUptimeNanoseconds: completed
        )
        metric.finalAttempt = attempt
        metric.finalAttemptOutcome = outcome
        metric.finalErrorClassification = classification?.rawValue
        metric.retryBackoffMilliseconds = backoffMilliseconds
        metric.finalEnqueuedUptimeNanoseconds = job.enqueuedUptimeNanoseconds
        await localMetricRecorder.append(metric)
    }

    @available(macOS 26.4, *)
    private func translateStableSource(
        _ text: String,
        mode: AppleTranslationMode = .highFidelityOnly
    ) async throws -> String {
        let response = try await appleTranslationService().translate(
            text,
            highFidelity: mode.finalUsesHighFidelity
        )
        return try EnglishSubtitleValidator.requireEnglish(response)
    }

    @MainActor
    private func publishLocalCaptions() {
        liveStableSegmentCount = localCommittedSegments.count
        liveSegments = localCommittedSegments
        if let localPreviewSegment { liveSegments.append(localPreviewSegment) }
        setLocalStatus("Listening...")
        throttledAutoSave()
    }

    @MainActor
    private func setLocalStatus(_ fallback: String) {
        liveStatusText = localFinalTranslationState.statusText ?? fallback
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
        trimOverlap(previous: previous, current: current, minimumMatchLength: 1)
    }

    /// English direct output must never lose a word because two unrelated
    /// clauses share one trailing character. Only a substantial overlap that
    /// starts and ends at word boundaries is safe to remove.
    static func trimEnglishOverlap(previous: String, current: String) -> String {
        trimOverlap(
            previous: previous,
            current: current,
            minimumMatchLength: 8,
            requireWordBoundaries: true
        )
    }

    private static func trimOverlap(
        previous: String,
        current: String,
        minimumMatchLength: Int,
        requireWordBoundaries: Bool = false
    ) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let maxCheck = min(source.count, target.count)
        guard maxCheck >= minimumMatchLength else { return current }
        for len in stride(from: maxCheck, through: minimumMatchLength, by: -1) {
            let candidate = String(source.suffix(len))
            let sourcePrefix = source.dropLast(len)
            let targetSuffix = target.dropFirst(len)
            let hasWordBoundaries = !requireWordBoundaries
                || (!(sourcePrefix.last.map(isWordCharacter) ?? false)
                    && !(targetSuffix.first.map(isWordCharacter) ?? false))
            if hasWordBoundaries, target.hasPrefix(candidate) {
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

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
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
        let audioPath: String?
        let localSourceLocale: String?
        let localTranslationMode: AppleTranslationMode?
        let localEnglishEngine: LocalEnglishEngine?
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
        let isDirectEnglish = isLocalEnglish && activeLocalEnglishEngine.producesDirectEnglish
        let segments = isDirectEnglish
            ? localCommittedSegments
            : (isLocalEnglish ? localSourceSegments : liveSegments)
        let text = segments.map { $0.text }.joined()
        let translations = isLocalEnglish
            ? (isDirectEnglish ? [] : localCommittedSegments.map(\.text))
            : liveTranslatedSegments
        let lang: String? = isLocalEnglish && !isDirectEnglish
            ? "en"
            : (!translations.isEmpty
                ? UserDefaults.standard.string(forKey: "targetLanguage") : nil)
        let sourceLocale = isLocalEnglish ? activeLocalSourceLocale : nil
        let translationMode = isLocalEnglish ? activeLocalTranslationMode : nil
        let localEngine = isLocalEnglish ? activeLocalEnglishEngine : nil
        let discardOriginal = isLocalEnglish && !isDirectEnglish
            ? !activeKeepOriginalTranscript : nil
        let audioPath = activeLocalRecorder?.recordingFileURL?.path

        // Write on a background queue to avoid blocking the main thread
        Task.detached(priority: .utility) {
            let data = LiveRecoveryData(
                segments: segments, fullText: text,
                translatedSegments: translations, translationLanguage: lang,
                audioPath: audioPath,
                localSourceLocale: sourceLocale,
                localTranslationMode: translationMode,
                localEnglishEngine: localEngine,
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

    static func existingRecoveryAudioURL(path: String?) -> URL? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = Self.liveRecoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let audioURL = Self.existingRecoveryAudioURL(path: recovery.audioPath)
        let isLocalEnglish = recovery.localSourceLocale != nil
            || recovery.localEnglishEngine != nil
        let isDirectEnglish = recovery.localEnglishEngine?.producesDirectEnglish == true
        guard !isLocalEnglish || audioURL != nil || !recovery.segments.isEmpty else {
            removeLiveRecoveryFile()
            return
        }
        let item = TranscriptionItem(
            fileURL: audioURL ?? URL(
                fileURLWithPath: "/recovered-source-only-\(UUID().uuidString)"
            ))
        item.segments = recovery.segments
        item.fullText = recovery.fullText
        item.translatedSegments = recovery.translatedSegments.map {
            EnglishSubtitleValidator.normalizedEnglish($0) ?? ""
        }
        item.translationLanguage = item.translatedSegments.contains(where: { !$0.isEmpty })
            ? recovery.translationLanguage : nil
        if !isDirectEnglish {
            item.localSourceLocale = recovery.localSourceLocale
            item.localTranslationMode = recovery.localTranslationMode
            item.discardOriginalAfterRetry = recovery.discardOriginalAfterRetry ?? false
        }
        item.translateToEnglish = isLocalEnglish && !isDirectEnglish
        item.localSourceTranscriptComplete = !isLocalEnglish
        if !isLocalEnglish {
            item.status = .completed
        } else if isDirectEnglish {
            item.status = .failed(audioURL != nil
                ? "Recovered direct English captions may be incomplete. The retained audio can be run with another model."
                : "Recovered direct English captions are partial; the missing audio tail cannot be recovered.")
        } else if audioURL != nil {
            item.status = .failed(
                "Recovered local subtitles may be incomplete. Retry English translation will re-transcribe the retained audio."
            )
        } else {
            item.status = .failed(
                "Recovered source is partial. Retry English translation will translate only the saved Japanese clauses; the missing audio tail cannot be recovered."
            )
        }
        let recoveryLabel = audioURL == nil && isLocalEnglish
            ? "Recovered partial subtitles"
            : "Recovered"
        item.fileName = "\(recoveryLabel) \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
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
