import XCTest
@testable import Qwen3ASR

final class QwenDecoderLoopGuardTests: XCTestCase {
    func testGreedyDecoderDetectsAPathologicallyCollapsedTail() {
        let pattern: [Int32] = [101, 102, 103]
        let collapsed = (0..<8).flatMap { _ in pattern }

        XCTAssertTrue(Qwen3ASRModel.hasCollapsedGreedyTail(collapsed))
    }
}
