import CryptoKit
import Foundation

enum HighQualityDeliverable: String, Codable, CaseIterable, Hashable, Sendable {
    case japaneseTranscript = "japanese-transcript"
    case englishTranslationTranscript = "english-translation-transcript"
    case englishSubtitles = "english-subtitles"
}

enum HighQualityASRBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwenJA = "qwen-ja"
    case parakeetJA = "parakeet-ja"
    case whisperKit = "whisperkit"
    case funASRNanoInt8 = "funasr-nano-int8"
    case reazonSpeechK2V2 = "reazonspeech-k2-v2-int8"

    static let productDefault: Self = .qwenJA
    // Experiment-only backends stay out of every product picker.
    static let allCases: [Self] = [.qwenJA, .parakeetJA, .whisperKit]

    var id: Self { self }

    var displayName: String {
        switch self {
        case .qwenJA: "Qwen JA"
        case .parakeetJA: "Parakeet JA"
        case .whisperKit: "WhisperKit large-v3"
        case .funASRNanoInt8: "Fun-ASR Nano int8"
        case .reazonSpeechK2V2: "ReazonSpeech K2 v2 int8"
        }
    }

    var model: HighQualityModelEvidence {
        switch self {
        case .qwenJA:
            .init(
                backend: self,
                modelID: LocalPrototypeModelID.qwen,
                revision: LocalPrototypeModelID.qwenRevision
            )
        case .parakeetJA:
            .init(
                backend: self,
                modelID: LocalPrototypeModelID.parakeet,
                revision: LocalPrototypeModelID.parakeetRevision
            )
        case .whisperKit:
            .init(
                backend: self,
                modelID: LocalPrototypeModelID.whisperKitEvidenceModelID,
                revision: LocalPrototypeModelID.whisperKitModelRevision,
                runtimeVersion: LocalPrototypeModelID.whisperKitRuntimeVersion
            )
        case .funASRNanoInt8:
            .init(
                backend: self,
                modelID: "k2-fsa/sherpa-onnx-funasr-nano-int8-2025-12-30",
                revision: "eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b",
                runtimeVersion: "sherpa-onnx 1.13.5 (3dc7c569f31ca2cd4a20ed6f7db780327e6714c5)"
            )
        case .reazonSpeechK2V2:
            .init(
                backend: self,
                modelID: "reazon-research/reazonspeech-k2-v2",
                revision: "291488c8151be24d7da4bf7af26e533fad96e407",
                runtimeVersion: "sherpa-onnx 1.13.4"
            )
        }
    }

    var declaredPeakMemoryBytes: UInt64 {
        switch self {
        case .qwenJA: 7 * 1_024 * 1_024 * 1_024
        case .parakeetJA: 4 * 1_024 * 1_024 * 1_024
        case .whisperKit: 8 * 1_024 * 1_024 * 1_024
        case .funASRNanoInt8: 4 * 1_024 * 1_024 * 1_024
        case .reazonSpeechK2V2: 2 * 1_024 * 1_024 * 1_024
        }
    }
}

enum HighQualityTranslator: String, Codable, CaseIterable, Identifiable, Sendable {
    case translateGemma12B = "translategemma-12b-it-4bit"
    case translateGemma4B = "translategemma-4b-it-4bit"

    static let productDefault: Self = .translateGemma12B

    var id: Self { self }

    var displayName: String {
        switch self {
        case .translateGemma12B: "TranslateGemma 12B"
        case .translateGemma4B: "TranslateGemma 4B (Bêta)"
        }
    }

    var detail: String {
        switch self {
        case .translateGemma12B:
            "Meilleure qualité — plus lent et plus gourmand en mémoire"
        case .translateGemma4B:
            "Bêta — plus rapide et léger, qualité en cours de comparaison"
        }
    }

    var candidate: LocalMLXTranslator.Candidate {
        switch self {
        case .translateGemma12B: .translateGemma12B
        case .translateGemma4B: .translateGemma4B
        }
    }

    var model: HighQualityTranslationModelEvidence {
        .init(
            translator: self,
            modelID: candidate.modelID,
            revision: candidate.revision,
            runtimeVersion: LocalMLXTranslator.runtimeVersion,
            weightSHA256: candidate.weightSHA256
        )
    }
}

struct HighQualityTranslationModelEvidence: Codable, Equatable, Sendable {
    let translator: HighQualityTranslator
    let modelID: String
    let revision: String
    let runtimeVersion: String
    let weightSHA256: [String]
}

enum HighQualityJobDependency: String, Codable, Sendable {
    case sourceAcquisition = "source-acquisition"
    case sourceNormalization = "source-normalization"
    case japaneseASR = "japanese-asr"
    case forcedAlignment = "forced-alignment"
    case speakerDiarization = "speaker-diarization"
    case llmTranslation = "llm-translation"
    case export
}

enum HighQualityJobStage: String, Codable, Sendable {
    case validating
    case acquiringSource = "acquiring-source"
    case normalizingSource = "normalizing-source"
    case preparingASR = "preparing-asr"
    case transcribing
    case preparingAlignment = "preparing-alignment"
    case aligning
    case preparingDiarization = "preparing-diarization"
    case diarizing
    case translating
    case exporting
    case completed
    case cancelled
    case failed
}

enum HighQualityJobFailureStage: String, Codable, Sendable {
    case acquisition
    case source
    case application
    case modelPreparation = "model-preparation"
    case asr
    case alignment
    case diarization
    case translation
    case export
    case cancelled
}

struct HighQualityJobProgress: Equatable, Sendable {
    let stage: HighQualityJobStage
    let fraction: Double
    let message: String

    static func terminal(for error: Error) -> Self {
        let cancelled = (error as? HighQualityJobError)?.stage == .cancelled
            || error is CancellationError
        return .init(
            stage: cancelled ? .cancelled : .failed,
            fraction: 1,
            message: error.localizedDescription
        )
    }

    static func accepts(_ operationID: UUID, while activeOperationID: UUID?) -> Bool {
        operationID == activeOperationID
    }
}

struct HighQualitySpeakerCountPolicy: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        case automatic
        case expected
    }

    static let validExpectedCounts = 1...20
    static let automatic = Self(mode: .automatic, expectedCount: nil)

    let mode: Mode
    let expectedCount: Int?

    static func expected(_ count: Int) -> Self {
        Self(mode: .expected, expectedCount: count)
    }

    var isValid: Bool {
        switch mode {
        case .automatic: expectedCount == nil
        case .expected: expectedCount.map(Self.validExpectedCounts.contains) == true
        }
    }
}

struct HighQualitySpeakerConfiguration: Codable, Equatable, Sendable {
    static let standard = Self(
        enhancedPrecision: false,
        sensitiveDetection: false,
        countPolicy: .automatic
    )
    static let sensitiveClusteringThreshold: Float = 0.55

    let enhancedPrecision: Bool
    let sensitiveDetection: Bool
    let countPolicy: HighQualitySpeakerCountPolicy

    var isValid: Bool { countPolicy.isValid }
}

struct HighQualityJobRequest: Sendable {
    let id: UUID
    let sourceURL: URL
    let deliverables: Set<HighQualityDeliverable>
    let asrMode: HighQualityASRMode
    let translator: HighQualityTranslator
    let speakerLabels: Bool
    let readableSubtitles: Bool
    let useExclusiveReconciliation: Bool
    let speakerConfiguration: HighQualitySpeakerConfiguration
    var speakerCountPolicy: HighQualitySpeakerCountPolicy { speakerConfiguration.countPolicy }
    let speakerLabelsByCueID: [String: String]
    let translationContextPolicy: HighQualityConversationContextPolicy
    let translationContextResetReasonsByCueID: [String: HighQualityConversationContextResetReason]
    let project: HighQualityProject?
    let adaptiveScopedTerms: Set<String>
    let adaptiveCalibration: HighQualityAdaptiveASRCalibration
    let outputRoot: URL

    var backend: HighQualityASRBackend { asrMode.primaryBackend }

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        deliverables: Set<HighQualityDeliverable>,
        backend: HighQualityASRBackend,
        translator: HighQualityTranslator = .productDefault,
        speakerLabels: Bool = false,
        readableSubtitles: Bool = false,
        useExclusiveReconciliation: Bool = false,
        speakerConfiguration: HighQualitySpeakerConfiguration = .standard,
        speakerLabelsByCueID: [String: String] = [:],
        translationContextPolicy: HighQualityConversationContextPolicy = .none,
        translationContextResetReasonsByCueID: [
            String: HighQualityConversationContextResetReason
        ] = [:],
        project: HighQualityProject? = nil,
        outputRoot: URL = AppStoragePaths.highQualityJobs
    ) {
        self.init(
            id: id,
            sourceURL: sourceURL,
            deliverables: deliverables,
            asrMode: .backend(backend),
            translator: translator,
            speakerLabels: speakerLabels,
            readableSubtitles: readableSubtitles,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerConfiguration: speakerConfiguration,
            speakerLabelsByCueID: speakerLabelsByCueID,
            translationContextPolicy: translationContextPolicy,
            translationContextResetReasonsByCueID: translationContextResetReasonsByCueID,
            project: project,
            outputRoot: outputRoot
        )
    }

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        deliverables: Set<HighQualityDeliverable>,
        asrMode: HighQualityASRMode,
        translator: HighQualityTranslator = .productDefault,
        speakerLabels: Bool = false,
        readableSubtitles: Bool = false,
        useExclusiveReconciliation: Bool = false,
        speakerConfiguration: HighQualitySpeakerConfiguration = .standard,
        speakerLabelsByCueID: [String: String] = [:],
        translationContextPolicy: HighQualityConversationContextPolicy = .none,
        translationContextResetReasonsByCueID: [
            String: HighQualityConversationContextResetReason
        ] = [:],
        adaptiveScopedTerms: Set<String> = [],
        adaptiveCalibration: HighQualityAdaptiveASRCalibration = .developmentV1,
        project: HighQualityProject? = nil,
        outputRoot: URL = AppStoragePaths.highQualityJobs
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.deliverables = deliverables
        self.asrMode = asrMode
        self.translator = translator
        self.speakerLabels = speakerLabels
        self.readableSubtitles = readableSubtitles
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerConfiguration = speakerConfiguration
        self.speakerLabelsByCueID = speakerLabelsByCueID
        self.translationContextPolicy = translationContextPolicy
        self.translationContextResetReasonsByCueID = translationContextResetReasonsByCueID
        self.project = project
        self.adaptiveScopedTerms = adaptiveScopedTerms
        self.adaptiveCalibration = adaptiveCalibration
        self.outputRoot = project?.jobsDirectory ?? outputRoot
    }
}

struct HighQualityJobFailure: Codable, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
}

struct HighQualitySourceProvenance: Codable, Equatable, Sendable {
    let path: String
    let fileName: String
    let byteCount: UInt64?
    let modifiedAt: Date?
    let sourceURL: String?
    let youtube: HighQualityYouTubeEvidence?
}

struct HighQualityYouTubeEvidence: Codable, Equatable, Sendable {
    let sourceURL: String
    let title: String
    let channel: String
    let description: String
    let ytDLPVersion: String
    let diagnostics: String
}

struct HighQualityYouTubeAcquisition: Sendable {
    let audioURL: URL
    let evidence: HighQualityYouTubeEvidence
}

struct HighQualityASRChunk: Codable, Equatable, Sendable {
    let index: Int
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let transcript: String
}

struct HighQualityASRCharacter: Codable, Equatable, Sendable {
    let chunkIndex: Int
    let text: String
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
}

struct HighQualityASRTimingEvidence: Codable, Equatable, Sendable {
    let text: String
    let tokenIDs: [Int]
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let confidence: Double?
}

struct HighQualityASRSegmentEvidence: Codable, Equatable, Sendable {
    let index: Int
    let text: String
    let tokenIDs: [Int]
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let averageLogProbability: Double?
    let noSpeechProbability: Double?
    let compressionRatio: Double?
}

struct HighQualityASRDiagnostics: Codable, Equatable, Sendable {
    let emptyOutput: Bool?

    init(emptyOutput: Bool? = nil) {
        self.emptyOutput = emptyOutput
    }
}

struct HighQualityASRWindowEvidence: Codable, Equatable, Sendable {
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let result: HighQualityASRExchange
}

struct HighQualityASRExchange: Codable, Equatable, Sendable {
    let rawTranscript: String
    let chunks: [HighQualityASRChunk]
    let characters: [HighQualityASRCharacter]?
    var model: HighQualityModelEvidence?
    let segments: [HighQualityASRSegmentEvidence]?
    let tokenTimings: [HighQualityASRTimingEvidence]?
    let wordTimings: [HighQualityASRTimingEvidence]?
    let confidence: Double?
    let averageLogProbability: Double?
    let diagnostics: HighQualityASRDiagnostics?
    let windows: [HighQualityASRWindowEvidence]?

    init(
        rawTranscript: String,
        chunks: [HighQualityASRChunk],
        characters: [HighQualityASRCharacter]? = nil,
        model: HighQualityModelEvidence? = nil,
        segments: [HighQualityASRSegmentEvidence]? = nil,
        tokenTimings: [HighQualityASRTimingEvidence]? = nil,
        wordTimings: [HighQualityASRTimingEvidence]? = nil,
        confidence: Double? = nil,
        averageLogProbability: Double? = nil,
        diagnostics: HighQualityASRDiagnostics? = nil,
        windows: [HighQualityASRWindowEvidence]? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.chunks = chunks
        self.characters = characters
        self.model = model
        self.segments = segments
        self.tokenTimings = tokenTimings
        self.wordTimings = wordTimings
        self.confidence = confidence
        self.averageLogProbability = averageLogProbability
        self.diagnostics = diagnostics
        self.windows = windows
    }
}

struct HighQualityTranslationTurn: Codable, Equatable, Sendable {
    let id: String
    let japanese: String
    let precedingJapanese: [String]
    let followingJapanese: [String]
    let speakerLabel: String?
    let sourceStart: TimeInterval?
    let sourceEnd: TimeInterval?

    init(
        id: String,
        japanese: String,
        precedingJapanese: [String],
        followingJapanese: [String],
        speakerLabel: String?,
        sourceStart: TimeInterval? = nil,
        sourceEnd: TimeInterval? = nil
    ) {
        self.id = id
        self.japanese = japanese
        self.precedingJapanese = precedingJapanese
        self.followingJapanese = followingJapanese
        self.speakerLabel = speakerLabel
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

struct HighQualityTranslationBatch: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let turns: [HighQualityTranslationTurn]
    let glossary: [HighQualityGlossaryPromptTerm]
    let glossaryByCueID: [String: [HighQualityGlossaryPromptTerm]]
    let conversationContextByCueID: [String: HighQualityConversationContextEvidence]
    let retryReasonCodes: [String: [HighQualityTranslationIntegrityReasonCode]]?

    init(
        source: HighQualitySourceProvenance,
        turns: [HighQualityTranslationTurn],
        glossary: [HighQualityGlossaryPromptTerm],
        glossaryByCueID: [String: [HighQualityGlossaryPromptTerm]]? = nil,
        conversationContextByCueID: [String: HighQualityConversationContextEvidence] = [:],
        retryReasonCodes: [String: [HighQualityTranslationIntegrityReasonCode]]? = nil
    ) {
        self.source = source
        self.turns = turns
        self.glossary = glossary
        self.glossaryByCueID = glossaryByCueID ?? Self.cueLocalGlossary(
            turns: turns,
            glossary: glossary
        )
        self.conversationContextByCueID = conversationContextByCueID
        self.retryReasonCodes = retryReasonCodes
    }

    private enum CodingKeys: String, CodingKey {
        case source, turns, glossary, glossaryByCueID, conversationContextByCueID
        case retryReasonCodes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(HighQualitySourceProvenance.self, forKey: .source)
        turns = try values.decode([HighQualityTranslationTurn].self, forKey: .turns)
        glossary = try values.decode([HighQualityGlossaryPromptTerm].self, forKey: .glossary)
        glossaryByCueID = try values.decodeIfPresent(
            [String: [HighQualityGlossaryPromptTerm]].self,
            forKey: .glossaryByCueID
        ) ?? Self.cueLocalGlossary(turns: turns, glossary: glossary)
        conversationContextByCueID = try values.decodeIfPresent(
            [String: HighQualityConversationContextEvidence].self,
            forKey: .conversationContextByCueID
        ) ?? [:]
        retryReasonCodes = try values.decodeIfPresent(
            [String: [HighQualityTranslationIntegrityReasonCode]].self,
            forKey: .retryReasonCodes
        )
    }

    func glossary(for turn: HighQualityTranslationTurn) -> [HighQualityGlossaryPromptTerm] {
        glossaryByCueID[turn.id] ?? []
    }

    func context(for turn: HighQualityTranslationTurn) -> HighQualityConversationContextEvidence? {
        conversationContextByCueID[turn.id]
    }

    private static func cueLocalGlossary(
        turns: [HighQualityTranslationTurn],
        glossary: [HighQualityGlossaryPromptTerm]
    ) -> [String: [HighQualityGlossaryPromptTerm]] {
        Dictionary(uniqueKeysWithValues: turns.map { turn in
            (turn.id, glossary.filter { term in
                HighQualityGlossarySelector.matchedForm(
                    in: turn.japanese,
                    forms: term.japanese
                ) != nil
            })
        })
    }
}

struct HighQualityTranslationAttempt: Codable, Equatable, Sendable {
    let number: Int
    let duration: TimeInterval
    let outcome: String
}

struct HighQualityTranslationExchange: Codable, Equatable, Sendable {
    let model: String
    let response: String
    let attempts: [HighQualityTranslationAttempt]
    let revision: String?
    let runtimeVersion: String?
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64

    init(
        model: String,
        response: String,
        attempts: [HighQualityTranslationAttempt],
        revision: String? = nil,
        runtimeVersion: String? = nil,
        batches: [HighQualityLocalTranslationBatch] = [],
        peakMemoryBytes: UInt64 = 0
    ) {
        self.model = model
        self.response = response
        self.attempts = attempts
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
    }
}

struct HighQualityLocalTranslationBatch: Codable, Equatable, Sendable {
    let cueIDs: [String]
    let sanitizedPrompt: String
    let nativePrompt: String?
    let nativeOutput: String?
    let model: String?
    let revision: String?
    let sanitizedOutput: String
    let inputTokens: Int
    let outputTokens: Int?
    let finishReason: String?
    let duration: TimeInterval?
    let attemptNumber: Int?
    let validationReasonCodes: [HighQualityTranslationIntegrityReasonCode]?
    let selected: Bool?
    let terminalOutcome: String?
    let context: HighQualityConversationContextEvidence?

    init(
        cueIDs: [String],
        sanitizedPrompt: String,
        nativePrompt: String? = nil,
        nativeOutput: String? = nil,
        model: String? = nil,
        revision: String? = nil,
        sanitizedOutput: String,
        inputTokens: Int,
        outputTokens: Int? = nil,
        finishReason: String? = nil,
        duration: TimeInterval? = nil,
        attemptNumber: Int? = nil,
        validationReasonCodes: [HighQualityTranslationIntegrityReasonCode]? = nil,
        selected: Bool? = nil,
        terminalOutcome: String? = nil,
        context: HighQualityConversationContextEvidence? = nil
    ) {
        self.cueIDs = cueIDs
        self.sanitizedPrompt = sanitizedPrompt
        self.nativePrompt = nativePrompt
        self.nativeOutput = nativeOutput
        self.model = model
        self.revision = revision
        self.sanitizedOutput = sanitizedOutput
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.duration = duration
        self.attemptNumber = attemptNumber
        self.validationReasonCodes = validationReasonCodes
        self.selected = selected
        self.terminalOutcome = terminalOutcome
        self.context = context
    }
}

struct HighQualityTranslationServiceError: Codable, LocalizedError, Sendable {
    let model: String
    let attempts: [HighQualityTranslationAttempt]
    let response: String?
    let revision: String?
    let runtimeVersion: String?
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64
    let message: String

    init(
        model: String,
        attempts: [HighQualityTranslationAttempt],
        response: String?,
        revision: String? = nil,
        runtimeVersion: String? = nil,
        batches: [HighQualityLocalTranslationBatch] = [],
        peakMemoryBytes: UInt64 = 0,
        message: String
    ) {
        self.model = model
        self.attempts = attempts
        self.response = response
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct HighQualityTranslationValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct HighQualitySemanticUnitDraft {
    var fragments: [HighQualitySemanticFragmentEvidence]
    var decisions: [String]

    var japanese: String { fragments.map(\.text).joined() }
}

struct HighQualityTranslationEvidence: Codable, Equatable, Sendable {
    let request: HighQualityTranslationBatch
    let response: String?
    let model: String
    let attempts: [HighQualityTranslationAttempt]
    let revision: String?
    let runtimeVersion: String?
    let weightSHA256: [String]
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64
    var validationFailures: [String]
    var integrityVerdicts: [HighQualityTranslationIntegrityVerdict]
    var worker: HighQualityTranslationWorkerEvidence?

    private enum CodingKeys: String, CodingKey {
        case request, response, model, attempts, revision, runtimeVersion, weightSHA256, batches
        case peakMemoryBytes, validationFailures, integrityVerdicts, worker
    }

    init(
        request: HighQualityTranslationBatch,
        response: String?,
        model: String,
        attempts: [HighQualityTranslationAttempt],
        revision: String?,
        runtimeVersion: String?,
        weightSHA256: [String] = [],
        batches: [HighQualityLocalTranslationBatch],
        peakMemoryBytes: UInt64,
        validationFailures: [String],
        integrityVerdicts: [HighQualityTranslationIntegrityVerdict] = [],
        worker: HighQualityTranslationWorkerEvidence? = nil
    ) {
        self.request = request
        self.response = response
        self.model = model
        self.attempts = attempts
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.weightSHA256 = weightSHA256
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
        self.validationFailures = validationFailures
        self.integrityVerdicts = integrityVerdicts
        self.worker = worker
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        request = try values.decode(HighQualityTranslationBatch.self, forKey: .request)
        response = try values.decodeIfPresent(String.self, forKey: .response)
        model = try values.decode(String.self, forKey: .model)
        attempts = try values.decode([HighQualityTranslationAttempt].self, forKey: .attempts)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        runtimeVersion = try values.decodeIfPresent(String.self, forKey: .runtimeVersion)
        weightSHA256 = try values.decodeIfPresent([String].self, forKey: .weightSHA256) ?? []
        batches = try values.decodeIfPresent(
            [HighQualityLocalTranslationBatch].self,
            forKey: .batches
        ) ?? []
        peakMemoryBytes = try values.decodeIfPresent(
            UInt64.self,
            forKey: .peakMemoryBytes
        ) ?? 0
        validationFailures = try values.decode(
            [String].self,
            forKey: .validationFailures
        )
        integrityVerdicts = try values.decodeIfPresent(
            [HighQualityTranslationIntegrityVerdict].self,
            forKey: .integrityVerdicts
        ) ?? []
        worker = try values.decodeIfPresent(
            HighQualityTranslationWorkerEvidence.self,
            forKey: .worker
        )
    }
}

struct HighQualityAlignedCue: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let timingOrigin: String?
    let timingPolicy: String?
    let timingQuality: String?

    init(
        id: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        timingOrigin: String? = nil,
        timingPolicy: String? = nil,
        timingQuality: String? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.timingOrigin = timingOrigin
        self.timingPolicy = timingPolicy
        self.timingQuality = timingQuality
    }
}

struct HighQualityAlignmentItem: Codable, Equatable, Sendable {
    let cueID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualityAlignmentFallbackMerge: Codable, Equatable, Sendable {
    let chunkIndex: Int
    let sourceCueID: String
    let targetCueID: String
    let direction: String
    let sourceText: String
    let targetOriginalText: String
    let mergedText: String
    let sourceOriginalStart: TimeInterval
    let sourceOriginalEnd: TimeInterval
    let targetOriginalStart: TimeInterval
    let targetOriginalEnd: TimeInterval
    let finalStart: TimeInterval
    let finalEnd: TimeInterval
    let freeGapEnd: TimeInterval
    let timingPolicy: String
}

struct HighQualityAlignmentChunk: Codable, Equatable, Sendable {
    let index: Int
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let cues: [HighQualityAlignedCue]
    let rawItems: [HighQualityAlignmentItem]

    init(
        index: Int,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        cues: [HighQualityAlignedCue],
        rawItems: [HighQualityAlignmentItem] = []
    ) {
        self.index = index
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.cues = cues
        self.rawItems = rawItems
    }
}

struct HighQualitySemanticUnitPolicyEvidence: Codable, Equatable, Sendable {
    let version: String
    let pauseSeconds: TimeInterval
    let maximumCharacters: Int
    let shortFragmentCharacters: Int
}

struct HighQualitySemanticFragmentEvidence: Codable, Equatable, Sendable {
    let index: Int
    let alignmentItemIndex: Int?
    let sourceCueID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualitySemanticUnitEvidence: Codable, Equatable, Sendable {
    let id: String
    let japanese: String
    let sourceFragmentIndices: [Int]
    let sourceCueIDs: [String]
    let start: TimeInterval
    let end: TimeInterval
    let decisions: [String]
    var speakerLabel: String?
    var speakerMappingIndices: [Int]
}

struct HighQualitySpeakerAttachmentEvidence: Codable, Equatable, Sendable {
    let semanticUnits: [HighQualitySemanticUnitEvidence]
}

struct HighQualityAlignmentExchange: Codable, Equatable, Sendable {
    let chunks: [HighQualityAlignmentChunk]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
    let configuration: [String: String]?
    let fallbackMerges: [HighQualityAlignmentFallbackMerge]?

    init(
        chunks: [HighQualityAlignmentChunk],
        modelID: String,
        revision: String,
        peakMemoryBytes: UInt64,
        configuration: [String: String]? = nil,
        fallbackMerges: [HighQualityAlignmentFallbackMerge]? = nil
    ) {
        self.chunks = chunks
        self.modelID = modelID
        self.revision = revision
        self.peakMemoryBytes = peakMemoryBytes
        self.configuration = configuration
        self.fallbackMerges = fallbackMerges
    }
}

struct HighQualityAlignmentEvidence: Codable, Equatable, Sendable {
    let modelID: String
    let revision: String
    let chunks: [HighQualityAlignmentChunk]
    let mergedCues: [HighQualityAlignedCue]
    let sourceDuration: TimeInterval
    let peakMemoryBytes: UInt64
    var validationDiagnostics: [String]
    var semanticUnitPolicy: HighQualitySemanticUnitPolicyEvidence? = nil
    var semanticFragments: [HighQualitySemanticFragmentEvidence]? = nil
    var semanticUnits: [HighQualitySemanticUnitEvidence]? = nil
    var configuration: [String: String]? = nil
    var worker: HighQualityWorkerEvidence? = nil
    var fallbackMerges: [HighQualityAlignmentFallbackMerge]? = nil
}

struct HighQualityDiarizationSpan: Codable, Equatable, Sendable {
    let speakerID: Int
    let start: TimeInterval
    let end: TimeInterval
}

private func highQualitySpeakerLabelsByID(
    _ spans: [HighQualityDiarizationSpan]
) -> [Int: String] {
    Dictionary(uniqueKeysWithValues: Set(spans.map(\.speakerID)).sorted()
        .enumerated().map { ($0.element, String(format: "SPEAKER_%02d", $0.offset)) })
}

struct HighQualityDiarizationExchange: Codable, Equatable, Sendable {
    let spans: [HighQualityDiarizationSpan]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
    let useExclusiveReconciliation: Bool
    let speakerCountPolicy: HighQualitySpeakerCountPolicy
    let configuration: [String: String]?
    let speakerCentroids: [Int: [Float]]?

    init(
        spans: [HighQualityDiarizationSpan],
        modelID: String,
        revision: String,
        peakMemoryBytes: UInt64,
        useExclusiveReconciliation: Bool = false,
        speakerCountPolicy: HighQualitySpeakerCountPolicy = .automatic,
        configuration: [String: String]? = nil,
        speakerCentroids: [Int: [Float]]? = nil
    ) {
        self.spans = spans
        self.modelID = modelID
        self.revision = revision
        self.peakMemoryBytes = peakMemoryBytes
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerCountPolicy = speakerCountPolicy
        self.configuration = configuration
        self.speakerCentroids = speakerCentroids
    }
}

struct HighQualitySpeakerCentroidEvidence: Codable, Equatable, Sendable {
    let speakerLabel: String
    let modelID: String
    let modelRevision: String
    let runtimeRevision: String
    let embeddingVariant: String
    let vectorDimension: Int
    let sourceJobID: UUID
    let vector: [Float]

    private enum CodingKeys: String, CodingKey {
        case speakerLabel = "speakerID"
        case modelID, modelRevision, runtimeRevision, embeddingVariant
        case vectorDimension, sourceJobID, vector
    }
}

enum HighQualitySpeakerCentroidIncompatibilityCause: String, Equatable, Sendable {
    case modelOrRevision
    case embeddingVariant
    case dimension

    var displayName: String {
        switch self {
        case .modelOrRevision: "model or revision"
        case .embeddingVariant: "embedding variant"
        case .dimension: "vector dimension"
        }
    }
}

struct HighQualitySpeakerCentroidSignature: Equatable, Sendable {
    let modelID: String
    let modelRevision: String
    let runtimeRevision: String
    let embeddingVariant: String
    let vectorDimension: Int

