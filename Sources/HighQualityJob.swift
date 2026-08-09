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

    static let productDefault: Self = .qwenJA

    var id: Self { self }

    var displayName: String {
        switch self {
        case .qwenJA: "Qwen JA"
        case .parakeetJA: "Parakeet JA"
        case .whisperKit: "WhisperKit large-v3"
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
        }
    }

    var declaredPeakMemoryBytes: UInt64 {
        switch self {
        case .qwenJA: 7 * 1_024 * 1_024 * 1_024
        case .parakeetJA: 4 * 1_024 * 1_024 * 1_024
        case .whisperKit: 8 * 1_024 * 1_024 * 1_024
        }
    }
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

struct HighQualityJobRequest: Sendable {
    let id: UUID
    let sourceURL: URL
    let deliverables: Set<HighQualityDeliverable>
    let backend: HighQualityASRBackend
    let speakerLabels: Bool
    let speakerLabelsByCueID: [String: String]
    let outputRoot: URL

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        deliverables: Set<HighQualityDeliverable>,
        backend: HighQualityASRBackend,
        speakerLabels: Bool = false,
        speakerLabelsByCueID: [String: String] = [:],
        outputRoot: URL = AppStoragePaths.highQualityJobs
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.deliverables = deliverables
        self.backend = backend
        self.speakerLabels = speakerLabels
        self.speakerLabelsByCueID = speakerLabelsByCueID
        self.outputRoot = outputRoot
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

struct HighQualityASRChunk: Equatable, Sendable {
    let index: Int
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let transcript: String
}

struct HighQualityASRExchange: Equatable, Sendable {
    let rawTranscript: String
    let chunks: [HighQualityASRChunk]
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
}

struct HighQualityTranslationAttempt: Codable, Equatable, Sendable {
    let number: Int
    let duration: TimeInterval
    let outcome: String
}

struct HighQualityTranslationExchange: Equatable, Sendable {
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
        duration: TimeInterval? = nil
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
    }
}

struct HighQualityTranslationServiceError: LocalizedError, Sendable {
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
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64
    var validationFailures: [String]
    var integrityVerdicts: [HighQualityTranslationIntegrityVerdict]

    private enum CodingKeys: String, CodingKey {
        case request, response, model, attempts, revision, runtimeVersion, batches
        case peakMemoryBytes, validationFailures, integrityVerdicts
    }

    init(
        request: HighQualityTranslationBatch,
        response: String?,
        model: String,
        attempts: [HighQualityTranslationAttempt],
        revision: String?,
        runtimeVersion: String?,
        batches: [HighQualityLocalTranslationBatch],
        peakMemoryBytes: UInt64,
        validationFailures: [String],
        integrityVerdicts: [HighQualityTranslationIntegrityVerdict] = []
    ) {
        self.request = request
        self.response = response
        self.model = model
        self.attempts = attempts
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
        self.validationFailures = validationFailures
        self.integrityVerdicts = integrityVerdicts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        request = try values.decode(HighQualityTranslationBatch.self, forKey: .request)
        response = try values.decodeIfPresent(String.self, forKey: .response)
        model = try values.decode(String.self, forKey: .model)
        attempts = try values.decode([HighQualityTranslationAttempt].self, forKey: .attempts)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        runtimeVersion = try values.decodeIfPresent(String.self, forKey: .runtimeVersion)
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
    }
}

struct HighQualityAlignedCue: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualityAlignmentItem: Codable, Equatable, Sendable {
    let cueID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
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

struct HighQualityAlignmentExchange: Equatable, Sendable {
    let chunks: [HighQualityAlignmentChunk]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
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
}

struct HighQualityDiarizationSpan: Codable, Equatable, Sendable {
    let speakerID: Int
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualityDiarizationExchange: Equatable, Sendable {
    let spans: [HighQualityDiarizationSpan]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
}

struct HighQualitySpeakerMapping: Codable, Equatable, Sendable {
    let cueID: String
    let alignmentItemIndex: Int
    let spanIndex: Int
    let alignedText: String
    let speakerLabel: String
    let overlapStart: TimeInterval
    let overlapEnd: TimeInterval
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
    var validationDiagnostics: [String]
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

struct HighQualityTranscriptTurn: Equatable, Sendable {
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

