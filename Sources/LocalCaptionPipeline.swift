import Foundation

struct SpeechSampleRange: Equatable, Sendable {
    let start: Int
    let end: Int
}

/// Independent cursors for the continuous Apple Speech preview stream.
/// Neither position has any authority over final-ASR or reclaimable PCM.
struct LocalAppleSpeechFeedState: Equatable, Sendable {
    static let progressiveFinalizationInterval = 24_000

    private(set) var sentThrough = 0
    private(set) var finalizeRequestedThrough = 0

    mutating func takeNewSamples(through target: Int) -> Range<Int>? {
        guard target > sentThrough else { return nil }
        let range = sentThrough..<target
        sentThrough = target
        return range
    }

    mutating func requestFinalization(
        through target: Int,
        every interval: Int
    ) -> Bool {
        guard target - finalizeRequestedThrough >= interval else { return false }
        finalizeRequestedThrough = target
        return true
    }
}

struct LocalPreviewWork: Equatable, Sendable {
    let generation: Int
    let update: LiveSourceUpdate
    let firstLexicalUptimeNanoseconds: UInt64
    let receivedUptimeNanoseconds: UInt64
    let isFirstEligibleInGeneration: Bool
    let bypassesThrottle: Bool
}

/// Latest-only preview state. Its sample boundary is deliberately separate
/// from the stable/FIFO cursors: suppressing a preview never validates PCM.
struct LocalPreviewPlanner: Sendable {
    private static let maximumContextSeconds = 6.0
    private static let terminalPunctuation: Set<Character> = ["。", "！", "？", "!", "?"]
    private(set) var generation = 0
    private(set) var suppressedThrough = 0
    private(set) var isSuspended = false
    private(set) var pending: LocalPreviewWork?
    private var sourceSegments: [TranscriptionSegment] = []
    private var hasIssuedEligibleWork = false
    private var firstLexicalUptimeNanoseconds: UInt64?

    mutating func submit(
        _ update: LiveSourceUpdate,
        receivedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard !isSuspended,
              let update = update.clipped(afterSample: suppressedThrough)
        else { return }
        if firstLexicalUptimeNanoseconds == nil,
           !update.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstLexicalUptimeNanoseconds = receivedUptimeNanoseconds
        }
        if let last = sourceSegments.last,
           update.segment.start < (last.end ?? last.start) - 0.02 {
            sourceSegments[sourceSegments.count - 1] = update.segment
        } else {
            sourceSegments.append(update.segment)
        }
        while sourceSegments.count > 1,
              (sourceSegments.last?.end ?? sourceSegments.last?.start ?? 0)
                - (sourceSegments.first?.start ?? 0) > Self.maximumContextSeconds {
            sourceSegments.removeFirst()
        }
        let combined = LiveSourceUpdate(
            segment: TranscriptionSegment(
                start: sourceSegments.first?.start ?? update.segment.start,
                end: sourceSegments.last?.end ?? update.segment.end,
                text: sourceSegments.map(\.text).joined(separator: " ")
            ),
            isFinal: false,
            finalizedThroughSample: update.finalizedThroughSample
        )
        guard Self.isEligibleSource(combined.segment.text) else { return }
        let isFirst = !hasIssuedEligibleWork
        pending = LocalPreviewWork(
            generation: generation,
            update: combined,
            firstLexicalUptimeNanoseconds: firstLexicalUptimeNanoseconds
                ?? receivedUptimeNanoseconds,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds,
            isFirstEligibleInGeneration: isFirst,
            bypassesThrottle: isFirst || Self.hasTerminalPunctuation(combined.segment.text)
        )
    }

    mutating func suspend(through sample: Int) {
        generation += 1
        suppressedThrough = max(suppressedThrough, sample)
        isSuspended = true
        pending = nil
        sourceSegments.removeAll(keepingCapacity: true)
        hasIssuedEligibleWork = false
        firstLexicalUptimeNanoseconds = nil
    }

    /// Invalidates only the phrase that just ended. Unlike `suspend`, the
    /// next phrase can immediately enqueue previews while its final is busy.
    mutating func advanceBoundary(through sample: Int) {
        generation += 1
        suppressedThrough = max(suppressedThrough, sample)
        isSuspended = false
        pending = nil
        sourceSegments.removeAll(keepingCapacity: true)
        hasIssuedEligibleWork = false
        firstLexicalUptimeNanoseconds = nil
    }

    mutating func resume(through sample: Int) {
        suppressedThrough = max(suppressedThrough, sample)
        isSuspended = false
    }

    mutating func takeLatest() -> LocalPreviewWork? {
        guard !isSuspended, let pending else { return nil }
        self.pending = nil
        hasIssuedEligibleWork = true
        return pending
    }

    func accepts(_ work: LocalPreviewWork) -> Bool {
        let start = Int((work.update.segment.start * 16_000).rounded())
        return !isSuspended
            && work.generation == generation
            && start >= suppressedThrough
    }

    static func isEligibleSource(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasTerminalPunctuation(text)
            || text.lazy.filter { !$0.isWhitespace }.prefix(2).count == 2
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        text.last.map(terminalPunctuation.contains) == true
    }
}

