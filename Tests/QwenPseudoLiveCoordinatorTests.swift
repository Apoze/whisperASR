import XCTest
@testable import WhisperASRApp

final class QwenPseudoLiveCoordinatorTests: XCTestCase {
    func testPreviewStatusTracksCatchUpDegradationRecoveryAndCancellation() {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds1)
        XCTAssertEqual(coordinator.previewStatus, .available)

        let first = coordinator.observe(speechStart: 0, availableThrough: 16_000)!
        XCTAssertNil(coordinator.observe(speechStart: 0, availableThrough: 32_000))
        XCTAssertEqual(coordinator.previewStatus, .catchingUp)

        let second = coordinator.completePreview(first, source: "old").next!
        XCTAssertNil(coordinator.failPreview(second))
        XCTAssertEqual(coordinator.previewStatus, .degraded)

        _ = coordinator.stageFinal(range: 0..<40_000, stableThrough: 40_000)
        XCTAssertEqual(coordinator.previewStatus, .degraded)
        _ = coordinator.completeFinal(range: 0..<40_000)

        let recovered = coordinator.observe(speechStart: 40_000, availableThrough: 56_000)!
        XCTAssertNotNil(coordinator.completePreview(recovered, source: "current").accepted)
        XCTAssertEqual(coordinator.previewStatus, .available)

