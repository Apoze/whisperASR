import Darwin
import Foundation
@testable import WhisperASRApp

struct BenchmarkProcessUsage: Sendable {
    let residentBytes: UInt64
    let cpuNanoseconds: UInt64
}

struct BenchmarkResourceSummary: Codable, Sendable {
    let maximumResidentBytes: UInt64?
    let averageCPUPercent: Double?
    let thermalStateBefore: String
    let thermalStateAfter: String
}

@MainActor
func startBenchmarkResourceSampler(
    pids: @escaping @Sendable () -> [Int32]
) -> Task<BenchmarkResourceSummary, Never> {
    let started = DispatchTime.now().uptimeNanoseconds
    let initialPIDs = pids()
    let usageBefore = benchmarkProcessUsage(pids: initialPIDs)
    let thermalBefore = benchmarkThermalState()
    return Task { @MainActor in
        var maximum = usageBefore?.residentBytes
        var latestCPU = usageBefore?.cpuNanoseconds
        while !Task.isCancelled {
            if let usage = benchmarkProcessUsage(pids: pids()) {
                maximum = max(maximum ?? 0, usage.residentBytes)
                latestCPU = max(latestCPU ?? 0, usage.cpuNanoseconds)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let usage = benchmarkProcessUsage(pids: pids()) {
            maximum = max(maximum ?? 0, usage.residentBytes)
            latestCPU = max(latestCPU ?? 0, usage.cpuNanoseconds)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let cpu: Double?
        if let before = usageBefore?.cpuNanoseconds,
           let after = latestCPU,
           after >= before,
           elapsed > 0 {
            cpu = 100 * Double(after - before) / Double(elapsed)
        } else {
            cpu = nil
        }
        return BenchmarkResourceSummary(
            maximumResidentBytes: maximum,
            averageCPUPercent: cpu,
            thermalStateBefore: thermalBefore,
            thermalStateAfter: benchmarkThermalState()
        )
    }
}

func benchmarkProcessUsage(pids: [Int32]) -> BenchmarkProcessUsage? {
    guard !pids.isEmpty else { return nil }
    var residentBytes: UInt64 = 0
    var cpuNanoseconds: UInt64 = 0
    var observed = false
    for pid in pids {
        guard let usage = benchmarkProcessUsage(pid: pid) else { continue }
        observed = true
        residentBytes += usage.residentBytes
        cpuNanoseconds += usage.cpuNanoseconds
    }
    guard observed else { return nil }
    return BenchmarkProcessUsage(
        residentBytes: residentBytes,
        cpuNanoseconds: cpuNanoseconds
    )
}

private func benchmarkProcessUsage(pid: Int32) -> BenchmarkProcessUsage? {
    guard pid > 0 else { return nil }
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        UnsafeMutableRawPointer(pointer).withMemoryRebound(
            to: rusage_info_t?.self,
            capacity: 1
        ) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else { return nil }
    return BenchmarkProcessUsage(
        residentBytes: info.ri_phys_footprint,
        cpuNanoseconds: info.ri_user_time + info.ri_system_time
    )
}

func benchmarkThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

struct BenchmarkBacklogWatchdog: Sendable {
    static let limitMilliseconds = 30_000.0
    static let graceNanoseconds: UInt64 = 60_000_000_000

    private(set) var maximumMilliseconds = 0.0
    private var overLimitSince: UInt64?

    mutating func observe(
        milliseconds: Double,
        at now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        let value = max(0, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds, value)
        guard value > Self.limitMilliseconds else {
            overLimitSince = nil
            return false
        }
        if let overLimitSince {
            return now - overLimitSince >= Self.graceNanoseconds
        }
        overLimitSince = now
        return false
    }
}

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

struct BenchmarkFinalTranslationEvent: Codable, Sendable {
    let finalID: String
    let source: String
    let english: String
    let sourceStartSample: Int
    let sourceEndSample: Int
    let endpointUptimeNanoseconds: UInt64
    let sourceReceivedUptimeNanoseconds: UInt64
    let translationStartedUptimeNanoseconds: UInt64
    let acceptedUptimeNanoseconds: UInt64
    let endpointToAcceptedMilliseconds: Double
    let attemptCount: Int
    let error: String?
}

struct BenchmarkFinalTranslationSummary: Sendable {
    static let empty = Self(events: [], appendOnly: true)

    let events: [BenchmarkFinalTranslationEvent]
    let appendOnly: Bool
}

@available(macOS 26.4, *)
actor BenchmarkFinalTranslator {
    private struct Job: Sendable {
        let finalID: String
        let source: String
        let sourceStartSample: Int
        let sourceEndSample: Int
        let endpointUptimeNanoseconds: UInt64
        let receivedUptimeNanoseconds: UInt64
    }

    private let service: AppleTranslationService?
    private let unavailableReason: String?
    private var pending: [Job] = []
    private var running = false
    private var events: [BenchmarkFinalTranslationEvent] = []
    private var submittedIDs = Set<String>()
    private var appendOnly = true

    init(service: AppleTranslationService?, unavailableReason: String? = nil) {
        self.service = service
        self.unavailableReason = unavailableReason
    }

    func submit(
        finalID: String,
        source: String,
        sourceStartSample: Int,
        sourceEndSample: Int,
        endpointUptimeNanoseconds: UInt64,
        receivedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard submittedIDs.insert(finalID).inserted else {
            appendOnly = false
            return
        }
        pending.append(Job(
            finalID: finalID,
            source: source,
            sourceStartSample: sourceStartSample,
            sourceEndSample: sourceEndSample,
            endpointUptimeNanoseconds: endpointUptimeNanoseconds,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds
        ))
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    func finish() async -> BenchmarkFinalTranslationSummary {
        while running || !pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return BenchmarkFinalTranslationSummary(
            events: events,
            appendOnly: appendOnly && Set(events.map(\.finalID)).count == events.count
        )
    }

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            let source = job.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let started = DispatchTime.now().uptimeNanoseconds
            var english = ""
            var failure: String?
            var attempts = 0
            if source.isEmpty {
                failure = "Empty Japanese final."
            } else if let service {
                for attempt in 1...3 {
                    attempts = attempt
                    do {
                        english = try EnglishSubtitleValidator.requireEnglish(
                            try await service.translate(source, highFidelity: true)
                        )
                        failure = nil
                        break
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            } else {
                failure = unavailableReason ?? "Apple highFidelity unavailable"
            }
            let accepted = DispatchTime.now().uptimeNanoseconds
            events.append(BenchmarkFinalTranslationEvent(
                finalID: job.finalID,
                source: source,
                english: english,
                sourceStartSample: job.sourceStartSample,
                sourceEndSample: job.sourceEndSample,
                endpointUptimeNanoseconds: job.endpointUptimeNanoseconds,
                sourceReceivedUptimeNanoseconds: job.receivedUptimeNanoseconds,
                translationStartedUptimeNanoseconds: started,
                acceptedUptimeNanoseconds: accepted,
                endpointToAcceptedMilliseconds: accepted > job.endpointUptimeNanoseconds
                    ? Double(accepted - job.endpointUptimeNanoseconds) / 1_000_000 : 0,
                attemptCount: attempts,
                error: failure
            ))
        }
        running = false
    }
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
