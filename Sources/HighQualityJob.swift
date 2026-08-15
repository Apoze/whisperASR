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
    let backend: HighQualityASRBackend
    let translator: HighQualityTranslator
    let speakerLabels: Bool
    let useExclusiveReconciliation: Bool
    let speakerConfiguration: HighQualitySpeakerConfiguration
    var speakerCountPolicy: HighQualitySpeakerCountPolicy { speakerConfiguration.countPolicy }
    let speakerLabelsByCueID: [String: String]
    let translationContextPolicy: HighQualityConversationContextPolicy
    let translationContextResetReasonsByCueID: [String: HighQualityConversationContextResetReason]
    let project: HighQualityProject?
    let outputRoot: URL

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        deliverables: Set<HighQualityDeliverable>,
        backend: HighQualityASRBackend,
        translator: HighQualityTranslator = .productDefault,
        speakerLabels: Bool = false,
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
        self.id = id
        self.sourceURL = sourceURL
        self.deliverables = deliverables
        self.backend = backend
        self.translator = translator
        self.speakerLabels = speakerLabels
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerConfiguration = speakerConfiguration
        self.speakerLabelsByCueID = speakerLabelsByCueID
        self.translationContextPolicy = translationContextPolicy
        self.translationContextResetReasonsByCueID = translationContextResetReasonsByCueID
        self.project = project
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

struct HighQualityASRExchange: Codable, Equatable, Sendable {
    let rawTranscript: String
    let chunks: [HighQualityASRChunk]
    let characters: [HighQualityASRCharacter]?
    let averageLogProbability: Double?

    init(
        rawTranscript: String,
        chunks: [HighQualityASRChunk],
        characters: [HighQualityASRCharacter]? = nil,
        averageLogProbability: Double? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.chunks = chunks
        self.characters = characters
        self.averageLogProbability = averageLogProbability
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

struct HighQualityDiarizationExchange: Codable, Equatable, Sendable {
    let spans: [HighQualityDiarizationSpan]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
    let useExclusiveReconciliation: Bool
    let speakerCountPolicy: HighQualitySpeakerCountPolicy
    let configuration: [String: String]?

    init(
        spans: [HighQualityDiarizationSpan],
        modelID: String,
        revision: String,
        peakMemoryBytes: UInt64,
        useExclusiveReconciliation: Bool = false,
        speakerCountPolicy: HighQualitySpeakerCountPolicy = .automatic,
        configuration: [String: String]? = nil
    ) {
        self.spans = spans
        self.modelID = modelID
        self.revision = revision
        self.peakMemoryBytes = peakMemoryBytes
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerCountPolicy = speakerCountPolicy
        self.configuration = configuration
    }
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
        worker: HighQualityWorkerEvidence? = nil
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
    }
}

struct HighQualitySubtitleCue: Codable, Equatable, Sendable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerLabel: String?
    let speakerName: String?

    init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerLabel: String? = nil,
        speakerName: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
        self.speakerName = speakerName
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
    static let currentSchemaVersion = 4

    enum Status: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
    }

    let schemaVersion: Int
    let jobID: UUID
    var status: Status
    var source: HighQualitySourceProvenance
    let deliverables: [HighQualityDeliverable]
    let selectedBackend: HighQualityASRBackend
    let translationModel: HighQualityTranslationModelEvidence?
    let speakerLabels: Bool
    let speakerConfiguration: HighQualitySpeakerConfiguration?
    let speakerCountPolicy: HighQualitySpeakerCountPolicy?
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
}

struct HighQualityRawEvidence: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let model: HighQualityModelEvidence
    let asrWorker: HighQualityASRWorkerEvidence?
    let speakerConfiguration: HighQualitySpeakerConfiguration?
    let speakerCountPolicy: HighQualitySpeakerCountPolicy?
    let rawASR: String?
    let glossary: HighQualityGlossarySelection
    let alignment: HighQualityAlignmentEvidence?
    let diarization: HighQualityDiarizationEvidence?
    let translation: HighQualityTranslationEvidence?
    let sampleRate: Int
    let sampleCount: Int
    let stageDurations: [HighQualityJobStage: TimeInterval]
    let peakMemoryBytes: UInt64
    let modelEvents: [HighQualityModelEvent]
    let failures: [HighQualityJobFailure]
    let generatedFiles: [HighQualityGeneratedFile]
    var resultTurns: [HighQualityTranscriptTurn]? = nil
    var subtitleCues: [HighQualitySubtitleCue]? = nil
    var japaneseTranscript: String? = nil
    var englishTranscript: String? = nil
    var projectID: UUID? = nil
}