        coordinator.cancel()
        XCTAssertEqual(coordinator.previewStatus, .unavailable)
    }

    func testPreviewStartIncludesPreRollWithoutCrossingTheLastBoundary() {
        XCTAssertEqual(
            QwenPseudoLiveCoordinator.previewStart(speechStart: 20_000, notBefore: 0),
            16_000
        )
        XCTAssertEqual(
            QwenPseudoLiveCoordinator.previewStart(speechStart: 20_000, notBefore: 18_000),
            18_000
        )
    }

    func testPseudoLiveRevisesTheWholePhraseThenCommitsOnlyTheFreshFinal() {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds2)

        XCTAssertNil(coordinator.observe(speechStart: 4_000, availableThrough: 20_000))
        let first = coordinator.observe(speechStart: 4_000, availableThrough: 36_000)!
        XCTAssertEqual(first.range, 4_000..<36_000)

        XCTAssertNil(coordinator.observe(speechStart: 4_000, availableThrough: 68_000))
        XCTAssertEqual(coordinator.coalescedTickCount, 1)

        let firstCompletion = coordinator.completePreview(
            first,
            source: "最初"
        )
        XCTAssertNil(firstCompletion.accepted)
        let revision = firstCompletion.next!
        XCTAssertEqual(revision.range, 4_000..<68_000)

        let final = coordinator.stageFinal(
            range: 4_000..<72_000,
            stableThrough: 72_000
        )
        let lateCompletion = coordinator.completePreview(
            revision,
            source: "古い"
        )
        XCTAssertNil(lateCompletion.accepted)
        XCTAssertNil(lateCompletion.next)
        XCTAssertEqual(coordinator.staleResultCount, 2)

        XCTAssertNil(coordinator.observe(speechStart: 72_000, availableThrough: 104_000))
        XCTAssertEqual(coordinator.completeFinal(final)?.range, 72_000..<104_000)
        XCTAssertEqual(final.range, 4_000..<72_000)
    }

    func testBoundaryRejectsTheEndedPhraseButKeepsForcedOverlapForTheNextOne() {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds1)
        let oldPreview = coordinator.observe(
            speechStart: 0,
            availableThrough: 16_000
        )!
        let final = coordinator.stageFinal(
            range: 0..<LocalEndpointPlanner.maxPhrase,
            stableThrough: LocalEndpointPlanner.maxPhrase
                - LocalEndpointPlanner.forcedOverlap
        )

        XCTAssertNil(coordinator.completePreview(oldPreview, source: "late").accepted)
        XCTAssertNil(coordinator.observe(speechStart: 0, availableThrough: 32_000))
        XCTAssertNil(coordinator.observe(
            speechStart: final.stableThrough,
            availableThrough: final.stableThrough + 16_000
        ))
        XCTAssertEqual(
            coordinator.completeFinal(final)?.range,
            final.stableThrough..<(final.stableThrough + 16_000)
        )
    }

    func testFakeServicesPublishRevisionsButPersistOnlyTheBoundaryFinal() async {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds2)
        let services = PseudoLiveServiceRecorder()
        var sourcePreview = ""
        var englishPreview = ""
        var stable: [(String, String)] = []
        var stableThrough = 0

        let first = coordinator.observe(speechStart: 0, availableThrough: 32_000)!
        let firstSource = await services.qwen(range: first.range, context: nil)
        let firstResult = coordinator.completePreview(first, source: firstSource).accepted!
        sourcePreview = firstResult.source
        englishPreview = await services.translateLowLatency(firstResult.source)

        let second = coordinator.observe(speechStart: 0, availableThrough: 64_000)!
        XCTAssertNil(coordinator.observe(speechStart: 0, availableThrough: 96_000))
        let secondSource = await services.qwen(range: second.range, context: nil)
        let third = coordinator.completePreview(second, source: secondSource).next!
        let thirdSource = await services.qwen(range: third.range, context: nil)
        let thirdResult = coordinator.completePreview(third, source: thirdSource).accepted!
        sourcePreview = thirdResult.source
        englishPreview = await services.translateLowLatency(thirdResult.source)

        let late = coordinator.observe(speechStart: 0, availableThrough: 128_000)!
        let lateSource = await services.qwen(range: late.range, context: nil)
        let final = coordinator.stageFinal(
            range: 0..<136_000,
            stableThrough: 136_000
        )
        XCTAssertNil(coordinator.completePreview(late, source: lateSource).accepted)
        let finalSource = await services.qwen(range: final.range, context: nil)
        let finalEnglish = await services.translateHighFidelity(finalSource)
        stable.append((finalSource, finalEnglish))
        stableThrough = final.range.upperBound
        _ = coordinator.completeFinal(final)

        XCTAssertEqual(sourcePreview, "source-96000")
        XCTAssertEqual(englishPreview, "fast-source-96000")
        XCTAssertEqual(stable.map(\.0), ["source-136000"])
        XCTAssertEqual(stable.map(\.1), ["final-source-136000"])
        XCTAssertEqual(stableThrough, 136_000)
        XCTAssertEqual(coordinator.coalescedTickCount, 1)
        XCTAssertEqual(coordinator.staleResultCount, 2)
        let calls = await services.snapshot()
        XCTAssertEqual(calls.qwenRanges, [
            0..<32_000, 0..<64_000, 0..<96_000, 0..<128_000, 0..<136_000,
        ])
        XCTAssertEqual(calls.contexts, [nil, nil, nil, nil, nil])
        XCTAssertEqual(calls.lowLatencyInputs, ["source-32000", "source-96000"])
        XCTAssertEqual(calls.highFidelityInputs, ["source-136000"])
    }

    func testAcceptedPreviewReplacesRatherThanAppends() {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds1)
        var published: [QwenPseudoLivePreviewResult] = []

        let first = coordinator.observe(speechStart: 0, availableThrough: 16_000)!
        published.append(coordinator.completePreview(
            first,
            source: "今日は"
        ).accepted!)
        let second = coordinator.observe(speechStart: 0, availableThrough: 32_000)!
        published.append(coordinator.completePreview(
            second,
            source: "今日は晴れ"
        ).accepted!)

        XCTAssertEqual(published.map(\.source), ["今日は", "今日は晴れ"])
        XCTAssertEqual(published.last?.work.range, 0..<32_000)
    }

    func testNewerSourceRejectsAnOlderTranslationResult() {
        var planner = LocalPreviewPlanner()
        planner.submit(sourceUpdate(text: "今日は", end: 16_000), receivedUptimeNanoseconds: 1)
        let old = planner.takeLatest()!
        planner.submit(
            sourceUpdate(text: "今日は晴れ", end: 32_000),
            receivedUptimeNanoseconds: 2
        )

        XCTAssertFalse(planner.accepts(old))
        XCTAssertEqual(planner.takeLatest()?.update.segment.text, "今日は晴れ")
    }

    func testStableOnlyAndCancellationScheduleNoPreviewWork() {
        var stableOnly = QwenPseudoLiveCoordinator(cadence: .seconds1, previewsEnabled: false)
        XCTAssertNil(stableOnly.observe(speechStart: 0, availableThrough: 48_000))

        var cancelled = QwenPseudoLiveCoordinator(cadence: .seconds1)
        let work = cancelled.observe(speechStart: 0, availableThrough: 16_000)!
        cancelled.cancel()
        XCTAssertNil(cancelled.completePreview(work, source: "遅い").accepted)
    }

    func testFailuresKeepTheStoppedPhraseAndPCMCursorAuthoritativeUntilRetry() async {
        var coordinator = QwenPseudoLiveCoordinator(cadence: .seconds1)
        let failedPreview = coordinator.observe(
            speechStart: 0,
            availableThrough: 16_000
        )!
        XCTAssertNil(coordinator.failPreview(failedPreview))

        var shortPhraseCoordinator = QwenPseudoLiveCoordinator(cadence: .seconds1)
        XCTAssertNil(shortPhraseCoordinator.observe(
            speechStart: 0,
            availableThrough: 8_000
        ))

        let fifo = LocalEndpointFIFO()
        let decision = await fifo.observe(
            totalSample: 20_000,
            speech: [SpeechSampleRange(start: 0, end: 8_000)],
            finishing: true
        )!
        let final = shortPhraseCoordinator.stageFinal(
            range: decision.audioStart..<decision.audioEnd,
            stableThrough: decision.stableThrough
        )
        XCTAssertNil(shortPhraseCoordinator.observe(
            speechStart: decision.stableThrough,
            availableThrough: decision.stableThrough + 16_000
        ))

        let retained = await fifo.next()
        var cursors = await fifo.cursors()
        XCTAssertEqual(retained?.decision, decision)
        XCTAssertEqual(cursors.finalized, 0)

        let retried = await fifo.next()
        XCTAssertEqual(retried, retained)

        XCTAssertEqual(
            shortPhraseCoordinator.completeFinal(final)?.range,
            decision.stableThrough..<(decision.stableThrough + 16_000)
        )
        await fifo.accept(retried!)
        cursors = await fifo.cursors()
        XCTAssertEqual(cursors.finalized, decision.stableThrough)
    }

    func testCadencePersistsOnlySupportedValues() {
        let suite = "QwenPseudoLiveCadence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(QwenPseudoLiveCadence.stored(in: defaults), .seconds2)
        for cadence in QwenPseudoLiveCadence.allCases {
            defaults.set(cadence.rawValue, forKey: QwenPseudoLiveCadence.storageKey)
            XCTAssertEqual(QwenPseudoLiveCadence.stored(in: defaults), cadence)
        }
        defaults.set(4, forKey: QwenPseudoLiveCadence.storageKey)
        XCTAssertEqual(QwenPseudoLiveCadence.stored(in: defaults), .seconds2)
    }

    func testAllCadencesUseFakeClockAndCoalesceToLatestFullPhrase() {
        let phraseStart = 4_000
        var now: UInt64 = 100

        for cadence in QwenPseudoLiveCadence.allCases {
            var coordinator = QwenPseudoLiveCoordinator(cadence: cadence)
            let interval = cadence.sampleCount

            XCTAssertNil(coordinator.observe(
                speechStart: phraseStart,
                availableThrough: phraseStart + interval - 1,
                requestedUptimeNanoseconds: now
            ))
            now += 1
            let first = coordinator.observe(
                speechStart: phraseStart,
                availableThrough: phraseStart + interval,
                requestedUptimeNanoseconds: now
            )!
            XCTAssertEqual(first.range, phraseStart..<(phraseStart + interval))
            XCTAssertEqual(first.requestedUptimeNanoseconds, now)

            now += 1
            XCTAssertNil(coordinator.observe(
                speechStart: phraseStart,
                availableThrough: phraseStart + interval * 2,
                requestedUptimeNanoseconds: now
            ))
            now += 1
            XCTAssertNil(coordinator.observe(
                speechStart: phraseStart,
                availableThrough: phraseStart + interval * 3,
                requestedUptimeNanoseconds: now
            ))

            let completion = coordinator.completePreview(first, source: "古い")
            XCTAssertNil(completion.accepted)
            XCTAssertEqual(
                completion.next?.range,
                phraseStart..<(phraseStart + interval * 3)
            )
            XCTAssertEqual(completion.next?.requestedUptimeNanoseconds, now)
            XCTAssertEqual(coordinator.coalescedTickCount, 2)
        }
    }

    func testPseudoLiveEngineNeverRequestsAppleSpeech() async throws {
        let appleSpeech = AppleSpeechCallRecorder()
        try await LocalEnglishEngine.qwenPseudoLiveApple.runAppleSpeechPreviewOperation {
            await appleSpeech.recordCall()
        }
        try await LocalEnglishEngine.qwenPseudoLiveApple.runAppleSpeechPreviewOperation {
            await appleSpeech.recordCall()
        }

        let appleSpeechCallCount = await appleSpeech.callCount
        XCTAssertEqual(appleSpeechCallCount, 0)
        XCTAssertEqual(
            LocalEnglishEngine.qwenPseudoLiveApple.requiredComponents,
            [.fireRedVAD, .qwen, .appleTranslation]
        )
        XCTAssertFalse(LocalEnglishEngine.qwenPseudoLiveApple.usesAppleSpeechPreview)
        XCTAssertFalse(LocalEnglishEngine.qwenPseudoLiveApple.usesVoxtralSourcePreview)
        XCTAssertTrue(LocalEnglishEngine.qwenApple.usesAppleSpeechPreview)
    }

    private func sourceUpdate(text: String, end: Int) -> LiveSourceUpdate {
        LiveSourceUpdate(
            segment: TranscriptionSegment(
                start: 0,
                end: Double(end) / 16_000,
                text: text
            ),
            isFinal: false,
            finalizedThroughSample: 0
        )
    }
}

private actor AppleSpeechCallRecorder {
    private(set) var callCount = 0

    func recordCall() { callCount += 1 }
}

private actor PseudoLiveServiceRecorder {
    struct Snapshot: Sendable {
        let qwenRanges: [Range<Int>]
        let contexts: [String?]
        let lowLatencyInputs: [String]
        let highFidelityInputs: [String]
    }

    private var qwenRanges: [Range<Int>] = []
    private var contexts: [String?] = []
    private var lowLatencyInputs: [String] = []
    private var highFidelityInputs: [String] = []

    func qwen(range: Range<Int>, context: String?) -> String {
        qwenRanges.append(range)
        contexts.append(context)
        return "source-\(range.upperBound)"
    }

    func translateLowLatency(_ source: String) -> String {
        lowLatencyInputs.append(source)
        return "fast-\(source)"
    }

    func translateHighFidelity(_ source: String) -> String {
        highFidelityInputs.append(source)
        return "final-\(source)"
    }

    func snapshot() -> Snapshot {
        Snapshot(
            qwenRanges: qwenRanges,
            contexts: contexts,
            lowLatencyInputs: lowLatencyInputs,
            highFidelityInputs: highFidelityInputs
        )
    }
}
