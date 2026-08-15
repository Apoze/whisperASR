import Foundation

enum HighQualityASRMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwenJA = "qwen-ja"
    case parakeetJA = "parakeet-ja"
    case whisperKit = "whisperkit"
    case funASRNanoInt8 = "funasr-nano-int8"
    case reazonSpeechK2V2 = "reazonspeech-k2-v2-int8"
    case adaptiveQwenParakeet = "adaptive-qwen-parakeet"

    static let productDefault = Self.qwenJA
    static var selectableCases: [Self] {
        var modes = HighQualityASRBackend.allCases.map(Self.backend)
        if HighQualityAdaptiveASR.isExposed { modes.append(.adaptiveQwenParakeet) }
        return modes
    }

    static func backend(_ backend: HighQualityASRBackend) -> Self {
        switch backend {
        case .qwenJA: .qwenJA
        case .parakeetJA: .parakeetJA
        case .whisperKit: .whisperKit
        case .funASRNanoInt8: .funASRNanoInt8
        case .reazonSpeechK2V2: .reazonSpeechK2V2
        }
    }

    var id: Self { self }
    var primaryBackend: HighQualityASRBackend {
        switch self {
        case .qwenJA, .adaptiveQwenParakeet: .qwenJA
        case .parakeetJA: .parakeetJA
        case .whisperKit: .whisperKit
        case .funASRNanoInt8: .funASRNanoInt8
        case .reazonSpeechK2V2: .reazonSpeechK2V2
        }
    }

    var displayName: String {
        switch self {
        case .adaptiveQwenParakeet: "Adaptive Qwen → Parakeet (Bêta)"
        default: primaryBackend.displayName
        }
    }

    var detail: String? {
        guard self == .adaptiveQwenParakeet else { return nil }
        return "Qwen d’abord; Parakeet analyse seulement les passages suspects, avec un coût supplémentaire proportionnel."
    }
}

struct HighQualityAdaptiveASRSegment: Codable, Equatable, Sendable {
    let id: String
    let startSample: Int
    let endSample: Int
    let rmsDBFS: Double
    let activeFrameRatio: Double
}

enum HighQualityAdaptiveASRSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case speechWithEmptyText = "speech-with-empty-text"
    case incompleteTimingCoverage = "incomplete-timing-coverage"
    case degenerateRepetition = "degenerate-repetition"
    case abnormalTextAudioCompression = "abnormal-text-audio-compression"
    case questionableNumber = "questionable-number"
    case questionableScopedTerm = "questionable-scoped-term"
}

struct HighQualityAdaptiveASRAssessment: Codable, Equatable, Sendable {
    let signals: [HighQualityAdaptiveASRSignal]
    let rawDefectScore: Double

    var isSuspect: Bool { !signals.isEmpty }
}

struct HighQualityAdaptiveASRBackendCalibration: Codable, Equatable, Sendable {
    let backend: HighQualityASRBackend
    let bestObservedDefect: Double
    let worstObservedDefect: Double
    let developmentSamples: Int
    let validationBlocks: Int
    let stable: Bool

    func calibratedScore(for rawDefect: Double) -> Double? {
        guard stable,
              developmentSamples > 0,
              validationBlocks >= 3,
              bestObservedDefect.isFinite,
              worstObservedDefect.isFinite,
              worstObservedDefect > bestObservedDefect,
              rawDefect.isFinite else { return nil }
        let defect = min(max(rawDefect, bestObservedDefect), worstObservedDefect)
        return 1 - (defect - bestObservedDefect)
            / (worstObservedDefect - bestObservedDefect)
    }
}

struct HighQualityAdaptiveASRCalibration: Codable, Equatable, Sendable {
    let version: String
    let qwen: HighQualityAdaptiveASRBackendCalibration
    let parakeet: HighQualityAdaptiveASRBackendCalibration
    let minimumMargin: Double
    let tieTolerance: Double
    let stableAcrossBlocks: Bool

