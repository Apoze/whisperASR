import Foundation

/// Drops the already-emitted prefix after the one permitted helper restart.
/// It waits until the replay diverges from an exact suffix of the previous
/// transcript, so partial overlap cannot be published twice.
struct VoxtralReplayDeduplicator: Sendable {
    private let previousTranscript: String
    private var replayTranscript = ""
    private var droppedCharacters: Int?
    private var emittedCharacters = 0

    init(previousTranscript: String) {
        self.previousTranscript = previousTranscript
    }

    mutating func ingest(_ transcript: String, finishing: Bool = false) -> String? {
        guard transcript.hasPrefix(replayTranscript) else { return nil }
        replayTranscript = transcript

        if droppedCharacters == nil {
            let overlap = longestSuffixPrefixOverlap(
                previous: previousTranscript,
                replay: replayTranscript
            )
            if overlap == replayTranscript.count, !finishing {
                return ""
            }
            // A one-character match is too weak to prove identity in Japanese.
            guard overlap >= 2 || (previousTranscript.isEmpty && overlap == 0) else {
                return finishing ? nil : ""
            }
            droppedCharacters = overlap
        }

        let visible = replayTranscript.dropFirst(droppedCharacters ?? 0)
        guard visible.count >= emittedCharacters else { return nil }
        let delta = String(visible.dropFirst(emittedCharacters))
        emittedCharacters = visible.count
        return delta
    }

    private func longestSuffixPrefixOverlap(previous: String, replay: String) -> Int {
        let maximum = min(previous.count, replay.count)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if previous.suffix(length) == replay.prefix(length) { return length }
        }
        return 0
    }
}

struct VoxtralClausePreview: Equatable, Sendable {
    let generation: Int
    let sourceText: String
    let sampleRange: Range<Int>
}

/// A logical subtitle boundary. It never asks the continuous Voxtral session
/// to finish or reset; the caller only stages the source text for translation.
struct VoxtralClauseBoundary: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case semantic
        case pause
        case speaker
        case forced
        case finish
    }

    enum SpeakerDecision: Equatable, Sendable {
        case applied(LocalSpeakerTransition)
        case diarizationLagFallback(LocalSpeakerTransition)
        case markerTimedOut(LocalSpeakerTransition)
    }

    enum Degradation: String, Equatable, Sendable {
        case degradedForcedBoundary
    }

    let generation: Int
    let kind: Kind
    let sourceText: String
    let sourceCharacterRange: Range<Int>
    let sampleRange: Range<Int>
    let endpointDetectedAt: Int
    let stagedAt: Int
    let speakerDecision: SpeakerDecision?
    let degradation: Degradation?
}

/// Corpus-measured correction for Voxtral's 80 ms emission-group proxy.
/// Speaker evidence stays observational until its error is demonstrably small.
struct VoxtralMarkerCalibration: Equatable, Sendable {
    static let frameSamples = 1_280
    static let maximumP95ErrorSamples = 3_840

    let biasSamples: Int
    let p95AbsoluteErrorSamples: Int

    init(biasSamples: Int, p95AbsoluteErrorSamples: Int) {
        self.biasSamples = Int((Double(biasSamples) / Double(Self.frameSamples)).rounded())
            * Self.frameSamples
        self.p95AbsoluteErrorSamples = p95AbsoluteErrorSamples
    }

    var permitsSpeakerBoundaries: Bool {
        p95AbsoluteErrorSamples >= 0
            && p95AbsoluteErrorSamples <= Self.maximumP95ErrorSamples
    }

    func calibratedEndSample(for marker: VoxtralEmissionMarker) -> Int {
        marker.proxyEndSample + biasSamples
    }
}

/// Pure policy for turning one append-only Voxtral transcript into bounded
/// translation clauses while keeping source staging separate from validation.
struct VoxtralClausePlanner: Sendable {
    static let sampleRate = 16_000
    static let vadSilence = sampleRate * 350 / 1_000
    /// Compatibility value for the default Q4/960 configuration. Production
    /// planners use their selected configuration's instance guard.
    static let stabilityGuard = sampleRate * 1_120 / 1_000
    static let softClauseTarget = sampleRate * 5
    /// Ten stable seconds is a checkpoint, not an arbitrary text cut.
    static let hardClauseTarget = sampleRate * 10
    static let hardClauseLimit = hardClauseTarget + stabilityGuard
    static let speakerMarkerEarlyTolerance = sampleRate * 160 / 1_000
    /// A marker candidate remains useful for 1.5 s. Speaker evidence may
    /// advance a boundary, but it never delays punctuation, pause, or timeout.
    static let speakerMarkerWait = sampleRate * 3 / 2
    static let maximumDiarizationLag = sampleRate * 3 / 2