struct LocalEndpointDecision: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case semantic, speaker, pause, forced, finish
    }

    let kind: Kind
    let audioStart: Int
    let audioEnd: Int
    let speechEnd: Int
    let endpointDetectedAt: Int
    let vadOnlyEndpointAt: Int
    let stableThrough: Int
    let cleanBreak: Bool
    var boundaryDegradation: String? = nil
}

/// Pure endpoint state. VAD proposes boundaries; only `accept` releases a
/// range. Failed ASR therefore cannot create a hole in the PCM timeline.
struct LocalEndpointPlanner: Sendable {
    static let sampleRate = 16_000
    static let preRoll = sampleRate / 4
    static let silence = sampleRate * 350 / 1_000
    static let postRoll = sampleRate / 2
    static let minimumBatch = sampleRate * 3 / 2
    static let maxPhrase = sampleRate * 15
    static let forcedOverlap = sampleRate * 800 / 1_000

    private(set) var finalizedThrough = 0
    private(set) var segmentedThrough = 0
    private(set) var stableAttemptEnd = 0
    private(set) var previewReadEnd = 0
    private var phraseSpeechStart: Int?
    private var phraseStartsWithForcedOverlap = false
    private var lastSpeechEnd: Int?

    mutating func notePreview(readThrough sample: Int) {
        previewReadEnd = max(previewReadEnd, sample)
    }

    mutating func observe(
        totalSample: Int,
        speech: [SpeechSampleRange],
        finishing: Bool = false
    ) -> LocalEndpointDecision? {
        for range in speech where range.end > segmentedThrough {
            let start = max(segmentedThrough, range.start)
            if phraseSpeechStart == nil {
                phraseSpeechStart = start
                phraseStartsWithForcedOverlap = false
            } else {
                phraseSpeechStart = min(phraseSpeechStart!, start)
            }
            lastSpeechEnd = max(lastSpeechEnd ?? range.end, range.end)
        }
        guard let speechStart = phraseSpeechStart,
              let speechEnd = lastSpeechEnd,
              totalSample > speechStart else { return nil }

        if finishing {
            return decision(
                kind: .finish,
                audioEnd: totalSample,
                speechStart: speechStart,
                speechEnd: speechEnd,
                cleanBreak: true
            )
        }

        if totalSample - speechStart >= Self.maxPhrase {
            let end = min(totalSample, speechStart + Self.maxPhrase)
            guard end > stableAttemptEnd else { return nil }
            return LocalEndpointDecision(
                kind: .forced,
                audioStart: phraseStartsWithForcedOverlap
                    ? speechStart : max(0, speechStart - Self.preRoll),
                audioEnd: end,
                speechEnd: min(speechEnd, end),
                endpointDetectedAt: end,
                vadOnlyEndpointAt: end,
                stableThrough: max(finalizedThrough, end - Self.forcedOverlap),
                cleanBreak: false
            )
        }

        guard totalSample - speechEnd >= Self.silence else { return nil }
        // Tiny utterances are grouped when possible. Starting a full local ASR
        // pass for every interjection created an ever-growing live backlog.
        guard totalSample - speechStart >= Self.minimumBatch else { return nil }

        // Detect the endpoint as soon as the silence criterion is met, but do
        // not hand the phrase to ASR until its full 500 ms post-roll exists.
        // This prevents quiet final morae from being clipped while keeping the
        // measured endpoint time independent from the deliberate post-roll.
        guard totalSample - speechEnd >= Self.postRoll else { return nil }
        let end = speechEnd + Self.postRoll
        guard end > stableAttemptEnd else { return nil }
        return decision(
            kind: .pause,
            audioEnd: end,
            speechStart: speechStart,
            speechEnd: speechEnd,
            cleanBreak: true
        )
    }

