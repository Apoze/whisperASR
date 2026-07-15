import Foundation
import XCTest
@testable import WhisperASRApp

final class LocalFinalTranslationRetryTests: XCTestCase {
    func testSharedEnglishValidationRejectsSourceScriptForLiveAndRetry() throws {
        XCTAssertEqual(
            EnglishSubtitleValidator.normalizedEnglish("  A faithful subtitle.  "),
            "A faithful subtitle."
        )
        XCTAssertNil(EnglishSubtitleValidator.normalizedEnglish("これは英語ではありません。"))
        XCTAssertNil(EnglishSubtitleValidator.normalizedEnglish("ｺﾝﾋﾟｭｰﾀｰ"))
        XCTAssertNil(EnglishSubtitleValidator.normalizedEnglish("﨑"))
        XCTAssertNil(EnglishSubtitleValidator.normalizedEnglish("𠮷"))
        XCTAssertThrowsError(
            try EnglishSubtitleValidator.requireEnglish("お姉さん？")
        ) { error in
            guard let error = error as? LocalPrototypeError,
                  case .invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testRecoveryUsesAudioWhenRealAndSavedClausesWhenItIsMissing() {
        XCTAssertEqual(
            LocalEnglishRetrySourceStrategy.resolve(
                sourceComplete: false,
                hasSavedSource: true,
                hasAudio: true
            ),
            .retranscribeAudio
        )
        XCTAssertEqual(
            LocalEnglishRetrySourceStrategy.resolve(
                sourceComplete: false,
                hasSavedSource: true,
                hasAudio: false
            ),
            .savedPartial
        )
        XCTAssertNil(
            LocalEnglishRetrySourceStrategy.resolve(
                sourceComplete: false,
                hasSavedSource: false,
                hasAudio: false
            )
        )
        let retainedAudioFallback = LocalEnglishRetrySourceStrategy.afterAudioFailure(
            hasSavedSource: true,
            hasAudio: true
        )
        XCTAssertEqual(retainedAudioFallback?.strategy, .savedPartial)
        XCTAssertEqual(retainedAudioFallback?.retainsAudioRetry, true)

        let sourceOnlyFallback = LocalEnglishRetrySourceStrategy.afterAudioFailure(
            hasSavedSource: true,
            hasAudio: false
        )
        XCTAssertEqual(sourceOnlyFallback?.strategy, .savedPartial)
        XCTAssertEqual(sourceOnlyFallback?.retainsAudioRetry, false)
        XCTAssertNil(LocalEnglishRetrySourceStrategy.afterAudioFailure(
            hasSavedSource: false,
            hasAudio: true
        ))
    }

    func testAudioRecoveryNeverReplacesSavedClausesWithShorterCoverage() {
        let saved = [
            TranscriptionSegment(start: 0, end: 10, text: "保存済みです。")
        ]
        XCTAssertFalse(LocalEnglishRetrySourceStrategy.acceptsAudioRetranscription(
            [TranscriptionSegment(start: 0, end: 5, text: "短いです。")],
            over: saved
        ))
        XCTAssertFalse(LocalEnglishRetrySourceStrategy.acceptsAudioRetranscription(
            [TranscriptionSegment(start: 1, end: 10, text: "冒頭がありません。")],
            over: saved
        ))
        XCTAssertTrue(LocalEnglishRetrySourceStrategy.acceptsAudioRetranscription(
            [TranscriptionSegment(start: 0, end: 10, text: "完全です。")],
            over: saved
        ))
        XCTAssertTrue(LocalEnglishRetrySourceStrategy.acceptsAudioRetranscription(
            [TranscriptionSegment(start: 0, end: 2, text: "初回です。")],
            over: []
        ))
    }

    func testRecoveryAudioURLNeverTreatsAMissingPathAsUsableAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-audio-\(UUID().uuidString).m4a")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(AppState.existingRecoveryAudioURL(path: url.path), url)
        XCTAssertNil(AppState.existingRecoveryAudioURL(path: url.path + ".missing"))
        XCTAssertNil(AppState.existingRecoveryAudioURL(path: nil))
    }

    func testPartialRecoveryCompletenessPersistsAfterItsSavedClausesAreTranslated() throws {
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-source-only-test")
        )
        item.status = .completed
        item.localSourceLocale = "ja-JP"
        item.localTranslationMode = .adaptive
        item.localSourceTranscriptComplete = false
        item.segments = [TranscriptionSegment(start: 0, end: 1, text: "はい。")]
        item.translatedSegments = ["Yes."]
        item.translationLanguage = "en"

        let restored = try TranscriptionStore.decodedItem(
            from: TranscriptionStore.encodedData(for: item)
        )
        XCTAssertFalse(restored.localSourceTranscriptComplete)
        XCTAssertEqual(restored.translatedSegments, ["Yes."])
    }

    func testAttemptStateDrivesTheRealBoundedRetryLifecycle() {
        var state = LocalFinalTranslationAttemptState()

        XCTAssertEqual(state.begin(), 1)
        let first = state.record(AppleLiveError.translationTimedOut)
        XCTAssertEqual(first.classification, .timedOut)
        XCTAssertEqual(first.disposition, .retry(after: .milliseconds(250)))
        XCTAssertFalse(state.exhausted)

        XCTAssertEqual(state.begin(), 2)
        XCTAssertEqual(
            state.record(AppleLiveError.emptyTranslation).disposition,
            .retry(after: .seconds(1))
        )
        XCTAssertFalse(state.exhausted)

        XCTAssertEqual(state.begin(), 3)
        XCTAssertEqual(
            state.record(LocalPrototypeError.invalidResponse).disposition,
            .retain
        )
        XCTAssertTrue(state.exhausted)
        XCTAssertEqual(state.count, 3)
    }