    init(
        backend: HighQualityASRBackend,
        modelID: String,
        revision: String,
        runtimeVersion: String? = nil
    ) {
        self.backend = backend
        self.modelID = modelID
        self.revision = revision
        self.runtimeVersion = runtimeVersion
    }
}

struct HighQualityModelEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case loadStarted = "load-started"
        case loadCompleted = "load-completed"
        case unloadCompleted = "unload-completed"
        case reserveChecked = "reserve-checked"
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
    let speakerLabels: Bool
    let dependencies: [HighQualityJobDependency]
    let model: HighQualityModelEvidence
    let startedAt: Date
    var finishedAt: Date?
    var stageDurations: [HighQualityJobStage: TimeInterval]
    var peakMemoryBytes: UInt64
    var modelEvents: [HighQualityModelEvent]
    var failures: [HighQualityJobFailure]
    var generatedFiles: [HighQualityGeneratedFile]
}

struct HighQualityRawEvidence: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let model: HighQualityModelEvidence
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
        let prepareAlignment: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let alignJapanese: @Sendable (
            [Float],
            [HighQualityTranslationTurn]
        ) async throws -> HighQualityAlignmentExchange
        let unloadAlignment: @Sendable () async -> Void
        let prepareDiarization: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let diarizeSpeakers: @Sendable ([Float]) async throws -> HighQualityDiarizationExchange
        let unloadDiarization: @Sendable () async -> Void
        let currentMemoryBytes: @Sendable () async -> UInt64
        let prepareTranslation: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let translateEnglish: @Sendable (
            HighQualityTranslationBatch
        ) async throws -> HighQualityTranslationExchange
        let unloadTranslation: @Sendable () async -> Void
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
            prepareDiarization: @escaping @Sendable (
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void = { _ in
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit is not configured.",
                    resultDirectory: nil
                )
            },
            diarizeSpeakers: @escaping @Sendable (
                [Float]
            ) async throws -> HighQualityDiarizationExchange = { _ in
                throw HighQualityJobError(
                    stage: .diarization,
                    message: "SpeakerKit is not configured.",
                    resultDirectory: nil
                )
            },
            unloadDiarization: @escaping @Sendable () async -> Void = {},
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
            self.prepareAlignment = prepareAlignment
            self.alignJapanese = alignJapanese
            self.unloadAlignment = unloadAlignment
            self.prepareDiarization = prepareDiarization
            self.diarizeSpeakers = diarizeSpeakers
            self.unloadDiarization = unloadDiarization
            self.currentMemoryBytes = currentMemoryBytes
            self.prepareTranslation = prepareTranslation
            self.translateEnglish = translateEnglish
            self.unloadTranslation = unloadTranslation
            self.heavyweightGate = heavyweightGate
        }