    /// Stage a boundary for FIFO processing without claiming that its PCM has
    /// been successfully recognized or translated.
    mutating func stage(_ decision: LocalEndpointDecision) {
        stableAttemptEnd = max(stableAttemptEnd, decision.audioEnd)
        segmentedThrough = max(segmentedThrough, decision.stableThrough)
        if decision.cleanBreak {
            phraseSpeechStart = nil
            phraseStartsWithForcedOverlap = false
            lastSpeechEnd = nil
        } else {
            phraseSpeechStart = decision.stableThrough
            phraseStartsWithForcedOverlap = true
            lastSpeechEnd = max(decision.stableThrough, decision.speechEnd)
        }
    }

    mutating func accept(_ decision: LocalEndpointDecision) {
        finalizedThrough = max(finalizedThrough, decision.stableThrough)
    }

    private func decision(
        kind: LocalEndpointDecision.Kind,
        audioEnd: Int,
        speechStart: Int,
        speechEnd: Int,
        cleanBreak: Bool
    ) -> LocalEndpointDecision {
        let silence = kind == .pause ? Self.silence : 0
        return LocalEndpointDecision(
            kind: kind,
            audioStart: phraseStartsWithForcedOverlap
                ? speechStart : max(0, speechStart - Self.preRoll),
            audioEnd: audioEnd,
            speechEnd: speechEnd,
            endpointDetectedAt: min(audioEnd, speechEnd + silence),
            vadOnlyEndpointAt: speechEnd + Self.silence,
            stableThrough: audioEnd,
            cleanBreak: cleanBreak
        )
    }
}

/// FIFO boundary handoff between continuous endpoint detection and the slower
/// final ASR worker. Staging never validates or releases PCM.
actor LocalEndpointFIFO {
    struct Entry: Equatable, Sendable {
        let decision: LocalEndpointDecision
        let stagedUptimeNanoseconds: UInt64
        let voxtralText: String?
    }

    private var planner = LocalEndpointPlanner()
    private var pending: [Entry] = []
    private var producerFinished = false

    @discardableResult
    func observe(
        totalSample: Int,
        speech: [SpeechSampleRange],
        finishing: Bool = false
    ) -> LocalEndpointDecision? {
        guard let decision = propose(
            totalSample: totalSample,
            speech: speech,
            finishing: finishing
        ) else { return nil }
        stage(decision)
        return decision
    }

    func propose(
        totalSample: Int,
        speech: [SpeechSampleRange],
        finishing: Bool = false
    ) -> LocalEndpointDecision? {
        planner.observe(
            totalSample: totalSample,
            speech: speech,
            finishing: finishing
        )
    }

    func stage(_ decision: LocalEndpointDecision, voxtralText: String? = nil) {
        planner.stage(decision)
        pending.append(Entry(
            decision: decision,
            stagedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            voxtralText: voxtralText
        ))
    }

    func next() -> Entry? { pending.first }

    func pendingCount() -> Int { pending.count }

    func accept(_ entry: Entry) {
        guard pending.first == entry else { return }
        pending.removeFirst()
        planner.accept(entry.decision)
    }

    func finishProducing() { producerFinished = true }

    func isDrained() -> Bool { producerFinished && pending.isEmpty }

    func cursors() -> (segmented: Int, finalized: Int) {
        (planner.segmentedThrough, planner.finalizedThrough)
    }
}

enum LocalPreviewRangePolicy {
    static func shouldClear(
        preview: TranscriptionSegment?,
        finalizedThrough sample: Int
    ) -> Bool {
        guard let preview else { return false }
        return Int((preview.start * 16_000).rounded()) < sample
    }
}

