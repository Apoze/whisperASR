import Foundation
import Darwin

final class SingleInstanceGuard {
    enum GuardError: LocalizedError {
        case alreadyRunning
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "WhisperASR is already running."
            case let .unavailable(message):
                "WhisperASR could not create its instance lock: \(message)"
            }
        }
    }

    private let descriptor: Int32

    init(lockURL: URL = AppStoragePaths.instanceLock) throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw GuardError.unavailable(String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw GuardError.alreadyRunning
            }
            throw GuardError.unavailable(String(cString: strerror(lockError)))
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
