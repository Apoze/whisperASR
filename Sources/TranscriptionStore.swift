import Foundation

enum TranscriptionStore {

    // MARK: - Codable DTO

    private struct StoredItem: Codable {
        let id: UUID
        let fileName: String
        let filePath: String
        let segments: [TranscriptionSegment]
        let fullText: String
        let dateAdded: Date
        let statusTag: String          // "completed", "failed", "pending"
        let errorMessage: String?
        let translatedSegments: [String]?
        let translationLanguage: String?
        let translateToEnglish: Bool?
        let localSourceLocale: String?
        let localTranslationMode: AppleTranslationMode?
        let discardOriginalAfterRetry: Bool?
        let localSourceTranscriptComplete: Bool?
    }

    // MARK: - Directory

    private static var storeDirectory: URL {
        AppStoragePaths.transcriptions
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true
        )
    }

    private static func fileURL(for id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static var recordingsDirectory: URL {
        AppStoragePaths.recordings
    }

    /// Resolve a stored recording path, healing it if it no longer exists. After
    /// moving to a new Mac the absolute path embeds the old username and breaks;
    /// if a file of the same name sits in the local Recordings folder we re-link
    /// to it. Only kicks in when the original is missing, so files that live
    /// elsewhere (e.g. drag-dropped) are left untouched.
    private static func resolveRecordingURL(storedPath: String) -> URL {
        let original = URL(fileURLWithPath: storedPath)
        if FileManager.default.fileExists(atPath: storedPath) { return original }
        let candidate = recordingsDirectory.appendingPathComponent(original.lastPathComponent)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return original
    }

    // MARK: - Save

    static func save(_ item: TranscriptionItem) throws {
        try save(item, at: fileURL(for: item.id))
    }

    /// Testable persistence entry point. Production uses the item-specific URL
    /// above; callers that need another destination do not have to redirect the
    /// process-wide Application Support directory.
    static func save(_ item: TranscriptionItem, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encodedData(for: item).write(to: url, options: .atomic)
    }

    /// Shared by production persistence and tests so migrations exercise the
    /// exact Codable path without writing into Application Support.
    static func encodedData(for item: TranscriptionItem) throws -> Data {
        let statusTag: String
        let errorMessage: String?
        switch item.status {
        case .completed:
            statusTag = "completed"
            errorMessage = nil
        case .failed(let msg):
            statusTag = "failed"
            errorMessage = msg
        default:
            statusTag = "pending"
            errorMessage = nil
        }

        let stored = StoredItem(
            id: item.id,
            fileName: item.fileName,
            filePath: item.fileURL.path,
            segments: item.segments,
            fullText: item.fullText,
            dateAdded: item.dateAdded,
            statusTag: statusTag,
            errorMessage: errorMessage,
            translatedSegments: item.translatedSegments.isEmpty ? nil : item.translatedSegments,
            translationLanguage: item.translationLanguage,
            translateToEnglish: item.translateToEnglish ? true : nil,
            localSourceLocale: item.localSourceLocale,
            localTranslationMode: item.localTranslationMode,
            discardOriginalAfterRetry: item.discardOriginalAfterRetry ? true : nil,
            // Local-English items retain this bit even after a partial recovery
            // has translated every saved clause and no retry remains possible.
            localSourceTranscriptComplete: item.translateToEnglish || item.localSourceLocale != nil
                ? item.localSourceTranscriptComplete : nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(stored)
    }

    // MARK: - Load

    static func loadAll() -> [TranscriptionItem] {
        try? ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TranscriptionItem? in
                guard let data = try? Data(contentsOf: url),
                      let item = try? decodedItem(from: data) else { return nil }
                return item
            }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    static func decodedItem(from data: Data) throws -> TranscriptionItem {
        let stored = try JSONDecoder().decode(StoredItem.self, from: data)
        let status: TranscriptionStatus
        switch stored.statusTag {
        case "completed": status = .completed
        case "failed": status = .failed(stored.errorMessage ?? "Unknown error")
        default: status = .pending
        }

        return TranscriptionItem(
            id: stored.id,
            fileName: stored.fileName,
            fileURL: resolveRecordingURL(storedPath: stored.filePath),
            dateAdded: stored.dateAdded,
            status: status,
            segments: stored.segments,
            fullText: stored.fullText,
            translatedSegments: stored.translatedSegments ?? [],
            translationLanguage: stored.translationLanguage,
            translateToEnglish: stored.translateToEnglish ?? false,
            localSourceLocale: stored.localSourceLocale,
            localTranslationMode: stored.localTranslationMode,
            discardOriginalAfterRetry: stored.discardOriginalAfterRetry ?? false,
            localSourceTranscriptComplete: stored.localSourceTranscriptComplete
                ?? !(stored.translateToEnglish ?? false)
        )
    }

    // MARK: - Delete

    /// Whether the audio file lives in the app's own Recordings folder, i.e. was
    /// recorded by WhisperASR rather than imported (drag-drop / file picker).
    static func isAppRecording(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            .hasPrefix(recordingsDirectory.standardizedFileURL.path + "/")
    }

    /// Once metadata is gone, the transcription is deleted. Failure to move an
    /// app-owned recording to Trash is reported separately so memory and disk
    /// cannot disagree about whether the sidebar item still exists.
    static func delete(_ item: TranscriptionItem) throws -> String? {
        let metadataURL = fileURL(for: item.id)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        // Only audio the app recorded is ours to dispose of — and it goes to the
        // Trash, not straight to deletion. Imported files are left untouched.
        if isAppRecording(item.fileURL),
           FileManager.default.fileExists(atPath: item.fileURL.path) {
            do {
                try FileManager.default.trashItem(at: item.fileURL, resultingItemURL: nil)
            } catch {
                return "The transcription was removed, but its audio remains at \(item.fileURL.path): \(error.localizedDescription)"
            }
        }
        return nil
    }
}
