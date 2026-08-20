import Darwin
import Foundation

enum AtomicDirectory {
    // ponytail: one process-wide lock; use per-directory locks only if contention appears.
    private static let storageLock = NSRecursiveLock()

    static func coordinated<T>(_ operation: () throws -> T) rethrows -> T {
        storageLock.lock()
        defer { storageLock.unlock() }
        return try operation()
    }

    static func update(_ active: URL, prepare: (URL) throws -> Void) throws {
        try coordinated {
            try updateUncoordinated(active, prepare: prepare)
        }
    }

    private static func updateUncoordinated(
        _ active: URL,
        prepare: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let staged = active.deletingLastPathComponent().appendingPathComponent(
            ".\(active.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: false)
        do {
            try hardLinkContents(of: active, to: staged)
            try prepare(staged)
            try swap(staged, with: active)
        } catch {
            do {
                try remove(staged)
            } catch let cleanupError {
                throw cleanupFailure(cleanupError, after: error, committed: false)
            }
            throw error
        }
        do {
            try remove(staged)
        } catch {
            throw cleanupFailure(error, after: nil, committed: true)
        }
    }

    static func swap(_ staged: URL, with active: URL) throws {
        let status = staged.path.withCString { stagedPath in
            active.path.withCString { activePath in
                renameatx_np(
                    AT_FDCWD,
                    stagedPath,
                    AT_FDCWD,
                    activePath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func hardLinkContents(of source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let canonicalSourcePath = source.resolvingSymlinksInPath().path
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let item as URL in enumerator {
            let sourcePath: String
            let itemPath: String
            if item.path.hasPrefix(source.path + "/") {
                sourcePath = source.path
                itemPath = item.path
            } else {
                sourcePath = canonicalSourcePath
                itemPath = item.resolvingSymlinksInPath().path
            }
            guard itemPath.hasPrefix(sourcePath + "/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relativePath = String(itemPath.dropFirst(sourcePath.count + 1))
            let target = destination.appendingPathComponent(relativePath)
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                try fileManager.createSymbolicLink(
                    atPath: target.path,
                    withDestinationPath: fileManager.destinationOfSymbolicLink(atPath: item.path)
                )
            } else if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            } else if try fileManager.attributesOfItem(atPath: item.path)[.immutable]
                as? Bool == true {
                try fileManager.copyItem(at: item, to: target)
            } else {
                try fileManager.linkItem(at: item, to: target)
            }
        }
        if let traversalError { throw traversalError }
    }

    static func remove(_ directory: URL) throws {
        try coordinated {
            try removeUncoordinated(directory)
        }
    }

    private static func removeUncoordinated(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let rootValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var traversalError: Error?
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) {
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                if try fileManager.attributesOfItem(atPath: item.path)[.immutable]
                    as? Bool == true {
                    try fileManager.setAttributes([.immutable: false], ofItemAtPath: item.path)
                }
            }
        }
        if let traversalError { throw traversalError }
        if try fileManager.attributesOfItem(atPath: directory.path)[.immutable]
            as? Bool == true {
            try fileManager.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        }
        try fileManager.removeItem(at: directory)
    }

    static func isStagingDirectory(_ directory: URL) -> Bool {
        let name = directory.lastPathComponent
        let parts = name.dropFirst().components(separatedBy: ".staging-")
        return name.hasPrefix(".")
            && parts.count == 2
            && !parts[0].isEmpty
            && UUID(uuidString: parts[1]) != nil
    }

    private static func cleanupFailure(
        _ cleanupError: Error,
        after operationError: Error?,
        committed: Bool
    ) -> Error {
        let prefix = committed
            ? "The directory update committed, but old data cleanup failed"
            : "The directory update failed and staging cleanup also failed"
        let operation = operationError.map { ": \($0.localizedDescription)" } ?? ""
        return NSError(
            domain: "WhisperASR.AtomicDirectory",
            code: committed ? 2 : 1,
            userInfo: [
                NSLocalizedDescriptionKey: "\(prefix)\(operation). "
                    + cleanupError.localizedDescription,
            ]
        )
    }
}
