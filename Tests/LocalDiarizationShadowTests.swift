import XCTest
@testable import WhisperASRApp

final class LocalDiarizationShadowTests: XCTestCase {
    func testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries() {
        XCTAssertFalse(
            LocalDiarizationShadowConfiguration.productionBoundaryAssistPromoted
        )
        XCTAssertFalse(LocalDiarizationShadowConfiguration.canInfluenceBoundaries)
    }

    func testAssistRequestReportsShadowOnlyWhilePromotionGateIsClosed() {
        guard LocalDiarizationShadowConfiguration.isAssistEnabled else {
            XCTAssertFalse(
                LocalDiarizationShadowConfiguration.isAssistRequestedButUnpromoted
            )
            return
        }
        XCTAssertTrue(
            LocalDiarizationShadowConfiguration.isAssistRequestedButUnpromoted
        )
    }

    func testJournalRecordsTurnSignalsWithoutPersistingTrackIdentity() async {
        let journal = LocalDiarizationShadowJournal()
        let transition = LocalSpeakerTransition(
            fromSpeaker: 4,
            toSpeaker: 9,
            changeSample: 16_000,
            confirmedAtSample: 19_200,
            confidence: 0.8,
            wasArmedByOverlap: true
        )
        await journal.append([
            LocalDiarizationUpdate(
                dominantSpeaker: 4,
                overlappingSpeakers: [],
                transition: nil,
                confidence: 0.9
            ),
            LocalDiarizationUpdate(
                dominantSpeaker: 9,
                overlappingSpeakers: [4, 9],
                transition: transition,
                confidence: 0.8
            ),
        ], observedThrough: 20_000)

        let metrics = await journal.snapshot()
        XCTAssertEqual(
            Set(metrics.map(\.kind)),
            Set([.rawSpeakerChange, .overlapArmed, .confirmedSpeakerChange])
        )
        XCTAssertTrue(metrics.allSatisfy { $0.dominantSpeaker == nil })
        XCTAssertTrue(metrics.allSatisfy { $0.overlappingSpeakers.isEmpty })
    }

    func testPersistentResamplerCarriesStateAndFlushesItsTail() throws {
        let resampler = PersistentDiarizationResampler()
        var output: [Float] = []
        for blockIndex in 0..<10 {
            let start = blockIndex * 1_600
            let input = (start..<(start + 1_600)).map { sample in
                sin(2 * .pi * 440 * Float(sample) / 16_000)
            }
            output.append(contentsOf: try resampler.append(input))
        }
        output.append(contentsOf: try resampler.finish())

        XCTAssertEqual(output.count, 8_000)
        XCTAssertGreaterThan(output.map(abs).max() ?? 0, 0.5)
    }

    func testPinnedRuntimeAndModelRevision() {
        XCTAssertEqual(LocalDiarizationModelManifest.fluidAudioVersion, "0.15.5")
        XCTAssertEqual(
            LocalDiarizationModelManifest.fluidAudioCommit,
            "19600a485baa4998812e4654b70d2bab8f2c9949"
        )
        XCTAssertEqual(
            LocalDiarizationModelManifest.revision,
            "125ed60504885cf1dbadacff8a0cececee04ef17"
        )
        XCTAssertEqual(LocalDiarizationModelManifest.files.count, 5)
        XCTAssertTrue(LocalDiarizationModelManifest.files.allSatisfy { $0.sha256.count == 64 })
    }