    private static let terminalPunctuation: Set<Character> = ["。", "！", "？", "!", "?"]
    private static let conservativeJapaneseEndings = [
        "じゃなかった", "じゃない", "でしょう", "でした", "ました", "ません",
        "でしょうか", "ですよね", "ますよね", "ですか", "ますか", "ですよ",
        "ますよ", "ですね", "ますね", "だよね", "だった", "だよ", "だね",
        "です", "ます",
    ]
    private static let meaningfulCharacters = CharacterSet.letters.union(.decimalDigits)

    private let markerCalibration: VoxtralMarkerCalibration?
    private let stabilityGuardSamples: Int

    private(set) var generation = 0
    private(set) var fedThrough = 0
    private(set) var pendingSourceText = ""
    private(set) var sourceStagedThrough = 0
    private(set) var englishValidatedThrough = 0
    private(set) var sourceStagedCharacterCount = 0
    private(set) var sourceValidatedCharacterCount = 0
    private(set) var sourceStagedUTF8Count = 0

    private var clauseSpeechStart: Int?
    private var lastSpeechEnd: Int?
    private var lastSourceUpdateThrough: Int?
    private var emissionMarkers: [VoxtralEmissionMarker] = []
    private var speakerTransitions: [LocalSpeakerTransition] = []
    private var speakerEvidenceDiscarded = false
    private var pendingSpeakerDecision: VoxtralClauseBoundary.SpeakerDecision?
    private var awaitingValidation: [VoxtralClauseBoundary] = []

    init(
        markerCalibration: VoxtralMarkerCalibration? = nil,
        stabilityGuardSamples: Int = Self.stabilityGuard
    ) {
        self.markerCalibration = markerCalibration
        self.stabilityGuardSamples = stabilityGuardSamples
    }

    var pendingValidationCount: Int { awaitingValidation.count }

    /// A helper restart invalidates session-relative UTF-8 offsets. Keep all
    /// transcript and clause state, but make speaker evidence shadow-only.
    mutating func discardSpeakerEvidence() {
        emissionMarkers.removeAll(keepingCapacity: false)
        speakerTransitions.removeAll(keepingCapacity: false)
        speakerEvidenceDiscarded = true
        pendingSpeakerDecision = nil
    }

    /// A diarizer failure invalidates only queued speaker changes. Validated
    /// Voxtral group markers may still protect forced text/PCM boundaries.
    mutating func discardSpeakerTransitions() {
        speakerTransitions.removeAll(keepingCapacity: false)
        pendingSpeakerDecision = nil
    }

    var preview: VoxtralClausePreview? {
        let text = normalized(pendingSourceText)
        guard Self.isMeaningful(text), fedThrough > sourceStagedThrough else { return nil }
        return VoxtralClausePreview(
            generation: generation,
            sourceText: text,
            sampleRange: sourceStagedThrough..<fedThrough
        )
    }