        static func production(for backend: HighQualityASRBackend) -> Self {
            let aligner = HighQualityForcedAlignerRuntime()
            let diarizer = HighQualitySpeakerKitRuntime()
            let translator = LocalMLXTranslator()
            let loadSource: @Sendable (URL) async throws -> [Float] = {
                try await AudioLoader.loadSamples(url: $0)
            }
            let acquireYouTube: @Sendable (
                URL,
                URL
            ) async throws -> HighQualityYouTubeAcquisition = {
                try await YouTubeAcquirer.acquire($0, to: $1)
            }
            switch backend {
            case .qwenJA:
                let runtime = QwenRuntime()
                let transcribe: @Sendable ([Float]) async throws -> String = {
                    try await runtime.transcribe(
                        audio: $0,
                        language: "Japanese",
                        preserveRawOutput: true,
                        cancellable: true
                    )
                }
                return Self(
                    loadSource: loadSource,
                    acquireYouTube: acquireYouTube,
                    prepareASR: { try await runtime.prepare(progress: $0) },
                    transcribeJapanese: transcribe,
                    transcribeJapaneseAnchored: { try await chunkedASR($0, transcribe: transcribe) },
                    unloadASR: { await runtime.unload() },
                    prepareAlignment: { try await aligner.prepare(progress: $0) },
                    alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                    unloadAlignment: { await aligner.unload() },
                    prepareDiarization: { try await diarizer.prepare(progress: $0) },
                    diarizeSpeakers: { try await diarizer.diarize(samples: $0) },
                    unloadDiarization: { await diarizer.unload() },
                    currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
                    prepareTranslation: { try await translator.prepare(progress: $0) },
                    translateEnglish: { try await translator.translate($0) },
                    unloadTranslation: { await translator.unload() },
                    heavyweightGate: .shared
                )
            case .parakeetJA:
                let runtime = ParakeetRuntime()
                let transcribe: @Sendable ([Float]) async throws -> String = {
                    try await runtime.transcribe(
                        audio: $0,
                        preserveRawOutput: true,
                        cancellable: true
                    )
                }
                return Self(
                    loadSource: loadSource,
                    acquireYouTube: acquireYouTube,
                    prepareASR: { try await runtime.prepare(progress: $0) },
                    transcribeJapanese: transcribe,
                    transcribeJapaneseAnchored: { try await chunkedASR($0, transcribe: transcribe) },
                    unloadASR: { await runtime.unload() },
                    prepareAlignment: { try await aligner.prepare(progress: $0) },
                    alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                    unloadAlignment: { await aligner.unload() },
                    prepareDiarization: { try await diarizer.prepare(progress: $0) },
                    diarizeSpeakers: { try await diarizer.diarize(samples: $0) },
                    unloadDiarization: { await diarizer.unload() },
                    currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
                    prepareTranslation: { try await translator.prepare(progress: $0) },
                    translateEnglish: { try await translator.translate($0) },
                    unloadTranslation: { await translator.unload() },
                    heavyweightGate: .shared
                )
            case .whisperKit:
                let runtime = WhisperKitRuntime()
                let transcribe: @Sendable ([Float]) async throws -> String = {
                    try await runtime.transcribe(audio: $0)
                }
                return Self(
                    loadSource: loadSource,
                    acquireYouTube: acquireYouTube,
                    prepareASR: { try await runtime.prepare(progress: $0) },
                    transcribeJapanese: transcribe,
                    transcribeJapaneseAnchored: { try await chunkedASR($0, transcribe: transcribe) },
                    unloadASR: { await runtime.unload() },
                    prepareAlignment: { try await aligner.prepare(progress: $0) },
                    alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                    unloadAlignment: { await aligner.unload() },
                    prepareDiarization: { try await diarizer.prepare(progress: $0) },
                    diarizeSpeakers: { try await diarizer.diarize(samples: $0) },
                    unloadDiarization: { await diarizer.unload() },
                    currentMemoryBytes: { WhisperKitRuntime.currentMemoryBytes() },
                    prepareTranslation: { try await translator.prepare(progress: $0) },
                    translateEnglish: { try await translator.translate($0) },
                    unloadTranslation: { await translator.unload() },
                    heavyweightGate: .shared
                )
            }
        }

