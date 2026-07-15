import Foundation
import Observation
import SwiftUI

// MARK: - Live Captions

enum LiveCaptionMode: String, CaseIterable, Identifiable {
    case original
    case localEnglish = "whisperEnglish"
    case api

    static let storageKey = "liveCaptionMode"
    static let keepOriginalKey = "keepOriginalTranscript"
    static let translationOnlyKey = "translationOnlyPref"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original — Whisper local"
        case .localEnglish: return "English — local"
        case .api: return "API — selected language"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> LiveCaptionMode {
        if let raw = defaults.string(forKey: storageKey), let mode = LiveCaptionMode(rawValue: raw) {
            return mode
        }
        // Migrate the previous live-translation checkbox without changing its meaning.
        if defaults.object(forKey: "liveTranslationPref") != nil {
            return defaults.bool(forKey: "liveTranslationPref") ? .api : .original
        }
        return .original
    }
}

enum LocalSpeechEngine: String, CaseIterable, Identifiable {
    case appleSpeech
    case whisper

    static let storageKey = "localSpeechEngine"
    static let sourceLocaleKey = "localSourceLocale"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech: return "Apple Speech — streaming"
        case .whisper: return "Whisper — selected model"
        }
    }
}

/// The deliberately narrow local-English pipelines. This stays separate
/// from the Whisper model catalog: each case describes a complete pipeline, not
/// a generally interchangeable model.
enum LocalEnglishEngine: String, CaseIterable, Identifiable, Codable {
    case whisperTurboApple
    case qwenApple
    case voxtralApple
    case voxtralCohereApple
    case whisperLargeV3Direct
    case cohereApple

    static let storageKey = "localEnglishEngine"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whisperTurboApple:
            return "Whisper Turbo → Apple"
        case .qwenApple:
            return "Qwen → Apple"
        case .voxtralApple:
            return "Voxtral live → Apple"
        case .voxtralCohereApple:
            return "Voxtral live + Cohere final → Apple"
        case .whisperLargeV3Direct:
            return "Whisper Large v3 → English direct"
        case .cohereApple:
            return "Cohere Q8 → Apple"
        }
    }

    var detail: String {
        switch self {
        case .whisperTurboApple:
            return "Reference: Whisper Large v3 Turbo transcribes, then Apple high-fidelity translates."
        case .qwenApple:
            return "Experimental: Qwen transcribes each FireRedVAD phrase, then Apple translates."
        case .voxtralApple:
            return "Experimental: one continuous Voxtral session supplies live source text and each stable clause for Apple Translation."
        case .voxtralCohereApple:
            return "Experimental: Voxtral supplies live previews while Cohere Q8 re-decodes each stable final."
        case .whisperLargeV3Direct:
            return "Experimental: Whisper Large v3 translates each FireRedVAD phrase directly to English."
        case .cohereApple:
            return "Experimental: Cohere Q8 transcribes each FireRedVAD phrase, then Apple translates."
        }
    }

    var requiredComponents: Set<LocalRuntimeComponent> {
        switch self {
        case .whisperTurboApple:
            return [.fireRedVAD, .whisperTurbo, .appleTranslation]
        case .qwenApple:
            return [.fireRedVAD, .qwen, .appleTranslation]
        case .voxtralApple:
            return [.fireRedVAD, .voxtral, .appleTranslation]
        case .voxtralCohereApple:
            return [.fireRedVAD, .voxtral, .cohere, .appleTranslation]
        case .whisperLargeV3Direct:
            return [.fireRedVAD, .whisperLargeV3]
        case .cohereApple:
            return [.fireRedVAD, .cohere, .appleTranslation]
        }
    }

    var usesVoxtralStreaming: Bool {
        self == .voxtralApple || self == .voxtralCohereApple
    }

    var usesAppleSpeechPreview: Bool { !usesVoxtralStreaming }

    var usesVoxtralSourcePreview: Bool { usesVoxtralStreaming }

    var usesCohereFinal: Bool {
        self == .voxtralCohereApple || self == .cohereApple
    }

    var producesDirectEnglish: Bool {
        self == .whisperLargeV3Direct
    }

    var usesAppleFinalTranslation: Bool { !producesDirectEnglish }

    var usesWhisperFinal: Bool {
        self == .whisperTurboApple || self == .whisperLargeV3Direct
    }

    var whisperModelID: String? {
        switch self {
        case .whisperTurboApple: return "large-v3-turbo"
        case .whisperLargeV3Direct: return "large-v3"
        default: return nil
        }
    }

    func requiresAppleLowLatency(for mode: AppleTranslationMode) -> Bool {
        mode.showsPreview || (usesAppleFinalTranslation && mode.requiresLowLatency)
    }

    func requiresAppleHighFidelity(for mode: AppleTranslationMode) -> Bool {
        usesAppleFinalTranslation && mode.requiresHighFidelity
    }

    /// Preserve existing installations: the old Whisper choice maps to the
    /// corrected reference pipeline; Apple Speech is no longer a benchmark
    /// candidate and maps to the same safe default.
    static func stored(in defaults: UserDefaults = .standard) -> Self {
        if defaults.string(forKey: storageKey) == "nemotronQwenApple" {
            return .qwenApple
        }
        if let raw = defaults.string(forKey: storageKey), let engine = Self(rawValue: raw) {
            return engine
        }
        return .whisperTurboApple
    }
}

