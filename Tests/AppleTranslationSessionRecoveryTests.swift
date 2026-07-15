import Foundation
import XCTest
@testable import WhisperASRApp

@available(macOS 26.4, *)
final class AppleTranslationSessionRecoveryTests: XCTestCase {
    func testRetryableInvocationFailuresRequireAFreshSession() {
        XCTAssertTrue(AppleTranslationService.requiresSessionReplacement(
            after: NSError(domain: "Translation", code: -1)
        ))
        XCTAssertTrue(AppleTranslationService.requiresSessionReplacement(
            after: AppleLiveError.translationTimedOut
        ))
        XCTAssertTrue(AppleTranslationService.requiresSessionReplacement(
            after: AppleLiveError.emptyTranslation
        ))
    }

    func testCancellationAndMissingAssetsDoNotReplaceTheSession() {
        XCTAssertFalse(AppleTranslationService.requiresSessionReplacement(
            after: CancellationError()
        ))
        XCTAssertFalse(AppleTranslationService.requiresSessionReplacement(
            after: AppleLiveError.translationAssetsUnavailable
        ))
    }
}