        static func chunkedASR(
            _ samples: [Float],
            transcribe: @escaping @Sendable ([Float]) async throws -> String
        ) async throws -> HighQualityASRExchange {
            var chunks: [HighQualityASRChunk] = []
            var start = 0
            var previousBoundaryWasSilent = true
            while start < samples.count {
                try Task.checkCancellation()
                let boundary = quietASRBoundary(in: samples, after: start)
                let overlap = 16_000
                let windowStart = previousBoundaryWasSilent ? start : max(0, start - overlap)
                let windowEnd = boundary.isSilent
                    ? boundary.index : min(samples.count, boundary.index + overlap)
                let raw = try await transcribe(Array(samples[windowStart..<windowEnd]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let transcript = removingTranscriptOverlap(
                    prefix: chunks.last?.transcript ?? "",
                    suffix: raw
                )
                if !transcript.isEmpty {
                    chunks.append(.init(
                        index: chunks.count,
                        sourceStart: Double(windowStart) / 16_000,
                        sourceEnd: Double(windowEnd) / 16_000,
                        transcript: transcript
                    ))
                }
                start = boundary.index
                previousBoundaryWasSilent = boundary.isSilent
            }
            return .init(
                rawTranscript: chunks.map(\.transcript).joined(separator: "\n"),
                chunks: chunks
            )
        }

        private static func quietASRBoundary(
            in samples: [Float],
            after start: Int
        ) -> (index: Int, isSilent: Bool) {
            let sampleRate = 16_000
            let target = start + 60 * sampleRate
            let minimumTail = 10 * sampleRate
            guard samples.count - target > minimumTail else { return (samples.count, true) }

            let searchRadius = 5 * sampleRate
            let frame = sampleRate / 50
            let searchStart = max(start + 30 * sampleRate, target - searchRadius)
            let searchEnd = min(samples.count - frame, target + searchRadius)
            var best = target
            var bestEnergy = Double.infinity
            for candidate in stride(from: searchStart, through: searchEnd, by: frame) {
                let energy = samples[candidate..<(candidate + frame)].reduce(0.0) {
                    $0 + Double($1 * $1)
                }
                if energy < bestEnergy
                    || (energy == bestEnergy && abs(candidate - target) < abs(best - target)) {
                    best = candidate
                    bestEnergy = energy
                }
            }
            return (best, bestEnergy / Double(frame) <= 0.003 * 0.003)
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

    private let servicesForBackend: @Sendable (HighQualityASRBackend) -> Services

    init() {
        servicesForBackend = { Services.production(for: $0) }
    }

    init(services: Services) {
        servicesForBackend = { _ in services }
    }

    init(servicesForBackend: @escaping @Sendable (HighQualityASRBackend) -> Services) {
        self.servicesForBackend = servicesForBackend
    }

    func run(
        _ request: HighQualityJobRequest,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
    ) async throws -> HighQualityJobResult {
        let services = servicesForBackend(request.backend)
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
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw HighQualityJobError(
                stage: .application,
                message: "Could not create the job result directory: \(error.localizedDescription)",
                resultDirectory: nil
            )
        }

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
        var manifest = HighQualityJobManifest(
            schemaVersion: 1,
            jobID: request.id,
            status: .failed,
            source: Self.provenance(for: request.sourceURL),
            deliverables: request.deliverables.sorted { $0.rawValue < $1.rawValue },
            selectedBackend: request.backend,
            speakerLabels: request.speakerLabels || !request.speakerLabelsByCueID.isEmpty,
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

        func releaseModel(
            _ lease: HeavyweightModelLease?,
            unload: @escaping @Sendable () async -> Void
        ) async throws -> UInt64? {
            guard let gate = services.heavyweightGate, let lease else {
                await unload()
                return nil
            }
            return try await gate.releaseModel(lease, unload: unload)
        }

        func cleanupModel(
            _ lease: HeavyweightModelLease?,
            modelID: String,
            unload: @escaping @Sendable () async -> Void
        ) async {
            do {
                let releasedMemory = try await releaseModel(lease, unload: unload)
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: modelID,
                    at: Date()
                ))
                if let releasedMemory {
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: modelID,
                        at: Date(),
                        message: "memory=\(releasedMemory)"
                    ))
                }
            } catch let gateError as HeavyweightModelGateError {
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
                manifest.modelEvents.append(.init(
                    kind: .guardFailed,
                    modelID: modelID,
                    at: Date(),
                    message: error.localizedDescription
                ))
            }
        }

