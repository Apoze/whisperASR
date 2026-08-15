import Darwin
import Foundation

enum AtomicDirectory {
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
}