enum LocalRuntimeComponent: String, Hashable, Sendable {
    case fireRedVAD
    case whisperTurbo
    case whisperLargeV3
    case qwen
    case voxtral
    case cohere
    case appleTranslation
}

enum LocalModelPhase: Equatable {
    case absent
    case downloading(progress: Double, message: String)
    case loading(message: String)
    case ready(residentBytes: UInt64)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AppleTranslationMode: String, CaseIterable, Identifiable, Codable {
    case adaptive
    case highFidelityOnly
    case lowLatencyOnly

    static let storageKey = "appleTranslationMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "Live preview → best final"
        case .highFidelityOnly: return "Stable final only"
        case .lowLatencyOnly: return "Live preview → fastest final"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppleTranslationMode {
        if let raw = defaults.string(forKey: storageKey), let mode = Self(rawValue: raw) {
            return mode
        }
        let old = defaults.string(forKey: LiveSubtitlePolicy.storageKey)
        return old == LiveSubtitlePolicy.stableOnly.rawValue ? .highFidelityOnly : .adaptive
    }

    var showsPreview: Bool { self != .highFidelityOnly }
    var finalUsesHighFidelity: Bool { self != .lowLatencyOnly }
    var requiresLowLatency: Bool { showsPreview || !finalUsesHighFidelity }
    var requiresHighFidelity: Bool { finalUsesHighFidelity }
}

struct SpeechLocaleChoice: Identifiable, Hashable {
    let id: String
    let label: String
}

enum LiveSubtitlePolicy: String, CaseIterable, Identifiable {
    case fastPreview
    case stableOnly

    static let storageKey = "liveSubtitlePolicy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastPreview: return "Fast preview"
        case .stableOnly: return "Stable only"
        }
    }
}

// MARK: - Transcript Font Size

enum TranscriptFontSize: String, CaseIterable {
    case small, normal, large

    var label: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Normal"
        case .large: return "Large"
        }
    }

    var bodyFont: Font {
        switch self {
        case .small: return .caption
        case .normal: return .body
        case .large: return .title3
        }
    }

    var translationFont: Font {
        switch self {
        case .small: return .caption2
        case .normal: return .callout
        case .large: return .body
        }
    }

    var timestampFont: Font {
        switch self {
        case .small: return .system(.caption2, design: .monospaced)
        case .normal: return .system(.caption, design: .monospaced)
        case .large: return .system(.footnote, design: .monospaced)
        }
    }
}

// MARK: - Transcription Segment

struct TranscriptionSegment: Codable, Equatable {
    let start: Double
    let end: Double?
    let text: String
}

// MARK: - Transcription Result

struct TranscriptionResult: Codable {
    let text: String
    let segments: [TranscriptionSegment]
    /// Whisper's auto-detected language code (e.g. "en", "zh"). Populated for
    /// file transcription; used by the OpenAI-compatible API's verbose_json.
    var detectedLanguage: String? = nil
}

// MARK: - Status

enum TranscriptionStatus: Equatable {
    case pending
    case transcribing
    case completed
    case failed(String)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case modelNotFound(String)
    case modelIncompatible(String)
    case modelBusy

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Transcription failed: \(msg)"
        case .modelNotFound(let msg): return msg
        case .modelIncompatible(let msg): return msg
        case .modelBusy: return "The Whisper model is busy with live captions. Try again when recording ends."
        }
    }
}

// MARK: - Transcription Item

@Observable
class TranscriptionItem: Identifiable {
    let id: UUID
    var fileName: String
    var fileURL: URL
    var status: TranscriptionStatus = .pending
    var segments: [TranscriptionSegment] = []
    var fullText: String = ""
    var progress: Double = 0
    var transcriptionStartTime: Date?
    var translatedSegments: [String] = []
    var translationLanguage: String?
    var isTranslating: Bool = false
    var translateToEnglish = false
    var localSourceLocale: String?
    var localTranslationMode: AppleTranslationMode?
    var discardOriginalAfterRetry = false
    /// False means the persisted source is only a recoverable prefix. Retry
    /// must re-transcribe the retained audio before it may mark the item done.
    var localSourceTranscriptComplete = true
    let dateAdded: Date

    init(fileURL: URL) {
        self.id = UUID()
        self.fileName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.dateAdded = Date()
    }

    /// Restore from persisted data
    init(id: UUID, fileName: String, fileURL: URL, dateAdded: Date,
         status: TranscriptionStatus, segments: [TranscriptionSegment], fullText: String,
         translatedSegments: [String] = [], translationLanguage: String? = nil,
         translateToEnglish: Bool = false, localSourceLocale: String? = nil,
         localTranslationMode: AppleTranslationMode? = nil,
         discardOriginalAfterRetry: Bool = false,
         localSourceTranscriptComplete: Bool = true) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.dateAdded = dateAdded
        self.status = status
        self.segments = segments
        self.fullText = fullText
        self.translatedSegments = translatedSegments
        self.translationLanguage = translationLanguage
        self.translateToEnglish = translateToEnglish
        self.localSourceLocale = localSourceLocale
        self.localTranslationMode = localTranslationMode
        self.discardOriginalAfterRetry = discardOriginalAfterRetry
        self.localSourceTranscriptComplete = localSourceTranscriptComplete
    }
}