    /// Appends only newly emitted Voxtral text and evaluates one logical
    /// boundary. Speech ranges are VAD observations, never permission to drop
    /// audio. At most one clause is staged per call.
    mutating func observe(
        delta: String = "",
        fedThrough proposedFedThrough: Int,
        sourceUpdateThrough: Int? = nil,
        speech: [SpeechSampleRange] = [],
        emissionMarkers newEmissionMarkers: [VoxtralEmissionMarker] = [],
        speakerTransitions newSpeakerTransitions: [LocalSpeakerTransition] = []
    ) -> VoxtralClauseBoundary? {
        fedThrough = max(fedThrough, proposedFedThrough)
        pendingSourceText.append(delta)
        ingest(
            emissionMarkers: newEmissionMarkers,
            speakerTransitions: newSpeakerTransitions
        )
        if delta.contains(where: { !$0.isWhitespace }) {
            lastSourceUpdateThrough = max(
                lastSourceUpdateThrough ?? 0,
                sourceUpdateThrough ?? fedThrough
            )
        }
        observeSpeech(speech)

        let stableThrough = max(sourceStagedThrough, fedThrough - stabilityGuardSamples)
        let start = clauseSpeechStart ?? sourceStagedThrough
        guard stableThrough > sourceStagedThrough else { return nil }

        if let expired = expireSpeakerTransitionIfNeeded() {
            pendingSpeakerDecision = pendingSpeakerDecision ?? .markerTimedOut(expired)
        }

        let semantic = semanticPrefix()
        let speaker = speakerPrefix(stableThrough: stableThrough)
        // A usable speaker cut owns the boundary even when punctuation arrived
        // slightly earlier in the same decoder update. Staging the semantic
        // prefix through `stableThrough` would otherwise advance past the
        // acoustic turn and prune the only evidence that B has started.
        if let speaker {
            return stage(
                kind: .speaker,
                text: speaker.text,
                consumedCharacters: speaker.consumedCharacters,
                through: speaker.transition.changeSample,
                detectedAt: speaker.transition.confirmedAtSample,
                speakerDecision: .applied(speaker.transition)
            )
        }

        let unresolvedTransition = speaker == nil ? speakerTransitions.first(where: {
            $0.changeSample > sourceStagedThrough && $0.changeSample <= fedThrough
        }) : nil

        let pauseReady = lastSpeechEnd.map {
            fedThrough - $0 >= stabilityGuardSamples
        } ?? false
        let stableDuration = stableThrough - start
        let softSemanticReady = stableDuration >= Self.softClauseTarget
            && hasConservativeJapaneseEnding(pendingSourceText)
            && lastSourceUpdateThrough.map {
                fedThrough - $0 >= stabilityGuardSamples
            } == true
        let forcedCheckpointReached = stableDuration >= Self.hardClauseTarget

        let fallbackDecision: VoxtralClauseBoundary.SpeakerDecision?
        if let unresolvedTransition {
            fallbackDecision = .diarizationLagFallback(unresolvedTransition)
        } else {
            fallbackDecision = pendingSpeakerDecision
        }

        if let semantic {
            return stage(
                kind: .semantic,
                text: semantic.text,
                consumedCharacters: semantic.consumedCharacters,
                through: stableThrough,
                detectedAt: fedThrough,
                speakerDecision: fallbackDecision
            )
        }

        if pauseReady, let speechEnd = lastSpeechEnd {
            return stageAll(
                kind: .pause,
                through: min(stableThrough, speechEnd),
                detectedAt: speechEnd + Self.vadSilence,
                speakerDecision: fallbackDecision
            )
        }

        if softSemanticReady {
            return stageAll(
                kind: .semantic,
                through: stableThrough,
                detectedAt: fedThrough,
                speakerDecision: fallbackDecision
            )
        }

        guard forcedCheckpointReached else { return nil }
        if let markerCut = forcedMarkerCut(
            checkpoint: start + Self.hardClauseTarget,
            limit: start + Self.hardClauseTarget + stabilityGuardSamples,
            stableThrough: stableThrough
        ) {
            return stage(
                kind: .forced,
                text: markerCut.text,
                consumedCharacters: markerCut.consumedCharacters,
                through: markerCut.sample,
                detectedAt: fedThrough,
                speakerDecision: fallbackDecision
            )
        }

        guard stableDuration >= Self.hardClauseTarget + stabilityGuardSamples else { return nil }
        return stageAll(
            kind: .forced,
            // Without a trustworthy marker there is no safe text offset.
            // Preserve the old lossless fallback by associating all staged
            // text with all currently stable PCM (at most one transport block
            // beyond the checkpoint in the production loop).
            through: stableThrough,
            detectedAt: fedThrough,
            speakerDecision: fallbackDecision,
            degradation: .degradedForcedBoundary
        )
    }

    /// Stages the last emitted source when capture really ends. This is the
    /// only tail path; ordinary clause boundaries never close the ASR session.
    mutating func finish(
        delta: String = "",
        fedThrough proposedFedThrough: Int
    ) -> VoxtralClauseBoundary? {
        fedThrough = max(fedThrough, proposedFedThrough)
        pendingSourceText.append(delta)
        if delta.contains(where: { !$0.isWhitespace }) {
            lastSourceUpdateThrough = max(
                lastSourceUpdateThrough ?? 0,
                proposedFedThrough
            )
        }
        return stageAll(
            kind: .finish,
            through: fedThrough,
            detectedAt: fedThrough
        )
    }

    /// Validation is FIFO: a later English result cannot release PCM past an
    /// earlier failed translation.
    @discardableResult
    mutating func validate(generation expectedGeneration: Int) -> Bool {
        guard let first = awaitingValidation.first,
              first.generation == expectedGeneration else { return false }
        awaitingValidation.removeFirst()
        englishValidatedThrough = first.sampleRange.upperBound
        sourceValidatedCharacterCount = first.sourceCharacterRange.upperBound
        return true
    }

    /// Lets the translation pipeline acknowledge the oldest staged clause
    /// using the same absolute PCM cursor carried by its final job.
    @discardableResult
    mutating func validate(through sample: Int) -> Bool {
        guard let first = awaitingValidation.first,
              first.sampleRange.upperBound == sample else { return false }
        return validate(generation: first.generation)
    }