        do {
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
                    kind: .reserveChecked,
                    backend: request.backend,
                    at: Date(),
                    message: "peak=\(asrLease.declaredPeakBytes) reserve=\(asrLease.reserveBytes) total=\(asrLease.totalMemoryBytes)"
                ))
            }
            manifest.modelEvents.append(.init(
                kind: .loadStarted,
                backend: request.backend,
                at: Date()
            ))
            try await services.prepareASR { fraction, message in
                progress(.init(
                    stage: .preparingASR,
                    fraction: 0.2 + min(max(fraction, 0), 1) * 0.25,
                    message: message
                ))
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
                asrExchange = try await services.transcribeJapaneseAnchored(samples)
            } else {
                let transcript = try await services.transcribeJapanese(samples)
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
            let asrReleasedMemory = try await releaseModel(asrLease, unload: services.unloadASR)
            asrLease = nil
            manifest.modelEvents.append(.init(
                kind: .unloadCompleted,
                backend: request.backend,
                at: Date()
            ))
            if let asrReleasedMemory {
                manifest.modelEvents.append(.init(
                    kind: .memoryReleaseChecked,
                    backend: request.backend,
                    at: Date(),
                    message: "memory=\(asrReleasedMemory)"
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
                alignmentLease = try await acquireModel(
                    HighQualityForcedAlignerRuntime.modelID,
                    peak: HighQualityForcedAlignerRuntime.declaredPeakMemoryBytes
                )
                if let alignmentLease {
                    manifest.modelEvents.append(.init(
                        kind: .reserveChecked,
                        modelID: HighQualityForcedAlignerRuntime.modelID,
                        at: Date(),
                        message: "peak=\(alignmentLease.declaredPeakBytes) reserve=\(alignmentLease.reserveBytes) total=\(alignmentLease.totalMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: HighQualityForcedAlignerRuntime.modelID,
                    at: Date()
                ))
                try await services.prepareAlignment { fraction, message in
                    progress(.init(
                        stage: .preparingAlignment,
                        fraction: 0.62 + min(max(fraction, 0), 1) * 0.08,
                        message: message
                    ))
                }
                try await markLoaded(alignmentLease)
                manifest.modelEvents.append(.init(
                    kind: .loadCompleted,
                    modelID: HighQualityForcedAlignerRuntime.modelID,
                    at: Date()
                ))
                try Task.checkCancellation()
                begin(.aligning, fraction: 0.7, message: "Aligning Japanese transcript…")
                let exchange = try await services.alignJapanese(samples, baseTurns)
                let duration = Double(samples.count) / 16_000
                alignmentEvidence = .init(
                    modelID: exchange.modelID,
                    revision: exchange.revision,
                    chunks: exchange.chunks.sorted { $0.index < $1.index },
                    mergedCues: [],
                    sourceDuration: duration,
                    peakMemoryBytes: exchange.peakMemoryBytes,
                    validationDiagnostics: []
                )
                do {
                    let merged = try Self.validatedAlignment(
                        exchange.chunks,
                        turns: baseTurns,
                        duration: duration
                    )
                    var validatedEvidence = HighQualityAlignmentEvidence(
                        modelID: exchange.modelID,
                        revision: exchange.revision,
                        chunks: exchange.chunks.sorted { $0.index < $1.index },
                        mergedCues: merged,
                        sourceDuration: duration,
                        peakMemoryBytes: exchange.peakMemoryBytes,
                        validationDiagnostics: []
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
                let releasedMemory = try await releaseModel(
                    alignmentLease,
                    unload: services.unloadAlignment
                )
                alignmentLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: HighQualityForcedAlignerRuntime.modelID,
                    at: Date()
                ))
                if let releasedMemory {
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: HighQualityForcedAlignerRuntime.modelID,
                        at: Date(),
                        message: "memory=\(releasedMemory)"
                    ))
                }
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
                diarizationLease = try await acquireModel(
                    HighQualitySpeakerKitRuntime.modelID,
                    peak: HighQualitySpeakerKitRuntime.declaredPeakMemoryBytes
                )
                if let diarizationLease {
                    manifest.modelEvents.append(.init(
                        kind: .reserveChecked,
                        modelID: HighQualitySpeakerKitRuntime.modelID,
                        at: Date(),
                        message: "peak=\(diarizationLease.declaredPeakBytes) reserve=\(diarizationLease.reserveBytes) total=\(diarizationLease.totalMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: HighQualitySpeakerKitRuntime.modelID,
                    at: Date()
                ))
                try await services.prepareDiarization { fraction, message in
                    progress(.init(
                        stage: .preparingDiarization,
                        fraction: 0.74 + min(max(fraction, 0), 1) * 0.04,
                        message: message
                    ))
                }
                try await markLoaded(diarizationLease)
                manifest.modelEvents.append(.init(
                    kind: .loadCompleted,
                    modelID: HighQualitySpeakerKitRuntime.modelID,
                    at: Date()
                ))
                try Task.checkCancellation()
                begin(.diarizing, fraction: 0.78, message: "Detecting speakers…")
                let exchange = try await services.diarizeSpeakers(samples)
                diarizationEvidence = .init(
                    modelID: exchange.modelID,
                    revision: exchange.revision,
                    rawSpans: exchange.spans,
                    mappings: [],
                    overlapRanges: [],
                    peakMemoryBytes: exchange.peakMemoryBytes,
                    validationDiagnostics: []
                )
                do {
                    diarizationEvidence = try Self.diarizationEvidence(
                        exchange,
                        items: alignedItems,
                        duration: Double(samples.count) / 16_000
                    )
                } catch {
                    diarizationEvidence?.validationDiagnostics = [error.localizedDescription]
                    throw error
                }
                manifest.peakMemoryBytes = max(manifest.peakMemoryBytes, exchange.peakMemoryBytes)
                diarizationUnloaded = true
                let releasedMemory = try await releaseModel(
                    diarizationLease,
                    unload: services.unloadDiarization
                )
                diarizationLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: HighQualitySpeakerKitRuntime.modelID,
                    at: Date()
                ))
                if let releasedMemory {
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: HighQualitySpeakerKitRuntime.modelID,
                        at: Date(),
                        message: "memory=\(releasedMemory)"
                    ))
                }
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
                turns: baseTurns
            )
            var translationsByID: [String: String] = [:]
            if needsTranslation {
                begin(.translating, fraction: 0.8, message: "Preparing local TranslateGemma…")
                let translationRequest = HighQualityTranslationBatch(
                    source: manifest.source,
                    turns: turns,
                    glossary: glossary.promptTerms
                )
                let integrityGlossary = glossary.decisions
                    .filter(\.selected)
                    .map { HighQualityTranslationIntegrityGlossaryTerm($0.term) }
                translationEvidence = .init(
                    request: translationRequest,
                    response: nil,
                    model: LocalMLXTranslator.modelID,
                    attempts: [],
                    revision: LocalMLXTranslator.revision,
                    runtimeVersion: LocalMLXTranslator.runtimeVersion,
                    batches: [],
                    peakMemoryBytes: 0,
                    validationFailures: []
                )
                translationLoadStarted = true
                translationLease = try await acquireModel(
                    LocalMLXTranslator.modelID,
                    peak: LocalMLXTranslator.declaredPeakMemoryBytes
                )
                if let translationLease {
                    manifest.modelEvents.append(.init(
                        kind: .reserveChecked,
                        modelID: LocalMLXTranslator.modelID,
                        at: Date(),
                        message: "peak=\(translationLease.declaredPeakBytes) reserve=\(translationLease.reserveBytes) total=\(translationLease.totalMemoryBytes)"
                    ))
                }
                manifest.modelEvents.append(.init(
                    kind: .loadStarted,
                    modelID: LocalMLXTranslator.modelID,
                    at: Date()
                ))
                do {
                    try await services.prepareTranslation { fraction, message in
                        progress(.init(
                            stage: .translating,
                            fraction: 0.8 + min(max(fraction, 0), 1) * 0.04,
                            message: message
                        ))
                    }
                    try await markLoaded(translationLease)
                    manifest.modelEvents.append(.init(
                        kind: .loadCompleted,
                        modelID: LocalMLXTranslator.modelID,
                        at: Date()
                    ))
                    progress(.init(stage: .translating, fraction: 0.84, message: "Translating to English locally…"))
                    let exchange = try await services.translateEnglish(translationRequest)
                    translationEvidence = .init(
                        request: translationRequest,
                        response: exchange.response,
                        model: exchange.model,
                        attempts: exchange.attempts,
                        revision: exchange.revision,
                        runtimeVersion: exchange.runtimeVersion,
                        batches: exchange.batches,
                        peakMemoryBytes: exchange.peakMemoryBytes,
                        validationFailures: [],
                        integrityVerdicts: HighQualityTranslationIntegrityValidator.validate(
                            turns: turns,
                            batches: exchange.batches,
                            glossary: integrityGlossary
                        )
                    )
                    do {
                        translationsByID = try Self.validatedTranslations(
                            exchange.response,
                            for: turns
                        )
                        translationEvidence?.integrityVerdicts =
                            HighQualityTranslationIntegrityValidator.validate(
                                turns: turns,
                                translations: translationsByID,
                                batches: exchange.batches,
                                glossary: integrityGlossary
                            )
                    } catch {
                        translationEvidence?.validationFailures = [error.localizedDescription]
                        throw error
                    }
                } catch let error as HighQualityTranslationServiceError {
                    translationEvidence = .init(
                        request: translationRequest,
                        response: error.response,
                        model: error.model,
                        attempts: error.attempts,
                        revision: error.revision,
                        runtimeVersion: error.runtimeVersion,
                        batches: error.batches,
                        peakMemoryBytes: error.peakMemoryBytes,
                        validationFailures: [],
                        integrityVerdicts: HighQualityTranslationIntegrityValidator.validate(
                            turns: turns,
                            batches: error.batches,
                            glossary: integrityGlossary
                        )
                    )
                    throw error
                }
                translationUnloaded = true
                let releasedMemory = try await releaseModel(
                    translationLease,
                    unload: services.unloadTranslation
                )
                translationLease = nil
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    modelID: LocalMLXTranslator.modelID,
                    at: Date()
                ))
                if let releasedMemory {
                    manifest.modelEvents.append(.init(
                        kind: .memoryReleaseChecked,
                        modelID: LocalMLXTranslator.modelID,
                        at: Date(),
                        message: "memory=\(releasedMemory)"
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
            try Self.writeDeliverables(
                japaneseTranscript: japaneseOutput,
                englishTranscript: englishTranscript,
                subtitleCues: needsSubtitles ? subtitleCues : nil,
                to: directory
            )
            japaneseTranscriptWritten = japaneseOutput != nil
            englishTranscriptWritten = englishTranscript != nil
            subtitlesWritten = needsSubtitles
            manifest.status = .completed
            var evidence = try Self.writeEvidenceAndManifest(
                rawASR: rawTranscript,
                glossary: glossary,
                alignment: alignmentEvidence,
                diarization: diarizationEvidence,
                translation: translationEvidence,
                sampleCount: sampleCount,
                manifest: manifest,
                to: directory
            )
            manifest.stageDurations[.exporting, default: 0] += Date().timeIntervalSince(stageStartedAt)
            manifest.finishedAt = Date()
            evidence = try Self.writeEvidenceAndManifest(
                rawASR: rawTranscript,
                glossary: glossary,
                alignment: alignmentEvidence,
                diarization: diarizationEvidence,
                translation: translationEvidence,
                sampleCount: sampleCount,
                manifest: manifest,
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
            }
            if alignmentLoadStarted, !alignmentUnloaded {
                alignmentUnloaded = true
                await cleanupModel(
                    alignmentLease,
                    modelID: HighQualityForcedAlignerRuntime.modelID,
                    unload: services.unloadAlignment
                )
            }
            if diarizationLoadStarted, !diarizationUnloaded {
                diarizationUnloaded = true
                await cleanupModel(
                    diarizationLease,
                    modelID: HighQualitySpeakerKitRuntime.modelID,
                    unload: services.unloadDiarization
                )
            }
            if translationLoadStarted, !translationUnloaded {
                translationUnloaded = true
                await cleanupModel(
                    translationLease,
                    modelID: LocalMLXTranslator.modelID,
                    unload: services.unloadTranslation
                )
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
            let failure = HighQualityJobFailure(
                stage: failureStage,
                message: error is CancellationError ? "Job cancelled." : error.localizedDescription
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
                    manifest: manifest,
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
        names: [String: String]
    ) throws -> HighQualityJobResult {
        let normalized = try Dictionary(uniqueKeysWithValues: names.map { label, name in
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw HighQualityJobError(
                    stage: .export,
                    message: "Speaker names cannot be empty.",
                    resultDirectory: result.directory
                )
            }
            return (label, value)
        })
        let turns = result.turns.map { turn in
            HighQualityTranscriptTurn(
                id: turn.id,
                japanese: turn.japanese,
                english: turn.english,
                speakerLabel: turn.speakerLabel,
                speakerName: turn.speakerLabel.flatMap { normalized[$0] } ?? turn.speakerName,
                start: turn.start,
                end: turn.end
            )
        }
        let subtitleCues = result.subtitleCues.map { cue in
            HighQualitySubtitleCue(
                id: cue.id,
                start: cue.start,
                end: cue.end,
                text: cue.text,
                speakerLabel: cue.speakerLabel,
                speakerName: cue.speakerLabel.flatMap { normalized[$0] } ?? cue.speakerName
            )
        }
        let deliverables = Set(result.manifest.deliverables)
        let japaneseTranscript = deliverables.contains(.japaneseTranscript)
            ? transcript(turns, text: \.japanese)
            : nil
        let englishTranscript = deliverables.contains(.englishTranslationTranscript)
            ? transcript(turns, text: \.english)
            : nil
        try writeDeliverables(
            japaneseTranscript: japaneseTranscript,
            englishTranscript: englishTranscript,
            subtitleCues: deliverables.contains(.englishSubtitles) ? subtitleCues : nil,
            to: result.directory
        )
        return .init(
            directory: result.directory,
            japaneseTranscript: japaneseTranscript ?? result.japaneseTranscript,
            englishTranscript: englishTranscript,
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

    private static func translationTurns(
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

    private static func semanticTranslationUnits(
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
        var fragments: [HighQualitySemanticFragmentEvidence] = []

        for cue in alignment.mergedCues {
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
                        start: previous?.start ?? next?.start ?? cue.start,
                        end: previous?.end ?? next?.end ?? cue.end
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
              Set(units.flatMap(\.sourceFragmentIndices)).count == fragments.count else {
            throw HighQualityTranslationValidationError(
                message: "Semantic translation units do not preserve all aligned Japanese."
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

    private static func diarizationEvidence(
        _ exchange: HighQualityDiarizationExchange,
        items: [HighQualityAlignmentItem],
        duration: TimeInterval
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
                    overlapEnd: end
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
            validationDiagnostics: []
        )
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

    private static func validatedTranslations(
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

    private static func containsTranslationScaffolding(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return [
            "here is the translation", "here's the translation",
            "translation:", "english translation:",
        ].contains { lowercased.hasPrefix($0) }
            || ["```", "speaker_id:", "context_before:", "context_after:", "<<<current:", "<<<end_current:"]
                .contains { lowercased.contains($0) }
    }

    private static func validatedAlignment(
        _ chunks: [HighQualityAlignmentChunk],
        turns: [HighQualityTranslationTurn],
        duration: TimeInterval
    ) throws -> [HighQualityAlignedCue] {
        guard duration.isFinite, duration >= 0 else {
            throw HighQualityTranslationValidationError(message: "Source duration is invalid.")
        }
        let expectedText = Dictionary(uniqueKeysWithValues: turns.map {
            ($0.id, $0.japanese.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let expectedIDs = Set(expectedText.keys)
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
                guard expectedIDs.contains(item.cueID),
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
                      cue.end >= cue.start,
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
        }
        guard seen == expectedIDs else {
            throw HighQualityTranslationValidationError(
                message: "Alignment is missing one or more transcript cues."
            )
        }
        return merged
    }

    private static func writeDeliverables(
        japaneseTranscript: String?,
        englishTranscript: String?,
        subtitleCues: [HighQualitySubtitleCue]?,
        to directory: URL
    ) throws {
        if let japaneseTranscript {
            try (japaneseTranscript + "\n").write(
                to: directory.appendingPathComponent("japanese-transcript.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let englishTranscript {
            try (englishTranscript + "\n").write(
                to: directory.appendingPathComponent("english-translation-transcript.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let subtitleCues {
            let webVTTURL = directory.appendingPathComponent("english-subtitles.vtt")
            do {
                try webVTT(subtitleCues).write(
                    to: webVTTURL,
                    atomically: true,
                    encoding: .utf8
                )
                try srt(subtitleCues).write(
                    to: directory.appendingPathComponent("english-subtitles.srt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                try? FileManager.default.removeItem(at: webVTTURL)
                throw error
            }
        }
    }

    private static func webVTT(_ cues: [HighQualitySubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            let text = (cue.speakerName ?? cue.speakerLabel).map {
                "<v \(webVTTSpeaker($0))>\(cue.text)"
            }
                ?? cue.text
            return "\(cue.id)\n\(SubtitleTimecode.webVTT(cue.start)) --> \(SubtitleTimecode.webVTT(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func srt(_ cues: [HighQualitySubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            let text = (cue.speakerName ?? cue.speakerLabel).map { "[\($0)] \(cue.text)" }
                ?? cue.text
            return "\(index + 1)\n\(SubtitleTimecode.srt(cue.start)) --> \(SubtitleTimecode.srt(cue.end))\n\(text)\n"
        }.joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
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
        manifest: HighQualityJobManifest
    ) -> HighQualityRawEvidence {
        HighQualityRawEvidence(
            source: manifest.source,
            model: manifest.model,
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
            generatedFiles: manifest.generatedFiles
        )
    }

    private static func writeEvidence(
        _ evidence: HighQualityRawEvidence,
        to directory: URL
    ) throws {
        try encoder.encode(evidence).write(
            to: directory.appendingPathComponent("raw-asr.json"),
            options: .atomic
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
        manifest: HighQualityJobManifest,
        to directory: URL
    ) throws -> HighQualityRawEvidence {
        let evidence = evidence(
            rawASR: rawASR,
            glossary: glossary,
            alignment: alignment,
            diarization: diarization,
            translation: translation,
            sampleCount: sampleCount,
            manifest: manifest
        )
        try writeEvidence(evidence, to: directory)
        try writeManifest(manifest, to: directory)
        return evidence
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