    static let developmentV1 = Self(
        version: "adaptive-qwen-parakeet-pre-holdout-v1",
        qwen: .init(
            backend: .qwenJA,
            bestObservedDefect: 0,
            worstObservedDefect: 4,
            developmentSamples: 0,
            validationBlocks: 0,
            stable: false
        ),
        parakeet: .init(
            backend: .parakeetJA,
            bestObservedDefect: 0,
            worstObservedDefect: 1,
            developmentSamples: 0,
            validationBlocks: 0,
            stable: false
        ),
        minimumMargin: 0.2,
        tieTolerance: 0.01,
        stableAcrossBlocks: false
    )

    var isStable: Bool {
        stableAcrossBlocks && qwen.stable && parakeet.stable
            && qwen.backend == .qwenJA && parakeet.backend == .parakeetJA
    }
}

enum HighQualityAdaptiveASRFallbackReason: String, Codable, Sendable {
    case notSuspect = "not-suspect"
    case alternateUnavailable = "alternate-unavailable"
    case missingEvidence = "missing-evidence"
    case unstableCalibration = "unstable-calibration"
    case tie
    case insufficientMargin = "insufficient-margin"
    case integrityVeto = "integrity-veto"
    case alternateFailure = "alternate-failure"
}

enum HighQualityAdaptiveASRVeto: String, Codable, CaseIterable, Hashable, Sendable {
    case newEmptySpeech = "new-empty-speech"
    case lostCoverage = "lost-coverage"
    case degenerateRepetition = "degenerate-repetition"
    case duplicatedText = "duplicated-text"
    case lostNumber = "lost-number"
    case lostScopedTerm = "lost-scoped-term"
}

struct HighQualityAdaptiveASRDecision: Codable, Equatable, Sendable {
    let segment: HighQualityAdaptiveASRSegment
    let signals: [HighQualityAdaptiveASRSignal]
    let executedBackends: [HighQualityASRBackend]
    let qwen: HighQualityASRExchange
    let parakeet: HighQualityASRExchange?
    let qwenRawDefectScore: Double
    let parakeetRawDefectScore: Double?
    let qwenCalibratedScore: Double?
    let parakeetCalibratedScore: Double?
    let vetoes: [HighQualityAdaptiveASRVeto]
    let selectedBackend: HighQualityASRBackend
    let selectedText: String
    let fallbackReason: HighQualityAdaptiveASRFallbackReason?
    let qwenDuration: TimeInterval
    let parakeetDuration: TimeInterval?
    let error: HighQualityAdaptiveASRErrorEvidence?
}

enum HighQualityAdaptiveASRErrorRoute: String, Codable, Sendable {
    case infrastructure
    case harness
    case candidate
}

struct HighQualityAdaptiveASRErrorEvidence: Codable, Equatable, Sendable {
    let route: HighQualityAdaptiveASRErrorRoute
    let stage: String
    let segmentID: String?
    let message: String
}

struct HighQualityAdaptiveASRAudit: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let calibration: HighQualityAdaptiveASRCalibration
    let decisions: [HighQualityAdaptiveASRDecision]
    let workers: [HighQualityASRWorkerEvidence]
    let qwenDuration: TimeInterval
    let parakeetDuration: TimeInterval
    let peakMemoryBytes: UInt64
    let errors: [HighQualityAdaptiveASRErrorEvidence]
}

enum HighQualityAdaptiveASR {
    static let isExposed = false
    private static let sampleRate = 16_000
    private static let frameSamples = sampleRate / 50
    private static let minimumSamples = 3 * sampleRate
    private static let maximumSamples = 8 * sampleRate

    static func route(_ error: any Error) -> HighQualityAdaptiveASRErrorRoute {
        if error is CancellationError
            || error is HeavyweightModelGateError
            || error is HighQualityWorkerProcessError {
            return .infrastructure
        }
        if let error = error as? HighQualityASRWorkerError {
            switch error {
            case .criticalMemoryPressure, .protocolFailure: return .infrastructure
            case .backendFailure: return .candidate
            }
        }
        return .candidate
    }