    func incompatibilityCauses(
        comparedWith other: Self
    ) -> [HighQualitySpeakerCentroidIncompatibilityCause] {
        var causes: [HighQualitySpeakerCentroidIncompatibilityCause] = []
        if modelID != other.modelID
            || modelRevision != other.modelRevision
            || runtimeRevision != other.runtimeRevision {
            causes.append(.modelOrRevision)
        }
        if embeddingVariant != other.embeddingVariant { causes.append(.embeddingVariant) }
        if vectorDimension != other.vectorDimension { causes.append(.dimension) }
        return causes
    }
}

extension HighQualitySpeakerCentroidEvidence {
    var compatibilitySignature: HighQualitySpeakerCentroidSignature {
        .init(
            modelID: modelID,
            modelRevision: modelRevision,
            runtimeRevision: runtimeRevision,
            embeddingVariant: embeddingVariant,
            vectorDimension: vectorDimension
        )
    }
}

struct HighQualityDuplicateSpeakerSuggestion: Equatable, Sendable {
    static let maximumCosineDistance: Float = 0.3
    static let uncertaintyMargin: Float = 0.1
    static let betaDescription = "Suggestions indicate uncertain acoustic similarity only; "
        + "they do not establish identity or merge speakers automatically."

    let firstSpeakerLabel: String
    let secondSpeakerLabel: String
    let cosineDistance: Float
}

struct HighQualitySpeakerMapping: Codable, Equatable, Sendable {
    let cueID: String
    let alignmentItemIndex: Int
    let spanIndex: Int
    let alignedText: String
    let speakerLabel: String
    let overlapStart: TimeInterval
    let overlapEnd: TimeInterval
    let attributionReason: String?

    init(
        cueID: String,
        alignmentItemIndex: Int,
        spanIndex: Int,
        alignedText: String,
        speakerLabel: String,
        overlapStart: TimeInterval,
        overlapEnd: TimeInterval,
        attributionReason: String? = nil
    ) {
        self.cueID = cueID
        self.alignmentItemIndex = alignmentItemIndex
        self.spanIndex = spanIndex
        self.alignedText = alignedText
        self.speakerLabel = speakerLabel
        self.overlapStart = overlapStart
        self.overlapEnd = overlapEnd
        self.attributionReason = attributionReason
    }
}

struct HighQualityOverlapRange: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabels: [String]
}

struct HighQualityDiarizationEvidence: Codable, Equatable, Sendable {
    let modelID: String
    let revision: String
    let rawSpans: [HighQualityDiarizationSpan]
    let mappings: [HighQualitySpeakerMapping]
    let overlapRanges: [HighQualityOverlapRange]
    let peakMemoryBytes: UInt64
    let useExclusiveReconciliation: Bool?
    let speakerCountPolicy: HighQualitySpeakerCountPolicy?
    let configuration: [String: String]?
    var validationDiagnostics: [String]
    var worker: HighQualityWorkerEvidence?
    var speakerCentroids: [HighQualitySpeakerCentroidEvidence]?

    init(
        modelID: String,
        revision: String,
        rawSpans: [HighQualityDiarizationSpan],
        mappings: [HighQualitySpeakerMapping],
        overlapRanges: [HighQualityOverlapRange],
        peakMemoryBytes: UInt64,
        useExclusiveReconciliation: Bool? = nil,
        speakerCountPolicy: HighQualitySpeakerCountPolicy? = nil,
        configuration: [String: String]? = nil,
        validationDiagnostics: [String],
        worker: HighQualityWorkerEvidence? = nil,
        speakerCentroids: [HighQualitySpeakerCentroidEvidence]? = nil
    ) {
        self.modelID = modelID
        self.revision = revision
        self.rawSpans = rawSpans
        self.mappings = mappings
        self.overlapRanges = overlapRanges
        self.peakMemoryBytes = peakMemoryBytes
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerCountPolicy = speakerCountPolicy
        self.configuration = configuration
        self.validationDiagnostics = validationDiagnostics
        self.worker = worker
        self.speakerCentroids = speakerCentroids
    }
}

struct HighQualitySubtitleCue: Codable, Equatable, Sendable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerLabel: String?
    let speakerName: String?
    let renderedLines: [String]?

    init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerLabel: String? = nil,
        speakerName: String? = nil,
        renderedLines: [String]? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
        self.speakerName = speakerName
        self.renderedLines = renderedLines
    }
}

struct HighQualityTranscriptTurn: Codable, Equatable, Sendable {
    let id: String
    let japanese: String
    let english: String?
    let speakerLabel: String?
    let speakerName: String?
    let start: TimeInterval?
    let end: TimeInterval?

    init(
        id: String,
        japanese: String,
        english: String?,
        speakerLabel: String? = nil,
        speakerName: String? = nil,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.id = id
        self.japanese = japanese
        self.english = english
        self.speakerLabel = speakerLabel
        self.speakerName = speakerName
        self.start = start
        self.end = end
    }
}

struct HighQualitySpeakerEdit: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case rename
        case merge
        case reassign
        case reset
    }

    let kind: Kind
    let speakerLabel: String?
    let targetSpeakerLabel: String?
    let turnID: String?
    let displayName: String?
    let at: Date

    private init(
        kind: Kind,
        speakerLabel: String? = nil,
        targetSpeakerLabel: String? = nil,
        turnID: String? = nil,
        displayName: String? = nil,
        at: Date
    ) {
        self.kind = kind
        self.speakerLabel = speakerLabel
        self.targetSpeakerLabel = targetSpeakerLabel
        self.turnID = turnID
        self.displayName = displayName
        self.at = at
    }

    static func rename(_ speakerLabel: String, to displayName: String, at: Date = Date()) -> Self {
        .init(
            kind: .rename,
            speakerLabel: speakerLabel,
            displayName: displayName,
            at: at
        )
    }

    static func merge(_ speakerLabel: String, into target: String, at: Date = Date()) -> Self {
        .init(
            kind: .merge,
            speakerLabel: speakerLabel,
            targetSpeakerLabel: target,
            at: at
        )
    }

    static func reassign(turnID: String, to speakerLabel: String, at: Date = Date()) -> Self {
        .init(
            kind: .reassign,
            targetSpeakerLabel: speakerLabel,
            turnID: turnID,
            at: at
        )
    }

    static func reset(at: Date = Date()) -> Self {
        .init(kind: .reset, at: at)
    }
}

struct HighQualityModelEvidence: Codable, Equatable, Sendable {
    let backend: HighQualityASRBackend
    let modelID: String
    let revision: String
    let runtimeVersion: String?
    let weightSHA256: [String: String]?

    init(
        backend: HighQualityASRBackend,
        modelID: String,
        revision: String,
        runtimeVersion: String? = nil,
        weightSHA256: [String: String]? = nil
    ) {
        self.backend = backend
        self.modelID = modelID
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.weightSHA256 = weightSHA256
    }

    func withWeightSHA256(_ hashes: [String: String]) -> Self {
        .init(
            backend: backend,
            modelID: modelID,
            revision: revision,
            runtimeVersion: runtimeVersion,
            weightSHA256: hashes
        )
    }
}

struct HighQualityModelEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case loadStarted = "load-started"
        case loadCompleted = "load-completed"
        case unloadCompleted = "unload-completed"
        case reserveChecked = "reserve-checked"
        case pressureChecked = "memory-pressure-checked"
        case memoryReleaseChecked = "memory-release-checked"
        case guardFailed = "guard-failed"
    }

    let kind: Kind
    let backend: HighQualityASRBackend?
    let modelID: String
    let message: String?
    let at: Date

    private enum CodingKeys: String, CodingKey {
        case kind, backend, modelID, message, at
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        backend = try values.decodeIfPresent(HighQualityASRBackend.self, forKey: .backend)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
            ?? backend?.model.modelID
            ?? "unknown"
        message = try values.decodeIfPresent(String.self, forKey: .message)
        at = try values.decode(Date.self, forKey: .at)
    }

    init(
        kind: Kind,
        backend: HighQualityASRBackend,
        at: Date,
        message: String? = nil
    ) {
        self.kind = kind
        self.backend = backend
        self.modelID = backend.model.modelID
        self.message = message
        self.at = at
    }

    init(kind: Kind, modelID: String, at: Date, message: String? = nil) {
        self.kind = kind
        self.backend = nil
        self.modelID = modelID
        self.message = message
        self.at = at
    }
}

struct HighQualityGeneratedFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case deliverable
        case evidence
        case manifest
    }

    let path: String
    let kind: Kind
}

struct HighQualityJobManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    enum Status: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
    }

    var schemaVersion: Int
    let jobID: UUID
    var status: Status
    var source: HighQualitySourceProvenance
    let deliverables: [HighQualityDeliverable]
    let selectedBackend: HighQualityASRBackend
    var selectedASRMode: HighQualityASRMode? = nil
    let translationModel: HighQualityTranslationModelEvidence?
    let speakerLabels: Bool
    let readableSubtitles: Bool?
    var speakerConfiguration: HighQualitySpeakerConfiguration?
    var speakerCountPolicy: HighQualitySpeakerCountPolicy?
    let dependencies: [HighQualityJobDependency]
    var model: HighQualityModelEvidence
    var asrWorker: HighQualityASRWorkerEvidence? = nil
    let startedAt: Date
    var finishedAt: Date?
    var stageDurations: [HighQualityJobStage: TimeInterval]
    var peakMemoryBytes: UInt64
    var modelEvents: [HighQualityModelEvent]
    var failures: [HighQualityJobFailure]
    var generatedFiles: [HighQualityGeneratedFile]
    var rawEvidenceSHA256: String? = nil
    var projectID: UUID? = nil
    var speakerReanalysisCount: Int? = nil
    var speakerEdits: [HighQualitySpeakerEdit]? = nil

    var usesLegacySavedResultFallback: Bool {
        schemaVersion == 2
            || (schemaVersion == 3
                && rawEvidenceSHA256 == nil
                && asrWorker?.result != nil)
    }

    var usesDurableSavedResultEvidence: Bool {
        schemaVersion >= 4 || (schemaVersion == 3 && rawEvidenceSHA256 != nil)
    }
}

struct HighQualitySpeakerReanalysisEvidence: Codable, Equatable, Sendable {
    let startedAt: Date
    let payloadPreparedAt: Date
    let preCommitWallTime: TimeInterval
    let configuration: HighQualitySpeakerConfiguration
    let modelEvents: [HighQualityModelEvent]
    let peakMemoryBytes: UInt64
    let replacedDiarization: HighQualityDiarizationEvidence
    let replacedAttachment: HighQualitySpeakerAttachmentEvidence?
    let replacedSpeakerEdits: [HighQualitySpeakerEdit]?
    let diarization: HighQualityDiarizationEvidence
    let attachment: HighQualitySpeakerAttachmentEvidence

    init(
        startedAt: Date,
        payloadPreparedAt: Date,
        preCommitWallTime: TimeInterval,
        configuration: HighQualitySpeakerConfiguration,
        modelEvents: [HighQualityModelEvent],
        peakMemoryBytes: UInt64,
        replacedDiarization: HighQualityDiarizationEvidence,
        replacedAttachment: HighQualitySpeakerAttachmentEvidence?,
        replacedSpeakerEdits: [HighQualitySpeakerEdit]?,
        diarization: HighQualityDiarizationEvidence,
        attachment: HighQualitySpeakerAttachmentEvidence
    ) {
        self.startedAt = startedAt
        self.payloadPreparedAt = payloadPreparedAt
        self.preCommitWallTime = preCommitWallTime
        self.configuration = configuration
        self.modelEvents = modelEvents
        self.peakMemoryBytes = peakMemoryBytes
        self.replacedDiarization = replacedDiarization
        self.replacedAttachment = replacedAttachment
        self.replacedSpeakerEdits = replacedSpeakerEdits
        self.diarization = diarization
        self.attachment = attachment
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, payloadPreparedAt, preCommitWallTime, configuration, modelEvents
        case peakMemoryBytes, replacedDiarization, replacedAttachment, replacedSpeakerEdits
        case diarization, attachment
        case finishedAt, wallTime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        payloadPreparedAt = try values.decodeIfPresent(Date.self, forKey: .payloadPreparedAt)
            ?? values.decode(Date.self, forKey: .finishedAt)
        preCommitWallTime = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .preCommitWallTime
        ) ?? values.decode(TimeInterval.self, forKey: .wallTime)
        configuration = try values.decode(
            HighQualitySpeakerConfiguration.self,
            forKey: .configuration
        )
        modelEvents = try values.decode([HighQualityModelEvent].self, forKey: .modelEvents)
        peakMemoryBytes = try values.decode(UInt64.self, forKey: .peakMemoryBytes)
        replacedDiarization = try values.decode(
            HighQualityDiarizationEvidence.self,
            forKey: .replacedDiarization
        )
        replacedAttachment = try values.decodeIfPresent(
            HighQualitySpeakerAttachmentEvidence.self,
            forKey: .replacedAttachment
        )
        replacedSpeakerEdits = try values.decodeIfPresent(
            [HighQualitySpeakerEdit].self,
            forKey: .replacedSpeakerEdits
        )
        diarization = try values.decode(
            HighQualityDiarizationEvidence.self,
            forKey: .diarization
        )
        attachment = try values.decode(
            HighQualitySpeakerAttachmentEvidence.self,
            forKey: .attachment
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(payloadPreparedAt, forKey: .payloadPreparedAt)
        try values.encode(preCommitWallTime, forKey: .preCommitWallTime)
        try values.encode(configuration, forKey: .configuration)
        try values.encode(modelEvents, forKey: .modelEvents)
        try values.encode(peakMemoryBytes, forKey: .peakMemoryBytes)
        try values.encode(replacedDiarization, forKey: .replacedDiarization)
        try values.encodeIfPresent(replacedAttachment, forKey: .replacedAttachment)
        try values.encodeIfPresent(replacedSpeakerEdits, forKey: .replacedSpeakerEdits)
        try values.encode(diarization, forKey: .diarization)
        try values.encode(attachment, forKey: .attachment)
    }
}

struct HighQualitySpeakerReanalysisCompletion: Codable, Equatable, Sendable {
    let reanalysisCount: Int
    let rawEvidenceSHA256: String
    let startedAt: Date
    let payloadPreparedAt: Date
    let finishedAt: Date
    let wallTime: TimeInterval
    let commitWallTime: TimeInterval
    let auditError: String?
}

private struct HighQualitySpeakerReanalysisJournal: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var entries: [HighQualitySpeakerReanalysisCompletion]
}

struct HighQualityRawEvidence: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let model: HighQualityModelEvidence
    let asrWorker: HighQualityASRWorkerEvidence?
    var adaptiveASR: HighQualityAdaptiveASRAudit? = nil
    var speakerConfiguration: HighQualitySpeakerConfiguration?
    var speakerCountPolicy: HighQualitySpeakerCountPolicy?
    let rawASR: String?
    let glossary: HighQualityGlossarySelection
    var alignment: HighQualityAlignmentEvidence?
    var diarization: HighQualityDiarizationEvidence?
    var speakerAttachment: HighQualitySpeakerAttachmentEvidence? = nil
    let translation: HighQualityTranslationEvidence?
    let sampleRate: Int
    let sampleCount: Int
    var sourceAudioSHA256: String? = nil
    var stageDurations: [HighQualityJobStage: TimeInterval]
    var peakMemoryBytes: UInt64
    var modelEvents: [HighQualityModelEvent]
    let failures: [HighQualityJobFailure]
    let generatedFiles: [HighQualityGeneratedFile]
    var resultTurns: [HighQualityTranscriptTurn]? = nil
    var subtitleCues: [HighQualitySubtitleCue]? = nil
    var japaneseTranscript: String? = nil
    var englishTranscript: String? = nil
    var readableSubtitles: HighQualityReadableSubtitleEvidence? = nil
    var projectID: UUID? = nil
    var speakerReanalyses: [HighQualitySpeakerReanalysisEvidence]? = nil
}

struct HighQualityJobResult: Sendable {
    let directory: URL
    let japaneseTranscript: String
    let englishTranscript: String?
    let turns: [HighQualityTranscriptTurn]
    let subtitleCues: [HighQualitySubtitleCue]
    let manifest: HighQualityJobManifest
    let evidence: HighQualityRawEvidence
    let speakerReanalysisCompletion: HighQualitySpeakerReanalysisCompletion?

    init(
        directory: URL,
        japaneseTranscript: String,
        englishTranscript: String?,
        turns: [HighQualityTranscriptTurn],
        subtitleCues: [HighQualitySubtitleCue],
        manifest: HighQualityJobManifest,
        evidence: HighQualityRawEvidence,
        speakerReanalysisCompletion: HighQualitySpeakerReanalysisCompletion? = nil
    ) {
        self.directory = directory
        self.japaneseTranscript = japaneseTranscript
        self.englishTranscript = englishTranscript
        self.turns = turns
        self.subtitleCues = subtitleCues
        self.manifest = manifest
        self.evidence = evidence
        self.speakerReanalysisCompletion = speakerReanalysisCompletion
    }

    fileprivate var automaticSpeakerLabels: Set<String> {
        var labels = Set(evidence.resultTurns?.compactMap(\.speakerLabel) ?? [])
        if let spans = evidence.diarization?.rawSpans {
            labels.formUnion(highQualitySpeakerLabelsByID(spans).values)
        }
        return labels
    }

    var editableSpeakerLabels: [String] {
        (try? HighQualityJob.speakerEditState(
            manifest.speakerEdits ?? [],
            for: self
        ).activeLabels.sorted()) ?? automaticSpeakerLabels.sorted()
    }

    var editableSpeakerNames: [String: String] {
        guard let state = try? HighQualityJob.speakerEditState(
            manifest.speakerEdits ?? [],
            for: self
        ) else { return [:] }
        var names = state.names
        for turn in turns {
            if let label = turn.speakerLabel, let name = turn.speakerName {
                names[label] = name
            }
        }
        return Dictionary(uniqueKeysWithValues: state.activeLabels.map {
            ($0, names[$0] ?? $0)
        })
    }

    var canUndoLastSpeakerEdit: Bool {
        !(manifest.speakerEdits ?? []).isEmpty
    }

    var hasArchivedSpeakerEdits: Bool {
        evidence.speakerReanalyses?.last?.replacedSpeakerEdits?.isEmpty == false
    }

    var canRestorePreviousSpeakerEdits: Bool {
        HighQualityJob.canRestorePreviousSpeakerEdits(in: self)
    }

    var shouldExplainIncompatibleArchivedSpeakerEdits: Bool {
        hasArchivedSpeakerEdits && !canRestorePreviousSpeakerEdits
    }

    fileprivate func withSpeakerReanalysisCompletion(
        _ completion: HighQualitySpeakerReanalysisCompletion?
    ) -> Self {
        .init(
            directory: directory,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            turns: turns,
            subtitleCues: subtitleCues,
            manifest: manifest,
            evidence: evidence,
            speakerReanalysisCompletion: completion
        )
    }
}

fileprivate struct HighQualitySpeakerEditState {
    var assignments: [String: String]
    var names: [String: String]
    var activeLabels: Set<String>
}

enum HighQualitySpeakerReanalysisAvailability: Equatable, Sendable {
    case unavailable
    case requiresVerifiedSource
    case available

    static let verifiedSourceExplanation = "This saved result has no verified source-audio fingerprint. Recompute the High-quality job before reanalyzing speakers."

    var explanation: String? {
        guard self == .requiresVerifiedSource else { return nil }
        return Self.verifiedSourceExplanation
    }
}

extension HighQualityJobResult {
    var hasDuplicateSpeakerBetaEvidence: Bool {
        compatibleSpeakerCentroids != nil
    }

    var duplicateSpeakerSuggestions: [HighQualityDuplicateSpeakerSuggestion] {
        compatibleSpeakerCentroids.map(HighQualityJob.duplicateSpeakerSuggestions) ?? []
    }

    fileprivate var compatibleSpeakerCentroids: [HighQualitySpeakerCentroidEvidence]? {
        guard let diarization = evidence.diarization else { return nil }
        let speakerCount = Set(diarization.rawSpans.map(\.speakerID)).count
        let expectedSpeakerLabels = Set((0..<speakerCount).map {
            String(format: "SPEAKER_%02d", $0)
        })
        guard diarization.validationDiagnostics.isEmpty,
              let centroids = diarization.speakerCentroids,
              Set(centroids.map(\.speakerLabel)) == expectedSpeakerLabels,
              let runtimeRevision = diarization.configuration?["runtimeRevision"],
              let embeddingVariant = diarization.configuration?["embedderVariant"],
              HighQualityJob.hasValidCompatibleSpeakerCentroids(centroids),
              let first = centroids.first else { return nil }
        let expectedSignature = HighQualitySpeakerCentroidSignature(
            modelID: diarization.modelID,
            modelRevision: diarization.revision,
            runtimeRevision: runtimeRevision,
            embeddingVariant: embeddingVariant,
            vectorDimension: first.vectorDimension
        )
        guard centroids.allSatisfy({
            $0.sourceJobID == manifest.jobID
                && $0.compatibilitySignature == expectedSignature
        }) else { return nil }
        return centroids
    }
}

struct HighQualitySavedResult: Identifiable, Sendable {
    let directory: URL
    let manifest: HighQualityJobManifest
    let relocatedSourcePath: String?

    init(
        directory: URL,
        manifest: HighQualityJobManifest,
        relocatedSourcePath: String? = nil
    ) {
        self.directory = directory
        self.manifest = manifest
        self.relocatedSourcePath = relocatedSourcePath
    }

    var id: UUID { manifest.jobID }
    var sourceURL: URL {
        URL(fileURLWithPath: relocatedSourcePath ?? manifest.source.path)
    }
    var sourceRelocationMessage: String? {
        guard !FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        if manifest.source.youtube != nil {
            return "The retained YouTube audio is missing. Reopen the recorded source evidence; WhisperASR will not download or transcribe it again."
        }
        return "The source file is missing or moved. Locate \(manifest.source.fileName) before using result actions."
    }
}

private struct HighQualityResultTransformations: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let customSpeakerLabels: [String: String]
    let speakerEdits: [HighQualitySpeakerEdit]
    var relocatedSourcePath: String? = nil

    init(
        schemaVersion: Int = currentSchemaVersion,
        customSpeakerLabels: [String: String] = [:],
        speakerEdits: [HighQualitySpeakerEdit] = [],
        relocatedSourcePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.customSpeakerLabels = customSpeakerLabels
        self.speakerEdits = speakerEdits
        self.relocatedSourcePath = relocatedSourcePath
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, customSpeakerLabels, speakerEdits, relocatedSourcePath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        customSpeakerLabels = try values.decodeIfPresent(
            [String: String].self,
            forKey: .customSpeakerLabels
        ) ?? [:]
        speakerEdits = try values.decodeIfPresent(
            [HighQualitySpeakerEdit].self,
            forKey: .speakerEdits
        ) ?? []
        relocatedSourcePath = try values.decodeIfPresent(
            String.self,
            forKey: .relocatedSourcePath
        )
    }
}

struct HighQualityJobError: LocalizedError, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
    let resultDirectory: URL?

    var errorDescription: String? { message }
}

private struct HighQualitySpeakerAnalysis {
    var evidence: HighQualityDiarizationEvidence
    let modelEvents: [HighQualityModelEvent]
    let peakMemoryBytes: UInt64
}

private struct HighQualitySpeakerAnalysisFailure: LocalizedError {
    let message: String
    let cancelled: Bool
    let evidence: HighQualityDiarizationEvidence
    let modelEvents: [HighQualityModelEvent]
    let peakMemoryBytes: UInt64

    var errorDescription: String? { message }
}

