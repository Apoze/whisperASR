import Foundation

/// Serializes the single live-recovery snapshot and rejects work from an old
/// recording after Finish, Cancel, or a newer recording has taken ownership.
actor LiveRecoveryStore {
    enum SaveOutcome: Equatable, Sendable {
        case saved
        case staleGeneration
        case inactiveSession
    }

    enum RemoveOutcome: Equatable, Sendable {
        case removed
        case inactiveSession
    }

    static var defaultURL: URL {
        AppStoragePaths.liveRecovery
    }

    let fileURL: URL

    private let fileManager: FileManager
    private var activeSessionID: UUID?
    private var latestGeneration: UInt64?

    init(
        fileURL: URL = LiveRecoveryStore.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func beginSession(_ sessionID: UUID) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        latestGeneration = nil
    }

    @discardableResult
    func save(
        _ data: Data,
        sessionID: UUID,
        generation: UInt64
    ) throws -> SaveOutcome {
        guard activeSessionID == sessionID else {
            return .inactiveSession
        }
        if let latestGeneration, generation <= latestGeneration {
            return .staleGeneration
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        latestGeneration = generation
        return .saved
    }

    @discardableResult
    func remove(sessionID: UUID) throws -> RemoveOutcome {
        guard activeSessionID == sessionID else {
            return .inactiveSession
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        activeSessionID = nil
        latestGeneration = nil
        return .removed
    }

    func data() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func exists() -> Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }
}
