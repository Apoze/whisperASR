import Foundation
@testable import WhisperASRApp

struct BenchmarkPreviewTranslationEvent: Codable, Sendable {
    let phraseKey: UInt64
    let source: String
    let english: String
    let sourceStartSample: Int?
    let sourceEndSample: Int?
    let sourceReceivedUptimeNanoseconds: UInt64
    let translationStartedUptimeNanoseconds: UInt64
    let completedUptimeNanoseconds: UInt64
    let error: String?
}

struct BenchmarkPreviewTranslationSummary: Sendable {
    static let empty = Self(
        count: 0,
        sourceLatencies: [],
        firstLatencies: [],
        revisions: [],
        translationLatencies: [],
        events: []
    )

    let count: Int
    let sourceLatencies: [Double]
    let firstLatencies: [Double]
    let revisions: [Int]
    let translationLatencies: [Double]
    let events: [BenchmarkPreviewTranslationEvent]
}

@available(macOS 26.4, *)
actor BenchmarkPreviewTranslator {
    private struct Job {
        let source: String
        let phraseKey: UInt64
        let phraseStartUptimeNanoseconds: UInt64
        let receivedUptimeNanoseconds: UInt64
        let sourceStartSample: Int?
        let sourceEndSample: Int?
    }

    private let service: AppleTranslationService
    private let highFidelity: Bool
    private var pending: Job?
    private var running = false
    private var lastStartedUptimeNanoseconds: UInt64 = 0
    private var lastStartedPhraseKey: UInt64?
    private var count = 0
    private var firstSourceLatencyByPhrase: [UInt64: Double] = [:]
    private var firstLatencyByPhrase: [UInt64: Double] = [:]
    private var revisionsByPhrase: [UInt64: Int] = [:]
    private var translationLatencies: [Double] = []
    private var events: [BenchmarkPreviewTranslationEvent] = []

    init(service: AppleTranslationService, highFidelity: Bool) {
        self.service = service
        self.highFidelity = highFidelity
    }

    func submit(
        source: String,
        phraseKey: UInt64,
        phraseStartUptimeNanoseconds: UInt64,
        receivedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sourceStartSample: Int? = nil,
        sourceEndSample: Int? = nil
    ) {
        guard LocalPreviewPlanner.isEligibleSource(source) else { return }
        if firstSourceLatencyByPhrase[phraseKey] == nil {
            firstSourceLatencyByPhrase[phraseKey] = receivedUptimeNanoseconds
                > phraseStartUptimeNanoseconds
                ? Double(receivedUptimeNanoseconds - phraseStartUptimeNanoseconds) / 1_000_000
                : 0
        }
        pending = Job(
            source: source,
            phraseKey: phraseKey,
            phraseStartUptimeNanoseconds: phraseStartUptimeNanoseconds,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds,
            sourceStartSample: sourceStartSample,
            sourceEndSample: sourceEndSample
        )
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    func finish() async -> BenchmarkPreviewTranslationSummary {
        while running || pending != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let phrases = revisionsByPhrase.keys.sorted()
        return BenchmarkPreviewTranslationSummary(
            count: count,
            sourceLatencies: phrases.compactMap { firstSourceLatencyByPhrase[$0] },
            firstLatencies: phrases.compactMap { firstLatencyByPhrase[$0] },
            revisions: phrases.compactMap { revisionsByPhrase[$0] },
            translationLatencies: translationLatencies,
            events: events
        )
    }

    private func drain() async {
        while let job = pending {
            pending = nil
            let now = DispatchTime.now().uptimeNanoseconds
            if lastStartedPhraseKey == job.phraseKey,
               lastStartedUptimeNanoseconds > 0,
               now - lastStartedUptimeNanoseconds < 500_000_000 {
                try? await Task.sleep(
                    nanoseconds: 500_000_000 - (now - lastStartedUptimeNanoseconds)
                )
            }
            let started = DispatchTime.now().uptimeNanoseconds
            lastStartedUptimeNanoseconds = started
            lastStartedPhraseKey = job.phraseKey
            do {
                let english = try EnglishSubtitleValidator.requireEnglish(
                    try await service.translate(job.source, highFidelity: highFidelity)
                )
                let completed = DispatchTime.now().uptimeNanoseconds
                translationLatencies.append(Double(completed - started) / 1_000_000)
                count += 1
                revisionsByPhrase[job.phraseKey, default: 0] += 1
                if firstLatencyByPhrase[job.phraseKey] == nil {
                    firstLatencyByPhrase[job.phraseKey] = completed
                        > job.phraseStartUptimeNanoseconds
                        ? Double(completed - job.phraseStartUptimeNanoseconds) / 1_000_000
                        : 0
                }
                events.append(BenchmarkPreviewTranslationEvent(
                    phraseKey: job.phraseKey,
                    source: job.source,
                    english: english,
                    sourceStartSample: job.sourceStartSample,
                    sourceEndSample: job.sourceEndSample,
                    sourceReceivedUptimeNanoseconds: job.receivedUptimeNanoseconds,
                    translationStartedUptimeNanoseconds: started,
                    completedUptimeNanoseconds: completed,
                    error: nil
                ))
            } catch {
                events.append(BenchmarkPreviewTranslationEvent(
                    phraseKey: job.phraseKey,
                    source: job.source,
                    english: "",
                    sourceStartSample: job.sourceStartSample,
                    sourceEndSample: job.sourceEndSample,
                    sourceReceivedUptimeNanoseconds: job.receivedUptimeNanoseconds,
                    translationStartedUptimeNanoseconds: started,
                    completedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    error: error.localizedDescription
                ))
            }
        }
        running = false
    }
}