struct HighQualityJob: Sendable {
    struct Services: Sendable {
        let loadSource: @Sendable (URL) async throws -> [Float]
        let acquireYouTube: @Sendable (URL, URL) async throws -> HighQualityYouTubeAcquisition
        let prepareASR: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let transcribeJapanese: @Sendable ([Float]) async throws -> String
        let transcribeJapaneseEvidence: @Sendable ([Float]) async throws
            -> HighQualityASRExchange
        let transcribeJapaneseAnchored: @Sendable ([Float]) async throws -> HighQualityASRExchange
        let unloadASR: @Sendable () async -> Void
        let asrWorkerEvidence: @Sendable () async -> HighQualityASRWorkerEvidence?
        let prepareAlignment: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let alignJapanese: @Sendable (
            [Float],
            [HighQualityTranslationTurn]
        ) async throws -> HighQualityAlignmentExchange
        let unloadAlignment: @Sendable () async -> Void
        let alignmentModelID: String
        let alignmentRevision: String
        let alignmentDeclaredPeakMemoryBytes: UInt64
        let alignmentWorkerEvidence: @Sendable () async -> HighQualityWorkerEvidence?
        let prepareDiarization: @Sendable (
            HighQualitySpeakerConfiguration,
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let diarizeSpeakers: @Sendable (
            [Float],
            Bool,
            HighQualitySpeakerConfiguration
        ) async throws -> HighQualityDiarizationExchange
        let unloadDiarization: @Sendable () async -> Void
        let diarizationModelID: String
        let diarizationDeclaredPeakMemoryBytes: UInt64
        let diarizationRevision: String
        let diarizationWorkerEvidence: @Sendable () async -> HighQualityWorkerEvidence?
        let completeDiarizationAttribution: Bool
        let currentMemoryBytes: @Sendable () async -> UInt64
        let prepareTranslation: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let translateEnglish: @Sendable (
            HighQualityTranslationBatch
        ) async throws -> HighQualityTranslationExchange
        let unloadTranslation: @Sendable () async -> Void
        let translationWorkerEvidence: @Sendable () async
            -> HighQualityTranslationWorkerEvidence?
        let heavyweightGate: HeavyweightModelGate?

        init(
            loadSource: @escaping @Sendable (URL) async throws -> [Float],
            acquireYouTube: @escaping @Sendable (
                URL,
                URL
            ) async throws -> HighQualityYouTubeAcquisition = { _, _ in
                throw HighQualityJobError(
                    stage: .acquisition,
                    message: "YouTube acquisition is not configured.",
                    resultDirectory: nil
                )
            },
            prepareASR: @escaping @Sendable (
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void,
            transcribeJapanese: @escaping @Sendable ([Float]) async throws -> String,
            transcribeJapaneseEvidence: (@Sendable ([Float]) async throws
                -> HighQualityASRExchange)? = nil,
            transcribeJapaneseAnchored: (@Sendable ([Float]) async throws -> HighQualityASRExchange)? = nil,
            unloadASR: @escaping @Sendable () async -> Void,
            asrWorkerEvidence: @escaping @Sendable () async
                -> HighQualityASRWorkerEvidence? = { nil },
            prepareAlignment: @escaping @Sendable (
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void = { _ in
                throw HighQualityJobError(
                    stage: .alignment,
                    message: "Forced alignment is not configured.",
                    resultDirectory: nil
                )
            },
            alignJapanese: @escaping @Sendable (
                [Float],
                [HighQualityTranslationTurn]
            ) async throws -> HighQualityAlignmentExchange = { _, _ in
                throw HighQualityJobError(
                    stage: .alignment,
                    message: "Forced alignment is not configured.",
                    resultDirectory: nil
                )
            },
            unloadAlignment: @escaping @Sendable () async -> Void = {},
            alignmentModelID: String = HighQualityForcedAlignerRuntime.modelID,
            alignmentRevision: String = HighQualityForcedAlignerRuntime.revision,
            alignmentDeclaredPeakMemoryBytes: UInt64 =
                HighQualityForcedAlignerRuntime.declaredPeakMemoryBytes,
            alignmentWorkerEvidence: @escaping @Sendable () async
                -> HighQualityWorkerEvidence? = { nil },
            prepareDiarization: @escaping @Sendable (
                HighQualitySpeakerConfiguration,
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void = { _, _ in
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit is not configured.",
                    resultDirectory: nil
                )
            },
            diarizeSpeakers: @escaping @Sendable (
                [Float],
                Bool,
                HighQualitySpeakerConfiguration
            ) async throws -> HighQualityDiarizationExchange = { _, _, _ in
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit is not configured.",
                    resultDirectory: nil
                )
            },
            unloadDiarization: @escaping @Sendable () async -> Void = {},
            diarizationModelID: String = HighQualitySpeakerKitRuntime.modelID,
            diarizationDeclaredPeakMemoryBytes: UInt64 =
                HighQualitySpeakerKitRuntime.declaredPeakMemoryBytes,
            diarizationRevision: String = HighQualitySpeakerKitRuntime.revision,
            diarizationWorkerEvidence: @escaping @Sendable () async
                -> HighQualityWorkerEvidence? = { nil },
            completeDiarizationAttribution: Bool = false,
            currentMemoryBytes: @escaping @Sendable () async -> UInt64 = { 0 },
            prepareTranslation: @escaping @Sendable (
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void = { _ in },
            translateEnglish: @escaping @Sendable (
                HighQualityTranslationBatch
            ) async throws -> HighQualityTranslationExchange = { _ in
                throw HighQualityJobError(
                    stage: .translation,
                    message: "Local translation is not configured.",
                    resultDirectory: nil
                )
            },
            unloadTranslation: @escaping @Sendable () async -> Void = {},
            translationWorkerEvidence: @escaping @Sendable () async
                -> HighQualityTranslationWorkerEvidence? = { nil },
            heavyweightGate: HeavyweightModelGate? = nil
        ) {
            self.loadSource = loadSource
            self.acquireYouTube = acquireYouTube
            self.prepareASR = prepareASR
            self.transcribeJapanese = transcribeJapanese
            self.transcribeJapaneseEvidence = transcribeJapaneseEvidence ?? { samples in
                let transcript = try await transcribeJapanese(samples)
                return .init(rawTranscript: transcript, chunks: [])
            }
            self.transcribeJapaneseAnchored = transcribeJapaneseAnchored ?? { samples in
                let transcript = try await transcribeJapanese(samples)
                return .init(
                    rawTranscript: transcript,
                    chunks: [.init(
                        index: 0,
                        sourceStart: 0,
                        sourceEnd: Double(samples.count) / 16_000,
                        transcript: transcript
                    )]
                )
            }
            self.unloadASR = unloadASR
            self.asrWorkerEvidence = asrWorkerEvidence
            self.prepareAlignment = prepareAlignment
            self.alignJapanese = alignJapanese
            self.unloadAlignment = unloadAlignment
            self.alignmentModelID = alignmentModelID
            self.alignmentRevision = alignmentRevision
            self.alignmentDeclaredPeakMemoryBytes = alignmentDeclaredPeakMemoryBytes
            self.alignmentWorkerEvidence = alignmentWorkerEvidence
            self.prepareDiarization = prepareDiarization
            self.diarizeSpeakers = diarizeSpeakers
            self.unloadDiarization = unloadDiarization
            self.diarizationModelID = diarizationModelID
            self.diarizationDeclaredPeakMemoryBytes = diarizationDeclaredPeakMemoryBytes
            self.diarizationRevision = diarizationRevision
            self.diarizationWorkerEvidence = diarizationWorkerEvidence
            self.completeDiarizationAttribution = completeDiarizationAttribution
            self.currentMemoryBytes = currentMemoryBytes
            self.prepareTranslation = prepareTranslation
            self.translateEnglish = translateEnglish
            self.unloadTranslation = unloadTranslation
            self.translationWorkerEvidence = translationWorkerEvidence
            self.heavyweightGate = heavyweightGate
        }

        static func production(
            for backend: HighQualityASRBackend,
            translator selection: HighQualityTranslator
        ) -> Self {
            let executableURL = ProcessInfo.processInfo.environment[
                "WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"
            ].map(URL.init(fileURLWithPath:))
                ?? Bundle.main.executableURL
                ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            let asr = HighQualityASRWorkerClient(backend: backend, executableURL: executableURL)
            let aligner = HighQualityAlignmentSpeakerWorkerClient(
                stage: .alignment,
                executableURL: executableURL
            )
            let diarizer = HighQualityAlignmentSpeakerWorkerClient(
                stage: .diarization,
                executableURL: executableURL
            )
            let translator = HighQualityTranslationWorkerClient(
                candidate: selection.candidate,
                executableURL: executableURL
            )
            let loadSource: @Sendable (URL) async throws -> [Float] = {
                try await AudioLoader.loadSamples(url: $0)
            }
            let acquireYouTube: @Sendable (
                URL,
                URL
            ) async throws -> HighQualityYouTubeAcquisition = {
                try await YouTubeAcquirer.acquire($0, to: $1)
            }
            let diarizeSpeakers: @Sendable (
                [Float],
                Bool,
                HighQualitySpeakerConfiguration
            ) async throws -> HighQualityDiarizationExchange = {
                try await diarizer.diarize(
                    samples: $0,
                    useExclusiveReconciliation: $1,
                    configuration: $2
                )
            }
            return Self(
                loadSource: loadSource,
                acquireYouTube: acquireYouTube,
                prepareASR: { try await asr.prepare(progress: $0) },
                transcribeJapanese: {
                    try await asr.transcribe($0, anchored: false).rawTranscript
                },
                transcribeJapaneseEvidence: {
                    try await asr.transcribe($0, anchored: false)
                },
                transcribeJapaneseAnchored: {
                    try await asr.transcribe($0, anchored: true)
                },
                unloadASR: { await asr.unload() },
                asrWorkerEvidence: { await asr.evidence },
                prepareAlignment: { try await aligner.prepare(progress: $0) },
                alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                unloadAlignment: { await aligner.unload() },
                alignmentWorkerEvidence: { await aligner.evidence },
                prepareDiarization: {
                    try await diarizer.prepare(configuration: $0, progress: $1)
                },
                diarizeSpeakers: diarizeSpeakers,
                unloadDiarization: { await diarizer.unload() },
                diarizationWorkerEvidence: { await diarizer.evidence },
                currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
                prepareTranslation: { try await translator.prepare(progress: $0) },
                translateEnglish: { try await translator.translate($0) },
                unloadTranslation: { await translator.unload() },
                translationWorkerEvidence: { await translator.evidence },
                heavyweightGate: .shared
            )
        }

        static func chunkedASR(
            _ samples: [Float],
            transcribe: @escaping @Sendable ([Float]) async throws -> String
        ) async throws -> HighQualityASRExchange {
            try await chunkedASR(samples) { chunk in
                .init(rawTranscript: try await transcribe(chunk), chunks: [])
            }
        }

        static func chunkedASR(
            _ samples: [Float],
            transcribe: @escaping @Sendable ([Float]) async throws -> HighQualityASRExchange
        ) async throws -> HighQualityASRExchange {
            var chunks: [HighQualityASRChunk] = []
            var characters: [HighQualityASRCharacter]? = nil
            var model: HighQualityModelEvidence?
            var backendWindows: [HighQualityASRWindowEvidence] = []
            var start = 0
            var alignmentAnchorStart = 0
            var previousBoundaryWasSilent = true
            while start < samples.count {
                try Task.checkCancellation()
                let overlap = 16_000
                let leadingOverlap = previousBoundaryWasSilent ? 0 : overlap
                let boundary = quietASRBoundary(
                    in: samples,
                    after: start,
                    leadingOverlap: leadingOverlap
                )
                let windowStart = max(0, start - leadingOverlap)
                let windowEnd = boundary.isSilent
                    ? boundary.index : min(samples.count, boundary.index + overlap)
                let rawExchange = try await transcribe(Array(samples[windowStart..<windowEnd]))
                if model == nil { model = rawExchange.model }
                var windowResult = rawExchange
                windowResult.model = nil
                backendWindows.append(.init(
                    sourceStart: Double(windowStart) / 16_000,
                    sourceEnd: Double(windowEnd) / 16_000,
                    result: windowResult
                ))
                let raw = rawExchange.rawTranscript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let transcript = removingTranscriptOverlap(
                    prefix: chunks.last?.transcript ?? "",
                    suffix: raw
                )
                let sourceStart = Double(alignmentAnchorStart) / 16_000
                let sourceEnd = Double(windowEnd) / 16_000
                if !transcript.isEmpty {
                    let chunkIndex = chunks.count
                    chunks.append(.init(
                        index: chunkIndex,
                        sourceStart: sourceStart,
                        sourceEnd: sourceEnd,
                        transcript: transcript
                    ))
                    if let rawCharacters = rawExchange.characters {
                        let removedPrefixCount = raw.count - transcript.count
                        let retained = rawCharacters.dropFirst(removedPrefixCount).map {
                            HighQualityASRCharacter(
                                chunkIndex: chunkIndex,
                                text: $0.text,
                                sourceStart: max(
                                    sourceStart,
                                    Double(windowStart) / 16_000 + $0.sourceStart
                                ),
                                sourceEnd: min(
                                    sourceEnd,
                                    Double(windowStart) / 16_000 + $0.sourceEnd
                                )
                            )
                        }
                        if characters == nil { characters = [] }
                        characters?.append(contentsOf: retained)
                    }
                }
                alignmentAnchorStart = windowEnd
                start = boundary.index
                previousBoundaryWasSilent = boundary.isSilent
            }
            return .init(
                rawTranscript: chunks.map(\.transcript).joined(separator: "\n"),
                chunks: chunks,
                characters: characters,
                model: model,
                windows: backendWindows.isEmpty ? nil : backendWindows
            )
        }

        private static func quietASRBoundary(
            in samples: [Float],
            after start: Int,
            leadingOverlap: Int
        ) -> (index: Int, isSilent: Bool) {
            let sampleRate = 16_000
            let overlap = sampleRate
            let maximumCore = HighQualityForcedAlignerRuntime.maximumWindowSeconds * sampleRate
                - leadingOverlap
            guard samples.count - start > maximumCore else { return (samples.count, true) }

            let latestSilentCut = start + maximumCore
            let fallbackCut = latestSilentCut - overlap
            let searchRadius = 5 * sampleRate
            let frame = sampleRate / 50
            let searchStart = max(start + maximumCore / 2, latestSilentCut - searchRadius)
            let searchEnd = min(samples.count - frame, latestSilentCut)
            var best = fallbackCut
            var bestEnergy = Double.infinity
            for candidate in stride(from: searchStart, through: searchEnd, by: frame) {
                let energy = samples[candidate..<(candidate + frame)].reduce(0.0) {
                    $0 + Double($1 * $1)
                }
                if energy < bestEnergy
                    || (energy == bestEnergy
                        && abs(candidate - latestSilentCut) < abs(best - latestSilentCut)) {
                    best = candidate
                    bestEnergy = energy
                }
            }
            let isSilent = bestEnergy / Double(frame) <= 0.003 * 0.003
            return (isSilent ? best : fallbackCut, isSilent)
        }

        private static func removingTranscriptOverlap(prefix: String, suffix: String) -> String {
            let left = Array(prefix)
            let right = Array(suffix)
            let limit = min(200, left.count, right.count)
            let overlap = stride(from: limit, through: 2, by: -1).first {
                left.suffix($0).elementsEqual(right.prefix($0))
            } ?? 0
            return String(right.dropFirst(overlap))
        }
    }

    private let servicesForSelection: @Sendable (
        HighQualityASRBackend,
        HighQualityTranslator
    ) -> Services
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        servicesForSelection = { Services.production(for: $0, translator: $1) }
        self.now = now
    }

    init(
        services: Services,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        servicesForSelection = { _, _ in services }
        self.now = now
    }

    init(
        servicesForBackend: @escaping @Sendable (HighQualityASRBackend) -> Services,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        servicesForSelection = { backend, _ in servicesForBackend(backend) }
        self.now = now
    }

    private func analyzeSpeakers(
        services: Services,
        workflowLease: HeavyweightWorkflowLease?,
        samples: [Float],
        alignedItems: [HighQualityAlignmentItem],
        duration: TimeInterval,
        useExclusiveReconciliation: Bool,
        configuration: HighQualitySpeakerConfiguration,
        sourceJobID: UUID,
        processingDiarization: () -> Void,
        progress: @escaping @Sendable (HighQualityJobStage, Double, String) -> Void
    ) async throws -> HighQualitySpeakerAnalysis {
        var lease: HeavyweightModelLease?
        var loadStarted = false
        var unloaded = false
        var modelEvents: [HighQualityModelEvent] = []
        var evidence = HighQualityDiarizationEvidence(
            modelID: services.diarizationModelID,
            revision: services.diarizationRevision,
            rawSpans: [],
            mappings: [],
            overlapRanges: [],
            peakMemoryBytes: 0,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerCountPolicy: configuration.countPolicy,
            validationDiagnostics: []
        )
        var peakMemoryBytes: UInt64 = 0

        @Sendable func guarded<T: Sendable>(
            _ lease: HeavyweightModelLease?,
            _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            guard let gate = services.heavyweightGate, let lease else {
                return try await operation()
            }
            return try await gate.withMemoryGuard(lease, operation: operation)
        }

        func appendReleaseEvidence(
            _ memory: HeavyweightModelMemoryEvidence,
            releasedMemoryBytes: UInt64
        ) {
            peakMemoryBytes = max(peakMemoryBytes, memory.peakMemoryBytes)
            modelEvents.append(.init(
                kind: .memoryReleaseChecked,
                modelID: services.diarizationModelID,
                at: Date(),
                message: "memory=\(releasedMemoryBytes) runtimePeak=\(memory.peakMemoryBytes) minimumAvailable=\(memory.minimumAvailableMemoryBytes) maximum=\(memory.maximumMemoryBytes) reserve=\(memory.reserveBytes)"
            ))
        }

        func unload() async throws {
            guard !unloaded else { return }
            if let gate = services.heavyweightGate, let lease {
                let memory: HeavyweightModelMemoryEvidence
                do {
                    memory = try await gate.memoryEvidence(lease)
                } catch {
                    unloaded = true
                    await services.unloadDiarization()
                    throw error
                }
                unloaded = true
                do {
                    let released = try await gate.releaseModel(
                        lease,
                        unload: services.unloadDiarization
                    )
                    modelEvents.append(.init(
                        kind: .unloadCompleted,
                        modelID: services.diarizationModelID,
                        at: Date()
                    ))
                    appendReleaseEvidence(memory, releasedMemoryBytes: released)
                } catch {
                    modelEvents.append(.init(
                        kind: .unloadCompleted,
                        modelID: services.diarizationModelID,
                        at: Date()
                    ))
                    throw error
                }
            } else {
                unloaded = true
                await services.unloadDiarization()
                modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: services.diarizationModelID,
                    at: Date()
                ))
            }
        }

