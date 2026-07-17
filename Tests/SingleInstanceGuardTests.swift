import XCTest
@testable import WhisperASRApp

final class SingleInstanceGuardTests: XCTestCase {
    func testOnlyOneOwnerCanHoldTheApplicationLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceGuardTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("instance.lock")
        var first: SingleInstanceGuard? = try SingleInstanceGuard(lockURL: lockURL)

        XCTAssertThrowsError(try SingleInstanceGuard(lockURL: lockURL)) { error in
            guard case SingleInstanceGuard.GuardError.alreadyRunning = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        first = nil
        XCTAssertNoThrow(try SingleInstanceGuard(lockURL: lockURL))
        _ = first
    }
}