    private mutating func observeSpeech(_ ranges: [SpeechSampleRange]) {
        for range in ranges where range.end > sourceStagedThrough {
            let start = max(sourceStagedThrough, range.start)
            clauseSpeechStart = min(clauseSpeechStart ?? start, start)
            lastSpeechEnd = max(lastSpeechEnd ?? range.end, range.end)
        }
    }

    private func semanticPrefix() -> (text: String, consumedCharacters: Int)? {
        guard let punctuation = pendingSourceText.lastIndex(where: {
            Self.terminalPunctuation.contains($0)
        }) else { return nil }

        let end = pendingSourceText.index(after: punctuation)
        let prefix = String(pendingSourceText[..<end])
        let suffix = pendingSourceText[end...]
        let leadingWhitespace = suffix.prefix(while: { $0.isWhitespace }).count
        let consumedCharacters = prefix.count + leadingWhitespace
        let text = normalized(String(pendingSourceText.prefix(consumedCharacters)))
        guard Self.isMeaningful(text) else { return nil }
        return (text, consumedCharacters)
    }

    private mutating func ingest(
        emissionMarkers newMarkers: [VoxtralEmissionMarker],
        speakerTransitions newTransitions: [LocalSpeakerTransition]
    ) {
        guard !speakerEvidenceDiscarded,
              markerCalibration?.permitsSpeakerBoundaries == true else { return }
        for marker in newMarkers where marker.isUsable && !emissionMarkers.contains(marker) {
            emissionMarkers.append(marker)
        }
        emissionMarkers.sort {
            ($0.proxyEndSample, $0.generatedIndex)
                < ($1.proxyEndSample, $1.generatedIndex)
        }

        for transition in newTransitions where !speakerTransitions.contains(transition) {
            speakerTransitions.append(transition)
        }
        speakerTransitions.sort {
            ($0.changeSample, $0.confirmedAtSample)
                < ($1.changeSample, $1.confirmedAtSample)
        }
        pruneSpeakerEvidence()
    }

    private mutating func speakerPrefix(
        stableThrough: Int
    ) -> (
        transition: LocalSpeakerTransition,
        text: String,
        consumedCharacters: Int
    )? {
        guard !speakerEvidenceDiscarded,
              let markerCalibration,
              markerCalibration.permitsSpeakerBoundaries else { return nil }
        pruneSpeakerEvidence()
        guard let transition = speakerTransitions.first,
              transition.changeSample <= stableThrough else { return nil }

        // [STREAMING_WORD] precedes its lexical group. The first group ending
        // after the turn change therefore gives the safe UTF-8 cut before B.
        guard let marker = emissionMarkers.first(where: {
            markerCalibration.calibratedEndSample(for: $0)
                >= transition.changeSample - Self.speakerMarkerEarlyTolerance
                && $0.groupTextStartUTF8 > sourceStagedUTF8Count
        }) else { return nil }

        let localUTF8Offset = marker.groupTextStartUTF8 - sourceStagedUTF8Count
        guard localUTF8Offset <= pendingSourceText.utf8.count else { return nil }
        let utf8Index = pendingSourceText.utf8.index(
            pendingSourceText.utf8.startIndex,
            offsetBy: localUTF8Offset
        )
        guard let textIndex = String.Index(utf8Index, within: pendingSourceText) else {
            return nil
        }
        let rawPrefix = String(pendingSourceText[..<textIndex])
        let rawSuffix = String(pendingSourceText[textIndex...])
        let text = normalized(rawPrefix)
        guard Self.isMeaningful(text), Self.isMeaningful(rawSuffix) else { return nil }
        return (transition, text, rawPrefix.count)
    }

    private mutating func stageAll(
        kind: VoxtralClauseBoundary.Kind,
        through sample: Int,
        detectedAt: Int,
        speakerDecision: VoxtralClauseBoundary.SpeakerDecision? = nil,
        degradation: VoxtralClauseBoundary.Degradation? = nil
    ) -> VoxtralClauseBoundary? {
        stage(
            kind: kind,
            text: normalized(pendingSourceText),
            consumedCharacters: pendingSourceText.count,
            through: sample,
            detectedAt: detectedAt,
            speakerDecision: speakerDecision,
            degradation: degradation
        )
    }