        do {
            if let gate = services.heavyweightGate, let workflowLease {
                lease = try await gate.acquireModel(
                    workflow: workflowLease,
                    modelID: services.diarizationModelID,
                    declaredPeakBytes: services.diarizationDeclaredPeakMemoryBytes
                )
            }
            if let lease {
                modelEvents.append(.init(
                    kind: .pressureChecked,
                    modelID: services.diarizationModelID,
                    at: Date(),
                    message: "policy=macos-memory-pressure peak=\(lease.declaredPeakBytes) reserve=\(lease.reserveBytes) total=\(lease.totalMemoryBytes) available=\(lease.availableMemoryBytes) baseline=\(lease.baselineMemoryBytes)"
                ))
            }
            loadStarted = true
            modelEvents.append(.init(
                kind: .loadStarted,
                modelID: services.diarizationModelID,
                at: Date()
            ))
            progress(.preparingDiarization, 0, "Preparing SpeakerKit…")
            try await guarded(lease) {
                try await services.prepareDiarization(configuration) { fraction, message in
                    progress(.preparingDiarization, min(max(fraction, 0), 1), message)
                }
            }
            if let gate = services.heavyweightGate, let lease {
                try await gate.markLoaded(lease)
            }
            modelEvents.append(.init(
                kind: .loadCompleted,
                modelID: services.diarizationModelID,
                at: Date()
            ))
            try Task.checkCancellation()

            processingDiarization()
            progress(.diarizing, 0, "Detecting speakers…")
            let exchange = try await guarded(lease) {
                try await services.diarizeSpeakers(
                    samples,
                    useExclusiveReconciliation,
                    configuration
                )
            }
            guard exchange.speakerCountPolicy == configuration.countPolicy else {
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit did not preserve the requested Speaker-count policy.",
                    resultDirectory: nil
                )
            }
            evidence = .init(
                modelID: exchange.modelID,
                revision: exchange.revision,
                rawSpans: exchange.spans,
                mappings: [],
                overlapRanges: [],
                peakMemoryBytes: exchange.peakMemoryBytes,
                useExclusiveReconciliation: exchange.useExclusiveReconciliation,
                speakerCountPolicy: exchange.speakerCountPolicy,
                configuration: exchange.configuration,
                validationDiagnostics: []
            )
            do {
                evidence = try Self.diarizationEvidence(
                    exchange,
                    items: alignedItems,
                    duration: duration,
                    completeAttribution: services.completeDiarizationAttribution,
                    sourceJobID: sourceJobID
                )
            } catch {
                evidence.validationDiagnostics = [error.localizedDescription]
                throw error
            }
            peakMemoryBytes = max(peakMemoryBytes, exchange.peakMemoryBytes)
            try await unload()
            lease = nil
            evidence.worker = await services.diarizationWorkerEvidence()
            peakMemoryBytes = max(
                peakMemoryBytes,
                evidence.worker?.peakPhysicalFootprintBytes ?? 0
            )
            guard evidence.worker?.pressureTransitions.contains(where: {
                $0.level == .critical
            }) != true else {
                throw HighQualityAlignmentSpeakerWorkerError.criticalMemoryPressure(
                    stage: "SpeakerKit"
                )
            }
            try Task.checkCancellation()
            return .init(
                evidence: evidence,
                modelEvents: modelEvents,
                peakMemoryBytes: peakMemoryBytes
            )
        } catch {
            let originalError = error
            var cleanupMessage: String?
            if loadStarted, !unloaded {
                do {
                    try await unload()
                    lease = nil
                } catch {
                    cleanupMessage = error.localizedDescription
                }
            }
            evidence.worker = await services.diarizationWorkerEvidence()
            peakMemoryBytes = max(
                max(peakMemoryBytes, evidence.peakMemoryBytes),
                evidence.worker?.peakPhysicalFootprintBytes ?? 0
            )
            if let gateError = originalError as? HeavyweightModelGateError {
                modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: services.diarizationModelID,
                    at: Date(),
                    message: gateError.localizedDescription
                ))
            }
            if let cleanupMessage {
                modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: services.diarizationModelID,
                    at: Date(),
                    message: cleanupMessage
                ))
            }
            let cancelled = originalError is CancellationError || Task.isCancelled
            if !cancelled, evidence.validationDiagnostics.isEmpty {
                evidence.validationDiagnostics = [originalError.localizedDescription]
            }
            let message = cancelled ? "Speaker analysis cancelled." : originalError.localizedDescription
            throw HighQualitySpeakerAnalysisFailure(
                message: cleanupMessage.map { message + " " + $0 } ?? message,
                cancelled: cancelled,
                evidence: evidence,
                modelEvents: modelEvents,
                peakMemoryBytes: peakMemoryBytes
            )
        }
    }

    static func savedResults(
        in root: URL = AppStoragePaths.highQualityJobs
    ) -> [HighQualitySavedResult] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let manifest = try? readManifest(in: directory),
                  manifest.status == .completed,
                  directory.lastPathComponent == manifest.jobID.uuidString else { return nil }
            return HighQualitySavedResult(
                directory: directory,
                manifest: manifest,
                relocatedSourcePath: (try? readTransformations(in: directory))?
                    .relocatedSourcePath
            )
        }.sorted {
            ($0.manifest.finishedAt ?? $0.manifest.startedAt)
                > ($1.manifest.finishedAt ?? $1.manifest.startedAt)
        }
    }

    static func reopen(_ saved: HighQualitySavedResult) throws -> HighQualityJobResult {
        let manifest = try readManifest(in: saved.directory)
        guard manifest.status == .completed,
              saved.directory.lastPathComponent == manifest.jobID.uuidString else {
            throw savedResultError("This High-quality job is not a completed saved result.", saved)
        }
        let evidenceURL = saved.directory.appendingPathComponent("raw-asr.json")
        let evidence: HighQualityRawEvidence
        let usesLegacyFallback = manifest.usesLegacySavedResultFallback
        let usesDurableEvidence = manifest.usesDurableSavedResultEvidence
        do {
            let data = try Data(contentsOf: evidenceURL)
            if let expected = manifest.rawEvidenceSHA256 {
                guard sha256(data) == expected else {
                    throw savedResultError("Raw evidence verification failed.", saved)
                }
            } else if !usesLegacyFallback {
                throw savedResultError("Raw evidence verification data is missing.", saved)
            }
            evidence = try decoder.decode(HighQualityRawEvidence.self, from: data)
        } catch let error as HighQualityJobError {
            throw error
        } catch {
            throw savedResultError("The saved raw evidence is unreadable.", saved)
        }
        guard evidence.source == manifest.source,
              evidence.model == manifest.model,
              evidence.asrWorker == manifest.asrWorker,
              (manifest.readableSubtitles == true) == (evidence.readableSubtitles != nil),
              evidence.generatedFiles == manifest.generatedFiles,
              evidence.projectID == manifest.projectID else {
            throw savedResultError("The saved manifest and raw evidence do not match.", saved)
        }
        for file in manifest.generatedFiles
            where usesLegacyFallback && file.kind == .deliverable {
            guard FileManager.default.fileExists(
                atPath: saved.directory.appendingPathComponent(file.path).path
            ) else {
                throw savedResultError("A saved Deliverable is missing: \(file.path).", saved)
            }
        }
        guard let rawASR = evidence.rawASR,
              !rawASR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw savedResultError("The saved raw transcript is missing.", saved)
        }
        let transcript = rawASR.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesDurableEvidence,
           evidence.resultTurns == nil
            || evidence.subtitleCues == nil
            || evidence.japaneseTranscript == nil {
            throw savedResultError("The saved result evidence is incomplete.", saved)
        }
        let resultTurns: [HighQualityTranscriptTurn]
        if let persistedTurns = evidence.resultTurns {
            resultTurns = persistedTurns
        } else {
            let turns: [HighQualityTranslationTurn]
            if let translation = evidence.translation {
                turns = translation.request.turns
            } else if let units = evidence.alignment?.semanticUnits, !units.isEmpty {
                turns = units.map {
                    HighQualityTranslationTurn(
                        id: $0.id,
                        japanese: $0.japanese,
                        precedingJapanese: [],
                        followingJapanese: [],
                        speakerLabel: $0.speakerLabel,
                        sourceStart: $0.start,
                        sourceEnd: $0.end
                    )
                }
            } else {
                turns = translationTurns(
                    from: transcript,
                    asrChunks: [],
                    speakerLabelsByCueID: [:]
                )
            }
            let labelsByID = Dictionary(uniqueKeysWithValues:
                (evidence.speakerAttachment?.semanticUnits
                    ?? evidence.alignment?.semanticUnits ?? []).compactMap { unit in
                    unit.speakerLabel.map { (unit.id, $0) }
                }
            )
            let translationsByID: [String: String]
            if let translation = evidence.translation, let response = translation.response {
                translationsByID = try validatedTranslations(response, for: turns)
            } else {
                translationsByID = [:]
            }
            resultTurns = Self.resultTurns(
                turns: turns,
                speakerLabelsByID: labelsByID,
                translationsByID: translationsByID
            )
        }
        let deliverables = Set(manifest.deliverables)
        let japaneseTranscript: String
        if let persistedTranscript = evidence.japaneseTranscript {
            japaneseTranscript = persistedTranscript
        } else if deliverables.contains(.japaneseTranscript) {
            japaneseTranscript = try storedText(
                at: saved.directory.appendingPathComponent("japanese-transcript.txt")
            )
        } else {
            japaneseTranscript = transcript
        }
        let englishTranscript: String?
        if deliverables.contains(.englishTranslationTranscript) {
            if let persistedTranscript = evidence.englishTranscript {
                englishTranscript = persistedTranscript
            } else if usesLegacyFallback {
                englishTranscript = try storedText(at: saved.directory.appendingPathComponent(
                    "english-translation-transcript.txt"
                ))
            } else {
                throw savedResultError("The saved English transcript is missing.", saved)
            }
        } else {
            englishTranscript = nil
        }
        let subtitleCues: [HighQualitySubtitleCue]
        if let persistedCues = evidence.subtitleCues {
            subtitleCues = persistedCues
        } else if deliverables.contains(.englishSubtitles) {
            subtitleCues = resultTurns.compactMap {
                guard let start = $0.start, let end = $0.end, let english = $0.english else {
                    return nil
                }
                return HighQualitySubtitleCue(
                    id: $0.id,
                    start: start,
                    end: end,
                    text: english,
                    speakerLabel: $0.speakerLabel
                )
            }
        } else {
            subtitleCues = []
        }
        var result = HighQualityJobResult(
            directory: saved.directory,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            turns: resultTurns,
            subtitleCues: subtitleCues,
            manifest: manifest,
            evidence: evidence
        )
        if let transformations = try readTransformations(in: saved.directory) {
            let edits = migratedSpeakerEdits(transformations, manifest: manifest)
            guard speakerEditAuditMatchesManifest(
                transformations,
                edits: edits,
                manifest: manifest
            ) else {
                throw savedResultError(
                    "The saved Speaker edit manifest and audit do not match.",
                    saved
                )
            }
            if !edits.isEmpty {
                result = try applyingSpeakerEdits(edits, to: result)
            }
        } else if manifest.speakerEdits?.isEmpty == false {
            throw savedResultError("The saved Speaker edit audit is missing.", saved)
        }
        if usesDurableEvidence {
            do {
                try restoreDeliverablesIfNeeded(for: result)
            } catch {
                throw savedResultError(
                    "Saved Deliverables could not be restored from verified evidence.",
                    saved
                )
            }
        }
        return try result.withSpeakerReanalysisCompletion(
            speakerReanalysisCompletion(for: manifest, in: saved.directory)
        )
    }

    func relocateSource(
        _ saved: HighQualitySavedResult,
        to sourceURL: URL
    ) async throws -> HighQualitySavedResult {
        guard saved.manifest.source.youtube == nil,
              sourceURL.isFileURL,
              (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                == true else {
            throw Self.savedResultError(
                "Choose an existing local media file.",
                saved,
                stage: .source
            )
        }
        let reopened = try Self.reopen(saved)
        guard Self.isValidSHA256(reopened.evidence.sourceAudioSHA256) else {
            throw Self.savedResultError(
                HighQualitySpeakerReanalysisAvailability.verifiedSourceExplanation,
                saved,
                stage: .source
            )
        }
        let selection = reopened.manifest.translationModel?.translator ?? .productDefault
        let services = servicesForSelection(reopened.manifest.selectedBackend, selection)
        let samples: [Float]
        do {
            samples = try await services.loadSource(sourceURL)
        } catch {
            throw Self.savedResultError(
                "The selected media could not be verified: \(error.localizedDescription)",
                saved,
                stage: .source
            )
        }
        guard Self.matchesSavedSource(
            sourceURL,
            samples: samples,
            sha256: Self.audioSHA256(samples),
            result: reopened
        ) else {
            throw Self.savedResultError(
                "The selected media does not match the saved source audio.",
                saved,
                stage: .source
            )
        }
        let previous = try Self.readTransformations(in: saved.directory)
        let relocatedPath = sourceURL.standardizedFileURL.path
        let transformations = try Self.encoder.encode(HighQualityResultTransformations(
            schemaVersion: previous?.schemaVersion
                ?? HighQualityResultTransformations.currentSchemaVersion,
            customSpeakerLabels: previous?.customSpeakerLabels ?? [:],
            speakerEdits: previous?.speakerEdits ?? [],
            relocatedSourcePath: relocatedPath
        ))
        try Self.transactionallyWrite(
            ["transformations.json": transformations],
            in: saved.directory,
            validateActive: {
                guard try Self.activeResultMatches(
                    reopened.manifest,
                    transformations: previous,
                    in: saved.directory
                ) else {
                    throw Self.savedResultError(
                        "The saved result changed during source relocation. Reopen it and try again.",
                        saved
                    )
                }
            }
        )
        return HighQualitySavedResult(
            directory: saved.directory,
            manifest: reopened.manifest,
            relocatedSourcePath: relocatedPath
        )
    }

    static func clearRelocatedSource(in directory: URL) throws {
        guard let previous = try readTransformations(in: directory),
              previous.relocatedSourcePath != nil else { return }
        let transformations = try encoder.encode(HighQualityResultTransformations(
            schemaVersion: previous.schemaVersion,
            customSpeakerLabels: previous.customSpeakerLabels,
            speakerEdits: previous.speakerEdits,
            relocatedSourcePath: nil
        ))
        try transactionallyWrite(
            ["transformations.json": transformations],
            in: directory
        )
    }

    static func speakerReanalysisAvailability(
        _ result: HighQualityJobResult
    ) -> HighQualitySpeakerReanalysisAvailability {
        guard result.manifest.schemaVersion >= 3,
              result.manifest.status == .completed,
              result.manifest.speakerLabels,
              result.manifest.dependencies.contains(.speakerDiarization),
              result.evidence.sampleRate == 16_000,
              result.evidence.sampleCount > 0,
              result.evidence.diarization != nil,
              result.evidence.alignment?.semanticUnits?.isEmpty == false,
              result.evidence.alignment?.semanticFragments != nil else {
            return .unavailable
        }
        return isValidSHA256(result.evidence.sourceAudioSHA256)
            ? .available : .requiresVerifiedSource
    }

    static func canRerunSpeakers(_ result: HighQualityJobResult) -> Bool {
        result.manifest.schemaVersion >= 3
            && result.manifest.status == .completed
            && result.manifest.speakerLabels
            && result.manifest.dependencies.contains(.speakerDiarization)
            && result.evidence.sampleRate == 16_000
            && result.evidence.sampleCount > 0
            && result.evidence.diarization != nil
            && result.evidence.alignment?.semanticUnits?.isEmpty == false
            && result.evidence.alignment?.semanticFragments != nil
    }

    func rerunSpeakers(
        _ saved: HighQualitySavedResult,
        configuration: HighQualitySpeakerConfiguration,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in },
        beforeCommit: () throws -> Void = {},
        beforeCompletionAudit: () throws -> Void = {},
        writeCompletionAudit: (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) async throws -> HighQualityJobResult {
        guard configuration.isValid else {
            throw HighQualityJobError(
                stage: .application,
                message: "Expected speaker count must be an integer from 1 through 20.",
                resultDirectory: saved.directory
            )
        }
        let previous = try Self.reopen(saved)
        let availability = Self.speakerReanalysisAvailability(previous)
        guard availability == .available else {
            throw HighQualityJobError(
                stage: availability == .requiresVerifiedSource ? .source : .application,
                message: availability.explanation
                    ?? "This saved result does not contain compatible alignment and SpeakerKit evidence.",
                resultDirectory: saved.directory
            )
        }
        guard Self.canRerunSpeakers(previous),
              let alignment = previous.evidence.alignment,
              let units = alignment.semanticUnits,
              let fragments = alignment.semanticFragments,
              let previousDiarization = previous.evidence.diarization else {
            throw HighQualityJobError(
                stage: .application,
                message: "This saved result does not contain compatible alignment and SpeakerKit evidence.",
                resultDirectory: saved.directory
            )
        }
        let transformations = try Self.readTransformations(in: saved.directory)
        let replacedSpeakerEdits = Self.migratedSpeakerEdits(
            transformations,
            manifest: previous.manifest
        )
        guard try Self.activeResultMatches(
            previous.manifest,
            transformations: transformations,
            in: saved.directory
        ) else {
            throw HighQualityJobError(
                stage: .application,
                message: "The saved Speaker result changed before reanalysis. Reopen it and try again.",
                resultDirectory: saved.directory
            )
        }
        let activeSaved = HighQualitySavedResult(
            directory: saved.directory,
            manifest: previous.manifest,
            relocatedSourcePath: transformations?.relocatedSourcePath
        )
        let sourceURL = activeSaved.sourceURL
        guard sourceURL.isFileURL,
              (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                == true else {
            throw HighQualityJobError(
                stage: .source,
                message: activeSaved.sourceRelocationMessage
                    ?? "The saved source audio is unavailable. Locate it before reanalysis.",
                resultDirectory: saved.directory
            )
        }

        let selection = previous.manifest.translationModel?.translator ?? .productDefault
        let services = servicesForSelection(previous.manifest.selectedBackend, selection)
        let rawStartedAt = now()
        let startedAt = Self.persistedDate(rawStartedAt)
        var currentStage = HighQualityJobStage.normalizingSource
        var workflowLease: HeavyweightWorkflowLease?

        do {
            progress(.init(
                stage: .normalizingSource,
                fraction: 0.05,
                message: "Loading saved source audio…"
            ))
            let samples = try await services.loadSource(sourceURL)
            let sourceAudioSHA256 = Self.audioSHA256(samples)
            guard Self.matchesSavedSource(
                sourceURL,
                samples: samples,
                sha256: sourceAudioSHA256,
                result: previous
            ) else {
                throw HighQualityJobError(
                    stage: .source,
                    message: "The selected source no longer matches the saved result.",
                    resultDirectory: saved.directory
                )
            }
            try Task.checkCancellation()
            let sourceFinishedAt = now()

            currentStage = .preparingDiarization
            if let gate = services.heavyweightGate {
                workflowLease = try await gate.beginWorkflow(.offline(saved.id))
            }
            let exclusive = previousDiarization.useExclusiveReconciliation ?? false
            var alignedItems = alignment.chunks.flatMap(\.rawItems)
            if alignedItems.isEmpty {
                alignedItems = alignment.mergedCues.map {
                    HighQualityAlignmentItem(
                        cueID: $0.id,
                        text: $0.text,
                        start: $0.start,
                        end: $0.end
                    )
                }
            }
            let analysis: HighQualitySpeakerAnalysis
            var diarizationStartedAt: Date?
            do {
                analysis = try await analyzeSpeakers(
                    services: services,
                    workflowLease: workflowLease,
                    samples: samples,
                    alignedItems: alignedItems,
                    duration: alignment.sourceDuration,
                    useExclusiveReconciliation: exclusive,
                    configuration: configuration,
                    sourceJobID: saved.id,
                    processingDiarization: {
                        diarizationStartedAt = now()
                        currentStage = .diarizing
                    }
                ) { stage, fraction, message in
                    progress(.init(
                        stage: stage,
                        fraction: stage == .preparingDiarization
                            ? 0.2 + fraction * 0.2 : 0.45,
                        message: stage == .diarizing ? "Reanalyzing speakers…" : message
                    ))
                }
            } catch let failure as HighQualitySpeakerAnalysisFailure {
                if failure.cancelled { throw CancellationError() }
                throw HighQualityJobError(
                    stage: .diarization,
                    message: failure.message,
                    resultDirectory: saved.directory
                )
            }
            let diarization = analysis.evidence
            guard diarization.modelID == services.diarizationModelID,
                  diarization.revision == services.diarizationRevision,
                  diarization.useExclusiveReconciliation == exclusive,
                  diarization.speakerCountPolicy == configuration.countPolicy else {
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit did not preserve the requested configuration.",
                    resultDirectory: saved.directory
                )
            }
            if let gate = services.heavyweightGate, let workflowLease {
                try await gate.endWorkflow(workflowLease)
            }
            workflowLease = nil
            try Task.checkCancellation()
            let exportStartedAt = now()

            let attachment = Self.speakerAttachment(
                units: units,
                fragments: fragments,
                mappings: diarization.mappings,
                explicitLabelsByCueID: [:]
            )
            let attachmentEvidence = HighQualitySpeakerAttachmentEvidence(
                semanticUnits: attachment.units
            )
            let turns = previous.turns.map { turn in
                HighQualityTranscriptTurn(
                    id: turn.id,
                    japanese: turn.japanese,
                    english: turn.english,
                    speakerLabel: attachment.labelsByUnitID[turn.id],
                    start: turn.start,
                    end: turn.end
                )
            }
            let labelsByID = Dictionary(uniqueKeysWithValues: turns.compactMap { turn in
                turn.speakerLabel.map { (turn.id, $0) }
            })
            let subtitleCues = previous.subtitleCues.map { cue in
                HighQualitySubtitleCue(
                    id: cue.id,
                    start: cue.start,
                    end: cue.end,
                    text: cue.text,
                    speakerLabel: labelsByID[cue.id],
                    renderedLines: cue.renderedLines
                )
            }
            let deliverables = Set(previous.manifest.deliverables)
            let japaneseTranscript = deliverables.contains(.japaneseTranscript)
                ? Self.transcript(turns, text: \.japanese) : previous.japaneseTranscript
            let englishTranscript = deliverables.contains(.englishTranslationTranscript)
                ? Self.transcript(turns, text: \.english) : nil
            let peakMemoryBytes = analysis.peakMemoryBytes
            let previousReanalyses = previous.evidence.speakerReanalyses ?? []
            func reanalysis(payloadPreparedAt: Date) -> HighQualitySpeakerReanalysisEvidence {
                HighQualitySpeakerReanalysisEvidence(
                    startedAt: startedAt,
                    payloadPreparedAt: payloadPreparedAt,
                    preCommitWallTime: payloadPreparedAt.timeIntervalSince(startedAt),
                    configuration: configuration,
                    modelEvents: analysis.modelEvents,
                    peakMemoryBytes: peakMemoryBytes,
                    replacedDiarization: previousDiarization,
                    replacedAttachment: previous.evidence.speakerAttachment
                        ?? .init(semanticUnits: units),
                    replacedSpeakerEdits: replacedSpeakerEdits,
                    diarization: diarization,
                    attachment: attachmentEvidence
                )
            }

            var manifest = previous.manifest
            manifest.schemaVersion = HighQualityJobManifest.currentSchemaVersion
            manifest.speakerConfiguration = configuration
            manifest.speakerCountPolicy = configuration.countPolicy
            let diarizationBoundary = diarizationStartedAt ?? exportStartedAt
            manifest.stageDurations[.normalizingSource, default: 0] +=
                sourceFinishedAt.timeIntervalSince(rawStartedAt)
            manifest.stageDurations[.preparingDiarization, default: 0] +=
                diarizationBoundary.timeIntervalSince(sourceFinishedAt)
            manifest.stageDurations[.diarizing, default: 0] +=
                exportStartedAt.timeIntervalSince(diarizationBoundary)
            manifest.peakMemoryBytes = max(manifest.peakMemoryBytes, peakMemoryBytes)
            manifest.modelEvents += analysis.modelEvents
            manifest.speakerReanalysisCount = previousReanalyses.count + 1
            manifest.speakerEdits = []

            var evidence = previous.evidence
            evidence.speakerConfiguration = configuration
            evidence.speakerCountPolicy = configuration.countPolicy
            evidence.diarization = diarization
            evidence.speakerAttachment = attachmentEvidence
            evidence.sourceAudioSHA256 = sourceAudioSHA256
            evidence.peakMemoryBytes = manifest.peakMemoryBytes
            evidence.modelEvents = manifest.modelEvents
            evidence.resultTurns = turns
            evidence.subtitleCues = subtitleCues
            evidence.japaneseTranscript = japaneseTranscript
            evidence.englishTranscript = englishTranscript

            currentStage = .exporting
            progress(.init(
                stage: .exporting,
                fraction: 0.9,
                message: "Replacing speaker results atomically…"
            ))
            try Task.checkCancellation()
            func payload(
                payloadPreparedAt: Date,
                exportingDuration: TimeInterval
            ) throws -> (
                evidence: Data,
                manifest: Data,
                result: HighQualityJobResult
            ) {
                var finalizedManifest = manifest
                finalizedManifest.stageDurations[.exporting, default: 0] +=
                    exportingDuration
                var finalizedEvidence = evidence
                finalizedEvidence.stageDurations = finalizedManifest.stageDurations
                finalizedEvidence.speakerReanalyses = previousReanalyses
                    + [reanalysis(payloadPreparedAt: payloadPreparedAt)]
                let evidenceData = try Self.encoder.encode(finalizedEvidence)
                finalizedManifest.rawEvidenceSHA256 = Self.sha256(evidenceData)
                let manifestData = try Self.encoder.encode(finalizedManifest)
                return (
                    evidenceData,
                    manifestData,
                    HighQualityJobResult(
                        directory: saved.directory,
                        japaneseTranscript: japaneseTranscript,
                        englishTranscript: englishTranscript,
                        turns: turns,
                        subtitleCues: subtitleCues,
                        manifest: try Self.decoder.decode(
                            HighQualityJobManifest.self,
                            from: manifestData
                        ),
                        evidence: try Self.decoder.decode(
                            HighQualityRawEvidence.self,
                            from: evidenceData
                        )
                    )
                )
            }
            let provisional = try payload(
                payloadPreparedAt: Self.persistedDate(exportStartedAt),
                exportingDuration: 0
            )
            var committedResult = provisional.result
            var payloadPreparedAt = exportStartedAt
            func completion(
                finishedAt: Date,
                auditError: String? = nil
            ) -> HighQualitySpeakerReanalysisCompletion {
                .init(
                    reanalysisCount: committedResult.manifest.speakerReanalysisCount ?? 0,
                    rawEvidenceSHA256: committedResult.manifest.rawEvidenceSHA256 ?? "",
                    startedAt: startedAt,
                    payloadPreparedAt: payloadPreparedAt,
                    finishedAt: finishedAt,
                    wallTime: finishedAt.timeIntervalSince(startedAt),
                    commitWallTime: finishedAt.timeIntervalSince(payloadPreparedAt),
                    auditError: auditError
                )
            }
            var files = Self.deliverableFiles(
                japaneseTranscript: deliverables.contains(.japaneseTranscript)
                    ? japaneseTranscript : nil,
                englishTranscript: englishTranscript,
                subtitleCues: deliverables.contains(.englishSubtitles) ? subtitleCues : nil
            )
            files["raw-asr.json"] = provisional.evidence
            files["manifest.json"] = provisional.manifest
            if let transformations {
                files["transformations.json"] = try Self.encoder.encode(
                    HighQualityResultTransformations(
                        schemaVersion: HighQualityResultTransformations.currentSchemaVersion,
                        customSpeakerLabels: [:],
                        relocatedSourcePath: transformations.relocatedSourcePath
                    )
                )
            }
            try Self.transactionallyWrite(
                files,
                in: saved.directory,
                beforeCommit: {
                    try Task.checkCancellation()
                    try beforeCommit()
                },
                finalizeBeforeCommit: {
                    let rawPayloadPreparedAt = now()
                    payloadPreparedAt = Self.persistedDate(rawPayloadPreparedAt)
                    let finalized = try payload(
                        payloadPreparedAt: payloadPreparedAt,
                        exportingDuration: rawPayloadPreparedAt.timeIntervalSince(exportStartedAt)
                    )
                    committedResult = finalized.result
                    return [
                        "raw-asr.json": finalized.evidence,
                        "manifest.json": finalized.manifest,
                        "speaker-reanalysis-journal.json": try Self
                            .speakerReanalysisJournalData(
                                upserting: completion(
                                    finishedAt: payloadPreparedAt,
                                    auditError: "End-to-end completion audit is pending."
                                ),
                                in: saved.directory
                            ),
                    ]
                },
                afterCommit: {
                    var finishedAt: Date?
                    do {
                        try beforeCompletionAudit()
                        let recordedAt = Self.persistedDate(now())
                        finishedAt = recordedAt
                        let recorded = completion(finishedAt: recordedAt)
                        try Self.writeSpeakerReanalysisCompletion(
                            recorded,
                            in: saved.directory,
                            write: writeCompletionAudit
                        )
                        committedResult = committedResult
                            .withSpeakerReanalysisCompletion(recorded)
                    } catch {
                        let message = "End-to-end completion audit failed: "
                            + error.localizedDescription
                        let failure = completion(
                            finishedAt: finishedAt ?? Self.persistedDate(now()),
                            auditError: message
                        )
                        try? Self.writeSpeakerReanalysisCompletion(
                            failure,
                            in: saved.directory
                        )
                        throw HighQualityJobError(
                            stage: .export,
                            message: "Speaker results were committed, but the completion audit failed. "
                                + error.localizedDescription,
                            resultDirectory: saved.directory
                        )
                    }
                },
                validateActive: {
                    guard try Self.activeResultMatches(
                        previous.manifest,
                        transformations: transformations,
                        in: saved.directory
                    ) else {
                        throw HighQualityJobError(
                            stage: .export,
                            message: "The saved Speaker result changed during reanalysis. Reopen it and try again.",
                            resultDirectory: saved.directory
                        )
                    }
                }
            )
            progress(.init(stage: .completed, fraction: 1, message: "Speakers reanalyzed"))
            return committedResult
        } catch {
            var cleanupMessage: String?
            if let gate = services.heavyweightGate, let workflowLease {
                do {
                    try await gate.endWorkflow(workflowLease)
                } catch {
                    cleanupMessage = cleanupMessage ?? error.localizedDescription
                }
            }
            let stage: HighQualityJobFailureStage
            if error is CancellationError || Task.isCancelled {
                stage = .cancelled
            } else {
                switch currentStage {
                case .normalizingSource: stage = .source
                case .preparingDiarization, .diarizing: stage = .diarization
                case .exporting: stage = .export
                default: stage = .application
                }
            }
            let message = error is CancellationError || Task.isCancelled
                ? "Speaker reanalysis cancelled."
                : error.localizedDescription
            throw HighQualityJobError(
                stage: stage,
                message: cleanupMessage.map { message + " " + $0 } ?? message,
                resultDirectory: saved.directory
            )
        }
    }

    func run(
        _ request: HighQualityJobRequest,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
    ) async throws -> HighQualityJobResult {
        guard let project = request.project else {
            return try await runUncoordinated(request, progress: progress)
        }
        return try await HighQualityProjectLifecycle.shared.run(projectID: project.id) {
            try await runUncoordinated(request, progress: progress)
        }
    }

    private func runUncoordinated(
        _ request: HighQualityJobRequest,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void
    ) async throws -> HighQualityJobResult {
        if let project = request.project {
            do {
                try project.validateForJob()
            } catch {
                throw HighQualityJobError(
                    stage: .application,
                    message: error.localizedDescription,
                    resultDirectory: nil
                )
            }
        }
        let isYouTubeSource = !request.sourceURL.isFileURL
        let needsSubtitles = request.deliverables.contains(.englishSubtitles)
        let needsTranslation = request.deliverables.contains(.englishTranslationTranscript)
            || needsSubtitles
        let needsAlignment = needsTranslation || request.speakerLabels
        guard !request.deliverables.isEmpty else {
            throw HighQualityJobError(
                stage: .application,
                message: "Select at least one Deliverable before starting.",
                resultDirectory: nil
            )
        }
        guard !request.readableSubtitles || needsSubtitles else {
            throw HighQualityJobError(
                stage: .application,
                message: "Readable subtitles require English WebVTT and SRT subtitles.",
                resultDirectory: nil
            )
        }
        if isYouTubeSource {
            try Self.validateYouTubeURL(request.sourceURL)
        }

        let directory = request.outputRoot.appendingPathComponent(
            request.id.uuidString,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: request.outputRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch {
            throw HighQualityJobError(
                stage: .application,
                message: FileManager.default.fileExists(atPath: directory.path)
                    ? "A High-quality job destination already exists for this identifier."
                    : "Could not reserve the job result directory: \(error.localizedDescription)",
                resultDirectory: directory
            )
        }
        if let project = request.project {
            do {
                try project.indexJob(
                    id: request.id,
                    source: Self.provenance(for: request.sourceURL),
                    resultDirectory: directory
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw HighQualityJobError(
                    stage: .application,
                    message: "Could not index the Project job: \(error.localizedDescription)",
                    resultDirectory: nil
                )
            }
        }
        let services = servicesForSelection(request.backend, request.translator)
        let translationModel = request.translator.model

        let startedAt = Date()
        var currentStage = HighQualityJobStage.validating
        var stageStartedAt = startedAt
        var sampleCount = 0
        var sourceAudioSHA256: String?
        var rawASR: String?
        var adaptiveASR: HighQualityAdaptiveASRAudit?
        var glossary = HighQualityGlossarySelection.empty
        var japaneseTranscriptWritten = false
        var englishTranscriptWritten = false
        var subtitlesWritten = false
        var alignmentEvidence: HighQualityAlignmentEvidence?
        var diarizationEvidence: HighQualityDiarizationEvidence?
        var speakerAttachmentEvidence: HighQualitySpeakerAttachmentEvidence?
        var alignedItems: [HighQualityAlignmentItem] = []
        var translationEvidence: HighQualityTranslationEvidence?
        var readableSubtitleEvidence: HighQualityReadableSubtitleEvidence?
        var acquiredAudioURL: URL?
        var asrLoadStarted = false
        var asrUnloaded = false
        var alignmentLoadStarted = false
        var alignmentUnloaded = false
        var translationLoadStarted = false
        var translationUnloaded = false
        var workflowLease: HeavyweightWorkflowLease?
        var asrLease: HeavyweightModelLease?
        var alignmentLease: HeavyweightModelLease?
        var translationLease: HeavyweightModelLease?
        var memorySampler: Task<UInt64, Never>?
        var cleanupFailureMessage: String?
        var manifest = HighQualityJobManifest(
            schemaVersion: HighQualityJobManifest.currentSchemaVersion,
            jobID: request.id,
            status: .failed,
            source: Self.provenance(for: request.sourceURL),
            deliverables: request.deliverables.sorted { $0.rawValue < $1.rawValue },
            selectedBackend: request.backend,
            selectedASRMode: request.asrMode,
            translationModel: needsTranslation ? translationModel : nil,
            speakerLabels: request.speakerLabels || !request.speakerLabelsByCueID.isEmpty,
            readableSubtitles: request.readableSubtitles ? true : nil,
            speakerConfiguration: request.speakerConfiguration,
            speakerCountPolicy: request.speakerCountPolicy,
            dependencies: (isYouTubeSource ? [.sourceAcquisition] : [])
                + [.sourceNormalization, .japaneseASR]
                + (needsAlignment ? [.forcedAlignment] : [])
                + (request.speakerLabels ? [.speakerDiarization] : [])
                + (needsTranslation ? [.llmTranslation] : [])
                + [.export],
            model: request.backend.model,
            startedAt: startedAt,
            finishedAt: nil,
            stageDurations: [:],
            peakMemoryBytes: 0,
            modelEvents: [],
            failures: [],
            generatedFiles: []
        )
        manifest.projectID = request.project?.id

        func begin(_ stage: HighQualityJobStage, fraction: Double, message: String) {
            let now = Date()
            if currentStage != .validating {
                manifest.stageDurations[currentStage, default: 0] += now.timeIntervalSince(stageStartedAt)
            }
            currentStage = stage
            stageStartedAt = now
            progress(.init(stage: stage, fraction: fraction, message: message))
        }

        func acquireModel(_ modelID: String, peak: UInt64) async throws -> HeavyweightModelLease? {
            guard let gate = services.heavyweightGate, let workflowLease else { return nil }
            return try await gate.acquireModel(
                workflow: workflowLease,
                modelID: modelID,
                declaredPeakBytes: peak
            )
        }

        func markLoaded(_ lease: HeavyweightModelLease?) async throws {
            guard let gate = services.heavyweightGate, let lease else { return }
            try await gate.markLoaded(lease)
        }

        @Sendable func withMemoryGuard<T: Sendable>(
            _ lease: HeavyweightModelLease?,
            operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            guard let gate = services.heavyweightGate, let lease else {
                return try await operation()
            }
            return try await gate.withMemoryGuard(lease, operation: operation)
        }

        func transcribeAdaptiveSegment(
            _ segment: HighQualityAdaptiveASRSegment,
            samples: [Float],
            using segmentServices: Services,
            lease: HeavyweightModelLease?
        ) async throws -> (exchange: HighQualityASRExchange, duration: TimeInterval) {
            try Task.checkCancellation()
            let started = Date()
            let exchange = try await withMemoryGuard(lease) {
                try await segmentServices.transcribeJapaneseEvidence(
                    Array(samples[segment.startSample..<segment.endSample])
                )
            }
            return (exchange, Date().timeIntervalSince(started))
        }

        func releaseModel(
            _ lease: HeavyweightModelLease?,
            unload: @escaping @Sendable () async -> Void
        ) async throws -> (
            releasedMemoryBytes: UInt64,
            evidence: HeavyweightModelMemoryEvidence
        )? {
            guard let gate = services.heavyweightGate, let lease else {
                await unload()
                return nil
            }
            let evidence = try await gate.memoryEvidence(lease)
            let releasedMemoryBytes = try await gate.releaseModel(lease, unload: unload)
            return (releasedMemoryBytes, evidence)
        }

        func releaseMessage(
            _ release: (releasedMemoryBytes: UInt64, evidence: HeavyweightModelMemoryEvidence)
        ) -> String {
            "memory=\(release.releasedMemoryBytes) runtimePeak=\(release.evidence.peakMemoryBytes) minimumAvailable=\(release.evidence.minimumAvailableMemoryBytes) maximum=\(release.evidence.maximumMemoryBytes) reserve=\(release.evidence.reserveBytes)"
        }

        func runAdaptivePass(
            backend: HighQualityASRBackend,
            segments: [HighQualityAdaptiveASRSegment],
            samples: [Float],
            prepareFraction: Double,
            transcribeFraction: Double
        ) async -> (
            results: [String: (HighQualityASRExchange, TimeInterval)],
            errors: [String: HighQualityAdaptiveASRErrorEvidence],
            fatalError: (any Error)?,
            worker: HighQualityASRWorkerEvidence?
        ) {
            guard !segments.isEmpty else { return ([:], [:], nil, nil) }
            let candidate = servicesForSelection(backend, request.translator)
            let stage = backend.rawValue
            var lease: HeavyweightModelLease?
            var results: [String: (HighQualityASRExchange, TimeInterval)] = [:]
            var errors: [String: HighQualityAdaptiveASRErrorEvidence] = [:]
            var fatalError: (any Error)?
            begin(
                .preparingASR,
                fraction: prepareFraction,
                message: "Preparing \(backend.displayName) for targeted passages…"
            )
            do {
                lease = try await acquireModel(
                    backend.model.modelID,
                    peak: backend.declaredPeakMemoryBytes
                )
                if let lease {
                    manifest.modelEvents.append(.init(
                        kind: .pressureChecked,
                        backend: backend,
                        at: Date(),
                        message: "policy=macos-memory-pressure peak=\(lease.declaredPeakBytes) reserve=\(lease.reserveBytes) total=\(lease.totalMemoryBytes) available=\(lease.availableMemoryBytes) baseline=\(lease.baselineMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    backend: backend,
                    at: Date()
                ))
                try await withMemoryGuard(lease) {
                    try await candidate.prepareASR { fraction, message in
                        progress(.init(
                            stage: .preparingASR,
                            fraction: prepareFraction + min(max(fraction, 0), 1) * 0.03,
                            message: message
                        ))
                    }
                }
                try await markLoaded(lease)
                manifest.modelEvents.append(.init(
                    kind: .loadCompleted,
                    backend: backend,
                    at: Date()
                ))
                begin(
                    .transcribing,
                    fraction: transcribeFraction,
                    message: "Checking targeted passages with \(backend.displayName)…"
                )
                for segment in segments {
                    do {
                        let result = try await transcribeAdaptiveSegment(
                            segment,
                            samples: samples,
                            using: candidate,
                            lease: lease
                        )
                        results[segment.id] = (result.exchange, result.duration)
                    } catch is CancellationError {
                        fatalError = CancellationError()
                        break
                    } catch {
                        let route = HighQualityAdaptiveASR.route(error)
                        errors[segment.id] = .init(
                            route: route,
                            stage: "\(stage)-transcription",
                            segmentID: segment.id,
                            message: error.localizedDescription,
                            candidateReason: HighQualityAdaptiveASR.candidateReason(error)
                        )
                        if route == .infrastructure {
                            fatalError = error
                            break
                        }
                    }
                }
            } catch {
                let route = HighQualityAdaptiveASR.route(error)
                for segment in segments where results[segment.id] == nil {
                    errors[segment.id] = .init(
                        route: route,
                        stage: "\(stage)-preparation",
                        segmentID: segment.id,
                        message: error.localizedDescription,
                        candidateReason: HighQualityAdaptiveASR.candidateReason(error)
                    )
                }
                if error is CancellationError || route == .infrastructure {
                    fatalError = error
                }
            }
            if let fatalError {
                for segment in segments
                where results[segment.id] == nil && errors[segment.id] == nil {
                    errors[segment.id] = .init(
                        route: .infrastructure,
                        stage: "\(stage)-aborted",
                        segmentID: segment.id,
                        message: fatalError.localizedDescription
                    )
                }
            }
            do {
                let release = try await releaseModel(lease, unload: candidate.unloadASR)
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    backend: backend,
                    at: Date()
                ))
                if let release {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        release.evidence.peakMemoryBytes
                    )
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        backend: backend,
                        at: Date(),
                        message: releaseMessage(release)
                    ))
                }
            } catch {
                await candidate.unloadASR()
                let evidence = HighQualityAdaptiveASRErrorEvidence(
                    route: .infrastructure,
                    stage: "\(stage)-unload",
                    segmentID: nil,
                    message: error.localizedDescription
                )
                for segment in segments where results[segment.id] == nil {
                    errors[segment.id] = evidence
                }
                fatalError = error
            }
            let worker = await candidate.asrWorkerEvidence()
            if let worker {
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    worker.lifecycle.peakPhysicalFootprintBytes
                )
            }
            return (results, errors, fatalError, worker)
        }

        func recordAdaptiveAudit(
            decisions: [HighQualityAdaptiveASRDecision],
            workers: [HighQualityASRWorkerEvidence]
        ) {
            adaptiveASR = .init(
                schemaVersion: HighQualityAdaptiveASRAudit.currentSchemaVersion,
                calibration: request.adaptiveCalibration,
                decisions: decisions,
                workers: workers,
                qwenDuration: decisions.reduce(0) { $0 + $1.qwenDuration },
                parakeetDuration: decisions.compactMap(\.parakeetDuration).reduce(0, +),
                whisperKitDuration: decisions.compactMap(\.whisperKitDuration).reduce(0, +),
                peakMemoryBytes: manifest.peakMemoryBytes,
                errors: decisions.flatMap {
                    [$0.error, $0.whisperKitError].compactMap { $0 }
                }
            )
        }

        func recordASRWorkerEvidence() async {
            guard let evidence = await services.asrWorkerEvidence() else { return }
            manifest.asrWorker = evidence
            manifest.model = evidence.model
            manifest.peakMemoryBytes = max(
                manifest.peakMemoryBytes,
                evidence.lifecycle.peakPhysicalFootprintBytes
            )
        }

        func rejectTerminalCriticalPressure(
            _ evidence: HighQualityWorkerEvidence?,
            stage: String
        ) throws {
            guard evidence?.pressureTransitions.contains(where: { $0.level == .critical }) == true
            else { return }
            throw HighQualityAlignmentSpeakerWorkerError.criticalMemoryPressure(stage: stage)
        }

        func cleanupModel(
            _ lease: HeavyweightModelLease?,
            modelID: String,
            unload: @escaping @Sendable () async -> Void
        ) async {
            do {
                let release = try await releaseModel(lease, unload: unload)
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: modelID,
                    at: Date()
                ))
                if let release {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        release.evidence.peakMemoryBytes
                    )
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: modelID,
                        at: Date(),
                        message: releaseMessage(release)
                    ))
                }
            } catch let gateError as HeavyweightModelGateError {
                cleanupFailureMessage = gateError.localizedDescription
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: modelID,
                    at: Date()
                ))
                manifest.modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: modelID,
                    at: Date(),
                    message: gateError.localizedDescription
                ))
            } catch {
                cleanupFailureMessage = error.localizedDescription
                manifest.modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: modelID,
                    at: Date(),
                    message: error.localizedDescription
                ))
            }
        }

        do {
            guard request.speakerConfiguration.isValid else {
                throw HighQualityJobError(
                    stage: .application,
                    message: "Expected speaker count must be an integer from 1 through 20.",
                    resultDirectory: directory
                )
            }
            guard request.speakerLabels || request.speakerConfiguration == .standard else {
                throw HighQualityJobError(
                    stage: .application,
                    message: "SpeakerKit beta settings require Speaker labels.",
                    resultDirectory: directory
                )
            }
            if let gate = services.heavyweightGate {
                workflowLease = try await gate.beginWorkflow(.offline(request.id))
            }
            var normalizedSourceURL = request.sourceURL
            if isYouTubeSource {
                begin(.acquiringSource, fraction: 0.02, message: "Acquiring YouTube audio…")
                let acquisitionDirectory = directory.appendingPathComponent(
                    "acquisition",
                    isDirectory: true
                )
                do {
                    let acquisition = try await services.acquireYouTube(
                        request.sourceURL,
                        acquisitionDirectory
                    )
                    normalizedSourceURL = acquisition.audioURL
                    acquiredAudioURL = acquisition.audioURL
                    manifest.source = Self.provenance(
                        for: acquisition.audioURL,
                        youtube: acquisition.evidence
                    )
                    try Task.checkCancellation()
                } catch let error as YouTubeAcquisitionError {
                    manifest.source = Self.provenance(
                        for: request.sourceURL,
                        youtube: .init(
                            sourceURL: request.sourceURL.absoluteString,
                            title: "",
                            channel: "",
                            description: "",
                            ytDLPVersion: error.ytDLPVersion ?? "",
                            diagnostics: error.diagnostics
                        )
                    )
                    if acquiredAudioURL == nil {
                        try? FileManager.default.removeItem(at: acquisitionDirectory)
                    }
                    throw error
                } catch {
                    if acquiredAudioURL == nil {
                        try? FileManager.default.removeItem(at: acquisitionDirectory)
                    }
                    throw error
                }
            }

            begin(.normalizingSource, fraction: 0.05, message: "Normalizing source audio…")
            let samples = try await services.loadSource(normalizedSourceURL)
            sampleCount = samples.count
            sourceAudioSHA256 = Self.audioSHA256(samples)
            try Task.checkCancellation()

            begin(
                .preparingASR,
                fraction: 0.2,
                message: "Preparing \(request.backend.displayName)…"
            )
            memorySampler = Task {
                var peak = await services.currentMemoryBytes()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    peak = max(peak, await services.currentMemoryBytes())
                }
                return max(peak, await services.currentMemoryBytes())
            }
            asrLoadStarted = true
            asrLease = try await acquireModel(
                request.backend.model.modelID,
                peak: request.backend.declaredPeakMemoryBytes
            )
            if let asrLease {
                manifest.modelEvents.append(.init(
                    kind: .pressureChecked,
                    backend: request.backend,
                    at: Date(),
                    message: "policy=macos-memory-pressure peak=\(asrLease.declaredPeakBytes) reserve=\(asrLease.reserveBytes) total=\(asrLease.totalMemoryBytes) available=\(asrLease.availableMemoryBytes) baseline=\(asrLease.baselineMemoryBytes)"
                ))
            }
            manifest.modelEvents.append(.init(
                kind: .loadStarted,
                backend: request.backend,
                at: Date()
            ))
            try await withMemoryGuard(asrLease) {
                try await services.prepareASR { fraction, message in
                    progress(.init(
                        stage: .preparingASR,
                        fraction: 0.2 + min(max(fraction, 0), 1) * 0.25,
                        message: message
                    ))
                }
            }
            try await markLoaded(asrLease)
            manifest.modelEvents.append(.init(
                kind: .loadCompleted,
                backend: request.backend,
                at: Date()
            ))
            try Task.checkCancellation()

            begin(.transcribing, fraction: 0.5, message: "Transcribing Japanese…")
            var adaptiveQwenResults: [(
                segment: HighQualityAdaptiveASRSegment,
                exchange: HighQualityASRExchange,
                duration: TimeInterval
            )] = []
            var asrExchange: HighQualityASRExchange
            if request.asrMode == .adaptiveQwenParakeet {
                for segment in HighQualityAdaptiveASR.plan(samples: samples) {
                    let result = try await transcribeAdaptiveSegment(
                        segment,
                        samples: samples,
                        using: services,
                        lease: asrLease
                    )
                    adaptiveQwenResults.append((
                        segment,
                        result.exchange,
                        result.duration
                    ))
                }
                asrExchange = HighQualityAdaptiveASR.compose(adaptiveQwenResults.map {
                    HighQualityAdaptiveASR.decide(
                        segment: $0.segment,
                        qwen: $0.exchange,
                        qwenDuration: $0.duration,
                        parakeet: nil,
                        parakeetDuration: nil,
                        scopedTerms: request.adaptiveScopedTerms,
                        calibration: request.adaptiveCalibration
                    )
                })
            } else if needsAlignment {
                asrExchange = try await withMemoryGuard(asrLease) {
                    try await services.transcribeJapaneseAnchored(samples)
                }
            } else {
                let transcript = try await withMemoryGuard(asrLease) {
                    try await services.transcribeJapanese(samples)
                }
                asrExchange = .init(rawTranscript: transcript, chunks: [])
            }
            rawASR = asrExchange.rawTranscript
            if request.asrMode != .adaptiveQwenParakeet {
                guard !asrExchange.rawTranscript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else { throw LocalPrototypeError.invalidResponse }
            }
            try Task.checkCancellation()

            asrUnloaded = true
            let asrRelease = try await releaseModel(asrLease, unload: services.unloadASR)
            asrLease = nil
            await recordASRWorkerEvidence()
            manifest.modelEvents.append(.init(
                kind: .unloadCompleted,
                backend: request.backend,
                at: Date()
            ))
            if let asrRelease {
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    asrRelease.evidence.peakMemoryBytes
                )
                manifest.modelEvents.append(.init(
                    kind: .memoryReleaseChecked,
                    backend: request.backend,
                    at: Date(),
                    message: releaseMessage(asrRelease)
                ))
            }
            if request.asrMode == .adaptiveQwenParakeet {
                var workers = manifest.asrWorker.map { [$0] } ?? []
                let suspects = adaptiveQwenResults.filter {
                    HighQualityAdaptiveASR.assess(
                        exchange: $0.exchange,
                        segment: $0.segment,
                        scopedTerms: request.adaptiveScopedTerms
                    ).isSuspect
                }
                let parakeetPass = await runAdaptivePass(
                    backend: .parakeetJA,
                    segments: suspects.map(\.segment),
                    samples: samples,
                    prepareFraction: 0.53,
                    transcribeFraction: 0.56
                )
                if let worker = parakeetPass.worker { workers.append(worker) }
                let provisionalDecisions = adaptiveQwenResults.map { qwen in
                    let alternate = parakeetPass.results[qwen.segment.id]
                    return HighQualityAdaptiveASR.decide(
                        segment: qwen.segment,
                        qwen: qwen.exchange,
                        qwenDuration: qwen.duration,
                        parakeet: alternate?.0,
                        parakeetDuration: alternate?.1,
                        scopedTerms: request.adaptiveScopedTerms,
                        calibration: request.adaptiveCalibration,
                        alternateError: parakeetPass.errors[qwen.segment.id]
                    )
                }
                if let fatalError = parakeetPass.fatalError {
                    recordAdaptiveAudit(decisions: provisionalDecisions, workers: workers)
                    throw fatalError
                }
                let whisperKitIDs = Set(provisionalDecisions.compactMap { decision in
                    decision.whisperKitLaunch?.shouldLaunch == true
                        ? decision.segment.id : nil
                })
                let whisperKitSegments = adaptiveQwenResults.compactMap {
                    whisperKitIDs.contains($0.segment.id) ? $0.segment : nil
                }
                let whisperKitPass: (
                    results: [String: (HighQualityASRExchange, TimeInterval)],
                    errors: [String: HighQualityAdaptiveASRErrorEvidence],
                    fatalError: (any Error)?,
                    worker: HighQualityASRWorkerEvidence?
                ) = await runAdaptivePass(
                    backend: .whisperKit,
                    segments: whisperKitSegments,
                    samples: samples,
                    prepareFraction: 0.58,
                    transcribeFraction: 0.61
                )
                if let worker = whisperKitPass.worker { workers.append(worker) }
                let decisions = adaptiveQwenResults.map { qwen in
                    let alternate = parakeetPass.results[qwen.segment.id]
                    let whisperKit = whisperKitPass.results[qwen.segment.id]
                    return HighQualityAdaptiveASR.decide(
                        segment: qwen.segment,
                        qwen: qwen.exchange,
                        qwenDuration: qwen.duration,
                        parakeet: alternate?.0,
                        parakeetDuration: alternate?.1,
                        whisperKit: whisperKit?.0,
                        whisperKitDuration: whisperKit?.1,
                        scopedTerms: request.adaptiveScopedTerms,
                        calibration: request.adaptiveCalibration,
                        alternateError: parakeetPass.errors[qwen.segment.id],
                        whisperKitError: whisperKitPass.errors[qwen.segment.id]
                    )
                }
                recordAdaptiveAudit(decisions: decisions, workers: workers)
                if let fatalError = whisperKitPass.fatalError { throw fatalError }
                asrExchange = HighQualityAdaptiveASR.compose(decisions)
                memorySampler?.cancel()
                if let memorySampler {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        await memorySampler.value
                    )
                }
                memorySampler = nil
            } else {
                memorySampler?.cancel()
                if let memorySampler {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        await memorySampler.value
                    )
                }
                memorySampler = nil
            }
            let rawTranscript = asrExchange.rawTranscript
            rawASR = rawTranscript
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw LocalPrototypeError.invalidResponse }
            try Task.checkCancellation()
            let baseTurns = Self.translationTurns(
                from: transcript,
                asrChunks: asrExchange.chunks,
                speakerLabelsByCueID: request.speakerLabelsByCueID
            )
            var turns = baseTurns
            if needsAlignment {
                begin(.preparingAlignment, fraction: 0.62, message: "Preparing forced alignment…")
                alignmentLoadStarted = true
                let duration = Double(samples.count) / 16_000
                alignmentEvidence = .init(
                    modelID: services.alignmentModelID,
                    revision: services.alignmentRevision,
                    chunks: [],
                    mergedCues: [],
                    sourceDuration: duration,
                    peakMemoryBytes: 0,
                    validationDiagnostics: []
                )
                alignmentLease = try await acquireModel(
                    services.alignmentModelID,
                    peak: services.alignmentDeclaredPeakMemoryBytes
                )
                if let alignmentLease {
                    manifest.modelEvents.append(.init(
                        kind: .pressureChecked,
                        modelID: services.alignmentModelID,
                        at: Date(),
                        message: "policy=macos-memory-pressure peak=\(alignmentLease.declaredPeakBytes) reserve=\(alignmentLease.reserveBytes) total=\(alignmentLease.totalMemoryBytes) available=\(alignmentLease.availableMemoryBytes) baseline=\(alignmentLease.baselineMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: services.alignmentModelID,
                    at: Date()
                ))
                try await withMemoryGuard(alignmentLease) {
                    try await services.prepareAlignment { fraction, message in
                        progress(.init(
                            stage: .preparingAlignment,
                            fraction: 0.62 + min(max(fraction, 0), 1) * 0.08,
                            message: message
                        ))
                    }
                }
                try await markLoaded(alignmentLease)
                manifest.modelEvents.append(.init(
                    kind: .loadCompleted,
                    modelID: services.alignmentModelID,
                    at: Date()
                ))
                try Task.checkCancellation()
                begin(.aligning, fraction: 0.7, message: "Aligning Japanese transcript…")
                let exchange = try await withMemoryGuard(alignmentLease) {
                    try await services.alignJapanese(samples, baseTurns)
                }
                alignmentEvidence = .init(
                    modelID: exchange.modelID,
                    revision: exchange.revision,
                    chunks: exchange.chunks.sorted { $0.index < $1.index },
                    mergedCues: [],
                    sourceDuration: duration,
                    peakMemoryBytes: exchange.peakMemoryBytes,
                    validationDiagnostics: [],
                    configuration: exchange.configuration,
                    fallbackMerges: exchange.fallbackMerges
                )
                do {
                    let merged = try Self.validatedAlignment(
                        exchange.chunks,
                        turns: baseTurns,
                        duration: duration,
                        fallbackMerges: exchange.fallbackMerges ?? []
                    )
                    var validatedEvidence = HighQualityAlignmentEvidence(
                        modelID: exchange.modelID,
                        revision: exchange.revision,
                        chunks: exchange.chunks.sorted { $0.index < $1.index },
                        mergedCues: merged,
                        sourceDuration: duration,
                        peakMemoryBytes: exchange.peakMemoryBytes,
                        validationDiagnostics: [],
                        configuration: exchange.configuration,
                        fallbackMerges: exchange.fallbackMerges
                    )
                    let semantic = try Self.semanticTranslationUnits(
                        alignment: validatedEvidence,
                        sourceTurns: baseTurns
                    )
                    turns = semantic.turns
                    validatedEvidence.semanticUnitPolicy = semantic.policy
                    validatedEvidence.semanticFragments = semantic.fragments
                    validatedEvidence.semanticUnits = semantic.units
                    alignmentEvidence = validatedEvidence
                } catch {
                    alignmentEvidence?.validationDiagnostics = [error.localizedDescription]
                    throw error
                }
                manifest.peakMemoryBytes = max(manifest.peakMemoryBytes, exchange.peakMemoryBytes)
                alignmentUnloaded = true
                let release = try await releaseModel(
                    alignmentLease,
                    unload: services.unloadAlignment
                )
                alignmentLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: services.alignmentModelID,
                    at: Date()
                ))
                if let release {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        release.evidence.peakMemoryBytes
                    )
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: services.alignmentModelID,
                        at: Date(),
                        message: releaseMessage(release)
                    ))
                }
                alignmentEvidence?.worker = await services.alignmentWorkerEvidence()
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    alignmentEvidence?.worker?.peakPhysicalFootprintBytes ?? 0
                )
                try rejectTerminalCriticalPressure(
                    alignmentEvidence?.worker,
                    stage: "Forced alignment"
                )
                try Task.checkCancellation()
                alignedItems = alignmentEvidence?.chunks.flatMap(\.rawItems) ?? []
                if alignedItems.isEmpty {
                    alignedItems = alignmentEvidence?.mergedCues.map {
                        HighQualityAlignmentItem(
                            cueID: $0.id,
                            text: $0.text,
                            start: $0.start,
                            end: $0.end
                        )
                    } ?? []
                }
            }
            if request.speakerLabels {
                begin(.preparingDiarization, fraction: 0.74, message: "Preparing SpeakerKit…")
                let analysis: HighQualitySpeakerAnalysis
                do {
                    analysis = try await analyzeSpeakers(
                        services: services,
                        workflowLease: workflowLease,
                        samples: samples,
                        alignedItems: alignedItems,
                        duration: Double(samples.count) / 16_000,
                        useExclusiveReconciliation: request.useExclusiveReconciliation,
                        configuration: request.speakerConfiguration,
                        sourceJobID: request.id,
                        processingDiarization: {
                            let startedAt = Date()
                            manifest.stageDurations[currentStage, default: 0] +=
                                startedAt.timeIntervalSince(stageStartedAt)
                            currentStage = .diarizing
                            stageStartedAt = startedAt
                        }
                    ) { stage, fraction, message in
                        progress(.init(
                            stage: stage,
                            fraction: stage == .preparingDiarization
                                ? 0.74 + fraction * 0.04 : 0.78,
                            message: message
                        ))
                    }
                } catch let failure as HighQualitySpeakerAnalysisFailure {
                    diarizationEvidence = failure.evidence
                    manifest.modelEvents += failure.modelEvents
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        failure.peakMemoryBytes
                    )
                    if failure.cancelled { throw CancellationError() }
                    throw HighQualityJobError(
                        stage: .diarization,
                        message: failure.message,
                        resultDirectory: directory
                    )
                }
                diarizationEvidence = analysis.evidence
                manifest.modelEvents += analysis.modelEvents
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    analysis.peakMemoryBytes
                )
            }
            let speakerAttachment = Self.speakerAttachment(
                units: alignmentEvidence?.semanticUnits ?? [],
                fragments: alignmentEvidence?.semanticFragments ?? [],
                mappings: diarizationEvidence?.mappings ?? [],
                explicitLabelsByCueID: request.speakerLabelsByCueID
            )
            speakerAttachmentEvidence = .init(semanticUnits: speakerAttachment.units)
            glossary = HighQualityGlossarySelector.select(
                source: manifest.source,
                turns: turns
            )
            var translationsByID: [String: String] = [:]
            if needsTranslation {
                begin(
                    .translating,
                    fraction: 0.8,
                    message: "Preparing local \(request.translator.displayName)…"
                )
                var translationRequest = HighQualityTranslationBatch(
                    source: manifest.source,
                    turns: turns,
                    glossary: glossary.promptTerms,
                    glossaryByCueID: Dictionary(uniqueKeysWithValues: turns.map {
                        ($0.id, glossary.promptTerms(for: $0.id))
                    })
                )
                let integrityGlossary = glossary.decisions
                    .filter(\.selected)
                    .map { HighQualityTranslationIntegrityGlossaryTerm($0.term) }
                let hardGlossaryTermIDs = Set(glossary.decisions.filter {
                    $0.selected && $0.guidance == .hard
                }.map(\.term.id))
                let integrityGlossaryByCueID = translationRequest.glossaryByCueID.mapValues {
                    $0.map {
                        HighQualityTranslationIntegrityGlossaryTerm(
                            $0,
                            critical: hardGlossaryTermIDs.contains($0.id)
                        )
                    }
                }
                translationEvidence = .init(
                    request: translationRequest,
                    response: nil,
                    model: translationModel.modelID,
                    attempts: [],
                    revision: translationModel.revision,
                    runtimeVersion: translationModel.runtimeVersion,
                    weightSHA256: translationModel.weightSHA256,
                    batches: [],
                    peakMemoryBytes: 0,
                    validationFailures: []
                )
                translationLoadStarted = true
                translationLease = try await acquireModel(
                    translationModel.modelID,
                    peak: request.translator.candidate.declaredPeakMemoryBytes
                )
                if let translationLease {
                    manifest.modelEvents.append(.init(
                        kind: .pressureChecked,
                        modelID: translationModel.modelID,
                        at: Date(),
                        message: "policy=macos-memory-pressure peak=\(translationLease.declaredPeakBytes) reserve=\(translationLease.reserveBytes) total=\(translationLease.totalMemoryBytes) available=\(translationLease.availableMemoryBytes) baseline=\(translationLease.baselineMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: translationModel.modelID,
                    at: Date()
                ))
                do {
                    try await withMemoryGuard(translationLease) {
                        try await services.prepareTranslation { fraction, message in
                            progress(.init(
                                stage: .translating,
                                fraction: 0.8 + min(max(fraction, 0), 1) * 0.04,
                                message: message
                            ))
                        }
                    }
                    try await markLoaded(translationLease)
                    manifest.modelEvents.append(.init(
                        kind: .loadCompleted,
                        modelID: translationModel.modelID,
                        at: Date()
                    ))
                    progress(.init(stage: .translating, fraction: 0.84, message: "Translating to English locally…"))
                    let activeTranslationLease = translationLease
                    let guardedTranslate: @Sendable (
                        HighQualityTranslationBatch
                    ) async throws -> HighQualityTranslationExchange = { batch in
                        try await withMemoryGuard(activeTranslationLease) {
                            try await services.translateEnglish(batch)
                        }
                    }
                    let firstPass = try await Self.firstTranslationPass(
                        request: translationRequest,
                        contextPolicy: request.translationContextPolicy,
                        resetReasons: request.translationContextResetReasonsByCueID,
                        integrityGlossaryByCueID: integrityGlossaryByCueID,
                        fallbackModel: translationModel.modelID,
                        translate: guardedTranslate
                    )
                    translationRequest = firstPass.request
                    let exchange = firstPass.exchange
                    translationEvidence = .init(
                        request: translationRequest,
                        response: exchange.response,
                        model: exchange.model,
                        attempts: exchange.attempts,
                        revision: exchange.revision,
                        runtimeVersion: exchange.runtimeVersion,
                        weightSHA256: translationModel.weightSHA256,
                        batches: exchange.batches,
                        peakMemoryBytes: exchange.peakMemoryBytes,
                        validationFailures: [],
                        integrityVerdicts: HighQualityTranslationIntegrityValidator.validate(
                            turns: turns,
                            batches: exchange.batches,
                            glossary: integrityGlossary,
                            glossaryByCueID: integrityGlossaryByCueID
                        )
                    )
                    do {
                        var selectedTranslations = HighQualityTranslationIntegrityValidator.canonicalized(
                            try Self.validatedTranslations(exchange.response, for: turns),
                            turns: turns,
                            glossaryByCueID: integrityGlossaryByCueID
                        )
                        let firstVerdicts = HighQualityTranslationIntegrityValidator.validate(
                            turns: turns,
                            translations: selectedTranslations,
                            batches: exchange.batches,
                            glossary: integrityGlossary,
                            glossaryByCueID: integrityGlossaryByCueID
                        )
                        let rejected = firstVerdicts.filter { $0.verdict != .pass }
                        var attempts = Self.numberedAttempts(exchange.attempts, startingAt: 1)
                        var batches = Self.annotatedBatches(
                            exchange.batches,
                            verdicts: firstVerdicts,
                            attempt: 1
                        )
                        var finalVerdicts = firstVerdicts
                        var response = try Self.translationResponse(selectedTranslations, for: turns)
                        var peakMemoryBytes = exchange.peakMemoryBytes

                        if !rejected.isEmpty {
                            try Task.checkCancellation()
                            let rejectedIDs = Set(rejected.map(\.cueID))
                            let criticalTermIDs = Set(rejected.flatMap {
                                $0.glossaryOpportunities.filter(\.critical).map(\.id)
                            })
                            let retryIntegrityGlossaryByCueID = integrityGlossaryByCueID.mapValues {
                                $0.filter { criticalTermIDs.contains($0.id) }
                            }
                            let retryRequest = HighQualityTranslationBatch(
                                source: translationRequest.source,
                                turns: turns.filter { rejectedIDs.contains($0.id) },
                                glossary: translationRequest.glossary.filter {
                                    criticalTermIDs.contains($0.id)
                                },
                                glossaryByCueID: Dictionary(uniqueKeysWithValues: turns
                                    .filter { rejectedIDs.contains($0.id) }
                                    .map { turn in
                                        (turn.id, translationRequest.glossary(for: turn).filter {
                                            criticalTermIDs.contains($0.id)
                                        })
                                    }),
                                retryReasonCodes: Dictionary(uniqueKeysWithValues: rejected.map {
                                    ($0.cueID, $0.reasons.map(\.code))
                                })
                            )
                            progress(.init(
                                stage: .translating,
                                fraction: 0.86,
                                message: "Retrying rejected English translation units…"
                            ))
                            let retryExchange: HighQualityTranslationExchange
                            do {
                                retryExchange = try await guardedTranslate(retryRequest)
                            } catch let error as HighQualityTranslationServiceError {
                                let errorVerdicts = HighQualityTranslationIntegrityValidator.validate(
                                    turns: retryRequest.turns,
                                    batches: error.batches,
                                    glossary: integrityGlossary.filter {
                                        criticalTermIDs.contains($0.id)
                                    },
                                    glossaryByCueID: retryIntegrityGlossaryByCueID
                                )
                                attempts += Self.numberedAttempts(
                                    error.attempts,
                                    startingAt: attempts.count + 1
                                )
                                batches += Self.annotatedBatches(
                                    error.batches,
                                    verdicts: errorVerdicts,
                                    attempt: 2,
                                    forceFailure: true
                                )
                                translationEvidence = .init(
                                    request: translationRequest,
                                    response: error.response,
                                    model: error.model,
                                    attempts: attempts,
                                    revision: error.revision,
                                    runtimeVersion: error.runtimeVersion,
                                    weightSHA256: translationModel.weightSHA256,
                                    batches: batches,
                                    peakMemoryBytes: max(peakMemoryBytes, error.peakMemoryBytes),
                                    validationFailures: [error.localizedDescription],
                                    integrityVerdicts: turns.compactMap { turn in
                                        errorVerdicts.first { $0.cueID == turn.id }
                                            ?? firstVerdicts.first { $0.cueID == turn.id }
                                    }
                                )
                                throw error
                            }
                            attempts += Self.numberedAttempts(
                                retryExchange.attempts,
                                startingAt: attempts.count + 1
                            )
                            peakMemoryBytes = max(peakMemoryBytes, retryExchange.peakMemoryBytes)
                            let retryTranslations: [String: String]
                            do {
                                retryTranslations = HighQualityTranslationIntegrityValidator.canonicalized(
                                    try Self.validatedTranslations(
                                        retryExchange.response,
                                        for: retryRequest.turns
                                    ),
                                    turns: retryRequest.turns,
                                    glossaryByCueID: retryIntegrityGlossaryByCueID
                                )
                            } catch {
                                let errorVerdicts = HighQualityTranslationIntegrityValidator.validate(
                                    turns: retryRequest.turns,
                                    batches: retryExchange.batches,
                                    glossary: integrityGlossary.filter {
                                        criticalTermIDs.contains($0.id)
                                    },
                                    glossaryByCueID: retryIntegrityGlossaryByCueID
                                )
                                batches += Self.annotatedBatches(
                                    retryExchange.batches,
                                    verdicts: errorVerdicts,
                                    attempt: 2,
                                    forceFailure: true
                                )
                                let message = error.localizedDescription
                                translationEvidence = .init(
                                    request: translationRequest,
                                    response: retryExchange.response,
                                    model: retryExchange.model,
                                    attempts: attempts,
                                    revision: retryExchange.revision,
                                    runtimeVersion: retryExchange.runtimeVersion,
                                    weightSHA256: translationModel.weightSHA256,
                                    batches: batches,
                                    peakMemoryBytes: peakMemoryBytes,
                                    validationFailures: [message],
                                    integrityVerdicts: turns.compactMap { turn in
                                        errorVerdicts.first { $0.cueID == turn.id }
                                            ?? firstVerdicts.first { $0.cueID == turn.id }
                                    }
                                )
                                throw error
                            }
                            var candidateTranslations = selectedTranslations
                            candidateTranslations.merge(retryTranslations) { _, retry in retry }
                            let retryVerdicts = HighQualityTranslationIntegrityValidator.validate(
                                turns: turns,
                                translations: candidateTranslations,
                                batches: retryExchange.batches,
                                glossary: integrityGlossary,
                                glossaryByCueID: integrityGlossaryByCueID
                            ).filter { rejectedIDs.contains($0.cueID) }
                            batches += Self.annotatedBatches(
                                retryExchange.batches,
                                verdicts: retryVerdicts,
                                attempt: 2
                            )
                            finalVerdicts = turns.compactMap { turn in
                                retryVerdicts.first { $0.cueID == turn.id }
                                    ?? firstVerdicts.first { $0.cueID == turn.id }
                            }
                            if retryVerdicts.contains(where: { $0.verdict == .hardFailure }) {
                                let failedIDs = retryVerdicts.filter { $0.verdict == .hardFailure }
                                    .map(\.cueID).joined(separator: ", ")
                                let message = "English translation failed validation twice for \(failedIDs). No invalid Deliverable was published."
                                translationEvidence = .init(
                                    request: translationRequest,
                                    response: retryExchange.response,
                                    model: retryExchange.model,
                                    attempts: attempts,
                                    revision: retryExchange.revision,
                                    runtimeVersion: retryExchange.runtimeVersion,
                                    weightSHA256: translationModel.weightSHA256,
                                    batches: batches,
                                    peakMemoryBytes: peakMemoryBytes,
                                    validationFailures: [message],
                                    integrityVerdicts: finalVerdicts
                                )
                                throw HighQualityTranslationValidationError(message: message)
                            }
                            selectedTranslations.merge(retryTranslations) { _, retry in retry }
                            response = try Self.translationResponse(selectedTranslations, for: turns)
                        }

                        translationsByID = selectedTranslations
                        translationEvidence = .init(
                            request: translationRequest,
                            response: response,
                            model: exchange.model,
                            attempts: attempts,
                            revision: exchange.revision,
                            runtimeVersion: exchange.runtimeVersion,
                            weightSHA256: translationModel.weightSHA256,
                            batches: batches,
                            peakMemoryBytes: peakMemoryBytes,
                            validationFailures: [],
                            integrityVerdicts: finalVerdicts
                        )
                    } catch {
                        if translationEvidence?.validationFailures.isEmpty == true {
                            translationEvidence?.validationFailures = [error.localizedDescription]
                        }
                        throw error
                    }
                } catch let error as HighQualityTranslationServiceError {
                    if translationEvidence?.validationFailures.isEmpty != false {
                        translationEvidence = .init(
                            request: translationRequest,
                            response: error.response,
                            model: error.model,
                            attempts: error.attempts,
                            revision: error.revision,
                            runtimeVersion: error.runtimeVersion,
                            weightSHA256: translationModel.weightSHA256,
                            batches: error.batches,
                            peakMemoryBytes: error.peakMemoryBytes,
                            validationFailures: [],
                            integrityVerdicts: HighQualityTranslationIntegrityValidator.validate(
                                turns: turns,
                                batches: error.batches,
                                glossary: integrityGlossary,
                                glossaryByCueID: integrityGlossaryByCueID
                            )
                        )
                    }
                    throw error
                }
                translationUnloaded = true
                let release = try await releaseModel(
                    translationLease,
                    unload: services.unloadTranslation
                )
                translationEvidence?.worker = await services.translationWorkerEvidence()
                translationLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: translationModel.modelID,
                    at: Date()
                ))
                if let release {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        release.evidence.peakMemoryBytes
                    )
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: translationModel.modelID,
                        at: Date(),
                        message: releaseMessage(release)
                    ))
                }
                try Task.checkCancellation()
            }

            if let gate = services.heavyweightGate, let lease = workflowLease {
                try await gate.endWorkflow(lease)
                workflowLease = nil
            }

            let resultTurns = Self.resultTurns(
                turns: turns,
                speakerLabelsByID: speakerAttachment.labelsByUnitID,
                translationsByID: translationsByID
            )
            let englishTranscript = request.deliverables.contains(.englishTranslationTranscript)
                ? Self.transcript(resultTurns, text: \.english)
                : nil
            var subtitleCues: [HighQualitySubtitleCue]
            if needsSubtitles {
                subtitleCues = resultTurns.compactMap { turn in
                    guard let start = turn.start,
                          let end = turn.end,
                          let english = turn.english else { return nil }
                    return .init(
                        id: turn.id,
                        start: start,
                        end: end,
                        text: english,
                        speakerLabel: turn.speakerLabel
                    )
                }
            } else {
                subtitleCues = []
            }
            if request.readableSubtitles {
                let reflow = try HighQualityReadableSubtitleReflow.apply(
                    to: subtitleCues,
                    units: alignmentEvidence?.semanticUnits ?? [],
                    fragments: alignmentEvidence?.semanticFragments ?? []
                )
                subtitleCues = reflow.cues
                readableSubtitleEvidence = reflow.evidence
            }
            begin(.exporting, fraction: 0.9, message: "Writing results…")
            manifest.generatedFiles = Self.generatedFiles(
                deliverables: request.deliverables,
                acquiredAudioURL: acquiredAudioURL
            )
            let japaneseOutput = request.deliverables.contains(.japaneseTranscript)
                ? (request.speakerLabels
                    ? Self.transcript(resultTurns, text: \.japanese)
                    : transcript)
                : nil
            try Task.checkCancellation()
            try Self.writeFiles(Self.deliverableFiles(
                japaneseTranscript: japaneseOutput,
                englishTranscript: englishTranscript,
                subtitleCues: needsSubtitles ? subtitleCues : nil
            ), to: directory)
            japaneseTranscriptWritten = japaneseOutput != nil
            englishTranscriptWritten = englishTranscript != nil
            subtitlesWritten = needsSubtitles
            manifest.status = .completed
            manifest.stageDurations[.exporting, default: 0] += Date().timeIntervalSince(stageStartedAt)
            manifest.finishedAt = Date()
            let evidence = try Self.writeEvidenceAndManifest(
                rawASR: rawTranscript,
                adaptiveASR: adaptiveASR,
                glossary: glossary,
                alignment: alignmentEvidence,
                diarization: diarizationEvidence,
                speakerAttachment: speakerAttachmentEvidence,
                translation: translationEvidence,
                sampleCount: sampleCount,
                sourceAudioSHA256: sourceAudioSHA256,
                resultTurns: resultTurns,
                subtitleCues: subtitleCues,
                japaneseTranscript: japaneseOutput ?? transcript,
                englishTranscript: englishTranscript,
                readableSubtitles: readableSubtitleEvidence,
                manifest: &manifest,
                to: directory
            )
            progress(.init(stage: .completed, fraction: 1, message: "Completed"))
            return HighQualityJobResult(
                directory: directory,
                japaneseTranscript: japaneseOutput ?? transcript,
                englishTranscript: englishTranscript,
                turns: resultTurns,
                subtitleCues: subtitleCues,
                manifest: manifest,
                evidence: evidence
            )
        } catch {
            if let gateError = error as? HeavyweightModelGateError {
                manifest.modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: asrLease?.modelID
                        ?? alignmentLease?.modelID
                        ?? ([.preparingDiarization, .diarizing].contains(currentStage)
                            ? services.diarizationModelID : nil)
                        ?? translationLease?.modelID
                        ?? "heavyweight-workflow",
                    at: Date(),
                    message: gateError.localizedDescription
                ))
            }
            memorySampler?.cancel()
            if let memorySampler {
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    await memorySampler.value
                )
            } else {
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    await services.currentMemoryBytes()
                )
            }
            memorySampler = nil
            if asrLoadStarted, !asrUnloaded {
                asrUnloaded = true
                await cleanupModel(
                    asrLease,
                    modelID: request.backend.model.modelID,
                    unload: services.unloadASR
                )
                await recordASRWorkerEvidence()
            }
            if alignmentLoadStarted, !alignmentUnloaded {
                alignmentUnloaded = true
                await cleanupModel(
                    alignmentLease,
                    modelID: services.alignmentModelID,
                    unload: services.unloadAlignment
                )
            }
            if alignmentLoadStarted {
                if [.preparingAlignment, .aligning].contains(currentStage),
                   alignmentEvidence?.validationDiagnostics.isEmpty == true {
                    alignmentEvidence?.validationDiagnostics = [error.localizedDescription]
                }
                alignmentEvidence?.worker = await services.alignmentWorkerEvidence()
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    alignmentEvidence?.worker?.peakPhysicalFootprintBytes ?? 0
                )
            }
            if translationLoadStarted, !translationUnloaded {
                translationUnloaded = true
                await cleanupModel(
                    translationLease,
                    modelID: translationModel.modelID,
                    unload: services.unloadTranslation
                )
                translationEvidence?.worker = await services.translationWorkerEvidence()
            }
            if let gate = services.heavyweightGate, let workflowLease {
                try? await gate.endWorkflow(workflowLease)
            }
            let failureStage: HighQualityJobFailureStage
            let status: HighQualityJobManifest.Status
            if error is CancellationError || Task.isCancelled {
                failureStage = .cancelled
                status = .cancelled
            } else {
                switch currentStage {
                case .acquiringSource: failureStage = .acquisition
                case .normalizingSource: failureStage = .source
                case .preparingASR: failureStage = .modelPreparation
                case .transcribing: failureStage = .asr
                case .preparingAlignment, .aligning: failureStage = .alignment
                case .preparingDiarization, .diarizing: failureStage = .diarization
                case .translating: failureStage = .translation
                case .exporting: failureStage = .export
                default: failureStage = .application
                }
                status = .failed
            }
            manifest.stageDurations[currentStage, default: 0] += Date().timeIntervalSince(stageStartedAt)
            manifest.status = status
            manifest.finishedAt = Date()
            let baseFailureMessage = error is CancellationError
                ? "Job cancelled."
                : error.localizedDescription
            let failure = HighQualityJobFailure(
                stage: failureStage,
                message: cleanupFailureMessage.map { baseFailureMessage + " " + $0 }
                    ?? baseFailureMessage
            )
            manifest.failures = [failure]
            manifest.generatedFiles = Self.generatedFiles(
                deliverables: Set([
                    japaneseTranscriptWritten ? .japaneseTranscript : nil,
                    englishTranscriptWritten ? .englishTranslationTranscript : nil,
                    subtitlesWritten ? .englishSubtitles : nil,
                ].compactMap { $0 }),
                acquiredAudioURL: acquiredAudioURL
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                _ = try Self.writeEvidenceAndManifest(
                    rawASR: rawASR,
                    adaptiveASR: adaptiveASR,
                    glossary: glossary,
                    alignment: alignmentEvidence,
                    diarization: diarizationEvidence,
                    speakerAttachment: speakerAttachmentEvidence,
                    translation: translationEvidence,
                    sampleCount: sampleCount,
                    sourceAudioSHA256: sourceAudioSHA256,
                    manifest: &manifest,
                    to: directory
                )
            } catch let finalizationError {
                throw HighQualityJobError(
                    stage: failureStage,
                    message: failure.message + " Results could not be finalized: "
                        + finalizationError.localizedDescription,
                    resultDirectory: directory
                )
            }
            progress(.init(
                stage: status == .cancelled ? .cancelled : .failed,
                fraction: 1,
                message: failure.message
            ))
            throw HighQualityJobError(
                stage: failureStage,
                message: failure.message,
                resultDirectory: directory
            )
        }
    }

    static func renameSpeakers(
        in result: HighQualityJobResult,
        names: [String: String],
        beforeCommit: () throws -> Void = {},
        afterStaging: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        return try saveSpeakerEdits(
            try speakerRenameEdits(names, in: result),
            in: result,
            beforeCommit: beforeCommit,
            afterStaging: afterStaging
        )
    }

    static func editSpeakers(
        in result: HighQualityJobResult,
        names: [String: String] = [:],
        edit: HighQualitySpeakerEdit,
        beforeCommit: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        try saveSpeakerEdits(
            try speakerRenameEdits(names, in: result) + [edit],
            in: result,
            beforeCommit: beforeCommit
        )
    }

    static func undoLastSpeakerEdit(
        in result: HighQualityJobResult,
        beforeCommit: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        let transformations = try readTransformations(in: result.directory)
        let edits = migratedSpeakerEdits(
            transformations,
            manifest: result.manifest
        )
        guard !edits.isEmpty else {
            throw speakerEditError("There is no Speaker edit to undo.", in: result.directory)
        }
        let previous = edits.dropLast()
        let snapshotStart = previous.lastIndex(where: { $0.kind == .reset })
            .map { previous.index(after: $0) } ?? previous.startIndex
        let snapshot = previous[snapshotStart..<previous.endIndex]
        let at = Date()
        let replayed = try replayedSpeakerEdits(snapshot, at: at, in: result.directory)
        return try saveSpeakerEdits(
            [.reset(at: at)] + replayed,
            in: result,
            beforeCommit: beforeCommit
        )
    }

    static func restorePreviousSpeakerEdits(
        in result: HighQualityJobResult,
        beforeCommit: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        guard let edits = try restorablePreviousSpeakerEdits(in: result) else {
            throw speakerEditError(
                "The archived Speaker edits are not compatible with the current Speaker IDs and provenance.",
                in: result.directory
            )
        }
        let at = Date()
        return try saveSpeakerEdits(
            [.reset(at: at)] + replayedSpeakerEdits(edits, at: at, in: result.directory),
            in: result,
            beforeCommit: beforeCommit
        )
    }

    fileprivate static func canRestorePreviousSpeakerEdits(
        in result: HighQualityJobResult
    ) -> Bool {
        (try? restorablePreviousSpeakerEdits(in: result)) != nil
    }

    private static func restorablePreviousSpeakerEdits(
        in result: HighQualityJobResult
    ) throws -> [HighQualitySpeakerEdit]? {
        guard result.manifest.speakerEdits?.isEmpty != false,
              let reanalysis = result.evidence.speakerReanalyses?.last,
              let edits = reanalysis.replacedSpeakerEdits,
              !edits.isEmpty,
              reanalysis.diarization == result.evidence.diarization,
              reanalysis.attachment == result.evidence.speakerAttachment,
              let replacedAttachment = reanalysis.replacedAttachment,
              speakerIdentityMatches(replacedAttachment, reanalysis.attachment) else {
            return nil
        }
        let replayed = try replayedSpeakerEdits(edits, at: Date(), in: result.directory)
        _ = try speakerEditState([.reset()] + replayed, for: result)
        return edits
    }

    private static func speakerIdentityMatches(
        _ previous: HighQualitySpeakerAttachmentEvidence,
        _ current: HighQualitySpeakerAttachmentEvidence
    ) -> Bool {
        let previousByID = Dictionary(
            previous.semanticUnits.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard previousByID.count == previous.semanticUnits.count,
              current.semanticUnits.count == previous.semanticUnits.count else { return false }
        return current.semanticUnits.allSatisfy { unit in
            guard let old = previousByID[unit.id] else { return false }
            return old.japanese == unit.japanese
                && old.sourceFragmentIndices == unit.sourceFragmentIndices
                && old.sourceCueIDs == unit.sourceCueIDs
                && old.start == unit.start
                && old.end == unit.end
                && old.decisions == unit.decisions
                && old.speakerLabel == unit.speakerLabel
        }
    }

    private static func replayedSpeakerEdits<S: Sequence>(
        _ edits: S,
        at: Date,
        in directory: URL
    ) throws -> [HighQualitySpeakerEdit] where S.Element == HighQualitySpeakerEdit {
        try edits.map { storedEdit in
            let edit = try normalizedSpeakerEdit(storedEdit, in: directory)
            switch edit.kind {
            case .rename:
                return .rename(edit.speakerLabel!, to: edit.displayName!, at: at)
            case .merge:
                return .merge(edit.speakerLabel!, into: edit.targetSpeakerLabel!, at: at)
            case .reassign:
                return .reassign(turnID: edit.turnID!, to: edit.targetSpeakerLabel!, at: at)
            case .reset:
                return .reset(at: at)
            }
        }
    }

    private static func speakerRenameEdits(
        _ names: [String: String],
        in result: HighQualityJobResult
    ) throws -> [HighQualitySpeakerEdit] {
        let currentNames = result.editableSpeakerNames
        return try names.sorted(by: { $0.key < $1.key }).compactMap { label, value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw HighQualityJobError(
                    stage: .export,
                    message: "Custom Speaker labels cannot be empty.",
                    resultDirectory: result.directory
                )
            }
            guard let currentName = currentNames[label], currentName != value else {
                return nil
            }
            return HighQualitySpeakerEdit.rename(label, to: value)
        }
    }

    private static func saveSpeakerEdits(
        _ newEdits: [HighQualitySpeakerEdit],
        in result: HighQualityJobResult,
        beforeCommit: () throws -> Void,
        afterStaging: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        guard result.manifest.schemaVersion >= 3 else {
            throw speakerEditError(
                "Speaker label edits require a result saved with the current schema.",
                in: result.directory
            )
        }
        guard result.manifest.speakerLabels else {
            throw speakerEditError(
                "This saved result has no Speaker assignments to edit.",
                in: result.directory
            )
        }
        let activeManifest = try readManifest(in: result.directory)
        guard activeManifest.status == .completed,
              activeManifest.jobID == result.manifest.jobID,
              activeManifest.rawEvidenceSHA256 == result.manifest.rawEvidenceSHA256,
              activeManifest.speakerEdits == result.manifest.speakerEdits else {
            throw speakerEditError(
                "Speaker edits changed since this result was opened. Reopen it and try again.",
                in: result.directory
            )
        }
        let previous = try readTransformations(in: result.directory)
        guard previous != nil || activeManifest.speakerEdits?.isEmpty != false else {
            throw speakerEditError(
                "The saved Speaker edit audit is missing.",
                in: result.directory
            )
        }
        let persistedEdits = migratedSpeakerEdits(previous, manifest: activeManifest)
        guard speakerEditAuditMatchesManifest(
            previous,
            edits: persistedEdits,
            manifest: activeManifest
        ) else {
            throw speakerEditError(
                "The saved Speaker edit manifest and audit do not match.",
                in: result.directory
            )
        }
        let current = HighQualityJobResult(
            directory: result.directory,
            japaneseTranscript: result.japaneseTranscript,
            englishTranscript: result.englishTranscript,
            turns: result.turns,
            subtitleCues: result.subtitleCues,
            manifest: activeManifest,
            evidence: result.evidence,
            speakerReanalysisCompletion: result.speakerReanalysisCompletion
        )
        let edits = persistedEdits
            + (try newEdits.map { try normalizedSpeakerEdit($0, in: result.directory) })
        let edited = try applyingSpeakerEdits(edits, to: current)
        var manifest = current.manifest
        manifest.schemaVersion = HighQualityJobManifest.currentSchemaVersion
        manifest.speakerEdits = edits
        let saved = HighQualityJobResult(
            directory: edited.directory,
            japaneseTranscript: edited.japaneseTranscript,
            englishTranscript: edited.englishTranscript,
            turns: edited.turns,
            subtitleCues: edited.subtitleCues,
            manifest: manifest,
            evidence: edited.evidence,
            speakerReanalysisCompletion: result.speakerReanalysisCompletion
        )
        let transformations = try encoder.encode(HighQualityResultTransformations(
            speakerEdits: edits,
            relocatedSourcePath: previous?.relocatedSourcePath
        ))
        let deliverables = Set(manifest.deliverables)
        var files = deliverableFiles(
            japaneseTranscript: deliverables.contains(.japaneseTranscript)
                ? saved.japaneseTranscript : nil,
            englishTranscript: saved.englishTranscript,
            subtitleCues: deliverables.contains(.englishSubtitles) ? saved.subtitleCues : nil
        )
        files["transformations.json"] = transformations
        files["manifest.json"] = try encoder.encode(manifest)
        try transactionallyWrite(
            files,
            in: result.directory,
            beforeCommit: beforeCommit,
            afterStaging: afterStaging,
            validateActive: {
                guard try activeResultMatches(
                    activeManifest,
                    transformations: previous,
                    in: result.directory
                ) else {
                    throw speakerEditError(
                        "Speaker result changed since this edit was prepared. Reopen it and try again.",
                        in: result.directory
                    )
                }
            }
        )
        return saved
    }

    private static func migratedSpeakerEdits(
        _ transformations: HighQualityResultTransformations?,
        manifest: HighQualityJobManifest
    ) -> [HighQualitySpeakerEdit] {
        guard let transformations else { return [] }
        let migrationDate = manifest.finishedAt ?? manifest.startedAt
        let legacy = transformations.customSpeakerLabels.sorted(by: { $0.key < $1.key }).map {
            HighQualitySpeakerEdit.rename($0.key, to: $0.value, at: migrationDate)
        }
        return legacy + transformations.speakerEdits
    }

    private static func speakerEditAuditMatchesManifest(
        _ transformations: HighQualityResultTransformations?,
        edits: [HighQualitySpeakerEdit],
        manifest: HighQualityJobManifest
    ) -> Bool {
        guard let transformations else {
            return manifest.speakerEdits?.isEmpty != false
        }
        if transformations.schemaVersion == 1 {
            return manifest.schemaVersion < HighQualityJobManifest.currentSchemaVersion
                && manifest.speakerEdits?.isEmpty != false
        }
        return (manifest.speakerEdits ?? []) == edits
    }

    private static func activeResultMatches(
        _ expected: HighQualityJobManifest,
        transformations: HighQualityResultTransformations?,
        in directory: URL
    ) throws -> Bool {
        try readManifest(in: directory) == expected
            && readTransformations(in: directory) == transformations
    }

    private static func normalizedSpeakerEdit(
        _ edit: HighQualitySpeakerEdit,
        in directory: URL
    ) throws -> HighQualitySpeakerEdit {
        let seconds = edit.at.timeIntervalSince1970
        guard seconds.isFinite else {
            throw speakerEditError("The Speaker edit timestamp is invalid.", in: directory)
        }
        let at = Date(timeIntervalSince1970: seconds.rounded(.down))
        let nonempty: (String?) -> String? = { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch edit.kind {
        case .rename:
            guard let label = nonempty(edit.speakerLabel),
                  let name = nonempty(edit.displayName),
                  edit.targetSpeakerLabel == nil,
                  edit.turnID == nil else {
                throw speakerEditError("The Speaker rename operation is invalid.", in: directory)
            }
            guard name.rangeOfCharacter(
                from: CharacterSet.controlCharacters.union(.newlines)
            ) == nil else {
                throw speakerEditError(
                    "Custom Speaker names cannot contain control characters or line breaks.",
                    in: directory
                )
            }
            return .rename(label, to: name, at: at)
        case .merge:
            guard let label = nonempty(edit.speakerLabel),
                  let target = nonempty(edit.targetSpeakerLabel),
                  edit.displayName == nil,
                  edit.turnID == nil else {
                throw speakerEditError("The Speaker merge operation is invalid.", in: directory)
            }
            return .merge(label, into: target, at: at)
        case .reassign:
            guard let turnID = nonempty(edit.turnID),
                  let target = nonempty(edit.targetSpeakerLabel),
                  edit.speakerLabel == nil,
                  edit.displayName == nil else {
                throw speakerEditError(
                    "The Speaker reassignment operation is invalid.",
                    in: directory
                )
            }
            return .reassign(turnID: turnID, to: target, at: at)
        case .reset:
            guard edit.speakerLabel == nil,
                  edit.targetSpeakerLabel == nil,
                  edit.turnID == nil,
                  edit.displayName == nil else {
                throw speakerEditError("The Speaker reset operation is invalid.", in: directory)
            }
            return .reset(at: at)
        }
    }

    fileprivate static func speakerEditState(
        _ edits: [HighQualitySpeakerEdit],
        for result: HighQualityJobResult
    ) throws -> HighQualitySpeakerEditState {
        guard let rawTurns = result.evidence.resultTurns else {
            throw speakerEditError(
                "The immutable Speaker result evidence is incomplete.",
                in: result.directory
            )
        }
        let turnIDs = Set(rawTurns.map(\.id))
        guard turnIDs.count == rawTurns.count else {
            throw speakerEditError(
                "The immutable Speaker result contains duplicate turn identifiers.",
                in: result.directory
            )
        }
        let rawAssignments = rawTurns.reduce(into: [String: String]()) { labels, turn in
            if let label = turn.speakerLabel { labels[turn.id] = label }
        }
        let rawNames = rawTurns.reduce(into: [String: String]()) { names, turn in
            if let label = turn.speakerLabel, let name = turn.speakerName {
                names[label] = name
            }
        }
        let rawLabels = result.automaticSpeakerLabels
        var assignments = rawAssignments
        var names = rawNames
        var activeLabels = rawLabels

        for storedEdit in edits {
            let edit = try normalizedSpeakerEdit(storedEdit, in: result.directory)
            switch edit.kind {
            case .rename:
                let label = edit.speakerLabel!
                guard activeLabels.contains(label) else {
                    throw speakerEditError(
                        "Cannot rename unknown or merged Speaker label \(label).",
                        in: result.directory
                    )
                }
                let name = edit.displayName!
                if name == label { names.removeValue(forKey: label) }
                else { names[label] = name }
            case .merge:
                let label = edit.speakerLabel!
                let target = edit.targetSpeakerLabel!
                guard label != target else {
                    throw speakerEditError(
                        "A Speaker label cannot be merged into itself.",
                        in: result.directory
                    )
                }
                guard activeLabels.contains(label), activeLabels.contains(target) else {
                    throw speakerEditError(
                        "Cannot merge unknown or already merged Speaker labels.",
                        in: result.directory
                    )
                }
                if let sourceName = names[label],
                   let targetName = names[target],
                   sourceName != targetName {
                    throw speakerEditError(
                        "Cannot merge Speaker labels with conflicting confirmed names.",
                        in: result.directory
                    )
                }
                if names[target] == nil { names[target] = names[label] }
                names.removeValue(forKey: label)
                assignments = assignments.mapValues { $0 == label ? target : $0 }
                activeLabels.remove(label)
            case .reassign:
                let turnID = edit.turnID!
                let target = edit.targetSpeakerLabel!
                guard turnIDs.contains(turnID) else {
                    throw speakerEditError(
                        "Cannot reassign unknown transcript turn \(turnID).",
                        in: result.directory
                    )
                }
                guard activeLabels.contains(target) else {
                    throw speakerEditError(
                        "Cannot reassign a turn to unknown or merged Speaker label \(target).",
                        in: result.directory
                    )
                }
                assignments[turnID] = target
            case .reset:
                assignments = rawAssignments
                names = rawNames
                activeLabels = rawLabels
            }
        }

        return .init(
            assignments: assignments,
            names: names,
            activeLabels: activeLabels
        )
    }

    private static func applyingSpeakerEdits(
        _ edits: [HighQualitySpeakerEdit],
        to result: HighQualityJobResult
    ) throws -> HighQualityJobResult {
        guard let rawTurns = result.evidence.resultTurns,
              let rawCues = result.evidence.subtitleCues else {
            throw speakerEditError(
                "The immutable Speaker result evidence is incomplete.",
                in: result.directory
            )
        }
        let turnIDs = Set(rawTurns.map(\.id))
        let state = try speakerEditState(edits, for: result)
        let assignments = state.assignments
        let names = state.names

        let turns: [HighQualityTranscriptTurn] = rawTurns.map { turn in
            let label = assignments[turn.id]
            return .init(
                id: turn.id,
                japanese: turn.japanese,
                english: turn.english,
                speakerLabel: label,
                speakerName: label.flatMap { names[$0] },
                start: turn.start,
                end: turn.end
            )
        }
        let subtitleCues: [HighQualitySubtitleCue] = rawCues.map { cue in
            let label = turnIDs.contains(cue.id) ? assignments[cue.id] : cue.speakerLabel
            return .init(
                id: cue.id,
                start: cue.start,
                end: cue.end,
                text: cue.text,
                speakerLabel: label,
                speakerName: label.flatMap { names[$0] },
                renderedLines: cue.renderedLines
            )
        }
        let deliverables = Set(result.manifest.deliverables)
        return .init(
            directory: result.directory,
            japaneseTranscript: deliverables.contains(.japaneseTranscript)
                ? transcript(turns, text: \.japanese) : result.japaneseTranscript,
            englishTranscript: deliverables.contains(.englishTranslationTranscript)
                ? transcript(turns, text: \.english) : nil,
            turns: turns,
            subtitleCues: subtitleCues,
            manifest: result.manifest,
            evidence: result.evidence,
            speakerReanalysisCompletion: result.speakerReanalysisCompletion
        )
    }

    private static func provenance(
        for url: URL,
        youtube: HighQualityYouTubeEvidence? = nil
    ) -> HighQualitySourceProvenance {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return HighQualitySourceProvenance(
            path: url.path,
            fileName: url.lastPathComponent,
            byteCount: values?.fileSize.map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            sourceURL: youtube?.sourceURL ?? (url.isFileURL ? nil : url.absoluteString),
            youtube: youtube
        )
    }

    static func translationTurns(
        from transcript: String,
        asrChunks: [HighQualityASRChunk],
        speakerLabelsByCueID: [String: String]
    ) -> [HighQualityTranslationTurn] {
        var turns: [(text: String, start: TimeInterval?, end: TimeInterval?)] = []
        let sources = asrChunks.isEmpty
            ? [(text: transcript, start: nil, end: nil)]
            : asrChunks.map { (text: $0.transcript, start: $0.sourceStart, end: $0.sourceEnd) }
        for source in sources {
            source.text.enumerateSubstrings(
                in: source.text.startIndex..<source.text.endIndex,
                options: .bySentences
            ) { sentence, _, _, _ in
                let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !sentence.isEmpty {
                    turns.append((sentence, source.start, source.end))
                }
            }
        }
        return turns.enumerated().map { index, turn in
            let id = String(format: "cue-%04d", index + 1)
            return HighQualityTranslationTurn(
                id: id,
                japanese: turn.text,
                precedingJapanese: index == 0 ? [] : [turns[index - 1].text],
                followingJapanese: index + 1 == turns.count ? [] : [turns[index + 1].text],
                speakerLabel: speakerLabelsByCueID[id],
                sourceStart: turn.start,
                sourceEnd: turn.end
            )
        }
    }

    static func semanticTranslationUnits(
        alignment: HighQualityAlignmentEvidence,
        sourceTurns: [HighQualityTranslationTurn]
    ) throws -> (
        policy: HighQualitySemanticUnitPolicyEvidence,
        fragments: [HighQualitySemanticFragmentEvidence],
        units: [HighQualitySemanticUnitEvidence],
        turns: [HighQualityTranslationTurn]
    ) {
        let policy = HighQualitySemanticUnitPolicyEvidence(
            version: "ja-semantic-v1",
            pauseSeconds: 0.75,
            maximumCharacters: 48,
            shortFragmentCharacters: 6
        )
        let rawItems = alignment.chunks.sorted { $0.index < $1.index }.flatMap(\.rawItems)
        let indexedItems = rawItems.enumerated().map { ($0.offset, $0.element) }
        let itemsByCue = Dictionary(grouping: indexedItems, by: { $0.1.cueID })
        let fallbackTargetIDs = Set(alignment.fallbackMerges?.map(\.targetCueID) ?? [])
        var coarseCueTimingIDs: Set<String> = []
        var fragments: [HighQualitySemanticFragmentEvidence] = []

        for cue in alignment.mergedCues {
            if fallbackTargetIDs.contains(cue.id) {
                fragments.append(.init(
                    index: fragments.count,
                    alignmentItemIndex: nil,
                    sourceCueID: cue.id,
                    text: cue.text,
                    start: cue.start,
                    end: cue.end
                ))
                continue
            }
            let items = itemsByCue[cue.id] ?? []
            if rawItems.isEmpty {
                let characters = Array(cue.text)
                let duration = (cue.end - cue.start) / Double(max(characters.count, 1))
                for (offset, character) in characters.enumerated() {
                    fragments.append(.init(
                        index: fragments.count,
                        alignmentItemIndex: nil,
                        sourceCueID: cue.id,
                        text: String(character),
                        start: cue.start + Double(offset) * duration,
                        end: cue.start + Double(offset + 1) * duration
                    ))
                }
                continue
            }
            let timedItems = items.flatMap { indexedItem in
                let characters = Array(indexedItem.1.text)
                let duration = (indexedItem.1.end - indexedItem.1.start)
                    / Double(max(characters.count, 1))
                return characters.enumerated().map { offset, character in
                    (
                        alignmentItemIndex: indexedItem.0,
                        text: String(character),
                        start: indexedItem.1.start + Double(offset) * duration,
                        end: indexedItem.1.start + Double(offset + 1) * duration
                    )
                }
            }
            if !timedItems.isEmpty, timedItems.allSatisfy({ $0.end <= $0.start }) {
                guard cue.text.count <= policy.maximumCharacters else {
                    throw HighQualityTranslationValidationError(
                        message: "Cue \(cue.id) needs coarse timing but exceeds the semantic limit."
                    )
                }
                coarseCueTimingIDs.insert(cue.id)
                fragments.append(.init(
                    index: fragments.count,
                    alignmentItemIndex: nil,
                    sourceCueID: cue.id,
                    text: cue.text,
                    start: cue.start,
                    end: cue.end
                ))
                continue
            }
            if timedItems.map(\.text).joined() == cue.text {
                for item in timedItems {
                    fragments.append(.init(
                        index: fragments.count,
                        alignmentItemIndex: item.alignmentItemIndex,
                        sourceCueID: cue.id,
                        text: item.text,
                        start: item.start,
                        end: item.end
                    ))
                }
                continue
            }
            let alignableCharacters = cue.text.filter {
                $0.isLetter || $0.isNumber || $0 == "'"
            }
            let alignableItems = timedItems.filter {
                $0.text.first?.isLetter == true || $0.text.first?.isNumber == true
                    || $0.text == "'"
            }
            guard alignableCharacters.count == alignableItems.count else {
                throw HighQualityTranslationValidationError(
                    message: "Alignment fragments do not preserve cue \(cue.id)."
                )
            }
            var itemIndex = 0
            for character in cue.text {
                if character.isLetter || character.isNumber || character == "'" {
                    let item = alignableItems[itemIndex]
                    itemIndex += 1
                    fragments.append(.init(
                        index: fragments.count,
                        alignmentItemIndex: item.alignmentItemIndex,
                        sourceCueID: cue.id,
                        text: String(character),
                        start: item.start,
                        end: item.end
                    ))
                } else {
                    let previous = fragments.last?.sourceCueID == cue.id
                        ? fragments.last : nil
                    let next = itemIndex < alignableItems.count
                        ? alignableItems[itemIndex] : nil
                    fragments.append(.init(
                        index: fragments.count,
                        alignmentItemIndex: previous?.alignmentItemIndex
                            ?? next?.alignmentItemIndex,
                        sourceCueID: cue.id,
                        text: String(character),
                        start: previous?.end ?? next?.start ?? cue.start,
                        end: previous?.end ?? next?.start ?? cue.end
                    ))
                }
            }
        }

        var drafts: [HighQualitySemanticUnitDraft] = []
        var current: [HighQualitySemanticFragmentEvidence] = []
        func finish(_ decision: String) {
            guard !current.isEmpty else { return }
            drafts.append(.init(fragments: current, decisions: [decision]))
            current = []
        }
        for (index, fragment) in fragments.enumerated() {
            if !current.isEmpty,
               current.map(\.text).joined().count + fragment.text.count
                    > policy.maximumCharacters {
                finish("boundary:maximum-size")
            }
            current.append(fragment)
            let next = fragments.indices.contains(index + 1) ? fragments[index + 1] : nil
            if hasTerminalJapanesePunctuation(current.map(\.text).joined()) {
                finish("boundary:punctuation")
            } else if let next, next.start - fragment.end >= policy.pauseSeconds {
                finish("boundary:pause")
            }
        }
        finish("boundary:end-of-input")
        for index in drafts.indices where !coarseCueTimingIDs.isDisjoint(
            with: drafts[index].fragments.map(\.sourceCueID)
        ) {
            drafts[index].decisions.append("fallback:positive-cue-timing")
        }

        var mergedDrafts: [HighQualitySemanticUnitDraft] = []
        for index in drafts.indices {
            let text = drafts[index].japanese
            if isStandaloneJapaneseInterjection(text) {
                drafts[index].decisions.append("keep:standalone-interjection")
                mergedDrafts.append(drafts[index])
            } else if text.count <= policy.shortFragmentCharacters,
                      !hasTerminalJapanesePunctuation(text),
                      index + 1 < drafts.count,
                      text.count + drafts[index + 1].japanese.count
                        <= policy.maximumCharacters {
                drafts[index + 1].fragments = drafts[index].fragments
                    + drafts[index + 1].fragments
                drafts[index + 1].decisions = drafts[index].decisions
                    + ["merge:short-fragment-into-next"] + drafts[index + 1].decisions
            } else {
                mergedDrafts.append(drafts[index])
            }
        }
        drafts = mergedDrafts

        var index = 0
        while index < drafts.count {
            let start = drafts[index].fragments.map(\.start).min() ?? 0
            let end = drafts[index].fragments.map(\.end).max() ?? 0
            guard end <= start else {
                index += 1
                continue
            }
            let sourceCueIDs = Set(drafts[index].fragments.map(\.sourceCueID))
            func viableNeighbor(_ neighbor: Int) -> Bool {
                guard drafts.indices.contains(neighbor),
                      drafts[neighbor].fragments.map(\.end).max() ?? 0
                        > drafts[neighbor].fragments.map(\.start).min() ?? 0,
                      !sourceCueIDs.isDisjoint(with: drafts[neighbor].fragments.map(\.sourceCueID)),
                      drafts[index].japanese.count + drafts[neighbor].japanese.count
                        <= policy.maximumCharacters else { return false }
                return true
            }
            let previous = index > 0 && viableNeighbor(index - 1) ? index - 1 : nil
            let following = viableNeighbor(index + 1) ? index + 1 : nil
            let target: Int?
            if let previous, let following {
                let previousEnd = drafts[previous].fragments.map(\.end).max() ?? start
                let followingStart = drafts[following].fragments.map(\.start).min() ?? end
                target = start - previousEnd <= followingStart - end ? previous : following
            } else {
                target = previous ?? following
            }
            guard let target else {
                throw HighQualityTranslationValidationError(
                    message: "Zero-duration semantic unit has no valid same-cue neighbor."
                )
            }
            if target < index {
                drafts[target].fragments += drafts[index].fragments
                drafts[target].decisions += ["merge:zero-duration-items-into-previous"]
                    + drafts[index].decisions
                drafts.remove(at: index)
            } else {
                drafts[target].fragments = drafts[index].fragments + drafts[target].fragments
                drafts[target].decisions = drafts[index].decisions
                    + ["merge:zero-duration-items-into-next"] + drafts[target].decisions
                drafts.remove(at: index)
            }
        }

        let units = drafts.enumerated().map { offset, draft in
            HighQualitySemanticUnitEvidence(
                id: String(format: "unit-%04d", offset + 1),
                japanese: draft.japanese,
                sourceFragmentIndices: draft.fragments.map(\.index),
                sourceCueIDs: draft.fragments.map(\.sourceCueID).reduce(into: []) {
                    if !$0.contains($1) { $0.append($1) }
                },
                start: draft.fragments.map(\.start).min() ?? 0,
                end: draft.fragments.map(\.end).max() ?? 0,
                decisions: draft.decisions,
                speakerLabel: nil,
                speakerMappingIndices: []
            )
        }
        guard units.map(\.japanese).joined() == sourceTurns.map(\.japanese).joined(),
              Set(units.flatMap(\.sourceFragmentIndices)).count == fragments.count,
              units.allSatisfy({ $0.end > $0.start }),
              zip(units, units.dropFirst()).allSatisfy({ $1.start >= $0.end }) else {
            throw HighQualityTranslationValidationError(
                message: "Semantic translation units do not preserve a valid aligned timeline."
            )
        }
        let sourceTurnsByID = Dictionary(uniqueKeysWithValues: sourceTurns.map {
            ($0.id, $0)
        })
        let turns = units.map { unit in
            let firstSource = unit.sourceCueIDs.first.flatMap { sourceTurnsByID[$0] }
            let lastSource = unit.sourceCueIDs.last.flatMap { sourceTurnsByID[$0] }
            return HighQualityTranslationTurn(
                id: unit.id,
                japanese: unit.japanese,
                precedingJapanese: firstSource?.precedingJapanese ?? [],
                followingJapanese: lastSource?.followingJapanese ?? [],
                speakerLabel: nil,
                sourceStart: unit.start,
                sourceEnd: unit.end
            )
        }
        return (policy, fragments, units, turns)
    }

    private static func hasTerminalJapanesePunctuation(_ text: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"’”」』】〕〗〙〛〞）)]〉》『")
        let trimmed = text.trimmingCharacters(in: closers.union(.whitespacesAndNewlines))
        return trimmed.last.map { "。！？!?｡".contains($0) } ?? false
    }

    private static func isStandaloneJapaneseInterjection(_ text: String) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        let value = text.trimmingCharacters(in: punctuation)
        return ["あ", "あっ", "うん", "え", "えっ", "お", "おお", "おっ", "はい", "へえ", "ほう", "わあ", "うわ", "うわあ"]
            .contains(value)
    }

    private static func speakerAttachment(
        units: [HighQualitySemanticUnitEvidence],
        fragments: [HighQualitySemanticFragmentEvidence],
        mappings: [HighQualitySpeakerMapping],
        explicitLabelsByCueID: [String: String]
    ) -> (units: [HighQualitySemanticUnitEvidence], labelsByUnitID: [String: String]) {
        var labelsByUnitID: [String: String] = [:]
        let updated = units.map { unit in
            let alignmentItems = Set(unit.sourceFragmentIndices.compactMap {
                fragments.indices.contains($0) ? fragments[$0].alignmentItemIndex : nil
            })
            let matching = mappings.enumerated().filter {
                alignmentItems.isEmpty
                    ? unit.sourceCueIDs.contains($0.element.cueID)
                    : alignmentItems.contains($0.element.alignmentItemIndex)
            }
            var durations: [String: TimeInterval] = [:]
            for mapping in matching.map(\.element) {
                durations[mapping.speakerLabel, default: 0] += mapping.overlapEnd
                    - mapping.overlapStart
            }
            let explicit = unit.sourceCueIDs.compactMap { explicitLabelsByCueID[$0] }
            let label = durations.max {
                $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
            }?.key ?? explicit.sorted().first
            labelsByUnitID[unit.id] = label
            var attached = unit
            attached.speakerLabel = label
            attached.speakerMappingIndices = matching.map(\.offset)
            return attached
        }
        return (updated, labelsByUnitID)
    }

    static func diarizationEvidence(
        _ exchange: HighQualityDiarizationExchange,
        items: [HighQualityAlignmentItem],
        duration: TimeInterval,
        completeAttribution: Bool = false,
        sourceJobID: UUID? = nil
    ) throws -> HighQualityDiarizationEvidence {
        let spans = exchange.spans.sorted {
            ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID)
        }
        guard duration.isFinite, duration >= 0, spans.allSatisfy({
            $0.speakerID >= 0 && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start && $0.end <= duration
        }) else {
            throw HighQualityJobError(
                stage: .diarization,
                message: "SpeakerKit returned an invalid diarization span.",
                resultDirectory: nil
            )
        }
        let labels = highQualitySpeakerLabelsByID(spans)
        var centroidDiagnostics: [String] = []
        let speakerCentroids: [HighQualitySpeakerCentroidEvidence]?
        if let vectors = exchange.speakerCentroids {
            if vectors.isEmpty {
                speakerCentroids = []
                if !spans.isEmpty {
                    centroidDiagnostics.append(
                        "Abstained from duplicate speaker suggestions: SpeakerKit returned no centroid vectors."
                    )
                }
            } else if let sourceJobID,
                      sourceJobID.uuidString != "00000000-0000-0000-0000-000000000000",
                      isTrimmedAndNonempty(exchange.modelID),
                      isTrimmedAndNonempty(exchange.revision),
                      let runtimeRevision = exchange.configuration?["runtimeRevision"],
                      isTrimmedAndNonempty(runtimeRevision),
                      let embeddingVariant = exchange.configuration?["embedderVariant"],
                      isTrimmedAndNonempty(embeddingVariant) {
                var retained: [HighQualitySpeakerCentroidEvidence] = []
                for speakerID in vectors.keys.sorted() {
                    guard let label = labels[speakerID] else {
                        centroidDiagnostics.append(
                            "Discarded SpeakerKit centroid \(speakerID): speaker has no diarization span."
                        )
                        continue
                    }
                    guard let vector = vectors[speakerID], !vector.isEmpty else {
                        centroidDiagnostics.append(
                            "Discarded SpeakerKit centroid \(label): vector is empty."
                        )
                        continue
                    }
                    guard vector.allSatisfy(\.isFinite) else {
                        centroidDiagnostics.append(
                            "Discarded SpeakerKit centroid \(label): vector contains non-finite values."
                        )
                        continue
                    }
                    guard vector.contains(where: { $0 != 0 }) else {
                        centroidDiagnostics.append(
                            "Discarded SpeakerKit centroid \(label): vector has zero norm."
                        )
                        continue
                    }
                    guard hasSafeSpeakerCentroidNorm(vector) else {
                        centroidDiagnostics.append(
                            "Discarded SpeakerKit centroid \(label): vector norm cannot be represented safely."
                        )
                        continue
                    }
                    retained.append(.init(
                        speakerLabel: label,
                        modelID: exchange.modelID,
                        modelRevision: exchange.revision,
                        runtimeRevision: runtimeRevision,
                        embeddingVariant: embeddingVariant,
                        vectorDimension: vector.count,
                        sourceJobID: sourceJobID,
                        vector: vector
                    ))
                }
                for (speakerID, label) in labels.sorted(by: { $0.key < $1.key })
                    where vectors[speakerID] == nil {
                    centroidDiagnostics.append(
                        "Abstained from duplicate speaker suggestions: \(label) has no centroid vector."
                    )
                }
                if Set(retained.map(\.vectorDimension)).count > 1 {
                    centroidDiagnostics.append(
                        "Abstained from duplicate speaker suggestions: centroid dimensions are incompatible."
                    )
                }
                speakerCentroids = retained
            } else {
                speakerCentroids = []
                centroidDiagnostics.append(
                    "Discarded \(vectors.count) SpeakerKit centroid(s): provenance is incomplete."
                )
            }
        } else {
            speakerCentroids = nil
        }
        var mappings: [HighQualitySpeakerMapping] = []
        for (itemIndex, item) in items.enumerated() {
            let candidates = spans.enumerated().compactMap { spanIndex, span -> HighQualitySpeakerMapping? in
                let start = max(item.start, span.start)
                let end = min(item.end, span.end)
                guard start < end, let label = labels[span.speakerID] else { return nil }
                return .init(
                    cueID: item.cueID,
                    alignmentItemIndex: itemIndex,
                    spanIndex: spanIndex,
                    alignedText: item.text,
                    speakerLabel: label,
                    overlapStart: start,
                    overlapEnd: end,
                    attributionReason: completeAttribution ? "longest-overlap" : nil
                )
            }
            if let principal = candidates.min(by: {
                let leftDuration = $0.overlapEnd - $0.overlapStart
                let rightDuration = $1.overlapEnd - $1.overlapStart
                return leftDuration == rightDuration
                    ? ($0.speakerLabel, $0.spanIndex) < ($1.speakerLabel, $1.spanIndex)
                    : leftDuration > rightDuration
            }) {
                mappings.append(principal)
            } else if completeAttribution,
                      let nearest = spans.enumerated().min(by: {
                          let leftDistance = Self.distance(from: item, to: $0.element)
                          let rightDistance = Self.distance(from: item, to: $1.element)
                          return leftDistance == rightDistance
                              ? ($0.element.speakerID, $0.offset)
                                  < ($1.element.speakerID, $1.offset)
                              : leftDistance < rightDistance
                      }),
                      let label = labels[nearest.element.speakerID] {
                let anchor = nearest.element.end <= item.start
                    ? nearest.element.end : nearest.element.start
                mappings.append(.init(
                    cueID: item.cueID,
                    alignmentItemIndex: itemIndex,
                    spanIndex: nearest.offset,
                    alignedText: item.text,
                    speakerLabel: label,
                    overlapStart: anchor,
                    overlapEnd: anchor,
                    attributionReason: "nearest-span-fallback"
                ))
            }
        }
        var overlapsByKey: [String: HighQualityOverlapRange] = [:]
        for leftIndex in spans.indices {
            for rightIndex in spans.indices where rightIndex > leftIndex {
                let left = spans[leftIndex]
                let right = spans[rightIndex]
                guard left.speakerID != right.speakerID else { continue }
                let start = max(left.start, right.start)
                let end = min(left.end, right.end)
                guard start < end,
                      let leftLabel = labels[left.speakerID],
                      let rightLabel = labels[right.speakerID] else { continue }
                let speakerLabels = [leftLabel, rightLabel].sorted()
                let key = "\(start)\0\(end)\0\(speakerLabels.joined(separator: "+"))"
                overlapsByKey[key] = .init(
                    start: start,
                    end: end,
                    speakerLabels: speakerLabels
                )
            }
        }
        return .init(
            modelID: exchange.modelID,
            revision: exchange.revision,
            rawSpans: spans,
            mappings: mappings.sorted {
                $0.alignmentItemIndex < $1.alignmentItemIndex
            },
            overlapRanges: overlapsByKey.values.sorted {
                ($0.start, $0.end, $0.speakerLabels.joined(separator: "+"))
                    < ($1.start, $1.end, $1.speakerLabels.joined(separator: "+"))
            },
            peakMemoryBytes: exchange.peakMemoryBytes,
            useExclusiveReconciliation: exchange.useExclusiveReconciliation,
            speakerCountPolicy: exchange.speakerCountPolicy,
            configuration: exchange.configuration,
            validationDiagnostics: centroidDiagnostics,
            speakerCentroids: speakerCentroids
        )
    }

    static func projectVoiceCentroids(
        in result: HighQualityJobResult
    ) -> [String: [HighQualitySpeakerCentroidEvidence]]? {
        guard let centroids = result.compatibleSpeakerCentroids,
              (try? speakerEditState(result.manifest.speakerEdits ?? [], for: result)) != nil else {
            return nil
        }
        let initial: [String: String] = Dictionary(uniqueKeysWithValues: centroids.map {
            ($0.speakerLabel, $0.speakerLabel)
        })
        var activeLabelByRawLabel = initial
        for edit in result.manifest.speakerEdits ?? [] {
            switch edit.kind {
            case .merge:
                guard let source = edit.speakerLabel,
                      let target = edit.targetSpeakerLabel else { return nil }
                activeLabelByRawLabel = activeLabelByRawLabel.mapValues {
                    $0 == source ? target : $0
                }
            case .reset:
                activeLabelByRawLabel = initial
            case .rename, .reassign:
                break
            }
        }
        return Dictionary(grouping: centroids) {
            activeLabelByRawLabel[$0.speakerLabel] ?? $0.speakerLabel
        }
    }

    static func persistedResultMatchingVoiceProvenance(
        _ result: HighQualityJobResult
    ) -> HighQualityJobResult? {
        guard let manifest = try? readManifest(in: result.directory),
              let evidenceData = try? Data(
                contentsOf: result.directory.appendingPathComponent("raw-asr.json")
              ),
              let persistedEvidence = try? decoder.decode(
                HighQualityRawEvidence.self,
                from: evidenceData
              ) else {
            return nil
        }
        let manifestMatches = manifest.jobID == result.manifest.jobID
            && manifest.projectID == result.manifest.projectID
            && manifest.schemaVersion == result.manifest.schemaVersion
            && manifest.status == result.manifest.status
            && manifest.rawEvidenceSHA256 == result.manifest.rawEvidenceSHA256
            && manifest.selectedBackend == result.manifest.selectedBackend
            && manifest.speakerLabels == result.manifest.speakerLabels
            && manifest.speakerConfiguration == result.manifest.speakerConfiguration
            && manifest.speakerCountPolicy == result.manifest.speakerCountPolicy
            && manifest.speakerEdits == result.manifest.speakerEdits
            && manifest.dependencies == result.manifest.dependencies
            && manifest.generatedFiles == result.manifest.generatedFiles
        let suppliedEvidenceMatches = persistedEvidence == result.evidence
            || (try? encoder.encode(result.evidence)).map {
                manifest.rawEvidenceSHA256 == sha256($0)
            } == true
        let matches = manifestMatches
            && manifest.rawEvidenceSHA256 == sha256(evidenceData)
            && suppliedEvidenceMatches
        guard matches else { return nil }
        return try? reopen(HighQualitySavedResult(
            directory: result.directory,
            manifest: manifest,
            relocatedSourcePath: nil
        ))
    }

    static func duplicateSpeakerSuggestions(
        from centroids: [HighQualitySpeakerCentroidEvidence]
    ) -> [HighQualityDuplicateSpeakerSuggestion] {
        guard centroids.count > 1,
              hasValidCompatibleSpeakerCentroids(centroids) else { return [] }
        var comparisons: [(left: Int, right: Int, distance: Float)] = []
        for leftIndex in centroids.indices {
            for rightIndex in centroids.indices where rightIndex > leftIndex {
                let left = centroids[leftIndex]
                let right = centroids[rightIndex]
                guard let distance = cosineDistance(left.vector, right.vector) else { return [] }
                comparisons.append((leftIndex, rightIndex, distance))
            }
        }
        func isUnambiguous(
            _ comparison: (left: Int, right: Int, distance: Float),
            for centroidIndex: Int
        ) -> Bool {
            let ranked = comparisons.filter {
                $0.left == centroidIndex || $0.right == centroidIndex
            }.sorted {
                ($0.distance, centroids[$0.left == centroidIndex ? $0.right : $0.left].speakerLabel)
                    < ($1.distance, centroids[$1.left == centroidIndex ? $1.right : $1.left].speakerLabel)
            }
            guard let nearest = ranked.first,
                  nearest.left == comparison.left,
                  nearest.right == comparison.right else { return false }
            return ranked.count == 1
                || ranked[1].distance - comparison.distance
                    >= HighQualityDuplicateSpeakerSuggestion.uncertaintyMargin
        }
        return comparisons.compactMap { comparison in
            guard comparison.distance
                    <= HighQualityDuplicateSpeakerSuggestion.maximumCosineDistance,
                  isUnambiguous(comparison, for: comparison.left),
                  isUnambiguous(comparison, for: comparison.right) else { return nil }
            let left = centroids[comparison.left]
            let right = centroids[comparison.right]
            return HighQualityDuplicateSpeakerSuggestion(
                firstSpeakerLabel: min(left.speakerLabel, right.speakerLabel),
                secondSpeakerLabel: max(left.speakerLabel, right.speakerLabel),
                cosineDistance: comparison.distance
            )
        }.sorted {
            ($0.cosineDistance, $0.firstSpeakerLabel, $0.secondSpeakerLabel)
                < ($1.cosineDistance, $1.firstSpeakerLabel, $1.secondSpeakerLabel)
        }
    }

    static func hasValidCompatibleSpeakerCentroids(
        _ centroids: [HighQualitySpeakerCentroidEvidence]
    ) -> Bool {
        guard let first = centroids.first,
              Set(centroids.map(\.speakerLabel)).count == centroids.count,
              centroids.allSatisfy(isValidSpeakerCentroid) else { return false }
        return centroids.dropFirst().allSatisfy {
            $0.sourceJobID == first.sourceJobID
                && $0.compatibilitySignature == first.compatibilitySignature
        }
    }

    private static func isValidSpeakerCentroid(
        _ centroid: HighQualitySpeakerCentroidEvidence
    ) -> Bool {
        guard [
            centroid.speakerLabel,
            centroid.modelID,
            centroid.modelRevision,
            centroid.runtimeRevision,
            centroid.embeddingVariant,
        ].allSatisfy(isTrimmedAndNonempty),
            centroid.sourceJobID.uuidString != "00000000-0000-0000-0000-000000000000",
            centroid.vectorDimension > 0,
            centroid.vectorDimension == centroid.vector.count,
            centroid.vector.allSatisfy(\.isFinite) else { return false }
        return hasSafeSpeakerCentroidNorm(centroid.vector)
    }

    private static func hasSafeSpeakerCentroidNorm(_ vector: [Float]) -> Bool {
        let squaredNorm = vector.reduce(Float.zero) { $0 + $1 * $1 }
        let minimum = Float.leastNormalMagnitude.squareRoot()
        let maximum = Float.greatestFiniteMagnitude.squareRoot()
        return (minimum...maximum).contains(squaredNorm)
    }

    private static func isTrimmedAndNonempty(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value
    }

    static func cosineDistance(_ left: [Float], _ right: [Float]) -> Float? {
        guard !left.isEmpty,
              left.count == right.count,
              hasSafeSpeakerCentroidNorm(left),
              hasSafeSpeakerCentroidNorm(right) else { return nil }
        var dot: Float = 0
        var leftMagnitude: Float = 0
        var rightMagnitude: Float = 0
        for index in left.indices {
            dot += left[index] * right[index]
            leftMagnitude += left[index] * left[index]
            rightMagnitude += right[index] * right[index]
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return nil }
        let distance = 1 - dot / sqrt(leftMagnitude * rightMagnitude)
        guard distance.isFinite else { return nil }
        return max(0, min(2, distance))
    }

    private static func distance(
        from item: HighQualityAlignmentItem,
        to span: HighQualityDiarizationSpan
    ) -> TimeInterval {
        if span.end <= item.start { return item.start - span.end }
        if item.end <= span.start { return span.start - item.end }
        return 0
    }

    private static func resultTurns(
        turns: [HighQualityTranslationTurn],
        speakerLabelsByID: [String: String],
        translationsByID: [String: String]
    ) -> [HighQualityTranscriptTurn] {
        turns.map { turn in
            return .init(
                id: turn.id,
                japanese: turn.japanese,
                english: translationsByID[turn.id],
                speakerLabel: speakerLabelsByID[turn.id] ?? turn.speakerLabel,
                start: turn.sourceStart,
                end: turn.sourceEnd
            )
        }
    }

    private static func transcript(
        _ turns: [HighQualityTranscriptTurn],
        text: KeyPath<HighQualityTranscriptTurn, String>
    ) -> String {
        turns.map {
            line($0[keyPath: text], speaker: $0.speakerName ?? $0.speakerLabel)
        }.joined(separator: "\n")
    }

    private static func transcript(
        _ turns: [HighQualityTranscriptTurn],
        text: KeyPath<HighQualityTranscriptTurn, String?>
    ) -> String {
        turns.compactMap { turn in
            turn[keyPath: text].map { line($0, speaker: turn.speakerName ?? turn.speakerLabel) }
        }.joined(separator: "\n")
    }

    private static func line(_ text: String, speaker: String?) -> String {
        speaker.map { "\($0): \(text)" } ?? text
    }

    static func validatedTranslations(
        _ response: String,
        for turns: [HighQualityTranslationTurn]
    ) throws -> [String: String] {
        struct Envelope: Decodable {
            struct Translation: Decodable {
                let id: String
                let text: String
            }
            let translations: [Translation]
        }

        guard let data = response.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw HighQualityTranslationValidationError(
                message: "Translation response is not valid structured JSON."
            )
        }
        let expectedIDs = Set(turns.map(\.id))
        var translations: [String: String] = [:]
        for translation in envelope.translations {
            guard expectedIDs.contains(translation.id) else {
                throw HighQualityTranslationValidationError(
                    message: "Translation response contains unknown cue \(translation.id)."
                )
            }
            guard translations[translation.id] == nil else {
                throw HighQualityTranslationValidationError(
                    message: "Translation response duplicates cue \(translation.id)."
                )
            }
            let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw HighQualityTranslationValidationError(
                    message: "Translation response leaves cue \(translation.id) empty."
                )
            }
            guard !containsTranslationScaffolding(text) else {
                throw HighQualityTranslationValidationError(
                    message: "Translation response contains explanatory scaffolding for cue \(translation.id)."
                )
            }
            translations[translation.id] = text
        }
        guard Set(translations.keys) == expectedIDs else {
            throw HighQualityTranslationValidationError(
                message: "Translation response is missing one or more requested cues."
            )
        }
        return translations
    }

    static func translationResponse(
        _ translations: [String: String],
        for turns: [HighQualityTranslationTurn]
    ) throws -> String {
        let items = turns.compactMap { turn in
            translations[turn.id].map { ["id": turn.id, "text": $0] }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "translations": items,
        ]), as: UTF8.self)
    }

    private static func numberedAttempts(
        _ attempts: [HighQualityTranslationAttempt],
        startingAt firstNumber: Int
    ) -> [HighQualityTranslationAttempt] {
        attempts.enumerated().map { offset, attempt in
            .init(
                number: firstNumber + offset,
                duration: attempt.duration,
                outcome: attempt.outcome
            )
        }
    }

    static func firstTranslationPass(
        request: HighQualityTranslationBatch,
        contextPolicy: HighQualityConversationContextPolicy,
        resetReasons: [String: HighQualityConversationContextResetReason],
        integrityGlossaryByCueID: [String: [HighQualityTranslationIntegrityGlossaryTerm]],
        fallbackModel: String = LocalMLXTranslator.modelID,
        translate: @Sendable (HighQualityTranslationBatch) async throws
            -> HighQualityTranslationExchange
    ) async throws -> (
        request: HighQualityTranslationBatch,
        exchange: HighQualityTranslationExchange
    ) {
        guard contextPolicy != .none else {
            return (request, try await translate(request))
        }

        var contextState = HighQualityConversationContextState(
            policy: contextPolicy,
            explicitResetReasons: resetReasons
        )
        var contexts: [String: HighQualityConversationContextEvidence] = [:]
        var translations: [String: String] = [:]
        var batches: [HighQualityLocalTranslationBatch] = []
        var evaluatedTurns: [HighQualityTranslationTurn] = []
        var duration: TimeInterval = 0
        var peakMemoryBytes: UInt64 = 0
        var firstExchange: HighQualityTranslationExchange?

        for turn in request.turns {
            try Task.checkCancellation()
            let context = contextState.context(for: turn)
            if let context { contexts[turn.id] = context }
            let unitRequest = HighQualityTranslationBatch(
                source: request.source,
                turns: [turn],
                glossary: request.glossary,
                glossaryByCueID: [turn.id: request.glossary(for: turn)],
                conversationContextByCueID: context.map { [turn.id: $0] } ?? [:]
            )
            let exchange: HighQualityTranslationExchange
            do {
                exchange = try await translate(unitRequest)
            } catch {
                if error is HeavyweightModelGateError { throw error }
                let serviceError = error as? HighQualityTranslationServiceError
                var errorAttempts = duration > 0 ? [HighQualityTranslationAttempt(
                    number: 1,
                    duration: duration,
                    outcome: "success"
                )] : []
                errorAttempts += numberedAttempts(
                    serviceError?.attempts ?? [.init(
                        number: 1,
                        duration: 0,
                        outcome: error.localizedDescription
                    )],
                    startingAt: errorAttempts.count + 1
                )
                throw HighQualityTranslationServiceError(
                    model: serviceError?.model ?? firstExchange?.model ?? fallbackModel,
                    attempts: errorAttempts,
                    response: serviceError?.response,
                    revision: serviceError?.revision ?? firstExchange?.revision,
                    runtimeVersion: serviceError?.runtimeVersion
                        ?? firstExchange?.runtimeVersion,
                    batches: batches + (serviceError?.batches ?? []),
                    peakMemoryBytes: max(
                        peakMemoryBytes,
                        serviceError?.peakMemoryBytes ?? 0
                    ),
                    message: error.localizedDescription
                )
            }
            if firstExchange == nil { firstExchange = exchange }
            duration += exchange.attempts.reduce(0) { $0 + $1.duration }
            peakMemoryBytes = max(peakMemoryBytes, exchange.peakMemoryBytes)
            let unitBatches = exchange.batches.map { batch in
                HighQualityLocalTranslationBatch(
                    cueIDs: batch.cueIDs,
                    sanitizedPrompt: batch.sanitizedPrompt,
                    nativePrompt: batch.nativePrompt,
                    nativeOutput: batch.nativeOutput,
                    model: batch.model,
                    revision: batch.revision,
                    sanitizedOutput: batch.sanitizedOutput,
                    inputTokens: batch.inputTokens,
                    outputTokens: batch.outputTokens,
                    finishReason: batch.finishReason,
                    duration: batch.duration,
                    context: context
                )
            }
            batches += unitBatches
            let unitTranslations = HighQualityTranslationIntegrityValidator.canonicalized(
                try validatedTranslations(exchange.response, for: [turn]),
                turns: [turn],
                glossaryByCueID: integrityGlossaryByCueID
            )
            translations.merge(unitTranslations) { _, latest in latest }
            evaluatedTurns.append(turn)
            let verdict = HighQualityTranslationIntegrityValidator.validate(
                turns: evaluatedTurns,
                translations: translations,
                batches: batches,
                glossary: [],
                glossaryByCueID: integrityGlossaryByCueID
            ).first { $0.cueID == turn.id }
            if verdict?.verdict == .pass, let english = unitTranslations[turn.id] {
                contextState.accept(turn, english: english)
            }
        }

        guard let firstExchange else {
            return (request, try await translate(request))
        }
        let contextualRequest = HighQualityTranslationBatch(
            source: request.source,
            turns: request.turns,
            glossary: request.glossary,
            glossaryByCueID: request.glossaryByCueID,
            conversationContextByCueID: contexts
        )
        return (contextualRequest, .init(
            model: firstExchange.model,
            response: try translationResponse(translations, for: request.turns),
            attempts: [.init(number: 1, duration: duration, outcome: "success")],
            revision: firstExchange.revision,
            runtimeVersion: firstExchange.runtimeVersion,
            batches: batches,
            peakMemoryBytes: peakMemoryBytes
        ))
    }

    static func annotatedBatches(
        _ batches: [HighQualityLocalTranslationBatch],
        verdicts: [HighQualityTranslationIntegrityVerdict],
        attempt: Int,
        forceFailure: Bool = false
    ) -> [HighQualityLocalTranslationBatch] {
        batches.map { batch in
            let unitVerdicts = verdicts.filter { batch.cueIDs.contains($0.cueID) }
            let accepted = !forceFailure
                && !unitVerdicts.isEmpty
                && unitVerdicts.allSatisfy {
                    attempt == 1 ? $0.verdict == .pass : $0.verdict != .hardFailure
                }
            return .init(
                cueIDs: batch.cueIDs,
                sanitizedPrompt: batch.sanitizedPrompt,
                nativePrompt: batch.nativePrompt,
                nativeOutput: batch.nativeOutput,
                model: batch.model,
                revision: batch.revision,
                sanitizedOutput: batch.sanitizedOutput,
                inputTokens: batch.inputTokens,
                outputTokens: batch.outputTokens,
                finishReason: batch.finishReason,
                duration: batch.duration,
                attemptNumber: attempt,
                validationReasonCodes: unitVerdicts.flatMap { $0.reasons.map(\.code) },
                selected: accepted,
                terminalOutcome: accepted ? "accepted" : (attempt == 1 ? "rejected" : "failed"),
                context: batch.context
            )
        }
    }

    private static func containsTranslationScaffolding(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return [
            "here is the translation", "here's the translation",
            "translation:", "english translation:",
        ].contains { lowercased.hasPrefix($0) }
            || ["```", "speaker_id:", "context_before:", "context_after:", "<<<current:", "<<<end_current:"]
                .contains { lowercased.contains($0) }
    }

    static func validatedAlignment(
        _ chunks: [HighQualityAlignmentChunk],
        turns: [HighQualityTranslationTurn],
        duration: TimeInterval,
        fallbackMerges: [HighQualityAlignmentFallbackMerge] = []
    ) throws -> [HighQualityAlignedCue] {
        guard duration.isFinite, duration >= 0 else {
            throw HighQualityTranslationValidationError(message: "Source duration is invalid.")
        }
        let rawExpectedText = Dictionary(uniqueKeysWithValues: turns.map {
            ($0.id, $0.japanese.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        var expectedText = rawExpectedText
        var mergedSourceIDs: Set<String> = []
        for merge in fallbackMerges {
            guard ["previous", "following"].contains(merge.direction),
                  ["merge-adjacent-valid-cue", "coarse-fallback-free-window-gap"]
                    .contains(merge.timingPolicy),
                  merge.sourceCueID != merge.targetCueID,
                  mergedSourceIDs.insert(merge.sourceCueID).inserted,
                  let sourceText = expectedText[merge.sourceCueID],
                  let targetText = expectedText[merge.targetCueID],
                  sourceText == merge.sourceText,
                  targetText == merge.targetOriginalText else {
                throw HighQualityTranslationValidationError(
                    message: "Alignment fallback evidence is inconsistent."
                )
            }
            let mergedText = merge.direction == "previous"
                ? targetText + sourceText : sourceText + targetText
            let mergedDuration = merge.finalEnd - merge.finalStart
            guard mergedText == merge.mergedText,
                  mergedText.count <= HighQualityForcedAlignerRuntime.maximumFallbackCharacters,
                  mergedDuration > 0,
                  Double(mergedText.count) / mergedDuration
                    <= HighQualityForcedAlignerRuntime.maximumFallbackCharactersPerSecond,
                  merge.sourceOriginalStart.isFinite,
                  merge.sourceOriginalEnd == merge.sourceOriginalStart,
                  merge.targetOriginalStart.isFinite,
                  merge.targetOriginalEnd > merge.targetOriginalStart,
                  merge.finalStart == merge.targetOriginalStart,
                  merge.finalEnd >= merge.targetOriginalEnd,
                  merge.finalEnd <= merge.freeGapEnd,
                  merge.timingPolicy == "coarse-fallback-free-window-gap"
                    || merge.finalEnd == merge.targetOriginalEnd else {
                throw HighQualityTranslationValidationError(
                    message: "Alignment fallback timing or readability is invalid."
                )
            }
            expectedText[merge.targetCueID] = mergedText
            expectedText.removeValue(forKey: merge.sourceCueID)
        }
        let expectedIDs = Set(expectedText.keys)
        let rawExpectedIDs = Set(rawExpectedText.keys)
        var seen: Set<String> = []
        var previousEnd = -Double.infinity
        var previousChunkStart = -Double.infinity
        var seenChunkIndices: Set<Int> = []
        var merged: [HighQualityAlignedCue] = []
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            guard chunk.sourceStart.isFinite,
                  chunk.sourceEnd.isFinite,
                  chunk.sourceStart >= 0,
                  chunk.sourceStart >= previousChunkStart,
                  chunk.sourceEnd >= chunk.sourceStart,
                  chunk.sourceEnd <= duration,
                  seenChunkIndices.insert(chunk.index).inserted else {
                throw HighQualityTranslationValidationError(
                    message: "Alignment chunk \(chunk.index) is outside the source timeline."
                )
            }
            previousChunkStart = chunk.sourceStart
            var previousRawStart = -Double.infinity
            for item in chunk.rawItems {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawExpectedIDs.contains(item.cueID),
                      !text.isEmpty,
                      item.start.isFinite,
                      item.end.isFinite,
                      item.start >= chunk.sourceStart,
                      item.end >= item.start,
                      item.end <= chunk.sourceEnd,
                      item.start >= previousRawStart else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment raw item for cue \(item.cueID) is invalid."
                    )
                }
                previousRawStart = item.start
            }
            for cue in chunk.cues {
                let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let cueRawItems = chunk.rawItems.filter { $0.cueID == cue.id }
                if cue.timingOrigin != nil || cue.timingPolicy != nil
                    || cue.timingQuality != nil {
                    let coarseDuration = Double(text.count)
                        / HighQualityForcedAlignerRuntime.maximumFallbackCharactersPerSecond
                    let anchor = cueRawItems.first?.start ?? .nan
                    let lowerBound = max(previousEnd, chunk.sourceStart)
                    let coarseStart = min(
                        max(anchor - coarseDuration, lowerBound),
                        chunk.sourceEnd - coarseDuration
                    )
                    guard cue.timingOrigin == "asr-window-anchor",
                          cue.timingPolicy == "single-zero-cue-asr-anchor-20cps",
                          cue.timingQuality == "coarse",
                          chunk.cues.count == 1,
                          text.count <= HighQualityForcedAlignerRuntime.maximumCoarseAnchorCharacters,
                          !cueRawItems.isEmpty,
                          cueRawItems.count == chunk.rawItems.count,
                          cueRawItems.allSatisfy({
                              $0.start == $0.end
                                  && $0.start == anchor
                                  && $0.start >= cue.start
                                  && $0.end <= cue.end
                          }),
                          coarseDuration <= chunk.sourceEnd - lowerBound,
                          cue.start == coarseStart,
                          cue.end == coarseStart + coarseDuration else {
                        throw HighQualityTranslationValidationError(
                            message: "Alignment cue \(cue.id) has invalid coarse timing evidence."
                        )
                    }
                }
                guard expectedIDs.contains(cue.id) else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment contains unknown cue \(cue.id)."
                    )
                }
                guard seen.insert(cue.id).inserted else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment duplicates cue \(cue.id)."
                    )
                }
                guard !text.isEmpty else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment leaves cue \(cue.id) empty."
                    )
                }
                guard text == expectedText[cue.id] else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment changes the Japanese text for cue \(cue.id)."
                    )
                }
                guard cue.start.isFinite,
                      cue.end.isFinite,
                      cue.start >= 0,
                      cue.end > cue.start,
                      cue.end <= duration,
                      cue.start >= chunk.sourceStart,
                      cue.end <= chunk.sourceEnd,
                      cue.start >= previousEnd else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment cue \(cue.id) has invalid or non-monotonic timing."
                    )
                }
                previousEnd = cue.end
                merged.append(.init(id: cue.id, text: text, start: cue.start, end: cue.end))
            }
            for fallback in fallbackMerges where fallback.chunkIndex == chunk.index {
                guard !chunk.cues.contains(where: { $0.id == fallback.sourceCueID }),
                      chunk.cues.contains(where: {
                          $0.id == fallback.targetCueID
                              && $0.text == fallback.mergedText
                              && $0.start == fallback.finalStart
                              && $0.end == fallback.finalEnd
                      }) else {
                    throw HighQualityTranslationValidationError(
                        message: "Alignment fallback does not match its chunk."
                    )
                }
            }
        }
        guard seen == expectedIDs,
              Set(fallbackMerges.map(\.chunkIndex)).isSubset(of: seenChunkIndices) else {
            throw HighQualityTranslationValidationError(
                message: "Alignment is missing one or more transcript cues."
            )
        }
        return merged
    }

    private static func restoreDeliverablesIfNeeded(for result: HighQualityJobResult) throws {
        let deliverables = Set(result.manifest.deliverables)
        let files = deliverableFiles(
            japaneseTranscript: deliverables.contains(.japaneseTranscript)
                ? result.japaneseTranscript : nil,
            englishTranscript: result.englishTranscript,
            subtitleCues: deliverables.contains(.englishSubtitles) ? result.subtitleCues : nil
        )
        guard files.contains(where: { path, data in
            (try? Data(contentsOf: result.directory.appendingPathComponent(path))) != data
        }) else { return }
        let transformations = try readTransformations(in: result.directory)
        try transactionallyWrite(
            files,
            in: result.directory,
            validateActive: {
                guard try activeResultMatches(
                    result.manifest,
                    transformations: transformations,
                    in: result.directory
                ) else {
                    throw HighQualityJobError(
                        stage: .export,
                        message: "The saved result changed while restoring Deliverables.",
                        resultDirectory: result.directory
                    )
                }
            }
        )
    }

    private static func deliverableFiles(
        japaneseTranscript: String?,
        englishTranscript: String?,
        subtitleCues: [HighQualitySubtitleCue]?
    ) -> [String: Data] {
        var files: [String: Data] = [:]
        if let japaneseTranscript {
            files["japanese-transcript.txt"] = Data((japaneseTranscript + "\n").utf8)
        }
        if let englishTranscript {
            files["english-translation-transcript.txt"] = Data(
                (englishTranscript + "\n").utf8
            )
        }
        if let subtitleCues {
            files["english-subtitles.vtt"] = Data(webVTT(subtitleCues).utf8)
            files["english-subtitles.srt"] = Data(srt(subtitleCues).utf8)
        }
        return files
    }

    private static func writeFiles(_ files: [String: Data], to directory: URL) throws {
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try data.write(
                to: directory.appendingPathComponent(path),
                options: .atomic
            )
        }
    }

    private static func transactionallyWrite(
        _ files: [String: Data],
        in directory: URL,
        beforeCommit: () throws -> Void = {},
        afterStaging: () throws -> Void = {},
        finalizeBeforeCommit: () throws -> [String: Data] = { [:] },
        afterCommit: () throws -> Void = {},
        validateActive: () throws -> Void = {}
    ) throws {
        let fileManager = FileManager.default
        try beforeCommit()
        let lockURL = directory.deletingLastPathComponent().appendingPathComponent(
            ".\(directory.lastPathComponent).update.lock"
        )
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try validateActive()
        let staging = directory.deletingLastPathComponent().appendingPathComponent(
            ".\(directory.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? AtomicDirectory.remove(staging) }
        try AtomicDirectory.cloneContents(of: directory, to: staging)
        try writeFiles(files, to: staging)
        guard files.allSatisfy({ path, data in
            (try? Data(contentsOf: staging.appendingPathComponent(path))) == data
        }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try afterStaging()
        // Stamp the commit only after a complete payload is staged and verified; the
        // stamp itself must precede the single atomic swap that makes it durable.
        let finalFiles = try finalizeBeforeCommit()
        try writeFiles(finalFiles, to: staging)
        let expectedFiles = files.merging(finalFiles) { _, final in final }
        guard expectedFiles.allSatisfy({ path, data in
            (try? Data(contentsOf: staging.appendingPathComponent(path))) == data
        }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Task.checkCancellation()
        try AtomicDirectory.swap(staging, with: directory)
        try afterCommit()
    }

    static func webVTT(_ cues: [HighQualitySubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            let content = subtitleText(cue)
            let text = (cue.speakerName ?? cue.speakerLabel).map {
                "<v \(webVTTSpeaker($0))>\(content)"
            }
                ?? content
            return "\(cue.id)\n\(SubtitleTimecode.webVTT(cue.start)) --> \(SubtitleTimecode.webVTT(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    static func srt(_ cues: [HighQualitySubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            let content = subtitleText(cue)
            let text = (cue.speakerName ?? cue.speakerLabel).map { "[\($0)] \(content)" }
                ?? content
            return "\(index + 1)\n\(SubtitleTimecode.srt(cue.start)) --> \(SubtitleTimecode.srt(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func subtitleText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func subtitleText(_ cue: HighQualitySubtitleCue) -> String {
        cue.renderedLines?.map(subtitleText).joined(separator: "\n")
            ?? subtitleText(cue.text)
    }

    private static func webVTTSpeaker(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func generatedFiles(
        deliverables: Set<HighQualityDeliverable>,
        acquiredAudioURL: URL? = nil
    ) -> [HighQualityGeneratedFile] {
        var files: [HighQualityGeneratedFile] = []
        if deliverables.contains(.japaneseTranscript) {
            files.append(.init(path: "japanese-transcript.txt", kind: .deliverable))
        }
        if deliverables.contains(.englishTranslationTranscript) {
            files.append(.init(path: "english-translation-transcript.txt", kind: .deliverable))
        }
        if deliverables.contains(.englishSubtitles) {
            files.append(.init(path: "english-subtitles.vtt", kind: .deliverable))
            files.append(.init(path: "english-subtitles.srt", kind: .deliverable))
        }
        if let acquiredAudioURL {
            files.append(.init(
                path: "acquisition/\(acquiredAudioURL.lastPathComponent)",
                kind: .evidence
            ))
        }
        files.append(.init(path: "raw-asr.json", kind: .evidence))
        files.append(.init(path: "manifest.json", kind: .manifest))
        return files
    }

    private static func validateYouTubeURL(_ url: URL) throws {
        let host = url.host?.lowercased()
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasPlaylist = url.path == "/playlist" || query.contains { $0.name == "list" }
        let pathParts = url.path.split(separator: "/")
        let isVideoPath: Bool
        if host == "youtu.be" {
            isVideoPath = pathParts.count == 1
        } else {
            isVideoPath = (url.path == "/watch" && query.contains {
                $0.name == "v" && !($0.value ?? "").isEmpty
            }) || (pathParts.count == 2 && ["shorts", "live"].contains(String(pathParts[0])))
        }
        guard url.scheme?.lowercased() == "https",
              youtubeHosts.contains(host ?? ""),
              url.user == nil,
              url.password == nil,
              !hasPlaylist,
              isVideoPath else {
            throw HighQualityJobError(
                stage: .acquisition,
                message: hasPlaylist
                    ? "YouTube playlists are not supported. Paste one public video URL."
                    : "Enter a valid public YouTube video URL.",
                resultDirectory: nil
            )
        }
    }

    private static func evidence(
        rawASR: String?,
        adaptiveASR: HighQualityAdaptiveASRAudit?,
        glossary: HighQualityGlossarySelection,
        alignment: HighQualityAlignmentEvidence?,
        diarization: HighQualityDiarizationEvidence?,
        speakerAttachment: HighQualitySpeakerAttachmentEvidence? = nil,
        translation: HighQualityTranslationEvidence?,
        sampleCount: Int,
        sourceAudioSHA256: String? = nil,
        resultTurns: [HighQualityTranscriptTurn]? = nil,
        subtitleCues: [HighQualitySubtitleCue]? = nil,
        japaneseTranscript: String? = nil,
        englishTranscript: String? = nil,
        readableSubtitles: HighQualityReadableSubtitleEvidence? = nil,
        manifest: HighQualityJobManifest
    ) -> HighQualityRawEvidence {
        HighQualityRawEvidence(
            source: manifest.source,
            model: manifest.model,
            asrWorker: manifest.asrWorker,
            adaptiveASR: adaptiveASR,
            speakerConfiguration: manifest.speakerConfiguration,
            speakerCountPolicy: manifest.speakerCountPolicy,
            rawASR: rawASR,
            glossary: glossary,
            alignment: alignment,
            diarization: diarization,
            speakerAttachment: speakerAttachment,
            translation: translation,
            sampleRate: 16_000,
            sampleCount: sampleCount,
            sourceAudioSHA256: sourceAudioSHA256,
            stageDurations: manifest.stageDurations,
            peakMemoryBytes: manifest.peakMemoryBytes,
            modelEvents: manifest.modelEvents,
            failures: manifest.failures,
            generatedFiles: manifest.generatedFiles,
            resultTurns: resultTurns,
            subtitleCues: subtitleCues,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            readableSubtitles: readableSubtitles,
            projectID: manifest.projectID
        )
    }

    @discardableResult
    private static func writeEvidenceAndManifest(
        rawASR: String?,
        adaptiveASR: HighQualityAdaptiveASRAudit?,
        glossary: HighQualityGlossarySelection,
        alignment: HighQualityAlignmentEvidence?,
        diarization: HighQualityDiarizationEvidence?,
        speakerAttachment: HighQualitySpeakerAttachmentEvidence? = nil,
        translation: HighQualityTranslationEvidence?,
        sampleCount: Int,
        sourceAudioSHA256: String? = nil,
        resultTurns: [HighQualityTranscriptTurn]? = nil,
        subtitleCues: [HighQualitySubtitleCue]? = nil,
        japaneseTranscript: String? = nil,
        englishTranscript: String? = nil,
        readableSubtitles: HighQualityReadableSubtitleEvidence? = nil,
        manifest: inout HighQualityJobManifest,
        to directory: URL
    ) throws -> HighQualityRawEvidence {
        let evidence = evidence(
            rawASR: rawASR,
            adaptiveASR: adaptiveASR,
            glossary: glossary,
            alignment: alignment,
            diarization: diarization,
            speakerAttachment: speakerAttachment,
            translation: translation,
            sampleCount: sampleCount,
            sourceAudioSHA256: sourceAudioSHA256,
            resultTurns: resultTurns,
            subtitleCues: subtitleCues,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            readableSubtitles: readableSubtitles,
            manifest: manifest
        )
        let data = try encoder.encode(evidence)
        manifest.rawEvidenceSHA256 = sha256(data)
        try data.write(
            to: directory.appendingPathComponent("raw-asr.json"),
            options: .atomic
        )
        try writeManifest(manifest, to: directory)
        return evidence
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func audioSHA256(_ samples: [Float]) -> String {
        var hasher = SHA256()
        samples.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidSHA256(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func matchesSavedSource(
        _ sourceURL: URL,
        samples: [Float],
        sha256: String,
        result: HighQualityJobResult
    ) -> Bool {
        guard samples.count == result.evidence.sampleCount else { return false }
        if let expected = result.evidence.sourceAudioSHA256 {
            return isValidSHA256(expected) && sha256 == expected.lowercased()
        }

        // Schema 3 results predate normalized-audio hashes; verify their stored file
        // provenance once, then persist the hash on the successful reanalysis.
        let current = provenance(for: sourceURL)
        guard let expectedBytes = result.evidence.source.byteCount,
              current.byteCount == expectedBytes,
              let expectedDate = result.evidence.source.modifiedAt,
              let currentDate = current.modifiedAt else { return false }
        let originalPath = URL(fileURLWithPath: result.evidence.source.path)
            .standardizedFileURL.path
        return sourceURL.standardizedFileURL.path == originalPath
            && Int64(currentDate.timeIntervalSince1970)
                == Int64(expectedDate.timeIntervalSince1970)
    }

    private static func writeManifest(
        _ manifest: HighQualityJobManifest,
        to directory: URL
    ) throws {
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private static func readManifest(in directory: URL) throws -> HighQualityJobManifest {
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        guard (2...HighQualityJobManifest.currentSchemaVersion).contains(
            manifest.schemaVersion
        ) else {
            throw HighQualityJobError(
                stage: .application,
                message: "This saved High-quality job uses an unsupported schema version.",
                resultDirectory: directory
            )
        }
        return manifest
    }

    private static func speakerReanalysisCompletion(
        for manifest: HighQualityJobManifest,
        in directory: URL
    ) throws -> HighQualitySpeakerReanalysisCompletion? {
        guard let count = manifest.speakerReanalysisCount,
              let evidenceHash = manifest.rawEvidenceSHA256 else { return nil }
        return try readSpeakerReanalysisJournal(in: directory)?.entries.last {
            $0.reanalysisCount == count && $0.rawEvidenceSHA256 == evidenceHash
        }
    }

    private static func writeSpeakerReanalysisCompletion(
        _ completion: HighQualitySpeakerReanalysisCompletion,
        in directory: URL,
        write: (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) throws {
        try write(
            speakerReanalysisJournalData(upserting: completion, in: directory),
            directory.appendingPathComponent("speaker-reanalysis-journal.json")
        )
    }

    private static func speakerReanalysisJournalData(
        upserting completion: HighQualitySpeakerReanalysisCompletion,
        in directory: URL
    ) throws -> Data {
        var journal = try readSpeakerReanalysisJournal(in: directory)
            ?? .init(
                schemaVersion: HighQualitySpeakerReanalysisJournal.currentSchemaVersion,
                entries: []
            )
        if let index = journal.entries.firstIndex(where: {
            $0.reanalysisCount == completion.reanalysisCount
        }) {
            journal.entries[index] = completion
        } else {
            journal.entries.append(completion)
        }
        return try encoder.encode(journal)
    }

    private static func readSpeakerReanalysisJournal(
        in directory: URL
    ) throws -> HighQualitySpeakerReanalysisJournal? {
        let url = directory.appendingPathComponent("speaker-reanalysis-journal.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let journal = try decoder.decode(
            HighQualitySpeakerReanalysisJournal.self,
            from: Data(contentsOf: url)
        )
        let counts = Set(journal.entries.map(\.reanalysisCount))
        guard journal.schemaVersion == HighQualitySpeakerReanalysisJournal.currentSchemaVersion,
              counts.count == journal.entries.count,
              journal.entries.allSatisfy({ entry in
                  entry.reanalysisCount > 0
                      && entry.rawEvidenceSHA256.count == 64
                      && entry.rawEvidenceSHA256.allSatisfy(\.isHexDigit)
                      && entry.startedAt.timeIntervalSince1970.isFinite
                      && entry.payloadPreparedAt >= entry.startedAt
                      && entry.finishedAt >= entry.payloadPreparedAt
                      && abs(entry.wallTime
                          - entry.finishedAt.timeIntervalSince(entry.startedAt)) < 0.000_001
                      && abs(entry.commitWallTime
                          - entry.finishedAt.timeIntervalSince(entry.payloadPreparedAt))
                          < 0.000_001
                      && entry.auditError?.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty != true
              }) else {
            throw HighQualityJobError(
                stage: .export,
                message: "The Speaker reanalysis completion audit is invalid.",
                resultDirectory: directory
            )
        }
        return journal
    }

    private static func readTransformations(
        in directory: URL
    ) throws -> HighQualityResultTransformations? {
        let url = directory.appendingPathComponent("transformations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let transformations = try decoder.decode(
                HighQualityResultTransformations.self,
                from: Data(contentsOf: url)
            )
            let normalizedEdits = try transformations.speakerEdits.map {
                try normalizedSpeakerEdit($0, in: directory)
            }
            guard (1...HighQualityResultTransformations.currentSchemaVersion)
                    .contains(transformations.schemaVersion),
                  transformations.schemaVersion != 1 || transformations.speakerEdits.isEmpty,
                  transformations.schemaVersion == 1
                    || transformations.customSpeakerLabels.isEmpty,
                  normalizedEdits == transformations.speakerEdits,
                  transformations.customSpeakerLabels.values.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }),
                  transformations.relocatedSourcePath?.hasPrefix("/") != false else {
                throw HighQualityJobError(
                    stage: .application,
                    message: "The saved transformations are unsupported.",
                    resultDirectory: directory
                )
            }
            return transformations
        } catch let error as HighQualityJobError {
            throw error
        } catch {
            throw HighQualityJobError(
                stage: .application,
                message: "The saved transformations are unreadable.",
                resultDirectory: directory
            )
        }
    }

    private static func storedText(at url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.last == "\n" { text.removeLast() }
        return text
    }

    private static func savedResultError(
        _ message: String,
        _ saved: HighQualitySavedResult,
        stage: HighQualityJobFailureStage = .application
    ) -> HighQualityJobError {
        HighQualityJobError(
            stage: stage,
            message: message,
            resultDirectory: saved.directory
        )
    }

    private static func speakerEditError(
        _ message: String,
        in directory: URL
    ) -> HighQualityJobError {
        HighQualityJobError(stage: .export, message: message, resultDirectory: directory)
    }

    private static var decoder: JSONDecoder {
        let fractionalDates = ISO8601DateFormatter()
        fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyDates = ISO8601DateFormatter()
        legacyDates.formatOptions = [.withInternetDateTime]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = fractionalDates.date(from: value) ?? legacyDates.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static func persistedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
    }

    private static var encoder: JSONEncoder {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dates.string(from: date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