    func testRetryableFailuresUseTheFixedThreeAttemptSchedule() {
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: AppleLiveError.translationTimedOut,
                afterAttempt: 1
            ),
            .retry(after: .milliseconds(250))
        )
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: AppleLiveError.emptyTranslation,
                afterAttempt: 2
            ),
            .retry(after: .seconds(1))
        )
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: LocalPrototypeError.invalidResponse,
                afterAttempt: 3
            ),
            .retain
        )
    }

    func testPermanentFailuresAreRetainedWithoutRetry() {
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: LocalPrototypeError.invalidResponse,
                afterAttempt: 1
            ),
            .retain
        )
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: AppleLiveError.translationAssetsUnavailable,
                afterAttempt: 1
            ),
            .retain
        )
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: LocalPrototypeError.cursorMismatch("test"),
                afterAttempt: 1
            ),
            .retain
        )
        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: CancellationError(),
                afterAttempt: 1
            ),
            .retain
        )
    }

    func testUnknownAppleFrameworkFailureGetsOneBoundedRetryStep() {
        let error = NSError(domain: "Translation", code: -1)

        XCTAssertEqual(
            LocalFinalTranslationRetryPolicy.disposition(
                for: error,
                afterAttempt: 1
            ),
            .retry(after: .milliseconds(250))
        )
    }

    func testFinalStatusTextRemainsExplicitAcrossTheRetryLifecycle() {
        XCTAssertNil(LocalFinalTranslationState.idle.statusText)
        XCTAssertEqual(LocalFinalTranslationState.queued.statusText, "Final queued")
        XCTAssertEqual(
            LocalFinalTranslationState.translating(attempt: 1).statusText,
            "Translating final — 1/3"
        )
        XCTAssertEqual(
            LocalFinalTranslationState.retrying(nextAttempt: 2).statusText,
            "Retrying final — 2/3"
        )
        XCTAssertEqual(
            LocalFinalTranslationState.failedRetained.statusText,
            "Final failed — audio retained"
        )

        var retained = LocalFinalTranslationState.failedRetained
        retained.noteEnqueued(isOnlyJob: false)
        XCTAssertEqual(retained, .failedRetained)
    }

    func testAppleFailureKeepsACompleteVoxtralSourceReusable() {
        let appleFailure = LocalCaptionCompletionAssessment(
            sourceFailure: nil,
            englishFailure: "Apple final translation failed"
        )
        XCTAssertTrue(appleFailure.sourceTranscriptComplete)
        XCTAssertEqual(appleFailure.failure, "Apple final translation failed")

        let sourceFailure = LocalCaptionCompletionAssessment(
            sourceFailure: "The final Voxtral source suffix was not drained.",
            englishFailure: "Apple final translation failed"
        )
        XCTAssertFalse(sourceFailure.sourceTranscriptComplete)
        XCTAssertEqual(
            sourceFailure.failure,
            "The final Voxtral source suffix was not drained."
        )
    }

    func testFinalAttemptMetricIncludesRetryEvidenceInJSONAndCSV() throws {
        var metric = LocalCaptionMetric(
            kind: .finalAttempt,
            engine: "voxtralApple",
            boundaryKind: "pause",
            rangeStart: 1_000,
            rangeEnd: 2_000,
            speechEnd: 1_800,
            endpointDetectedAt: 1_900,
            vadOnlyEndpointAt: 1_900,
            queueMilliseconds: 12,
            asrMilliseconds: 34,
            translationMilliseconds: 56,
            renderedUptimeNanoseconds: 900,
            sourceText: "こんにちは",
            englishText: "",
            revision: nil,
            previewLatencyMilliseconds: nil,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: nil,
            translationStartedUptimeNanoseconds: 700,
            translationCompletedUptimeNanoseconds: 756
        )
        metric.finalAttempt = 2
        metric.finalAttemptOutcome = "retry"
        metric.finalErrorClassification = LocalFinalTranslationErrorClassification.timedOut.rawValue
        metric.retryBackoffMilliseconds = 1_000
        metric.finalEnqueuedUptimeNanoseconds = 600

        let json = String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)
        XCTAssertTrue(json.contains("\"finalAttempt\":2"))
        XCTAssertTrue(json.contains("\"finalAttemptOutcome\":\"retry\""))
        XCTAssertTrue(json.contains("\"finalErrorClassification\":\"timedOut\""))

        let csv = String(
            decoding: LocalCaptionMetricRecorder.csvData(for: [metric]),
            as: UTF8.self
        )
        XCTAssertTrue(csv.contains("final_attempt_outcome"))
        XCTAssertTrue(csv.contains("final_error_classification"))
        XCTAssertTrue(csv.contains(",2,retry,timedOut,1000.000,600,"))
    }

    func testOnlyAnOverlappingPreviewIsClearedWhenTheFinalPublishes() {
        let previousPreview = TranscriptionSegment(start: 0.5, end: 1, text: "A")
        let nextPreview = TranscriptionSegment(start: 1.1, end: 2, text: "B")

        XCTAssertTrue(LocalPreviewRangePolicy.shouldClear(
            preview: previousPreview,
            finalizedThrough: 16_000
        ))
        XCTAssertFalse(LocalPreviewRangePolicy.shouldClear(
            preview: nextPreview,
            finalizedThrough: 16_000
        ))
    }
}