struct HighQualityJobResult: Sendable {
    let directory: URL
    let japaneseTranscript: String
    let englishTranscript: String?
    let turns: [HighQualityTranscriptTurn]
    let subtitleCues: [HighQualitySubtitleCue]
    let manifest: HighQualityJobManifest
    let evidence: HighQualityRawEvidence
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

private struct HighQualityResultTransformations: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let customSpeakerLabels: [String: String]
    var relocatedSourcePath: String? = nil
}

struct HighQualityJobError: LocalizedError, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
    let resultDirectory: URL?

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
                characters: characters
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

    init() {
        servicesForSelection = { Services.production(for: $0, translator: $1) }
    }

    init(services: Services) {
        servicesForSelection = { _, _ in services }
    }

    init(servicesForBackend: @escaping @Sendable (HighQualityASRBackend) -> Services) {
        servicesForSelection = { backend, _ in servicesForBackend(backend) }
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
        do {
            let data = try Data(contentsOf: evidenceURL)
            if let expected = manifest.rawEvidenceSHA256 {
                guard sha256(data) == expected else {
                    throw savedResultError("Raw evidence verification failed.", saved)
                }
            } else if manifest.schemaVersion >= 3 {
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
              evidence.generatedFiles == manifest.generatedFiles,
              evidence.projectID == manifest.projectID else {
            throw savedResultError("The saved manifest and raw evidence do not match.", saved)
        }
        for file in manifest.generatedFiles
            where manifest.schemaVersion < 3 && file.kind == .deliverable {
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
        if manifest.schemaVersion >= 3,
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
                (evidence.alignment?.semanticUnits ?? []).compactMap { unit in
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
            } else if manifest.schemaVersion < 3 {
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
            result = applyingCustomSpeakerLabels(
                transformations.customSpeakerLabels,
                to: result
            )
        }
        if manifest.schemaVersion >= 3 {
            do {
                try restoreDeliverablesIfNeeded(for: result)
            } catch {
                throw savedResultError(
                    "Saved Deliverables could not be restored from verified evidence.",
                    saved
                )
            }
        }
        return result
    }

    static func relocateSource(
        _ saved: HighQualitySavedResult,
        to sourceURL: URL
    ) throws -> HighQualitySavedResult {
        guard saved.manifest.source.youtube == nil,
              sourceURL.isFileURL,
              (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                == true else {
            throw savedResultError("Choose an existing local media file.", saved)
        }
        _ = try reopen(saved)
        let previous = try readTransformations(in: saved.directory)
        let relocatedPath = sourceURL.standardizedFileURL.path
        let transformations = try encoder.encode(HighQualityResultTransformations(
            schemaVersion: HighQualityResultTransformations.currentSchemaVersion,
            customSpeakerLabels: previous?.customSpeakerLabels ?? [:],
            relocatedSourcePath: relocatedPath
        ))
        try transactionallyWrite(
            ["transformations.json": transformations],
            in: saved.directory
        )
        return HighQualitySavedResult(
            directory: saved.directory,
            manifest: saved.manifest,
            relocatedSourcePath: relocatedPath
        )
    }

    static func clearRelocatedSource(in directory: URL) throws {
        guard let previous = try readTransformations(in: directory),
              previous.relocatedSourcePath != nil else { return }
        let transformations = try encoder.encode(HighQualityResultTransformations(
            schemaVersion: HighQualityResultTransformations.currentSchemaVersion,
            customSpeakerLabels: previous.customSpeakerLabels,
            relocatedSourcePath: nil
        ))
        try transactionallyWrite(
            ["transformations.json": transformations],
            in: directory
        )
    }

    func run(
        _ request: HighQualityJobRequest,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
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
        var rawASR: String?
        var glossary = HighQualityGlossarySelection.empty
        var japaneseTranscriptWritten = false
        var englishTranscriptWritten = false
        var subtitlesWritten = false
        var alignmentEvidence: HighQualityAlignmentEvidence?
        var diarizationEvidence: HighQualityDiarizationEvidence?
        var alignedItems: [HighQualityAlignmentItem] = []
        var translationEvidence: HighQualityTranslationEvidence?
        var acquiredAudioURL: URL?
        var asrLoadStarted = false
        var asrUnloaded = false
        var alignmentLoadStarted = false
        var alignmentUnloaded = false
        var diarizationLoadStarted = false
        var diarizationUnloaded = false
        var translationLoadStarted = false
        var translationUnloaded = false
        var workflowLease: HeavyweightWorkflowLease?
        var asrLease: HeavyweightModelLease?
        var alignmentLease: HeavyweightModelLease?
        var diarizationLease: HeavyweightModelLease?
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
            translationModel: needsTranslation ? translationModel : nil,
            speakerLabels: request.speakerLabels || !request.speakerLabelsByCueID.isEmpty,
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
            let asrExchange: HighQualityASRExchange
            if needsAlignment {
                asrExchange = try await withMemoryGuard(asrLease) {
                    try await services.transcribeJapaneseAnchored(samples)
                }
            } else {
                let transcript = try await withMemoryGuard(asrLease) {
                    try await services.transcribeJapanese(samples)
                }
                asrExchange = .init(rawTranscript: transcript, chunks: [])
            }
            let rawTranscript = asrExchange.rawTranscript
            rawASR = rawTranscript
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw LocalPrototypeError.invalidResponse }
            try Task.checkCancellation()

            memorySampler?.cancel()
            if let memorySampler {
                manifest.peakMemoryBytes = await memorySampler.value
            }
            memorySampler = nil
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
                diarizationLoadStarted = true
                diarizationEvidence = .init(
                    modelID: services.diarizationModelID,
                    revision: services.diarizationRevision,
                    rawSpans: [],
                    mappings: [],
                    overlapRanges: [],
                    peakMemoryBytes: 0,
                    useExclusiveReconciliation: request.useExclusiveReconciliation,
                    speakerCountPolicy: request.speakerCountPolicy,
                    validationDiagnostics: []
                )
                diarizationLease = try await acquireModel(
                    services.diarizationModelID,
                    peak: services.diarizationDeclaredPeakMemoryBytes
                )
                if let diarizationLease {
                    manifest.modelEvents.append(.init(
                        kind: .pressureChecked,
                        modelID: services.diarizationModelID,
                        at: Date(),
                        message: "policy=macos-memory-pressure peak=\(diarizationLease.declaredPeakBytes) reserve=\(diarizationLease.reserveBytes) total=\(diarizationLease.totalMemoryBytes) available=\(diarizationLease.availableMemoryBytes) baseline=\(diarizationLease.baselineMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: services.diarizationModelID,
                    at: Date()
                ))
                try await withMemoryGuard(diarizationLease) {
                    try await services.prepareDiarization(request.speakerConfiguration) {
                        fraction, message in
                        progress(.init(
                            stage: .preparingDiarization,
                            fraction: 0.74 + min(max(fraction, 0), 1) * 0.04,
                            message: message
                        ))
                    }
                }
                try await markLoaded(diarizationLease)
                manifest.modelEvents.append(.init(
                    kind: .loadCompleted,
                    modelID: services.diarizationModelID,
                    at: Date()
                ))
                try Task.checkCancellation()
                begin(.diarizing, fraction: 0.78, message: "Detecting speakers…")
                let exchange = try await withMemoryGuard(diarizationLease) {
                    try await services.diarizeSpeakers(
                        samples,
                        request.useExclusiveReconciliation,
                        request.speakerConfiguration
                    )
                }
                guard exchange.speakerCountPolicy == request.speakerCountPolicy else {
                    throw HighQualityJobError(
                        stage: .diarization,
                        message: "SpeakerKit did not preserve the requested Speaker-count policy.",
                        resultDirectory: directory
                    )
                }
                diarizationEvidence = .init(
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
                    diarizationEvidence = try Self.diarizationEvidence(
                        exchange,
                        items: alignedItems,
                        duration: Double(samples.count) / 16_000,
                        completeAttribution: services.completeDiarizationAttribution
                    )
                } catch {
                    diarizationEvidence?.validationDiagnostics = [error.localizedDescription]
                    throw error
                }
                manifest.peakMemoryBytes = max(manifest.peakMemoryBytes, exchange.peakMemoryBytes)
                diarizationUnloaded = true
                let release = try await releaseModel(
                    diarizationLease,
                    unload: services.unloadDiarization
                )
                diarizationLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: services.diarizationModelID,
                    at: Date()
                ))
                if let release {
                    manifest.peakMemoryBytes = max(
                        manifest.peakMemoryBytes,
                        release.evidence.peakMemoryBytes
                    )
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: services.diarizationModelID,
                        at: Date(),
                        message: releaseMessage(release)
                    ))
                }
                diarizationEvidence?.worker = await services.diarizationWorkerEvidence()
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    diarizationEvidence?.worker?.peakPhysicalFootprintBytes ?? 0
                )
                try rejectTerminalCriticalPressure(
                    diarizationEvidence?.worker,
                    stage: "SpeakerKit"
                )
                try Task.checkCancellation()
            }
            let speakerAttachment = Self.speakerAttachment(
                units: alignmentEvidence?.semanticUnits ?? [],
                fragments: alignmentEvidence?.semanticFragments ?? [],
                mappings: diarizationEvidence?.mappings ?? [],
                explicitLabelsByCueID: request.speakerLabelsByCueID
            )
            alignmentEvidence?.semanticUnits = speakerAttachment.units
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
            let subtitleCues: [HighQualitySubtitleCue]
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
                glossary: glossary,
                alignment: alignmentEvidence,
                diarization: diarizationEvidence,
                translation: translationEvidence,
                sampleCount: sampleCount,
                resultTurns: resultTurns,
                subtitleCues: subtitleCues,
                japaneseTranscript: japaneseOutput ?? transcript,
                englishTranscript: englishTranscript,
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
                        ?? diarizationLease?.modelID
                        ?? translationLease?.modelID
                        ?? "heavyweight-workflow",
                    at: Date(),
                    message: gateError.localizedDescription
                ))
            }
            memorySampler?.cancel()
            if let memorySampler {
                manifest.peakMemoryBytes = await memorySampler.value
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
            if diarizationLoadStarted, !diarizationUnloaded {
                diarizationUnloaded = true
                await cleanupModel(
                    diarizationLease,
                    modelID: services.diarizationModelID,
                    unload: services.unloadDiarization
                )
            }
            if diarizationLoadStarted {
                if [.preparingDiarization, .diarizing].contains(currentStage),
                   diarizationEvidence?.validationDiagnostics.isEmpty == true {
                    diarizationEvidence?.validationDiagnostics = [error.localizedDescription]
                }
                diarizationEvidence?.worker = await services.diarizationWorkerEvidence()
                manifest.peakMemoryBytes = max(
                    manifest.peakMemoryBytes,
                    diarizationEvidence?.worker?.peakPhysicalFootprintBytes ?? 0
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
                    glossary: glossary,
                    alignment: alignmentEvidence,
                    diarization: diarizationEvidence,
                    translation: translationEvidence,
                    sampleCount: sampleCount,
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
        beforeCommit: () throws -> Void = {}
    ) throws -> HighQualityJobResult {
        guard result.manifest.schemaVersion >= 3 else {
            throw HighQualityJobError(
                stage: .export,
                message: "Speaker label edits require a result saved with the current schema.",
                resultDirectory: result.directory
            )
        }
        let normalizedLabels = try Dictionary(uniqueKeysWithValues: names.map { label, value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw HighQualityJobError(
                    stage: .export,
                    message: "Custom Speaker labels cannot be empty.",
                    resultDirectory: result.directory
                )
            }
            return (label, value)
        })
        let renamed = applyingCustomSpeakerLabels(normalizedLabels, to: result)
        let deliverables = Set(result.manifest.deliverables)
        let customLabels = renamed.turns.reduce(into: [String: String]()) { labels, turn in
            if let label = turn.speakerLabel, let customLabel = turn.speakerName {
                labels[label] = customLabel
            }
        }
        let previous = try readTransformations(in: result.directory)
        let transformations = try encoder.encode(HighQualityResultTransformations(
            schemaVersion: HighQualityResultTransformations.currentSchemaVersion,
            customSpeakerLabels: customLabels,
            relocatedSourcePath: previous?.relocatedSourcePath
        ))
        var files = deliverableFiles(
            japaneseTranscript: deliverables.contains(.japaneseTranscript)
                ? renamed.japaneseTranscript : nil,
            englishTranscript: renamed.englishTranscript,
            subtitleCues: deliverables.contains(.englishSubtitles) ? renamed.subtitleCues : nil
        )
        files["transformations.json"] = transformations
        try transactionallyWrite(
            files,
            in: result.directory,
            beforeCommit: beforeCommit
        )
        return renamed
    }

    private static func applyingCustomSpeakerLabels(
        _ labels: [String: String],
        to result: HighQualityJobResult
    ) -> HighQualityJobResult {
        let turns: [HighQualityTranscriptTurn] = result.turns.map { turn in
            .init(
                id: turn.id,
                japanese: turn.japanese,
                english: turn.english,
                speakerLabel: turn.speakerLabel,
                speakerName: turn.speakerLabel.flatMap { labels[$0] } ?? turn.speakerName,
                start: turn.start,
                end: turn.end
            )
        }
        let subtitleCues: [HighQualitySubtitleCue] = result.subtitleCues.map { cue in
            .init(
                id: cue.id,
                start: cue.start,
                end: cue.end,
                text: cue.text,
                speakerLabel: cue.speakerLabel,
                speakerName: cue.speakerLabel.flatMap { labels[$0] } ?? cue.speakerName
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
            evidence: result.evidence
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
        completeAttribution: Bool = false
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
        let labels = Dictionary(uniqueKeysWithValues: Set(spans.map(\.speakerID)).sorted()
            .enumerated().map { ($0.element, String(format: "SPEAKER_%02d", $0.offset)) })
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
            validationDiagnostics: []
        )
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
        try transactionallyWrite(files, in: result.directory)
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
        beforeCommit: () throws -> Void = {}
    ) throws {
        try AtomicDirectory.update(directory) { staging in
            try writeFiles(files, to: staging)
            guard files.allSatisfy({ path, data in
                (try? Data(contentsOf: staging.appendingPathComponent(path))) == data
            }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try beforeCommit()
        }
    }

    private static func webVTT(_ cues: [HighQualitySubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            let content = subtitleText(cue.text)
            let text = (cue.speakerName ?? cue.speakerLabel).map {
                "<v \(webVTTSpeaker($0))>\(content)"
            }
                ?? content
            return "\(cue.id)\n\(SubtitleTimecode.webVTT(cue.start)) --> \(SubtitleTimecode.webVTT(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func srt(_ cues: [HighQualitySubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            let content = subtitleText(cue.text)
            let text = (cue.speakerName ?? cue.speakerLabel).map { "[\($0)] \(content)" }
                ?? content
            return "\(index + 1)\n\(SubtitleTimecode.srt(cue.start)) --> \(SubtitleTimecode.srt(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func subtitleText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func webVTTSpeaker(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
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
        glossary: HighQualityGlossarySelection,
        alignment: HighQualityAlignmentEvidence?,
        diarization: HighQualityDiarizationEvidence?,
        translation: HighQualityTranslationEvidence?,
        sampleCount: Int,
        resultTurns: [HighQualityTranscriptTurn]? = nil,
        subtitleCues: [HighQualitySubtitleCue]? = nil,
        japaneseTranscript: String? = nil,
        englishTranscript: String? = nil,
        manifest: HighQualityJobManifest
    ) -> HighQualityRawEvidence {
        HighQualityRawEvidence(
            source: manifest.source,
            model: manifest.model,
            asrWorker: manifest.asrWorker,
            speakerConfiguration: manifest.speakerConfiguration,
            speakerCountPolicy: manifest.speakerCountPolicy,
            rawASR: rawASR,
            glossary: glossary,
            alignment: alignment,
            diarization: diarization,
            translation: translation,
            sampleRate: 16_000,
            sampleCount: sampleCount,
            stageDurations: manifest.stageDurations,
            peakMemoryBytes: manifest.peakMemoryBytes,
            modelEvents: manifest.modelEvents,
            failures: manifest.failures,
            generatedFiles: manifest.generatedFiles,
            resultTurns: resultTurns,
            subtitleCues: subtitleCues,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            projectID: manifest.projectID
        )
    }

    @discardableResult
    private static func writeEvidenceAndManifest(
        rawASR: String?,
        glossary: HighQualityGlossarySelection,
        alignment: HighQualityAlignmentEvidence?,
        diarization: HighQualityDiarizationEvidence?,
        translation: HighQualityTranslationEvidence?,
        sampleCount: Int,
        resultTurns: [HighQualityTranscriptTurn]? = nil,
        subtitleCues: [HighQualitySubtitleCue]? = nil,
        japaneseTranscript: String? = nil,
        englishTranscript: String? = nil,
        manifest: inout HighQualityJobManifest,
        to directory: URL
    ) throws -> HighQualityRawEvidence {
        let evidence = evidence(
            rawASR: rawASR,
            glossary: glossary,
            alignment: alignment,
            diarization: diarization,
            translation: translation,
            sampleCount: sampleCount,
            resultTurns: resultTurns,
            subtitleCues: subtitleCues,
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
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
            guard transformations.schemaVersion
                    == HighQualityResultTransformations.currentSchemaVersion,
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
        _ saved: HighQualitySavedResult
    ) -> HighQualityJobError {
        HighQualityJobError(
            stage: .application,
            message: message,
            resultDirectory: saved.directory
        )
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