    private mutating func stage(
        kind: VoxtralClauseBoundary.Kind,
        text: String,
        consumedCharacters: Int,
        through sample: Int,
        detectedAt: Int,
        speakerDecision: VoxtralClauseBoundary.SpeakerDecision? = nil,
        degradation: VoxtralClauseBoundary.Degradation? = nil
    ) -> VoxtralClauseBoundary? {
        guard Self.isMeaningful(text),
              consumedCharacters > 0,
              sample > sourceStagedThrough else { return nil }

        let boundary = VoxtralClauseBoundary(
            generation: generation,
            kind: kind,
            sourceText: text,
            sourceCharacterRange: sourceStagedCharacterCount..<(sourceStagedCharacterCount + consumedCharacters),
            sampleRange: sourceStagedThrough..<sample,
            endpointDetectedAt: detectedAt,
            stagedAt: fedThrough,
            speakerDecision: speakerDecision,
            degradation: degradation
        )

        let consumedRawText = String(pendingSourceText.prefix(consumedCharacters))
        pendingSourceText.removeFirst(consumedCharacters)
        sourceStagedUTF8Count += consumedRawText.utf8.count
        if !Self.isMeaningful(pendingSourceText) {
            lastSourceUpdateThrough = nil
        }
        sourceStagedCharacterCount = boundary.sourceCharacterRange.upperBound
        sourceStagedThrough = boundary.sampleRange.upperBound
        generation += 1
        awaitingValidation.append(boundary)
        pendingSpeakerDecision = nil
        switch speakerDecision {
        case .diarizationLagFallback(let transition), .markerTimedOut(let transition):
            speakerTransitions.removeAll { $0 == transition }
        case .applied, nil:
            break
        }

        if let speechEnd = lastSpeechEnd, speechEnd > sourceStagedThrough {
            clauseSpeechStart = sourceStagedThrough
        } else {
            clauseSpeechStart = nil
            lastSpeechEnd = nil
        }
        if Self.isMeaningful(pendingSourceText), clauseSpeechStart == nil {
            clauseSpeechStart = sourceStagedThrough
        }
        pruneSpeakerEvidence()
        return boundary
    }

    private mutating func pruneSpeakerEvidence() {
        emissionMarkers.removeAll {
            // Keep the marker at the new text origin: its acoustic end anchors
            // the first un-staged group for the next marker pair.
            $0.groupTextStartUTF8 < sourceStagedUTF8Count
                || (markerCalibration?.calibratedEndSample(for: $0)
                    ?? $0.proxyEndSample) <= sourceStagedThrough
        }
        speakerTransitions.removeAll { $0.changeSample <= sourceStagedThrough }
    }

    /// Marker i is the acoustic end of group i; marker i+1 is the UTF-8 start
    /// of the following group. Both are required for a lossless text/PCM cut.
    private func forcedMarkerCut(
        checkpoint: Int,
        limit: Int,
        stableThrough: Int
    ) -> (text: String, consumedCharacters: Int, sample: Int)? {
        guard let markerCalibration,
              markerCalibration.permitsSpeakerBoundaries,
              emissionMarkers.count >= 2 else { return nil }

        for index in 0..<(emissionMarkers.count - 1) {
            let current = emissionMarkers[index]
            let next = emissionMarkers[index + 1]
            let sample = markerCalibration.calibratedEndSample(for: current)
            guard sample >= checkpoint,
                  sample <= limit,
                  sample <= stableThrough,
                  next.groupTextStartUTF8 > current.groupTextStartUTF8,
                  next.groupTextStartUTF8 > sourceStagedUTF8Count else { continue }

            let localUTF8Offset = next.groupTextStartUTF8 - sourceStagedUTF8Count
            guard localUTF8Offset <= pendingSourceText.utf8.count else { continue }
            let utf8Index = pendingSourceText.utf8.index(
                pendingSourceText.utf8.startIndex,
                offsetBy: localUTF8Offset
            )
            guard let textIndex = String.Index(utf8Index, within: pendingSourceText) else {
                continue
            }
            let rawPrefix = String(pendingSourceText[..<textIndex])
            let text = normalized(rawPrefix)
            guard Self.isMeaningful(text) else { continue }
            return (text, rawPrefix.count, sample)
        }
        return nil
    }

    private mutating func expireSpeakerTransitionIfNeeded() -> LocalSpeakerTransition? {
        guard let transition = speakerTransitions.first,
              fedThrough >= transition.confirmedAtSample + Self.speakerMarkerWait else {
            return nil
        }
        speakerTransitions.removeFirst()
        return transition
    }

    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters)
            .joined()
            .precomposedStringWithCanonicalMapping
    }

    private func hasConservativeJapaneseEnding(_ text: String) -> Bool {
        let text = normalized(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.conservativeJapaneseEndings.contains(where: text.hasSuffix)
    }

    private static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { meaningfulCharacters.contains($0) }
    }
}
