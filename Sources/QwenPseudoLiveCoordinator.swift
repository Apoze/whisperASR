import Foundation

enum QwenPseudoLiveCadence: Int, CaseIterable, Identifiable, Codable, Sendable {
    case seconds1 = 1
    case seconds2 = 2
    case seconds3 = 3

    static let storageKey = "qwenPseudoLiveCadenceSeconds"

    var id: Int { rawValue }
    var sampleCount: Int { rawValue * LocalEndpointPlanner.sampleRate }
    var label: String { "\(rawValue) second\(rawValue == 1 ? "" : "s")" }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.integer(forKey: storageKey)) ?? .seconds2
    }
}

struct QwenPseudoLivePreviewWork: Equatable, Sendable {
    let generation: Int
    let range: Range<Int>
    let requestedUptimeNanoseconds: UInt64
}

struct QwenPseudoLiveFinalWork: Equatable, Sendable {
    let generation: Int
    let range: Range<Int>
    let stableThrough: Int
}

struct QwenPseudoLivePreviewResult: Equatable, Sendable {
    let work: QwenPseudoLivePreviewWork
    let source: String
}

struct QwenPseudoLivePreviewCompletion: Equatable, Sendable {
    let accepted: QwenPseudoLivePreviewResult?
    let next: QwenPseudoLivePreviewWork?
}

/// Schedules cumulative Qwen snapshots without granting them stable-PCM authority.
/// The endpoint FIFO remains the sole owner of final ranges and reclamation.
struct QwenPseudoLiveCoordinator: Sendable {
    let cadence: QwenPseudoLiveCadence
    let previewsEnabled: Bool

    private(set) var coalescedTickCount = 0
    private(set) var staleResultCount = 0
    private(set) var generation = 0

    private var phraseStart: Int?
    private var lastRequestedEnd: Int?
    private var latestRequestedRange: Range<Int>?
    private var inFlight: QwenPseudoLivePreviewWork?
    private var pending: QwenPseudoLivePreviewWork?
    private var pendingFinals: [QwenPseudoLiveFinalWork] = []
    private var previewNotBefore = 0
    private var isCancelled = false

    var isCatchingUp: Bool { pending != nil }

    init(cadence: QwenPseudoLiveCadence, previewsEnabled: Bool = true) {
        self.cadence = cadence
        self.previewsEnabled = previewsEnabled
    }

    static func previewStart(speechStart: Int, notBefore: Int) -> Int {
        max(notBefore, speechStart - LocalEndpointPlanner.preRoll)
    }

    mutating func observe(
        speechStart: Int,
        availableThrough: Int,
        requestedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> QwenPseudoLivePreviewWork? {
        guard previewsEnabled,
              !isCancelled,
              speechStart >= previewNotBefore,
              availableThrough > speechStart else { return nil }
        if phraseStart == nil {
            phraseStart = speechStart
            lastRequestedEnd = speechStart
        }
        guard let phraseStart,
              availableThrough - (lastRequestedEnd ?? phraseStart) >= cadence.sampleCount else {
            return nil
        }

        lastRequestedEnd = availableThrough
        let work = QwenPseudoLivePreviewWork(
            generation: generation,
            range: phraseStart..<availableThrough,
            requestedUptimeNanoseconds: requestedUptimeNanoseconds
        )
        latestRequestedRange = work.range
        guard inFlight == nil, pendingFinals.isEmpty else {
            if pending != nil || inFlight != nil { coalescedTickCount += 1 }
            pending = work
            return nil
        }
        inFlight = work
        return work
    }

    mutating func completePreview(
        _ work: QwenPseudoLivePreviewWork,
        source: String
    ) -> QwenPseudoLivePreviewCompletion {
        guard inFlight == work else {
            staleResultCount += 1
            return QwenPseudoLivePreviewCompletion(accepted: nil, next: nil)
        }
        inFlight = nil
        let accepted = !isCancelled
            && work.generation == generation
            && work.range == latestRequestedRange
            ? QwenPseudoLivePreviewResult(work: work, source: source)
            : nil
        if accepted == nil { staleResultCount += 1 }
        return QwenPseudoLivePreviewCompletion(
            accepted: accepted,
            next: takePendingIfReady()
        )
    }

    mutating func failPreview(
        _ work: QwenPseudoLivePreviewWork
    ) -> QwenPseudoLivePreviewWork? {
        guard inFlight == work else {
            staleResultCount += 1
            return nil
        }
        inFlight = nil
        return takePendingIfReady()
    }

    mutating func stageFinal(
        range: Range<Int>,
        stableThrough: Int
    ) -> QwenPseudoLiveFinalWork {
        generation += 1
        phraseStart = nil
        lastRequestedEnd = nil
        latestRequestedRange = nil
        pending = nil
        previewNotBefore = max(previewNotBefore, stableThrough)
        let work = QwenPseudoLiveFinalWork(
            generation: generation,
            range: range,
            stableThrough: stableThrough
        )
        pendingFinals.append(work)
        return work
    }

    mutating func completeFinal(
        _ work: QwenPseudoLiveFinalWork
    ) -> QwenPseudoLivePreviewWork? {
        guard pendingFinals.first == work else { return nil }
        pendingFinals.removeFirst()
        return takePendingIfReady()
    }

    mutating func completeFinal(range: Range<Int>) -> QwenPseudoLivePreviewWork? {
        guard let work = pendingFinals.first, work.range == range else { return nil }
        return completeFinal(work)
    }

    mutating func cancel() {
        isCancelled = true
        generation += 1
        phraseStart = nil
        lastRequestedEnd = nil
        latestRequestedRange = nil
        pending = nil
        pendingFinals.removeAll()
    }

    private mutating func takePendingIfReady() -> QwenPseudoLivePreviewWork? {
        guard !isCancelled, pendingFinals.isEmpty, inFlight == nil, let pending else {
            return nil
        }
        self.pending = nil
        inFlight = pending
        return pending
    }
}