    static func plan(samples: [Float]) -> [HighQualityAdaptiveASRSegment] {
        guard !samples.isEmpty else { return [] }
        var result: [HighQualityAdaptiveASRSegment] = []
        var start = 0
        while start < samples.count {
            let remaining = samples.count - start
            let end: Int
            if remaining <= maximumSamples {
                end = samples.count
            } else {
                let latest = min(start + maximumSamples, samples.count - minimumSamples)
                var best = start + minimumSamples
                var bestEnergy = Double.infinity
                for candidate in stride(
                    from: start + minimumSamples,
                    through: latest,
                    by: frameSamples
                ) {
                    let energy = samples[(candidate - frameSamples)..<candidate].reduce(0.0) {
                        $0 + Double($1 * $1)
                    }
                    if energy < bestEnergy || (energy == bestEnergy && candidate > best) {
                        best = candidate
                        bestEnergy = energy
                    }
                }
                end = best
            }
            let values = samples[start..<end]
            let frames = stride(from: start, to: end, by: frameSamples).map {
                samples[$0..<min($0 + frameSamples, end)]
            }
            result.append(.init(
                id: String(format: "segment-%04d", result.count + 1),
                startSample: start,
                endSample: end,
                rmsDBFS: dbfs(values),
                activeFrameRatio: Double(frames.filter { dbfs($0) >= -42 }.count)
                    / Double(frames.count)
            ))
            start = end
        }
        return result
    }