    func testReducerReportsDominantSpeakerChangeAtAbsoluteSample() {
        var reducer = LocalDiarizationReducer(sessionBaseSample: 8_000)

        let updates = reducer.consume(
            predictions: [0.9, 0.1, 0.2, 0.8, 0.1, 0.7],
            frameCount: 3,
            startFrame: 10,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertEqual(updates[0].dominantSpeaker, 0)
        XCTAssertNil(updates[0].changeSample)
        XCTAssertEqual(updates[1].dominantSpeaker, 1)
        XCTAssertNil(updates[1].transition)
        XCTAssertEqual(updates[2].transition, LocalSpeakerTransition(
            fromSpeaker: 0,
            toSpeaker: 1,
            changeSample: 25_600,
            confirmedAtSample: 28_800,
            confidence: 0.7,
            wasArmedByOverlap: false
        ))
        XCTAssertEqual(updates[2].changeSample, 25_600)
    }

    func testReducerReportsOverlapWithoutInventingAChange() {
        var reducer = LocalDiarizationReducer()

        let update = reducer.consume(
            predictions: [0.7, 0.8, 0.1],
            frameCount: 1,
            startFrame: 0,
            speakerCount: 3,
            frameDurationSeconds: 0.1
        ).first

        XCTAssertEqual(update?.dominantSpeaker, 1)
        XCTAssertEqual(update?.overlappingSpeakers, Set([0, 1]))
        XCTAssertNil(update?.transition)
    }

    func testSilenceDoesNotForgetThePreviousSpeaker() {
        var reducer = LocalDiarizationReducer()
        _ = reducer.consume(
            predictions: [0.9, 0.1],
            frameCount: 1,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )
        let updates = reducer.consume(
            predictions: [0.1, 0.1, 0.2, 0.9, 0.1, 0.8],
            frameCount: 3,
            startFrame: 1,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertNil(updates[0].dominantSpeaker)
        XCTAssertEqual(updates[1].dominantSpeaker, 1)
        XCTAssertNil(updates[1].transition)
        XCTAssertEqual(updates[2].changeSample, 3_200)
        XCTAssertEqual(updates[2].transition?.confirmedAtSample, 6_400)
    }

    func testSingleNoisySpeakerFlipDoesNotBecomeATransition() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.2, 0.8,
                0.85, 0.15,
            ],
            frameCount: 3,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertTrue(updates.allSatisfy { $0.transition == nil })
        XCTAssertEqual(reducer.lastDominantSpeaker, 0)
    }

