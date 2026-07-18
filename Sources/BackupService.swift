import Foundation

/// Exports and restores app configuration as a single portable JSON file, so a
/// user moving to a new Mac can carry over their settings.
///
/// Configuration is the only thing that lives outside the Recordings and
/// Transcriptions folders. The user copies those two folders manually; the
/// transcripts themselves come straight from the copied Transcriptions folder
/// (read by `TranscriptionStore.loadAll()`), and each recording's audio link is
/// auto-repaired on load by `TranscriptionStore.resolveRecordingURL` — which
/// re-links by filename when the stored absolute path (with the old username)
/// no longer resolves. So the backup deliberately does *not* duplicate
/// transcription metadata; it only carries the settings.
enum BackupService {

    /// Bumped only if the on-disk schema changes incompatibly.
    static let formatVersion = 1

    // MARK: - DTOs

    struct BackupFile: Codable {
        var version: Int
        var createdAt: Date
        var appVersion: String?
        var configuration: BackupConfiguration
    }

    /// Every persisted UserDefaults setting. All optional so a future/older
    /// backup that omits a key simply leaves the current value untouched.
    struct BackupConfiguration: Codable {
        var transcriptFontSize: String?
        var selectedModelFile: String?
        var modelPath: String?
        var targetLanguage: String?
        var translationEndpoint: String?
        var translationModel: String?
        var translationAPIKey: String?
        var liveTranslationPref: Bool?
        var liveCaptionMode: String?
        var keepOriginalTranscript: Bool?
        var translationOnlyPref: Bool?
        var liveSubtitlePolicy: String?
        var localEnglishEngine: String?
        var localSpeechEngine: String?
        var localSourceLocale: String?
        var appleTranslationMode: String?
        var voxtralContinuousConfiguration: String?
        var japaneseGlossaryEnabled: Bool?
        var japaneseGlossaryRules: String?
        var recentRecordingApps: [String]?
    }

    // MARK: - Export

    static func makeBackup() -> BackupFile {
        let d = UserDefaults.standard
        let config = BackupConfiguration(
            transcriptFontSize: d.string(forKey: "transcriptFontSize"),
            selectedModelFile: d.string(forKey: "selectedModelFile"),
            modelPath: d.string(forKey: "modelPath"),
            targetLanguage: d.string(forKey: "targetLanguage"),
            translationEndpoint: d.string(forKey: "translationEndpoint"),
            translationModel: d.string(forKey: "translationModel"),
            translationAPIKey: d.string(forKey: "translationAPIKey"),
            liveTranslationPref: d.object(forKey: "liveTranslationPref") == nil
                ? nil : d.bool(forKey: "liveTranslationPref"),
            liveCaptionMode: d.string(forKey: LiveCaptionMode.storageKey),
            keepOriginalTranscript: d.object(forKey: LiveCaptionMode.keepOriginalKey) == nil
                ? nil : d.bool(forKey: LiveCaptionMode.keepOriginalKey),
            translationOnlyPref: d.object(forKey: LiveCaptionMode.translationOnlyKey) == nil
                ? nil : d.bool(forKey: LiveCaptionMode.translationOnlyKey),
            liveSubtitlePolicy: d.string(forKey: LiveSubtitlePolicy.storageKey),
            localEnglishEngine: d.string(forKey: LocalEnglishEngine.storageKey),
            localSpeechEngine: d.string(forKey: LocalSpeechEngine.storageKey),
            localSourceLocale: d.string(forKey: LocalSpeechEngine.sourceLocaleKey),
            appleTranslationMode: d.string(forKey: AppleTranslationMode.storageKey),
            voxtralContinuousConfiguration: d.string(
                forKey: VoxtralContinuousConfiguration.storageKey
            ),
            japaneseGlossaryEnabled: d.object(forKey: JapaneseGlossary.enabledKey) == nil
                ? nil : d.bool(forKey: JapaneseGlossary.enabledKey),
            japaneseGlossaryRules: d.string(forKey: JapaneseGlossary.rulesKey),
            recentRecordingApps: d.stringArray(forKey: "recentRecordingApps")
        )

        return BackupFile(
            version: formatVersion,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            configuration: config
        )
    }

    static func encode(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFile.self, from: data)
    }

    // MARK: - Restore

    /// Writes the backed-up configuration back to UserDefaults. Touches
    /// ModelManager and UserDefaults, so it runs on the main actor. Only keys
    /// present in the backup are written, so missing keys leave the current
    /// value intact.
    @MainActor
    static func restore(_ backup: BackupFile) {
        let c = backup.configuration
        let d = UserDefaults.standard
        func set(_ value: String?, _ key: String) {
            if let value { d.set(value, forKey: key) }
        }
        set(c.transcriptFontSize, "transcriptFontSize")
        set(c.selectedModelFile, "selectedModelFile")
        set(c.modelPath, "modelPath")
        set(c.targetLanguage, "targetLanguage")
        set(c.translationEndpoint, "translationEndpoint")
        set(c.translationModel, "translationModel")
        set(c.translationAPIKey, "translationAPIKey")
        if let pref = c.liveTranslationPref { d.set(pref, forKey: "liveTranslationPref") }
        if let mode = c.liveCaptionMode {
            d.set(mode, forKey: LiveCaptionMode.storageKey)
        } else if let pref = c.liveTranslationPref {
            d.set(
                (pref ? LiveCaptionMode.api : LiveCaptionMode.original).rawValue,
                forKey: LiveCaptionMode.storageKey
            )
        }
        if let keepOriginal = c.keepOriginalTranscript {
            d.set(keepOriginal, forKey: LiveCaptionMode.keepOriginalKey)
        }
        if let translationOnly = c.translationOnlyPref {
            d.set(translationOnly, forKey: LiveCaptionMode.translationOnlyKey)
        }
        if let policy = c.liveSubtitlePolicy {
            d.set(policy, forKey: LiveSubtitlePolicy.storageKey)
        }
        set(c.localEnglishEngine, LocalEnglishEngine.storageKey)
        set(c.localSpeechEngine, LocalSpeechEngine.storageKey)
        set(c.localSourceLocale, LocalSpeechEngine.sourceLocaleKey)
        if let mode = c.appleTranslationMode {
            d.set(mode, forKey: AppleTranslationMode.storageKey)
        } else if let policy = c.liveSubtitlePolicy {
            d.set(
                policy == LiveSubtitlePolicy.stableOnly.rawValue
                    ? AppleTranslationMode.highFidelityOnly.rawValue
                    : AppleTranslationMode.adaptive.rawValue,
                forKey: AppleTranslationMode.storageKey
            )
        }
        set(
            c.voxtralContinuousConfiguration,
            VoxtralContinuousConfiguration.storageKey
        )
        if let enabled = c.japaneseGlossaryEnabled {
            d.set(enabled, forKey: JapaneseGlossary.enabledKey)
        }
        set(c.japaneseGlossaryRules, JapaneseGlossary.rulesKey)
        if let apps = c.recentRecordingApps { d.set(apps, forKey: "recentRecordingApps") }

        // ModelManager caches the selection in a stored property; nudge it so the
        // toolbar/Settings reflect the restored choice. refresh() will clear it
        // again if that model isn't downloaded on this Mac yet — which is correct,
        // and it re-selects automatically once the model is downloaded.
        if let sel = c.selectedModelFile {
            ModelManager.shared.selectedFileName = sel
        }
        ModelManager.shared.refresh()
    }
}
