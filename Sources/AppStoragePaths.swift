import Foundation

enum AppStoragePaths {
    static var root: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("WhisperASR", isDirectory: true)
    }

    static var recordings: URL {
        root.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var recovery: URL {
        root.appendingPathComponent("Recovery", isDirectory: true)
    }

    static var transcriptions: URL {
        root.appendingPathComponent("Transcriptions", isDirectory: true)
    }

    static var highQualityJobs: URL {
        root.appendingPathComponent("HighQualityJobs", isDirectory: true)
    }

    static var highQualityProjects: URL {
        root.appendingPathComponent("HighQualityProjects", isDirectory: true)
    }

    static var liveRecovery: URL {
        root.appendingPathComponent("live_recovery.json")
    }

    static var instanceLock: URL {
        root.appendingPathComponent("instance.lock")
    }
}