    static func assess(
        qwen: HighQualityASRExchange,
        segment: HighQualityAdaptiveASRSegment,
        scopedTerms: Set<String>
    ) -> HighQualityAdaptiveASRAssessment {
        let text = normalized(qwen.rawTranscript)
        let duration = Double(segment.endSample - segment.startSample) / Double(sampleRate)
        let characterRate = Double(text.count) / max(duration, 0.02)
        let repetition = repetitionRatio(text)
        var signals: [HighQualityAdaptiveASRSignal] = []
        var defect = 0.0
        if text.isEmpty && segment.activeFrameRatio >= 0.2 {
            signals.append(.speechWithEmptyText)
            defect += 4
        }
        if let coverage = timingCoverage(qwen), !text.isEmpty, coverage < duration * 0.5 {
            signals.append(.incompleteTimingCoverage)
            defect += 1 - coverage / max(duration, 0.02)
        }
        if repetition > 0.25 {
            signals.append(.degenerateRepetition)
            defect += 4 * (repetition - 0.25)
        }
        if characterRate > 12 || (characterRate < 1 && segment.activeFrameRatio >= 0.2) {
            signals.append(.abnormalTextAudioCompression)
            defect += characterRate < 1 ? 1 - characterRate : (characterRate - 12) / 6
        }
        if qwen.rawTranscript.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
            signals.append(.questionableNumber)
            defect += 0.25
        }
        if scopedTerms.contains(where: {
            let term = normalized($0)
            return !term.isEmpty && text.contains(term)
        }) {
            signals.append(.questionableScopedTerm)
            defect += 0.25
        }
        return .init(signals: signals, rawDefectScore: defect)
    }

    static func decide(
        segment: HighQualityAdaptiveASRSegment,
        qwen: HighQualityASRExchange,
        qwenDuration: TimeInterval,
        parakeet: HighQualityASRExchange?,
        parakeetDuration: TimeInterval?,
        scopedTerms: Set<String>,
        calibration: HighQualityAdaptiveASRCalibration,
        alternateError: HighQualityAdaptiveASRErrorEvidence? = nil
    ) -> HighQualityAdaptiveASRDecision {
        let qwenAssessment = assess(qwen: qwen, segment: segment, scopedTerms: scopedTerms)
        guard let parakeet else {
            return decision(
                segment: segment,
                assessment: qwenAssessment,
                qwen: qwen,
                qwenDuration: qwenDuration,
                fallback: alternateError == nil
                    ? (qwenAssessment.isSuspect ? .alternateUnavailable : .notSuspect)
                    : .alternateFailure,
                executedBackends: alternateError == nil
                    ? [.qwenJA] : [.qwenJA, .parakeetJA],
                error: alternateError
            )
        }
        let parakeetAssessment = assess(
            qwen: parakeet,
            segment: segment,
            scopedTerms: scopedTerms
        )
        let parakeetRaw = parakeet.confidence.map {
            parakeetAssessment.rawDefectScore + 1 - $0
        }
        let qwenScore = calibration.qwen.calibratedScore(
            for: qwenAssessment.rawDefectScore
        )
        let parakeetScore = parakeetRaw.flatMap {
            calibration.parakeet.calibratedScore(for: $0)
        }
        let vetoes = vetoes(
            qwen: qwen,
            parakeet: parakeet,
            segment: segment,
            scopedTerms: scopedTerms
        )
        let fallback: HighQualityAdaptiveASRFallbackReason?
        if !qwenAssessment.isSuspect {
            fallback = .notSuspect
        } else if !vetoes.isEmpty {
            fallback = .integrityVeto
        } else if !calibration.isStable {
            fallback = .unstableCalibration
        } else if qwenScore == nil || parakeetScore == nil {
            fallback = .missingEvidence
        } else if abs(parakeetScore! - qwenScore!) <= calibration.tieTolerance {
            fallback = .tie
        } else if parakeetScore! - qwenScore! <= calibration.minimumMargin {
            fallback = .insufficientMargin
        } else {
            fallback = nil
        }
        return .init(
            segment: segment,
            signals: qwenAssessment.signals,
            executedBackends: [.qwenJA, .parakeetJA],
            qwen: qwen,
            parakeet: parakeet,
            qwenRawDefectScore: qwenAssessment.rawDefectScore,
            parakeetRawDefectScore: parakeetRaw,
            qwenCalibratedScore: qwenScore,
            parakeetCalibratedScore: parakeetScore,
            vetoes: vetoes,
            selectedBackend: fallback == nil ? .parakeetJA : .qwenJA,
            selectedText: fallback == nil ? parakeet.rawTranscript : qwen.rawTranscript,
            fallbackReason: fallback,
            qwenDuration: qwenDuration,
            parakeetDuration: parakeetDuration,
            error: alternateError
        )
    }

    static func compose(_ decisions: [HighQualityAdaptiveASRDecision]) -> HighQualityASRExchange {
        let chunks: [HighQualityASRChunk] = decisions.enumerated().compactMap {
            index, decision -> HighQualityASRChunk? in
            let text = decision.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return HighQualityASRChunk(
                index: index,
                sourceStart: Double(decision.segment.startSample) / Double(sampleRate),
                sourceEnd: Double(decision.segment.endSample) / Double(sampleRate),
                transcript: text
            )
        }
        let windows: [HighQualityASRWindowEvidence] = decisions.map { decision in
            .init(
                sourceStart: Double(decision.segment.startSample) / Double(sampleRate),
                sourceEnd: Double(decision.segment.endSample) / Double(sampleRate),
                result: decision.selectedBackend == .parakeetJA
                    ? decision.parakeet ?? decision.qwen : decision.qwen
            )
        }
        return .init(
            rawTranscript: chunks.map(\.transcript).joined(),
            chunks: chunks,
            model: decisions.first?.qwen.model,
            windows: windows
        )
    }

    private static func dbfs(_ samples: ArraySlice<Float>) -> Double {
        let squareSum = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return squareSum == 0 ? -120 : 10 * log10(squareSum / Double(samples.count))
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        .lowercased()
    }

    private static func repetitionRatio(_ text: String) -> Double {
        let characters = Array(text)
        guard characters.count >= 3 else { return 0 }
        let grams = (0...(characters.count - 3)).map {
            String(characters[$0...($0 + 2)])
        }
        return 1 - Double(Set(grams).count) / Double(grams.count)
    }

    private static func timingCoverage(_ exchange: HighQualityASRExchange) -> Double? {
        let ranges: [(Double, Double)]
        if let timings = exchange.wordTimings ?? exchange.tokenTimings {
            ranges = timings.map { ($0.sourceStart, $0.sourceEnd) }
        } else if let segments = exchange.segments {
            ranges = segments.map { ($0.sourceStart, $0.sourceEnd) }
        } else {
            return nil
        }
        var covered = 0.0
        var current: (Double, Double)?
        for range in ranges.sorted(by: { $0.0 < $1.0 }) where range.1 >= range.0 {
            if let value = current, range.0 <= value.1 {
                current = (value.0, max(value.1, range.1))
            } else {
                if let value = current { covered += value.1 - value.0 }
                current = range
            }
        }
        if let value = current { covered += value.1 - value.0 }
        return covered
    }

    static func vetoes(
        qwen: HighQualityASRExchange,
        parakeet: HighQualityASRExchange,
        segment: HighQualityAdaptiveASRSegment,
        scopedTerms: Set<String>
    ) -> [HighQualityAdaptiveASRVeto] {
        let qwenText = normalized(qwen.rawTranscript)
        let parakeetText = normalized(parakeet.rawTranscript)
        var vetoes = Set<HighQualityAdaptiveASRVeto>()
        if !qwenText.isEmpty, parakeetText.isEmpty, segment.activeFrameRatio >= 0.2 {
            vetoes.insert(.newEmptySpeech)
        }
        if qwenText.count >= 4,
           repetitionRatio(qwenText) <= 0.25,
           parakeetText.count * 2 < qwenText.count {
            vetoes.insert(.lostCoverage)
        } else if let qwenCoverage = timingCoverage(qwen),
                  let parakeetCoverage = timingCoverage(parakeet),
                  parakeetCoverage * 2 < qwenCoverage {
            vetoes.insert(.lostCoverage)
        }
        if repetitionRatio(parakeetText) > 0.25,
           repetitionRatio(qwenText) <= 0.25 {
            vetoes.insert(.degenerateRepetition)
        }
        if isDuplicated(parakeet) { vetoes.insert(.duplicatedText) }
        if !numbers(in: qwen.rawTranscript).isSubset(
            of: numbers(in: parakeet.rawTranscript)
        ) {
            vetoes.insert(.lostNumber)
        }
        if scopedTerms.contains(where: {
            let term = normalized($0)
            return !term.isEmpty && qwenText.contains(term) && !parakeetText.contains(term)
        }) {
            vetoes.insert(.lostScopedTerm)
        }
        return HighQualityAdaptiveASRVeto.allCases.filter(vetoes.contains)
    }

    private static func numbers(in text: String) -> Set<String> {
        var numbers = Set<String>()
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                numbers.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { numbers.insert(current) }
        return numbers
    }

    private static func isDuplicated(_ exchange: HighQualityASRExchange) -> Bool {
        if zip(exchange.chunks, exchange.chunks.dropFirst()).contains(where: {
            let left = normalized($0.transcript)
            return !left.isEmpty && left == normalized($1.transcript)
        }) {
            return true
        }
        let characters = Array(normalized(exchange.rawTranscript))
        guard characters.count >= 4, characters.count.isMultiple(of: 2) else { return false }
        let middle = characters.count / 2
        return characters[..<middle] == characters[middle...]
    }

    private static func decision(
        segment: HighQualityAdaptiveASRSegment,
        assessment: HighQualityAdaptiveASRAssessment,
        qwen: HighQualityASRExchange,
        qwenDuration: TimeInterval,
        fallback: HighQualityAdaptiveASRFallbackReason,
        executedBackends: [HighQualityASRBackend] = [.qwenJA],
        error: HighQualityAdaptiveASRErrorEvidence? = nil
    ) -> HighQualityAdaptiveASRDecision {
        .init(
            segment: segment,
            signals: assessment.signals,
            executedBackends: executedBackends,
            qwen: qwen,
            parakeet: nil,
            qwenRawDefectScore: assessment.rawDefectScore,
            parakeetRawDefectScore: nil,
            qwenCalibratedScore: nil,
            parakeetCalibratedScore: nil,
            vetoes: [],
            selectedBackend: .qwenJA,
            selectedText: qwen.rawTranscript,
            fallbackReason: fallback,
            qwenDuration: qwenDuration,
            parakeetDuration: nil,
            error: error
        )
    }
}
