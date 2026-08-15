import Darwin
import Foundation

enum AtomicDirectory {
    static func update(_ active: URL, prepare: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let staged = active.deletingLastPathComponent().appendingPathComponent(
            ".\(active.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { remove(staged) }
        try hardLinkContents(of: active, to: staged)
        try prepare(staged)
        try swap(staged, with: active)
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

    static func remove(_ directory: URL) {
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) {
            for case let item as URL in enumerator
                where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink != true {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: item.path
                )
            }
        }
        try? FileManager.default.setAttributes(
            [.immutable: false],
            ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }
}