struct LocalFinalSourceSelection: Equatable, Sendable {
    let text: String
    let degraded: Bool
}

enum LocalFinalSourceSelector {
    static func hybrid(cohere: String?, voxtral: String?) throws -> LocalFinalSourceSelection {
        let cohere = cohere?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cohere.isEmpty {
            return LocalFinalSourceSelection(text: cohere, degraded: false)
        }
        let voxtral = voxtral?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !voxtral.isEmpty else { throw LocalPrototypeError.invalidResponse }
        return LocalFinalSourceSelection(text: voxtral, degraded: true)
    }
}

enum EnglishSubtitleValidator {
    static func normalizedEnglish(_ text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !containsSourceScript(normalized) else { return nil }
        return normalized
    }

    static func requireEnglish(_ text: String) throws -> String {
        guard let normalized = normalizedEnglish(text) else {
            throw LocalPrototypeError.invalidResponse
        }
        return normalized
    }

    static func containsSourceScript(_ text: String) -> Bool {
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, // Hangul Jamo
                 0x2E80...0x2FFF, // CJK radicals and ideographic punctuation
                 0x3005...0x3007, // CJK iteration marks and ideographic zero
                 0x3031...0x3035, 0x303B...0x303C, // Kana iteration marks
                 0x3040...0x30FF, // Hiragana + Katakana
                 0x3100...0x312F, 0x31A0...0x31BF, // Bopomofo
                 0x3130...0x318F, // Hangul compatibility Jamo
                 0x31F0...0x31FF, // Katakana phonetic extensions
                 0x3400...0x4DBF, 0x4E00...0x9FFF, // CJK unified ideographs
                 0xA960...0xA97F, 0xAC00...0xD7FF, // Hangul syllables/extensions
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFF65...0xFF9F, // Half-width Japanese punctuation/Katakana
                 0x1AFF0...0x1B16F, // Kana extended/supplement blocks
                 0x20000...0x323AF: // CJK extensions B through H
                return true
            default:
                return false
            }
        }
    }
}

enum LocalCaptionMetricKind: String, Codable, Sendable {
    case preview
    case final
    case finalAttempt
}

struct LocalCaptionMetric: Codable, Sendable {
    let kind: LocalCaptionMetricKind
    let engine: String
    let boundaryKind: String?
    var boundaryDegradation: String? = nil
    let rangeStart: Int
    let rangeEnd: Int
    let speechEnd: Int
    let endpointDetectedAt: Int
    let vadOnlyEndpointAt: Int
    let queueMilliseconds: Double
    let asrMilliseconds: Double
    let translationMilliseconds: Double
    let renderedUptimeNanoseconds: UInt64
    let sourceText: String?
    let englishText: String
    let revision: Int?
    let previewLatencyMilliseconds: Double?
    var speechEndToRenderedMilliseconds: Double? = nil
    let firstLexicalUptimeNanoseconds: UInt64?
    let sourceEligibleUptimeNanoseconds: UInt64?
    let translationStartedUptimeNanoseconds: UInt64?
    let translationCompletedUptimeNanoseconds: UInt64?
    var finalAttempt: Int? = nil
    var finalAttemptOutcome: String? = nil
    var finalErrorClassification: String? = nil
    var retryBackoffMilliseconds: Double? = nil
    var finalEnqueuedUptimeNanoseconds: UInt64? = nil
    var previewGeneration: Int? = nil
    var isFirstEligibleInGeneration: Bool? = nil
    var acceptedStart: Int? = nil
    var stableThrough: Int? = nil
    var committedThrough: Int? = nil
    var finalSegmentIndex: Int? = nil
}

