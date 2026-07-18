import Foundation
import XCTest
@testable import WhisperASRApp

final class LiveCaptionTests: XCTestCase {
    func testAsyncDeadlineReturnsCompletedWork() async throws {
        let value = try await withAsyncDeadline(
            .seconds(1),
            operationName: "test"
        ) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testAsyncDeadlineDoesNotWaitForNonCooperativeWork() async {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await withAsyncDeadline(
                .milliseconds(20),
                operationName: "non-cooperative test"
            ) {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: 1)
                    }
                }
            }
            XCTFail("Expected the deadline to expire")
        } catch is AsyncDeadlineError {
            let elapsed = Double(
                DispatchTime.now().uptimeNanoseconds - started
            ) / 1_000_000
            XCTAssertLessThan(elapsed, 200)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLegacyLiveTranslationPreferenceMigratesToAPI() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "liveTranslationPref")

        XCTAssertEqual(LiveCaptionMode.stored(in: defaults), .api)
    }

    func testExplicitCaptionModeWinsOverLegacyPreference() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "liveTranslationPref")
        defaults.set(LiveCaptionMode.localEnglish.rawValue, forKey: LiveCaptionMode.storageKey)

        XCTAssertEqual(LiveCaptionMode.stored(in: defaults), .localEnglish)
    }

    func testLocalEnglishKeepsTheExistingStoredRawValue() {
        XCTAssertEqual(LiveCaptionMode.localEnglish.rawValue, "whisperEnglish")
    }

    func testOldFastPreviewPreferenceMigratesToAdaptiveAppleTranslation() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(LiveSubtitlePolicy.fastPreview.rawValue, forKey: LiveSubtitlePolicy.storageKey)

        XCTAssertEqual(AppleTranslationMode.stored(in: defaults), .adaptive)
    }

    func testAdaptiveIsTheDefaultAppleTranslationMode() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppleTranslationMode.stored(in: defaults), .adaptive)
    }

    func testOldStableOnlyPreferenceMigratesToHighFidelityAppleTranslation() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(LiveSubtitlePolicy.stableOnly.rawValue, forKey: LiveSubtitlePolicy.storageKey)

        XCTAssertEqual(AppleTranslationMode.stored(in: defaults), .highFidelityOnly)
    }

    func testExplicitAppleTranslationModeWinsOverMigratedPreference() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(LiveSubtitlePolicy.stableOnly.rawValue, forKey: LiveSubtitlePolicy.storageKey)
        defaults.set(AppleTranslationMode.lowLatencyOnly.rawValue, forKey: AppleTranslationMode.storageKey)

        XCTAssertEqual(AppleTranslationMode.stored(in: defaults), .lowLatencyOnly)
        XCTAssertTrue(AppleTranslationMode.lowLatencyOnly.showsPreview)
        XCTAssertFalse(AppleTranslationMode.lowLatencyOnly.finalUsesHighFidelity)
    }

    func testAppleTranslationModeReadinessRequirements() {
        XCTAssertTrue(AppleTranslationMode.adaptive.showsPreview)
        XCTAssertTrue(AppleTranslationMode.adaptive.requiresLowLatency)
        XCTAssertTrue(AppleTranslationMode.adaptive.requiresHighFidelity)
        XCTAssertFalse(AppleTranslationMode.highFidelityOnly.showsPreview)
        XCTAssertFalse(AppleTranslationMode.highFidelityOnly.requiresLowLatency)
        XCTAssertTrue(AppleTranslationMode.lowLatencyOnly.showsPreview)
        XCTAssertFalse(AppleTranslationMode.lowLatencyOnly.requiresHighFidelity)
    }

    @MainActor
    func testApplePreparationCallbackIsScopedToCapturedSelection() {
        let defaults = UserDefaults.standard
        let keys = [
            LiveCaptionMode.storageKey,
            LocalEnglishEngine.storageKey,
            AppleTranslationMode.storageKey,
            LocalSpeechEngine.sourceLocaleKey,
            APIServer.enabledKey,
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(false, forKey: APIServer.enabledKey)
        defaults.set(LiveCaptionMode.localEnglish.rawValue, forKey: LiveCaptionMode.storageKey)
        defaults.set(LocalEnglishEngine.voxtralApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        defaults.set(AppleTranslationMode.adaptive.rawValue, forKey: AppleTranslationMode.storageKey)
        defaults.set("ja", forKey: LocalSpeechEngine.sourceLocaleKey)
        let state = AppState()
        let generation = state.localPreparationGeneration

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: true,
            error: nil,
            engine: .qwenApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: generation
        )
        XCTAssertFalse(state.appleTranslationLowReady)

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: true,
            error: nil,
            engine: .voxtralApple,
            translationMode: .highFidelityOnly,
            sourceLocale: "ja",
            generation: generation
        )
        XCTAssertFalse(state.appleTranslationLowReady)

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: true,
            error: nil,
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "fr",
            generation: generation
        )
        XCTAssertFalse(state.appleTranslationLowReady)

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: true,
            error: nil,
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: generation
        )
        XCTAssertTrue(state.appleTranslationLowReady)

        state.resetAppleTranslationPreparation()
        let nextGeneration = state.localPreparationGeneration
        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: false,
            error: "stale failure",
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: generation
        )
        XCTAssertNil(state.appleTranslationPreparationError)

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: false,
            error: "temporary failure",
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: nextGeneration
        )
        XCTAssertEqual(state.appleTranslationPreparationError, "temporary failure")
        XCTAssertNil(state.localResourceError)

        state.reportAppleTranslationPreparation(
            highFidelity: true,
            ready: true,
            error: nil,
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: nextGeneration
        )
        XCTAssertEqual(state.appleTranslationPreparationError, "temporary failure")

        state.reportAppleTranslationPreparation(
            highFidelity: false,
            ready: true,
            error: nil,
            engine: .voxtralApple,
            translationMode: .adaptive,
            sourceLocale: "ja",
            generation: nextGeneration
        )
        XCTAssertTrue(state.appleTranslationLowReady)
        XCTAssertNil(state.appleTranslationPreparationError)
        state.shutdown()
    }

    func testTranslationOnlyPrimarySegmentsDropMissingTranslations() {
        let source = [
            TranscriptionSegment(start: 0, end: 1, text: "one"),
            TranscriptionSegment(start: 1, end: 2, text: "two"),
        ]

        XCTAssertEqual(
            AppState.primarySegments(from: source, translations: ["First", ""]),
            [TranscriptionSegment(start: 0, end: 1, text: "First")]
        )
    }

    func testLocalEnglishEnginePersistsAndDefaultsToReference() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .whisperTurboApple)
        defaults.set(LocalEnglishEngine.qwenApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .qwenApple)
        defaults.set(LocalEnglishEngine.voxtralApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .voxtralApple)
        defaults.set(LocalEnglishEngine.voxtralQwenApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .voxtralQwenApple)
        defaults.set(LocalEnglishEngine.voxtralTurboApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .voxtralTurboApple)
        defaults.set(LocalEnglishEngine.voxtralCohereApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .voxtralCohereApple)
        defaults.set(LocalEnglishEngine.whisperLargeV3Direct.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .whisperLargeV3Direct)
        defaults.set(LocalEnglishEngine.cohereApple.rawValue, forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .cohereApple)
        defaults.set("qwenJaEnDirect", forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .whisperTurboApple)
    }

    func testOldNemotronPipelinePreferenceMigratesToQwenOnly() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("nemotronQwenApple", forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .qwenApple)
    }

    func testEliminatedGranitePreferenceFallsBackToReference() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("graniteDirect", forKey: LocalEnglishEngine.storageKey)
        XCTAssertEqual(LocalEnglishEngine.stored(in: defaults), .whisperTurboApple)
    }

    func testEachPrototypeLoadsOnlyItsRequiredModels() {
        XCTAssertEqual(
            LocalEnglishEngine.whisperTurboApple.requiredComponents,
            [.fireRedVAD, .whisperTurbo, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.qwenApple.requiredComponents,
            [.fireRedVAD, .qwen, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.voxtralApple.requiredComponents,
            [.fireRedVAD, .voxtral, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.voxtralQwenApple.requiredComponents,
            [.fireRedVAD, .voxtral, .qwen, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.voxtralTurboApple.requiredComponents,
            [.fireRedVAD, .voxtral, .whisperTurbo, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.voxtralCohereApple.requiredComponents,
            [.fireRedVAD, .voxtral, .cohere, .appleTranslation]
        )
        XCTAssertEqual(
            LocalEnglishEngine.whisperLargeV3Direct.requiredComponents,
            [.fireRedVAD, .whisperLargeV3]
        )
        XCTAssertEqual(
            LocalEnglishEngine.cohereApple.requiredComponents,
            [.fireRedVAD, .cohere, .appleTranslation]
        )
        XCTAssertTrue(LocalEnglishEngine.whisperLargeV3Direct.producesDirectEnglish)
        XCTAssertFalse(LocalEnglishEngine.whisperLargeV3Direct.usesAppleFinalTranslation)
        XCTAssertFalse(LocalEnglishEngine.whisperLargeV3Direct.requiresAppleHighFidelity(for: .adaptive))
        XCTAssertTrue(LocalEnglishEngine.whisperLargeV3Direct.requiresAppleLowLatency(for: .adaptive))
        XCTAssertTrue(LocalEnglishEngine.voxtralApple.usesVoxtralStreaming)
        XCTAssertTrue(LocalEnglishEngine.voxtralQwenApple.usesContinuousVoxtral)
        XCTAssertTrue(LocalEnglishEngine.voxtralTurboApple.usesContinuousVoxtral)
        XCTAssertTrue(LocalEnglishEngine.voxtralTurboApple.usesWhisperFinal)
        XCTAssertEqual(LocalEnglishEngine.voxtralTurboApple.whisperModelID, "large-v3-turbo")
        XCTAssertTrue(LocalEnglishEngine.voxtralCohereApple.usesCohereFinal)
        XCTAssertFalse(LocalEnglishEngine.voxtralApple.usesAppleSpeechPreview)
        XCTAssertTrue(LocalEnglishEngine.voxtralApple.usesVoxtralSourcePreview)
        XCTAssertFalse(LocalEnglishEngine.voxtralCohereApple.usesAppleSpeechPreview)
        XCTAssertTrue(LocalEnglishEngine.voxtralCohereApple.usesVoxtralSourcePreview)
    }

    func testAppleSpeechFeedCursorsAreContiguousAndIndependent() {
        var feed = LocalAppleSpeechFeedState()

        XCTAssertEqual(feed.takeNewSamples(through: 1_600), 0..<1_600)
        XCTAssertNil(feed.takeNewSamples(through: 1_600))
        XCTAssertEqual(feed.takeNewSamples(through: 5_120), 1_600..<5_120)
        XCTAssertEqual(feed.sentThrough, 5_120)

        XCTAssertFalse(feed.requestFinalization(through: 23_999, every: 24_000))
        XCTAssertEqual(feed.sentThrough, 5_120)
        XCTAssertTrue(feed.requestFinalization(through: 24_000, every: 24_000))
        XCTAssertEqual(feed.finalizeRequestedThrough, 24_000)
        XCTAssertEqual(feed.sentThrough, 5_120)
        XCTAssertFalse(feed.requestFinalization(through: 30_000, every: 24_000))
    }

    @MainActor
    func testCoherePrototypeQuantizationCanBeSelectedWithoutLoadingModels() async {
        let manager = LocalEnglishModelManager()
        XCTAssertEqual(manager.cohereQuantization, .q8)
        await manager.selectCohereQuantization(.q6)
        XCTAssertEqual(manager.cohereQuantization, .q6)
        await manager.selectCohereQuantization(.q8)
        XCTAssertEqual(manager.cohereQuantization, .q8)
    }

    func testPreviewCursorCannotAdvanceStableOrPCMCursor() {
        var planner = LocalEndpointPlanner()
        planner.notePreview(readThrough: 32_000)
        XCTAssertEqual(planner.previewReadEnd, 32_000)
        XCTAssertEqual(planner.stableAttemptEnd, 0)
        XCTAssertEqual(planner.finalizedThrough, 0)
    }

    func testLocalPreviewSlotKeepsOnlyTheLatestUpdate() {
        var planner = LocalPreviewPlanner()
        planner.submit(previewUpdate(start: 0, end: 1, text: "first"), receivedUptimeNanoseconds: 1)
        planner.submit(previewUpdate(start: 0, end: 2, text: "second"), receivedUptimeNanoseconds: 2)

        let work = planner.takeLatest()
        XCTAssertEqual(work?.update.segment.text, "second")
        XCTAssertEqual(work?.receivedUptimeNanoseconds, 2)
        XCTAssertNil(planner.takeLatest())
    }

    func testPreviewWaitsForTwoGraphemesAndMarksFirstEligiblePerGeneration() {
        var planner = LocalPreviewPlanner()

        XCTAssertFalse(LocalPreviewPlanner.isEligibleSource("あ"))
        XCTAssertTrue(LocalPreviewPlanner.isEligibleSource("あの"))
        XCTAssertTrue(LocalPreviewPlanner.isEligibleSource("？"))

        planner.submit(
            previewUpdate(start: 0, end: 1, text: "あ"),
            receivedUptimeNanoseconds: 10
        )
        XCTAssertNil(planner.pending)

        planner.submit(
            previewUpdate(start: 0, end: 2, text: "あの"),
            receivedUptimeNanoseconds: 20
        )
        let first = planner.takeLatest()
        XCTAssertEqual(first?.update.segment.text, "あの")
        XCTAssertEqual(first?.firstLexicalUptimeNanoseconds, 10)
        XCTAssertEqual(first?.receivedUptimeNanoseconds, 20)
        XCTAssertTrue(first?.isFirstEligibleInGeneration == true)
        XCTAssertTrue(first?.bypassesThrottle == true)

        planner.submit(previewUpdate(start: 0, end: 3, text: "あのね"))
        let revision = planner.takeLatest()
        XCTAssertFalse(revision?.isFirstEligibleInGeneration ?? true)
        XCTAssertFalse(revision?.bypassesThrottle ?? true)

        planner.submit(previewUpdate(start: 0, end: 4, text: "あのね。"))
        XCTAssertTrue(planner.takeLatest()?.bypassesThrottle == true)

        planner.advanceBoundary(through: 48_000)
        planner.submit(previewUpdate(start: 3, end: 4, text: "？"))
        XCTAssertTrue(planner.takeLatest()?.isFirstEligibleInGeneration == true)
    }

    func testIneligiblePreviewRevisionDoesNotErasePendingEligiblePrefix() {
        var planner = LocalPreviewPlanner()
        planner.submit(previewUpdate(start: 0, end: 2, text: "あの"))
        planner.submit(previewUpdate(start: 0, end: 2.1, text: "あ"))

        XCTAssertEqual(planner.takeLatest()?.update.segment.text, "あの")
    }

    func testPreviewAccumulatesOnlyTheCurrentBoundedPhrase() {
        var planner = LocalPreviewPlanner()
        planner.submit(previewUpdate(start: 0, end: 1, text: "first"))
        _ = planner.takeLatest()
        planner.submit(previewUpdate(start: 1, end: 2, text: "second"))
        XCTAssertEqual(planner.takeLatest()?.update.segment.text, "first second")

        planner.suspend(through: 32_000)
        planner.resume(through: 32_000)
        planner.submit(previewUpdate(start: 2, end: 3, text: "third"))
        XCTAssertEqual(planner.takeLatest()?.update.segment.text, "third")
    }

    func testFinalBoundaryInvalidatesLatePreviewWithoutAdvancingPCM() {
        var preview = LocalPreviewPlanner()
        preview.submit(previewUpdate(start: 0, end: 2, text: "old"), receivedUptimeNanoseconds: 1)
        let oldWork = preview.takeLatest()!
        preview.suspend(through: 16_000)

        XCTAssertFalse(preview.accepts(oldWork))
        XCTAssertEqual(preview.suppressedThrough, 16_000)

        preview.resume(through: 16_000)
        preview.submit(previewUpdate(start: 0.5, end: 2, text: "overlap"), receivedUptimeNanoseconds: 2)
        XCTAssertNil(preview.takeLatest())
        preview.submit(previewUpdate(start: 1, end: 2, text: "new"), receivedUptimeNanoseconds: 3)
        let newWork = preview.takeLatest()
        XCTAssertEqual(newWork?.update.segment.text, "new")
        XCTAssertTrue(newWork.map { preview.accepts($0) } == true)

        let stable = LocalEndpointPlanner()
        XCTAssertEqual(stable.finalizedThrough, 0)
    }

    func testVoxtralBoundaryAcceptsTheNextPhraseWhileRejectingLateOldWork() {
        var preview = LocalPreviewPlanner()
        preview.submit(previewUpdate(start: 0, end: 2, text: "old"))
        let old = preview.takeLatest()!

        preview.advanceBoundary(through: 32_000)
        XCTAssertFalse(preview.isSuspended)
        XCTAssertFalse(preview.accepts(old))

        preview.submit(previewUpdate(start: 2, end: 3, text: "next"))
        let next = preview.takeLatest()
        XCTAssertEqual(next?.update.segment.text, "next")
        XCTAssertTrue(next.map { preview.accepts($0) } == true)
    }

    func testOldFinalClearsOnlyAnOverlappingPreview() {
        XCTAssertTrue(LocalPreviewRangePolicy.shouldClear(
            preview: TranscriptionSegment(start: 1, end: 2, text: "old"),
            finalizedThrough: 32_000
        ))
        XCTAssertFalse(LocalPreviewRangePolicy.shouldClear(
            preview: TranscriptionSegment(start: 2, end: 3, text: "next"),
            finalizedThrough: 32_000
        ))
    }

    func testShortPhraseIsCoalescedToAvoidInferenceBacklog() {
        var planner = LocalEndpointPlanner()
        let speechEnd = 8_000
        XCTAssertNil(planner.observe(
            totalSample: speechEnd + LocalEndpointPlanner.silence,
            speech: [SpeechSampleRange(start: 0, end: speechEnd)]
        ))
        XCTAssertNil(planner.observe(
            totalSample: speechEnd + LocalEndpointPlanner.postRoll,
            speech: [SpeechSampleRange(start: 0, end: speechEnd)]
        ))
        let decision = planner.observe(
            totalSample: LocalEndpointPlanner.minimumBatch,
            speech: [SpeechSampleRange(start: 0, end: speechEnd)]
        )
        XCTAssertEqual(decision?.kind, .pause)
        XCTAssertEqual(decision?.endpointDetectedAt, speechEnd + LocalEndpointPlanner.silence)
        XCTAssertEqual(decision?.audioEnd, speechEnd + LocalEndpointPlanner.postRoll)
        XCTAssertTrue(decision?.cleanBreak == true)
    }

    func testForcedCutRetainsExactly800Milliseconds() {
        var planner = LocalEndpointPlanner()
        let end = LocalEndpointPlanner.maxPhrase
        let decision = planner.observe(
            totalSample: end,
            speech: [SpeechSampleRange(start: 0, end: end)]
        )
        XCTAssertEqual(decision?.kind, .forced)
        XCTAssertEqual(decision?.stableThrough, end - LocalEndpointPlanner.forcedOverlap)
    }

    func testStagedAttemptDoesNotReleasePCMOrBlockLaterSegmentation() {
        var planner = LocalEndpointPlanner()
        let end = LocalEndpointPlanner.maxPhrase
        let speech = [SpeechSampleRange(start: 0, end: end)]
        let decision = planner.observe(totalSample: end, speech: speech)!
        planner.stage(decision)
        XCTAssertEqual(planner.finalizedThrough, 0)
        XCTAssertNil(planner.observe(totalSample: end, speech: speech))
        XCTAssertNotNil(planner.observe(
            totalSample: end + 40_000,
            speech: [SpeechSampleRange(start: decision.stableThrough, end: end + 40_000)],
            finishing: true
        ))
    }

    func testAcceptedForcedRangeAndFinishCoverTimelineWithoutHole() {
        var planner = LocalEndpointPlanner()
        let forcedEnd = LocalEndpointPlanner.maxPhrase
        let first = planner.observe(
            totalSample: forcedEnd,
            speech: [SpeechSampleRange(start: 0, end: forcedEnd)]
        )!
        planner.stage(first)
        planner.accept(first)
        let finalEnd = forcedEnd + 40_000
        let tail = planner.observe(
            totalSample: finalEnd,
            speech: [SpeechSampleRange(start: first.stableThrough, end: finalEnd)],
            finishing: true
        )!
        XCTAssertEqual(tail.audioStart, first.stableThrough)
        planner.accept(tail)
        XCTAssertEqual(planner.finalizedThrough, finalEnd)
    }

    func testEndpointFIFOStagesAheadWithoutValidatingPCM() async {
        let fifo = LocalEndpointFIFO()
        let forcedEnd = LocalEndpointPlanner.maxPhrase
        let first = await fifo.observe(
            totalSample: forcedEnd,
            speech: [SpeechSampleRange(start: 0, end: forcedEnd)]
        )!
        let finalEnd = forcedEnd + 40_000
        let tail = await fifo.observe(
            totalSample: finalEnd,
            speech: [SpeechSampleRange(start: first.stableThrough, end: finalEnd)],
            finishing: true
        )!

        var cursors = await fifo.cursors()
        XCTAssertEqual(cursors.segmented, finalEnd)
        XCTAssertEqual(cursors.finalized, 0)
        let queuedFirst = await fifo.next()
        let firstPendingCount = await fifo.pendingCount()
        XCTAssertEqual(queuedFirst?.decision, first)
        XCTAssertEqual(firstPendingCount, 2)

        await fifo.accept(queuedFirst!)
        cursors = await fifo.cursors()
        XCTAssertEqual(cursors.finalized, first.stableThrough)
        let queuedTail = await fifo.next()
        let tailPendingCount = await fifo.pendingCount()
        XCTAssertEqual(queuedTail?.decision, tail)
        XCTAssertEqual(tailPendingCount, 1)
        await fifo.accept(queuedTail!)
        await fifo.finishProducing()
        let drained = await fifo.isDrained()
        XCTAssertTrue(drained)
    }

    func testEndpointFIFOCarriesTheVoxtralFinalWithoutValidatingPCM() async {
        let fifo = LocalEndpointFIFO()
        let decision = await fifo.propose(
            totalSample: LocalEndpointPlanner.maxPhrase,
            speech: [SpeechSampleRange(start: 0, end: LocalEndpointPlanner.maxPhrase)]
        )!
        await fifo.stage(decision, voxtralText: "完了。")

        let entry = await fifo.next()
        XCTAssertEqual(entry?.voxtralText, "完了。")
        let cursors = await fifo.cursors()
        XCTAssertEqual(cursors.finalized, 0)
    }

    func testCohereFailureFallsBackToVoxtralOnlyWhenVoxtralIsValid() throws {
        XCTAssertEqual(
            try LocalFinalSourceSelector.hybrid(cohere: "", voxtral: " 次で最後です。 "),
            LocalFinalSourceSelection(text: "次で最後です。", degraded: true)
        )
        XCTAssertEqual(
            try LocalFinalSourceSelector.hybrid(cohere: " Cohere final ", voxtral: "Voxtral"),
            LocalFinalSourceSelection(text: "Cohere final", degraded: false)
        )
        XCTAssertThrowsError(try LocalFinalSourceSelector.hybrid(cohere: nil, voxtral: ""))
    }

    func testCanonicalCorpusUsesTwelveEqualMultiSentencePassages() {
        let passages = CanonicalBenchmarkCorpus.passages(totalSamples: 16_000 * 282)
        XCTAssertEqual(passages.count, 12)
        XCTAssertEqual(passages.first?.startSample, 0)
        XCTAssertEqual(passages.last?.endSample, 16_000 * 282)
        XCTAssertTrue(passages.allSatisfy {
            let seconds = Double($0.endSample - $0.startSample) / 16_000
            return (12...25).contains(seconds)
        })
        for pair in zip(passages, passages.dropFirst()) {
            XCTAssertEqual(pair.0.endSample, pair.1.startSample)
        }

        let shortCorpus = CanonicalBenchmarkCorpus.passages(totalSamples: 16_000 * 40)
        XCTAssertEqual(shortCorpus.count, 2)
        XCTAssertTrue(shortCorpus.allSatisfy { $0.endSample - $0.startSample == 16_000 * 20 })
    }

    func testPCMEncoderProducesCanonical16KMonoWAV() {
        let wav = PCM16WAV.data(samples: [0, 0.5, -0.5])
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(wav.count, 44 + 3 * 2)
    }

    func testClearlyNonEnglishTranslationIsRejected() {
        XCTAssertTrue(AppState.isClearlyNonEnglishTranslation("これは日本語の字幕です。翻訳されていません。"))
        XCTAssertTrue(AppState.isClearlyNonEnglishTranslation("え?"))
        XCTAssertTrue(AppState.isClearlyNonEnglishTranslation("한국어"))
        XCTAssertFalse(AppState.isClearlyNonEnglishTranslation("This subtitle is already translated to English."))
        XCTAssertFalse(AppState.isClearlyNonEnglishTranslation("Tokyo"))
    }

    func testEnglishSubtitleScriptValidation() {
        XCTAssertTrue(EnglishSubtitleValidator.containsSourceScript("これは字幕です。"))
        XCTAssertTrue(EnglishSubtitleValidator.containsSourceScript("한국어"))
        XCTAssertFalse(EnglishSubtitleValidator.containsSourceScript("A faithful English subtitle."))
    }

    @MainActor
    func testLocalModelManagerUnloadIsIdempotent() async {
        let manager = LocalEnglishModelManager()
        await manager.unload()
        await manager.unload()
        XCTAssertNil(manager.loadedEngine)
        XCTAssertEqual(manager.phase(for: .whisperTurboApple), .absent)
        XCTAssertEqual(manager.phase(for: .qwenApple), .absent)
        XCTAssertEqual(manager.phase(for: .voxtralApple), .absent)
        XCTAssertEqual(manager.phase(for: .voxtralCohereApple), .absent)
        XCTAssertEqual(manager.phase(for: .whisperLargeV3Direct), .absent)
        XCTAssertEqual(manager.phase(for: .cohereApple), .absent)
    }

    func testCatalogRejectsKnownNonTranslationModels() {
        XCTAssertFalse(ModelCatalog.model(id: "large-v3-turbo")!.supportsEnglishTranslation)
        XCTAssertFalse(ModelCatalog.model(id: "breeze-asr-25")!.supportsEnglishTranslation)
        XCTAssertTrue(ModelCatalog.model(id: "large-v3")!.supportsEnglishTranslation)
        XCTAssertEqual(
            ModelCatalog.model(id: "large-v3")!.sha256,
            "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        )
        XCTAssertTrue(ModelCatalog.model(id: "medium")!.supportsEnglishTranslation)
    }

    func testModelDownloaderComputesStreamingSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try ModelDownloader.sha256(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testOlderBackupWithoutSubtitlePolicyStillDecodes() throws {
        let json = Data(#"""
        {
          "version": 1,
          "createdAt": "2026-07-13T00:00:00Z",
          "configuration": {}
        }
        """#.utf8)

        let backup = try BackupService.decode(json)
        XCTAssertNil(backup.configuration.liveSubtitlePolicy)
        XCTAssertNil(backup.configuration.localEnglishEngine)
        XCTAssertNil(backup.configuration.localSpeechEngine)
        XCTAssertNil(backup.configuration.localSourceLocale)
        XCTAssertNil(backup.configuration.appleTranslationMode)
    }

    func testRetrySourceCompletenessRoundTripsWithoutTouchingUserStorage() throws {
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a")
        )
        item.status = .failed("Apple translation failed")
        item.translateToEnglish = true
        item.localSourceTranscriptComplete = true
        item.segments = [TranscriptionSegment(start: 0, end: 1, text: "はい。")]
        item.fullText = "はい。"

        let encoded = try TranscriptionStore.encodedData(for: item)
        let restored = try TranscriptionStore.decodedItem(from: encoded)
        XCTAssertTrue(restored.translateToEnglish)
        XCTAssertTrue(restored.localSourceTranscriptComplete)
        XCTAssertEqual(restored.segments, item.segments)

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy.removeValue(forKey: "localSourceTranscriptComplete")
        let legacyRestored = try TranscriptionStore.decodedItem(
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertFalse(legacyRestored.localSourceTranscriptComplete)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "LiveCaptionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func previewUpdate(
        start: Double,
        end: Double,
        text: String
    ) -> LiveSourceUpdate {
        LiveSourceUpdate(
            segment: TranscriptionSegment(start: start, end: end, text: text),
            isFinal: false,
            finalizedThroughSample: 0
        )
    }
}
