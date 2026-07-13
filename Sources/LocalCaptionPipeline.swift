import Foundation

struct SpeechSampleRange: Equatable, Sendable {
    let start: Int
    let end: Int
}

struct LocalPreviewWork: Equatable, Sendable {
    let generation: Int
    let update: LiveSourceUpdate
    let receivedUptimeNanoseconds: UInt64
}

/// Latest-only preview state. Its sample boundary is deliberately separate
/// from the stable/FIFO cursors: suppressing a preview never validates PCM.
struct LocalPreviewPlanner: Sendable {
    private static let maximumContextSeconds = 6.0
    private(set) var generation = 0
    private(set) var suppressedThrough = 0
    private(set) var isSuspended = false
    private(set) var pending: LocalPreviewWork?
    private var sourceSegments: [TranscriptionSegment] = []

    mutating func submit(
        _ update: LiveSourceUpdate,
        receivedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard !isSuspended,
              let update = update.clipped(afterSample: suppressedThrough)
        else { return }
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
        pending = LocalPreviewWork(
            generation: generation,
            update: combined,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds
        )
    }

    mutating func suspend(through sample: Int) {
        generation += 1
        suppressedThrough = max(suppressedThrough, sample)
        isSuspended = true
        pending = nil
        sourceSegments.removeAll(keepingCapacity: true)
    }

    mutating func resume(through sample: Int) {
        suppressedThrough = max(suppressedThrough, sample)
        isSuspended = false
    }

    mutating func takeLatest() -> LocalPreviewWork? {
        guard !isSuspended, let pending else { return nil }
        self.pending = nil
        return pending
    }

    func accepts(_ work: LocalPreviewWork) -> Bool {
        let start = Int((work.update.segment.start * 16_000).rounded())
        return !isSuspended
            && work.generation == generation
            && start >= suppressedThrough
    }
}

struct LocalEndpointDecision: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case pause, forced, finish }

    let kind: Kind
    let audioStart: Int
    let audioEnd: Int
    let speechEnd: Int
    let endpointDetectedAt: Int
    let vadOnlyEndpointAt: Int
    let stableThrough: Int
    let cleanBreak: Bool
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
        guard let decision = planner.observe(
            totalSample: totalSample,
            speech: speech,
            finishing: finishing
        ) else { return nil }
        planner.stage(decision)
        pending.append(Entry(
            decision: decision,
            stagedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
        return decision
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

enum EnglishSubtitleValidator {
    static func containsSourceScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana + Katakana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, // CJK
                 0xAC00...0xD7AF: // Hangul
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
}

struct LocalCaptionMetric: Codable, Sendable {
    let kind: LocalCaptionMetricKind
    let engine: String
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
}

actor LocalCaptionMetricRecorder {
    private let enabled = ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK"] == "1"
    private var records: [LocalCaptionMetric] = []

    func reset() {
        if enabled { records.removeAll(keepingCapacity: true) }
    }
    func append(_ metric: LocalCaptionMetric) {
        if enabled { records.append(metric) }
    }
    func snapshot() -> [LocalCaptionMetric] { records }

    /// Opt-in integration runs stay out of source control by living under
    /// `.build/benchmarks`. Normal recordings incur no disk instrumentation.
    func writeOptInReport() throws -> URL? {
        guard ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK"] == "1" else {
            return nil
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stem = "local-captions-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-" ))"
        let file = root.appendingPathComponent("\(stem).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
        var csv = "kind,engine,range_start,range_end,speech_end,endpoint,vad_only_endpoint,queue_ms,asr_ms,translation_ms,revision,preview_latency_ms,source,english\n"
        for record in records {
            csv += [
                record.kind.rawValue, record.engine,
                String(record.rangeStart), String(record.rangeEnd),
                String(record.speechEnd), String(record.endpointDetectedAt),
                String(record.vadOnlyEndpointAt),
                String(format: "%.3f", record.queueMilliseconds),
                String(format: "%.3f", record.asrMilliseconds),
                String(format: "%.3f", record.translationMilliseconds),
                record.revision.map(String.init) ?? "",
                record.previewLatencyMilliseconds.map { String(format: "%.3f", $0) } ?? "",
                Self.csv(record.sourceText ?? ""), Self.csv(record.englishText),
            ].joined(separator: ",") + "\n"
        }
        try Data(csv.utf8).write(
            to: root.appendingPathComponent("\(stem).csv"),
            options: .atomic
        )
        return file
    }

    private static func csv(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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

    static func writeIfRequested(samples: [Float]) throws -> URL? {
        guard ProcessInfo.processInfo.environment["WHISPERASR_CAPTURE_CANONICAL"] == "1" else {
            return nil
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("canonical-firefox-16k-mono.wav")
        try PCM16WAV.data(samples: samples).write(to: wav, options: .atomic)
        let manifest = root.appendingPathComponent("canonical-passages.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(passages(totalSamples: samples.count)).write(
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