actor LocalCaptionMetricRecorder {
    private let enabled: Bool
    private var records: [LocalCaptionMetric] = []
    private var maximumCombinedResidentBytes: UInt64 = 0
    private var maximumHelperBacklogSamples = 0
    private var maximumEndpointFIFOCount = 0
    private var helperProcessIdentifier: Int32?

    init(
        enabled: Bool = ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK"] == "1"
    ) {
        self.enabled = enabled
    }

    func reset() {
        guard enabled else { return }
        records.removeAll(keepingCapacity: true)
        maximumCombinedResidentBytes = 0
        maximumHelperBacklogSamples = 0
        maximumEndpointFIFOCount = 0
        helperProcessIdentifier = nil
    }

    func append(_ metric: LocalCaptionMetric) {
        if enabled { records.append(metric) }
    }

    func observe(
        combinedResidentBytes: UInt64,
        helperBacklogSamples: Int,
        helperProcessIdentifier: Int32?,
        endpointFIFOCount: Int = 0
    ) {
        guard enabled else { return }
        maximumCombinedResidentBytes = max(
            maximumCombinedResidentBytes,
            combinedResidentBytes
        )
        maximumHelperBacklogSamples = max(
            maximumHelperBacklogSamples,
            helperBacklogSamples
        )
        maximumEndpointFIFOCount = max(maximumEndpointFIFOCount, endpointFIFOCount)
        if let helperProcessIdentifier {
            self.helperProcessIdentifier = helperProcessIdentifier
        }
    }

    func snapshot() -> [LocalCaptionMetric] { records }

    /// Opt-in integration runs stay out of source control by living under
    /// `.build/benchmarks`. Normal recordings incur no disk instrumentation.
    func writeOptInReport(
        stem: String,
        canonicalPCMURL: URL?,
        summary: LocalCaptionBenchmarkSummary,
        whisperModelSelection: LocalWhisperModelSelection? = nil,
        voxtralConfiguration: VoxtralContinuousConfiguration? = nil,
        japaneseGlossary: JapaneseGlossary = .empty,
        outputDirectory: URL? = nil
    ) throws -> URL? {
        guard enabled else { return nil }
        let root = try outputDirectory ?? LocalBenchmarkOutput.directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("\(stem)-metrics.json")
        let csv = root.appendingPathComponent("\(stem)-metrics.csv")
        let session = root.appendingPathComponent("\(stem)-session.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
        try Self.csvData(for: records).write(
            to: csv,
            options: .atomic
        )
        guard let executableURL = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let report = LocalCaptionBenchmarkSessionReport(
            summary: summary,
            applicationProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            applicationBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            applicationExecutableFile: executableURL.lastPathComponent,
            applicationExecutableSHA256: try LocalBenchmarkOutput.sha256(executableURL),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            helperProcessIdentifier: helperProcessIdentifier,
            maximumCombinedResidentBytes: maximumCombinedResidentBytes,
            maximumHelperBacklogSamples: maximumHelperBacklogSamples,
            maximumEndpointFIFOCount: maximumEndpointFIFOCount,
            metricsFile: file.lastPathComponent,
            metricsSHA256: try LocalBenchmarkOutput.sha256(file),
            metricsCSVFile: csv.lastPathComponent,
            canonicalPCMFile: canonicalPCMURL?.lastPathComponent,
            canonicalPCMSHA256: try canonicalPCMURL.map(LocalBenchmarkOutput.sha256),
            whisperCandidate: whisperModelSelection?.candidate,
            whisperModelID: whisperModelSelection?.modelID,
            whisperModelRevision: whisperModelSelection?.revision,
            whisperModelFile: whisperModelSelection?.fileURL.lastPathComponent,
            whisperModelSHA256: whisperModelSelection?.expectedSHA256,
            voxtralModelID: voxtralConfiguration?.model.modelID,
            voxtralModelRevision: voxtralConfiguration?.model.modelRevision,
            voxtralLocalSnapshotID: voxtralConfiguration?.model.localSnapshotID,
            voxtralLocalArtifactRevision: voxtralConfiguration?.model.localArtifactRevision,
            voxtralConversionSourceID: voxtralConfiguration?.model.conversionSource?.modelID,
            voxtralConversionSourceRevision:
                voxtralConfiguration?.model.conversionSource?.revision,
            voxtralRuntimePatchSHA256: voxtralConfiguration == nil
                ? nil : VoxtralHelperManifest.runtimePatchSHA256,
            voxtralDelayMilliseconds: voxtralConfiguration?.delay.rawValue,
            transportBlockMilliseconds: voxtralConfiguration == nil
                ? nil : VoxtralHelperManifest.transportBlockMilliseconds,
            japaneseGlossarySHA256: japaneseGlossary.fingerprint
        )
        try encoder.encode(report).write(to: session, options: .atomic)
        return file
    }

    static func csvData(for records: [LocalCaptionMetric]) -> Data {
        var csv = "kind,engine,boundary_kind,boundary_degradation,range_start,range_end,speech_end,endpoint,vad_only_endpoint,queue_ms,asr_ms,translation_ms,revision,preview_latency_ms,speech_end_to_rendered_ms,first_lexical_ns,source_eligible_ns,translation_started_ns,translation_completed_ns,published_ns,final_attempt,final_attempt_outcome,final_error_classification,retry_backoff_ms,final_enqueued_ns,preview_generation,is_first_eligible,accepted_start,stable_through,committed_through,final_segment_index,source,english\n"
        for record in records {
            let revision = record.revision.map(String.init) ?? ""
            let previewLatency = record.previewLatencyMilliseconds.map {
                String(format: "%.3f", $0)
            } ?? ""
            let speechEndLatency = record.speechEndToRenderedMilliseconds.map {
                String(format: "%.3f", $0)
            } ?? ""
            let firstLexical = record.firstLexicalUptimeNanoseconds.map { String($0) } ?? ""
            let sourceEligible = record.sourceEligibleUptimeNanoseconds.map { String($0) } ?? ""
            let translationStarted = record.translationStartedUptimeNanoseconds.map { String($0) } ?? ""
            let translationCompleted = record.translationCompletedUptimeNanoseconds.map { String($0) } ?? ""
            let finalAttempt = record.finalAttempt.map(String.init) ?? ""
            let retryBackoff = record.retryBackoffMilliseconds.map {
                String(format: "%.3f", $0)
            } ?? ""
            let finalEnqueued = record.finalEnqueuedUptimeNanoseconds.map { String($0) } ?? ""
            let fields: [String] = [
                record.kind.rawValue, record.engine,
                record.boundaryKind ?? "",
                record.boundaryDegradation ?? "",
                String(record.rangeStart), String(record.rangeEnd),
                String(record.speechEnd), String(record.endpointDetectedAt),
                String(record.vadOnlyEndpointAt),
                String(format: "%.3f", record.queueMilliseconds),
                String(format: "%.3f", record.asrMilliseconds),
                String(format: "%.3f", record.translationMilliseconds),
                revision,
                previewLatency,
                speechEndLatency,
                firstLexical,
                sourceEligible,
                translationStarted,
                translationCompleted,
                String(record.renderedUptimeNanoseconds),
                finalAttempt,
                record.finalAttemptOutcome ?? "",
                record.finalErrorClassification ?? "",
                retryBackoff,
                finalEnqueued,
                record.previewGeneration.map(String.init) ?? "",
                record.isFirstEligibleInGeneration.map(String.init) ?? "",
                record.acceptedStart.map(String.init) ?? "",
                record.stableThrough.map(String.init) ?? "",
                record.committedThrough.map(String.init) ?? "",
                record.finalSegmentIndex.map(String.init) ?? "",
                Self.csv(record.sourceText ?? ""), Self.csv(record.englishText),
            ]
            csv += fields.joined(separator: ",") + "\n"
        }
        return Data(csv.utf8)
    }

    private static func csv(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct LocalCaptionBenchmarkSummary: Codable, Equatable, Sendable {
    let sessionID: UUID
    let engine: String
    let translationMode: String
    let finalSampleCount: Int
    let pcmComplete: Bool
    let m4aDroppedSampleCount: Int
    let helperSentThrough: Int?
    let helperAcknowledgedThrough: Int?
    let endingHelperBacklogSamples: Int?
    let sourceStagedThrough: Int
    let englishValidatedThrough: Int
    let committedSampleCount: Int
    var sourceFinalizedThrough: Int = 0
    var endingEndpointFIFOCount: Int = 0
    var endingTranslationQueueCount: Int = 0
    var finalTranslationInFlight: Bool = false
    var sourcePipelineFailure: String? = nil
    var completionFailure: String? = nil
    var sourceLocale: String? = nil
    var captureTiming: AudioCaptureTiming? = nil
    var capturedApplicationBundleIdentifier: String? = nil
    var capturedApplicationProcessIdentifier: Int32? = nil
    var microphoneIncluded: Bool = false
}

private struct LocalCaptionBenchmarkSessionReport: Codable {
    let summary: LocalCaptionBenchmarkSummary
    let applicationProcessIdentifier: Int32
    let applicationVersion: String?
    let applicationBuild: String?
    let applicationExecutableFile: String
    let applicationExecutableSHA256: String
    let operatingSystemVersion: String
    let helperProcessIdentifier: Int32?
    let maximumCombinedResidentBytes: UInt64
    let maximumHelperBacklogSamples: Int
    let maximumEndpointFIFOCount: Int
    let metricsFile: String
    let metricsSHA256: String
    let metricsCSVFile: String
    let canonicalPCMFile: String?
    let canonicalPCMSHA256: String?
    let whisperCandidate: String?
    let whisperModelID: String?
    let whisperModelRevision: String?
    let whisperModelFile: String?
    let whisperModelSHA256: String?
    let voxtralModelID: String?
    let voxtralModelRevision: String?
    let voxtralLocalSnapshotID: String?
    let voxtralLocalArtifactRevision: String?
    let voxtralConversionSourceID: String?
    let voxtralConversionSourceRevision: String?
    let voxtralRuntimePatchSHA256: String?
    let voxtralDelayMilliseconds: Int?
    let transportBlockMilliseconds: Int?
    let japaneseGlossarySHA256: String?
}

enum LocalBenchmarkOutput {
    static func directory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let explicit = environment["WHISPERASR_BENCHMARK_OUTPUT_DIR"],
              !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "LocalBenchmarkOutput",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "WHISPERASR_BENCHMARK_OUTPUT_DIR is required for benchmark runs."]
            )
        }
        let url = URL(fileURLWithPath: explicit, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    static func stem(sessionID: UUID, date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "local-captions-\(timestamp)-\(sessionID.uuidString.lowercased())"
    }

    static func sha256(_ url: URL) throws -> String {
        try ModelDownloader.sha256(of: url)
    }
}

enum PCM16WAV {
    static func data(samples: [Float], sampleRate: UInt32 = 16_000) -> Data {
        let pcm = samples.map { sample -> Int16 in
            Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
        }
        let dataBytes = UInt32(pcm.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataBytes)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataBytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

struct CanonicalBenchmarkPassage: Codable, Equatable, Sendable {
    let id: Int
    let startSample: Int
    let endSample: Int
}

enum CanonicalBenchmarkCorpus {
    static func passages(totalSamples: Int, count requestedCount: Int? = nil) -> [CanonicalBenchmarkPassage] {
        let duration = Double(totalSamples) / Double(LocalEndpointPlanner.sampleRate)
        let count = requestedCount ?? max(1, min(12, Int((duration / 20).rounded())))
        guard totalSamples > 0, count > 0 else { return [] }
        return (0..<count).compactMap { index in
            let start = totalSamples * index / count
            let end = totalSamples * (index + 1) / count
            guard end > start else { return nil }
            return CanonicalBenchmarkPassage(id: index + 1, startSample: start, endSample: end)
        }
    }

    static func writeIfRequested(
        artifact: RecoverablePCMSpool.Artifact?,
        stem: String
    ) throws -> URL? {
        guard ProcessInfo.processInfo.environment["WHISPERASR_CAPTURE_CANONICAL"] == "1" else {
            return nil
        }
        guard let artifact, artifact.isComplete else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = try LocalBenchmarkOutput.directory()
        let wav = root.appendingPathComponent("\(stem)-canonical-f32.wav")
        if FileManager.default.fileExists(atPath: wav.path) {
            try FileManager.default.removeItem(at: wav)
        }
        try FileManager.default.copyItem(at: artifact.audioURL, to: wav)
        let manifest = root.appendingPathComponent("\(stem)-canonical-passages.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(passages(totalSamples: artifact.sampleCount)).write(
            to: manifest,
            options: .atomic
        )
        return wav
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(Data(string.utf8)) }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