    func testConfirmationCarriesAcrossConsecutivePredictionBatches() {
        var reducer = LocalDiarizationReducer()
        _ = reducer.consume(
            predictions: [0.9, 0.1],
            frameCount: 1,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )
        let firstCandidate = reducer.consume(
            predictions: [0.2, 0.8],
            frameCount: 1,
            startFrame: 1,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )
        let confirmation = reducer.consume(
            predictions: [0.1, 0.75],
            frameCount: 1,
            startFrame: 2,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertNil(firstCandidate[0].transition)
        XCTAssertEqual(confirmation[0].transition?.changeSample, 1_600)
        XCTAssertEqual(confirmation[0].transition?.confirmedAtSample, 4_800)
    }

    func testOverlapArmsButDoesNotConfirmSpeakerTransition() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.8, 0.75,
                0.2, 0.85,
                0.1, 0.7,
            ],
            frameCount: 4,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertEqual(updates[1].overlappingSpeakers, Set([0, 1]))
        XCTAssertNil(updates[1].transition)
        XCTAssertNil(updates[2].transition)
        XCTAssertEqual(updates[3].transition, LocalSpeakerTransition(
            fromSpeaker: 0,
            toSpeaker: 1,
            changeSample: 3_200,
            confirmedAtSample: 6_400,
            confidence: 0.7,
            wasArmedByOverlap: true
        ))
    }

    func testClearlyDominantSpeakerDuringOverlapKeepsTheTrueChangeSample() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.6, 0.9,
                0.1, 0.85,
            ],
            frameCount: 3,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertEqual(updates[1].overlappingSpeakers, Set([0, 1]))
        XCTAssertNil(updates[1].transition)
        XCTAssertEqual(updates[2].transition, LocalSpeakerTransition(
            fromSpeaker: 0,
            toSpeaker: 1,
            changeSample: 1_600,
            confirmedAtSample: 4_800,
            confidence: 0.85,
            wasArmedByOverlap: true
        ))
    }

    func testOverlapArmSurvivesABriefSilentDropout() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.8, 0.75,
                0.1, 0.1,
                0.1, 0.8,
                0.1, 0.75,
            ],
            frameCount: 5,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertNil(updates[2].dominantSpeaker)
        XCTAssertEqual(updates[4].transition?.changeSample, 4_800)
        XCTAssertEqual(updates[4].transition?.confirmedAtSample, 8_000)
        XCTAssertEqual(updates[4].transition?.wasArmedByOverlap, true)
    }

    func testOverlapDominanceOscillationDoesNotFlapSpeakers() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.7, 0.8,
                0.85, 0.75,
                0.72, 0.88,
                0.9, 0.1,
            ],
            frameCount: 5,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertTrue(updates.allSatisfy { $0.transition == nil })
        XCTAssertEqual(reducer.lastDominantSpeaker, 0)
    }

    func testHysteresisRejectsAnAmbiguousExclusiveFrame() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [
                0.9, 0.1,
                0.45, 0.65,
                0.3, 0.75,
                0.2, 0.7,
            ],
            frameCount: 4,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        )

        XCTAssertNil(updates[1].transition)
        XCTAssertNil(updates[2].transition)
        XCTAssertEqual(updates[3].transition?.changeSample, 3_200)
        XCTAssertEqual(updates[3].transition?.confirmedAtSample, 6_400)
        XCTAssertEqual(updates[3].transition?.confidence ?? 0, 0.7, accuracy: 0.0001)
    }

    func testActiveSpeakerUsesSeparateActivationAndDeactivationThresholds() {
        var reducer = LocalDiarizationReducer()

        let updates = reducer.consume(
            predictions: [0.61, 0.50, 0.39],
            frameCount: 3,
            startFrame: 0,
            speakerCount: 1,
            frameDurationSeconds: 0.1
        )

        XCTAssertEqual(updates[0].dominantSpeaker, 0)
        XCTAssertEqual(updates[1].dominantSpeaker, 0)
        XCTAssertNil(updates[2].dominantSpeaker)
    }

    func testMalformedPredictionsAreIgnored() {
        var reducer = LocalDiarizationReducer()
        XCTAssertTrue(reducer.consume(
            predictions: [0.9],
            frameCount: 2,
            startFrame: 0,
            speakerCount: 2,
            frameDurationSeconds: 0.1
        ).isEmpty)
    }

    func testShadowIsSilentUntilExplicitlyPrepared() async {
        let shadow = LocalDiarizationShadow()

        let updates = await shadow.append(samples: [0, 0], range: 0..<2)
        let status = await shadow.status()

        XCTAssertTrue(updates.isEmpty)
        XCTAssertFalse(status.isReady)
        XCTAssertNil(status.failureReason)
    }

    func testCachedSnapshotMustMatchHashesBeforeReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent(
            LocalDiarizationModelManifest.revision,
            isDirectory: true
        )
        let model = snapshot.appendingPathComponent(
            LocalDiarizationModelManifest.modelDirectory,
            isDirectory: true
        )
        for file in LocalDiarizationModelManifest.files {
            let url = model.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        try Data(LocalDiarizationModelManifest.revision.utf8).write(
            to: snapshot.appendingPathComponent(".complete")
        )

        let store = LocalDiarizationModelStore(cacheRoot: root)
        let isValid = try await store.cachedSnapshotIsValid(
            model: model,
            marker: snapshot.appendingPathComponent(".complete")
        )
        XCTAssertFalse(isValid)
    }

    func testOptInExactModelLoadsAndAcceptsStreamingAudio() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_RUN_LSEEND_INTEGRATION"] == "1" else {
            throw XCTSkip("Set WHISPERASR_RUN_LSEEND_INTEGRATION=1 to download and load LS-EEND")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shadow = LocalDiarizationShadow(
            modelStore: LocalDiarizationModelStore(cacheRoot: root)
        )

        await shadow.prepare()
        var status = await shadow.status()
        XCTAssertTrue(status.isReady, status.failureReason ?? "LS-EEND failed to prepare")
        for start in stride(from: 0, to: 32_000, by: 1_600) {
            _ = await shadow.append(
                samples: [Float](repeating: 0, count: 1_600),
                range: start..<(start + 1_600)
            )
        }
        _ = await shadow.finish()
        status = await shadow.status()
        XCTAssertTrue(status.isReady, status.failureReason ?? "LS-EEND failed while streaming")
    }
}
