import XCTest
@testable import WhisperASRApp

final class VoxtralClausePlannerTests: XCTestCase {
    func testReplayDeduplicatorWaitsForTheWholeOldSuffixThenEmitsOnlyNewText() {
        var replay = VoxtralReplayDeduplicator(previousTranscript: "前の文。こんにちは")

        XCTAssertEqual(replay.ingest("こん"), "")
        XCTAssertEqual(replay.ingest("こんにちは"), "")
        XCTAssertEqual(replay.ingest("こんにちは世界"), "世界")
        XCTAssertEqual(replay.ingest("こんにちは世界！"), "！")
    }

    func testReplayDeduplicatorRejectsARewrittenStreamAndAnUnmatchedFinal() {
        var rewritten = VoxtralReplayDeduplicator(previousTranscript: "こんにちは")
        XCTAssertEqual(rewritten.ingest("こん"), "")
        XCTAssertNil(rewritten.ingest("さよなら"))

        var unmatched = VoxtralReplayDeduplicator(previousTranscript: "以前の言葉")
        XCTAssertEqual(unmatched.ingest("別の"), "")
        XCTAssertNil(unmatched.ingest("別の言葉", finishing: true))
    }

    func testSemanticBoundaryUsesTheLastTerminalPunctuationAndKeepsTheSuffix() {
        var planner = VoxtralClausePlanner()

        let boundary = planner.observe(
            delta: "最初。次！ まだ続く",
            fedThrough: 42_000,
            speech: [SpeechSampleRange(start: 0, end: 40_000)]
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, "最初。次！ ")
        XCTAssertEqual(boundary?.generation, 0)
        XCTAssertEqual(boundary?.sourceCharacterRange, 0..<6)
        XCTAssertEqual(boundary?.sampleRange, 0..<(42_000 - VoxtralClausePlanner.stabilityGuard))
        XCTAssertEqual(planner.pendingSourceText, "まだ続く")
        XCTAssertEqual(planner.preview?.generation, 1)
        XCTAssertEqual(planner.preview?.sourceText, "まだ続く")
    }

    func testShortTerminalQuestionDoesNotWaitForMinimumClause() {
        var planner = VoxtralClausePlanner()
        let stableEnd = VoxtralClausePlanner.sampleRate / 2
        let fedThrough = stableEnd + VoxtralClausePlanner.stabilityGuard

        let boundary = planner.observe(
            delta: "本当？",
            fedThrough: fedThrough,
            speech: [SpeechSampleRange(start: 0, end: fedThrough)]
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, "本当？")
        XCTAssertEqual(boundary?.sampleRange, 0..<stableEnd)
    }

    func testShortReplyFinalizesOnConfirmedPauseWithoutMinimumClause() {
        var planner = VoxtralClausePlanner()
        let speechEnd = VoxtralClausePlanner.sampleRate / 2
        let speech = [SpeechSampleRange(start: 0, end: speechEnd)]

        XCTAssertNil(planner.observe(
            delta: "はい",
            fedThrough: speechEnd + VoxtralClausePlanner.vadSilence,
            sourceUpdateThrough: speechEnd,
            speech: speech
        ))
        XCTAssertNil(planner.observe(
            fedThrough: speechEnd + VoxtralClausePlanner.stabilityGuard - 1
        ))

        let boundary = planner.observe(
            fedThrough: speechEnd + VoxtralClausePlanner.stabilityGuard
        )
        XCTAssertEqual(boundary?.kind, .pause)
        XCTAssertEqual(boundary?.endpointDetectedAt, speechEnd + VoxtralClausePlanner.vadSilence)
        XCTAssertEqual(boundary?.stagedAt, speechEnd + VoxtralClausePlanner.stabilityGuard)
        XCTAssertEqual(boundary?.sampleRange, 0..<speechEnd)
    }

    func testPauseFinalizesAtTheDelayGuardWithoutWaitingForSourceSettlement() {
        var planner = VoxtralClausePlanner()
        let speechEnd = VoxtralClausePlanner.sampleRate * 4
        let fedThrough = speechEnd + VoxtralClausePlanner.stabilityGuard

        let boundary = planner.observe(
            delta: "魚だったら新鮮な魚がすぐ海に来て",
            fedThrough: fedThrough,
            sourceUpdateThrough: fedThrough,
            speech: [SpeechSampleRange(start: 0, end: speechEnd)]
        )

        XCTAssertEqual(boundary?.kind, .pause)
        XCTAssertEqual(boundary?.sourceText, "魚だったら新鮮な魚がすぐ海に来て")
        XCTAssertEqual(boundary?.sampleRange, 0..<speechEnd)
        XCTAssertEqual(boundary?.stagedAt, fedThrough)
    }

    func testSoftTargetDoesNotCutIncompleteNegationAndCompletionKeepsSuffix() {
        var planner = VoxtralClausePlanner()
        let softTarget = VoxtralClausePlanner.softClauseTarget
        let softFeed = softTarget + VoxtralClausePlanner.stabilityGuard

        XCTAssertNil(planner.observe(
            delta: "ここには行か",
            fedThrough: softTarget,
            speech: [SpeechSampleRange(start: 0, end: softTarget)]
        ))
        XCTAssertNil(planner.observe(
            fedThrough: softFeed,
            speech: [SpeechSampleRange(start: softTarget, end: softFeed)]
        ))
        XCTAssertEqual(planner.sourceStagedThrough, 0)
        XCTAssertEqual(planner.pendingSourceText, "ここには行か")

        let completedStableEnd = VoxtralClausePlanner.softClauseTarget
            + VoxtralClausePlanner.sampleRate / 2
        let completedFeed = completedStableEnd + VoxtralClausePlanner.stabilityGuard
        let boundary = planner.observe(
            delta: "ない。次",
            fedThrough: completedFeed,
            speech: [SpeechSampleRange(start: softFeed, end: completedFeed)]
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, "ここには行かない。")
        XCTAssertEqual(boundary?.sampleRange, 0..<completedStableEnd)
        XCTAssertEqual(planner.pendingSourceText, "次")
        XCTAssertEqual(planner.preview?.sourceText, "次")
    }

    func testConservativeFiniteEndingMayStageAfterSoftTarget() {
        var planner = VoxtralClausePlanner()
        let softTarget = VoxtralClausePlanner.softClauseTarget
        let fedThrough = softTarget + VoxtralClausePlanner.stabilityGuard

        XCTAssertNil(planner.observe(
            delta: "今日はここまでです",
            fedThrough: softTarget,
            speech: [SpeechSampleRange(start: 0, end: softTarget)]
        ))
        let boundary = planner.observe(
            fedThrough: fedThrough,
            speech: [SpeechSampleRange(start: softTarget, end: fedThrough)]
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, "今日はここまでです")
        XCTAssertEqual(boundary?.sampleRange, 0..<VoxtralClausePlanner.softClauseTarget)
    }

    func testContinuationEndingsAreRejectedAtSoftTarget() {
        let continuations = [
            "行きたいけど",
            "問題が",
            "雨だから",
            "静かなので",
            "知っているのに",
            "それもあるし",
            "ここで待って",
            "話はここで",
            "日本について",
            "好きな食べ物は",
            "日本は食べ物が",
            "和食が今ね、",
            "例えば",
            "魚だったらやっぱりね",
            "落ち着くかな",
        ]
        let softTarget = VoxtralClausePlanner.softClauseTarget
        let fedThrough = softTarget + VoxtralClausePlanner.stabilityGuard

        for source in continuations {
            var planner = VoxtralClausePlanner()
            XCTAssertNil(planner.observe(
                delta: source,
                fedThrough: softTarget,
                speech: [SpeechSampleRange(start: 0, end: softTarget)]
            ))
            let boundary = planner.observe(
                fedThrough: fedThrough,
                speech: [SpeechSampleRange(start: softTarget, end: fedThrough)]
            )

            XCTAssertNil(boundary, "Unexpected soft boundary for continuative ending: \(source)")
            XCTAssertEqual(planner.sourceStagedThrough, 0)
            XCTAssertEqual(planner.pendingSourceText, source)
        }
    }

    func testHardTargetWaitsForTheAbsoluteLimitWithoutAValidatedMarkerPair() {
        var planner = VoxtralClausePlanner()
        let softTarget = VoxtralClausePlanner.softClauseTarget
        let softFeed = softTarget + VoxtralClausePlanner.stabilityGuard

        XCTAssertNil(planner.observe(
            delta: "まだ続いて",
            fedThrough: softTarget,
            speech: [SpeechSampleRange(start: 0, end: softTarget)]
        ))
        XCTAssertNil(planner.observe(
            fedThrough: softFeed,
            speech: [SpeechSampleRange(start: softTarget, end: softFeed)]
        ))

        let checkpointFeed = VoxtralClausePlanner.hardClauseTarget
            + VoxtralClausePlanner.stabilityGuard
        XCTAssertNil(planner.observe(
            fedThrough: checkpointFeed,
            speech: [SpeechSampleRange(start: softFeed, end: checkpointFeed)]
        ))

        let limitFeed = VoxtralClausePlanner.hardClauseLimit
            + VoxtralClausePlanner.stabilityGuard
        let boundary = planner.observe(
            fedThrough: limitFeed,
            speech: [SpeechSampleRange(start: checkpointFeed, end: limitFeed)]
        )

        XCTAssertEqual(boundary?.kind, .forced)
        XCTAssertEqual(boundary?.degradation, .degradedForcedBoundary)
        XCTAssertEqual(boundary?.sourceText, "まだ続いて")
        XCTAssertEqual(boundary?.endpointDetectedAt, limitFeed)
        XCTAssertEqual(
            boundary?.sampleRange,
            0..<(limitFeed - VoxtralClausePlanner.stabilityGuard)
        )
    }

    func testDegradedHardLimitKeepsStableOvershootWithTheTextItConsumes() {
        var planner = VoxtralClausePlanner()
        let block = VoxtralClausePlanner.sampleRate / 10
        let beforeHardFeed = VoxtralClausePlanner.hardClauseLimit
            + VoxtralClausePlanner.stabilityGuard - 1

        XCTAssertNil(planner.observe(
            delta: "前半",
            fedThrough: beforeHardFeed,
            sourceUpdateThrough: 0,
            speech: [SpeechSampleRange(start: 0, end: beforeHardFeed)]
        ))

        let overshootFeed = VoxtralClausePlanner.hardClauseLimit
            + VoxtralClausePlanner.stabilityGuard + block
        let boundary = planner.observe(
            delta: "後半",
            fedThrough: overshootFeed,
            sourceUpdateThrough: 0,
            speech: [SpeechSampleRange(start: beforeHardFeed, end: overshootFeed)]
        )
        let stableThrough = overshootFeed - VoxtralClausePlanner.stabilityGuard

        XCTAssertEqual(boundary?.kind, .forced)
        XCTAssertEqual(boundary?.degradation, .degradedForcedBoundary)
        XCTAssertEqual(boundary?.sourceText, "前半後半")
        XCTAssertEqual(boundary?.sampleRange, 0..<stableThrough)

        _ = planner.observe(delta: "次", fedThrough: overshootFeed)
        let tail = planner.finish(fedThrough: overshootFeed + block)
        XCTAssertEqual(tail?.sourceText, "次")
        XCTAssertEqual(tail?.sampleRange.lowerBound, stableThrough)
        XCTAssertEqual(
            [boundary?.sourceText, tail?.sourceText].compactMap { $0 }.joined(),
            "前半後半次"
        )
    }

    func testDegradedHardLimitStagesEvenWhenTheSourceJustChanged() {
        var planner = VoxtralClausePlanner()
        let hardFeed = VoxtralClausePlanner.hardClauseLimit
            + VoxtralClausePlanner.stabilityGuard

        let boundary = planner.observe(
            delta: "句読点なしで話し続けて",
            fedThrough: hardFeed,
            sourceUpdateThrough: hardFeed,
            speech: [SpeechSampleRange(start: 0, end: hardFeed)]
        )

        XCTAssertEqual(boundary?.kind, .forced)
        XCTAssertEqual(boundary?.degradation, .degradedForcedBoundary)
        XCTAssertEqual(boundary?.sourceText, "句読点なしで話し続けて")
        XCTAssertEqual(
            boundary?.sampleRange,
            0..<(hardFeed - VoxtralClausePlanner.stabilityGuard)
        )
        XCTAssertEqual(
            boundary?.endpointDetectedAt,
            hardFeed
        )
    }

    func testValidatedMarkerPairCutsTextAndPCMAfterTheSameVoxtralGroup() {
        var planner = speakerPlanner()
        let firstGroup = "新鮮な魚"
        let nextGroup = "について話します"
        let groupEnd = VoxtralClausePlanner.hardClauseTarget
            + VoxtralClausePlanner.sampleRate / 5
        let fedThrough = groupEnd + VoxtralClausePlanner.stabilityGuard

        let boundary = planner.observe(
            delta: firstGroup + nextGroup,
            fedThrough: fedThrough,
            emissionMarkers: [
                emissionMarker(groupStartUTF8: 0, proxyEndSample: groupEnd),
                emissionMarker(
                    groupStartUTF8: firstGroup.utf8.count,
                    proxyEndSample: groupEnd + VoxtralClausePlanner.sampleRate
                ),
            ]
        )

        XCTAssertEqual(boundary?.kind, .forced)
        XCTAssertNil(boundary?.degradation)
        XCTAssertEqual(boundary?.sourceText, firstGroup)
        XCTAssertEqual(boundary?.sampleRange, 0..<groupEnd)
        XCTAssertEqual(planner.pendingSourceText, nextGroup)
        XCTAssertEqual(boundary?.sourceCharacterRange, 0..<firstGroup.count)
    }

    func testCheckpointWaitsForFollowingMarkerThenUsesTheCompletePair() {
        var planner = speakerPlanner()
        let firstGroup = "一番好きな食べ物"
        let nextGroup = "はお米です"
        let groupEnd = VoxtralClausePlanner.hardClauseTarget
            + VoxtralClausePlanner.sampleRate / 4
        let checkpointFeed = VoxtralClausePlanner.hardClauseTarget
            + VoxtralClausePlanner.stabilityGuard

        XCTAssertNil(planner.observe(
            delta: firstGroup + nextGroup,
            fedThrough: checkpointFeed,
            emissionMarkers: [
                emissionMarker(groupStartUTF8: 0, proxyEndSample: groupEnd),
            ]
        ))

        let boundary = planner.observe(
            fedThrough: groupEnd + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [
                emissionMarker(
                    groupStartUTF8: firstGroup.utf8.count,
                    proxyEndSample: groupEnd + VoxtralClausePlanner.sampleRate
                ),
            ]
        )

        XCTAssertEqual(boundary?.sourceText, firstGroup)
        XCTAssertEqual(boundary?.sampleRange.upperBound, groupEnd)
        XCTAssertEqual(planner.pendingSourceText, nextGroup)
    }

    func testFollowingMarkerIsRetainedAsTheNextClauseAnchor() {
        var planner = speakerPlanner()
        let first = "新鮮な魚"
        let second = "もんね"
        let tail = "次の話"
        let firstEnd = VoxtralClausePlanner.hardClauseTarget
        let secondEnd = firstEnd + VoxtralClausePlanner.hardClauseTarget

        let firstBoundary = planner.observe(
            delta: first + second + tail,
            fedThrough: firstEnd + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [
                emissionMarker(groupStartUTF8: 0, proxyEndSample: firstEnd),
                emissionMarker(
                    groupStartUTF8: first.utf8.count,
                    proxyEndSample: secondEnd
                ),
            ]
        )!

        let secondBoundary = planner.observe(
            fedThrough: secondEnd + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [
                emissionMarker(
                    groupStartUTF8: (first + second).utf8.count,
                    proxyEndSample: secondEnd + VoxtralClausePlanner.sampleRate
                ),
            ]
        )!
        let final = planner.finish(
            fedThrough: secondEnd + VoxtralClausePlanner.sampleRate * 2
        )!

        XCTAssertEqual(firstBoundary.sourceText, first)
        XCTAssertEqual(secondBoundary.sourceText, second)
        XCTAssertEqual(final.sourceText, tail)
        XCTAssertEqual(
            [firstBoundary.sourceText, secondBoundary.sourceText, final.sourceText].joined(),
            first + second + tail
        )
        XCTAssertEqual(firstBoundary.sampleRange.upperBound, secondBoundary.sampleRange.lowerBound)
        XCTAssertEqual(secondBoundary.sampleRange.upperBound, final.sampleRange.lowerBound)
    }

    func testStagingAndEnglishValidationHaveIndependentFIFOCursors() {
        var planner = VoxtralClausePlanner()
        let first = planner.observe(
            delta: "一。二",
            fedThrough: 42_000,
            speech: [SpeechSampleRange(start: 0, end: 40_000)]
        )!
        let firstStagedThrough = planner.sourceStagedThrough
        let firstCharacters = planner.sourceStagedCharacterCount

        let second = planner.observe(
            delta: "！",
            fedThrough: 84_000,
            speech: [SpeechSampleRange(start: firstStagedThrough, end: 80_000)]
        )!

        XCTAssertEqual(first.generation, 0)
        XCTAssertEqual(second.generation, 1)
        XCTAssertEqual(second.sampleRange.lowerBound, first.sampleRange.upperBound)
        XCTAssertEqual(planner.pendingValidationCount, 2)
        XCTAssertGreaterThan(planner.sourceStagedThrough, firstStagedThrough)
        XCTAssertGreaterThan(planner.sourceStagedCharacterCount, firstCharacters)
        XCTAssertEqual(planner.englishValidatedThrough, 0)
        XCTAssertEqual(planner.sourceValidatedCharacterCount, 0)

        XCTAssertFalse(planner.validate(generation: second.generation))
        XCTAssertTrue(planner.validate(generation: first.generation))
        XCTAssertEqual(planner.englishValidatedThrough, first.sampleRange.upperBound)
        XCTAssertEqual(
            planner.sourceValidatedCharacterCount,
            first.sourceCharacterRange.upperBound
        )
        XCTAssertEqual(planner.pendingValidationCount, 1)
    }

    func testPunctuationWithoutMeaningNeverCreatesAnEmptyFinal() {
        var planner = VoxtralClausePlanner()

        XCTAssertNil(planner.observe(
            delta: " 。！？!? \n",
            fedThrough: 100_000,
            speech: [SpeechSampleRange(start: 0, end: 80_000)]
        ))
        XCTAssertEqual(planner.pendingValidationCount, 0)
        XCTAssertEqual(planner.sourceStagedThrough, 0)
        XCTAssertNil(planner.preview)
    }

    func testFinalSourceUsesNFCAndRemovesTransportControlsWithoutRewritingText() {
        var planner = VoxtralClausePlanner()
        let stableEnd = VoxtralClausePlanner.sampleRate

        let boundary = planner.observe(
            delta: "か\u{3099}\u{0000}く。",
            fedThrough: stableEnd + VoxtralClausePlanner.stabilityGuard,
            speech: [SpeechSampleRange(start: 0, end: stableEnd)]
        )

        XCTAssertEqual(boundary?.sourceText, "がく。")
    }

    func testClauseLedgerPreservesSpacesAndLatinCodeSwitchExactly() {
        var planner = VoxtralClausePlanner()
        let transcript = "日本語。 English Name"
        let firstFeed = 48_000

        let first = planner.observe(
            delta: transcript,
            fedThrough: firstFeed
        )!
        let tail = planner.finish(fedThrough: 64_000)!

        XCTAssertEqual(first.sourceText, "日本語。 ")
        XCTAssertEqual(tail.sourceText, "English Name")
        XCTAssertEqual(first.sourceText + tail.sourceText, transcript)
        XCTAssertEqual(first.sourceCharacterRange.upperBound, tail.sourceCharacterRange.lowerBound)
    }

    func testPreviewIsTheCurrentUnstagedSuffixWithItsOwnGenerationAndRange() {
        var planner = VoxtralClausePlanner()
        _ = planner.observe(
            delta: "完了。 次",
            fedThrough: 42_000,
            speech: [SpeechSampleRange(start: 0, end: 40_000)]
        )

        XCTAssertEqual(planner.preview, VoxtralClausePreview(
            generation: 1,
            sourceText: "次",
            sampleRange: planner.sourceStagedThrough..<planner.fedThrough
        ))
    }

    func testLogicalBoundariesNeverRequestRuntimeFinishOrReset() {
        XCTAssertEqual(
            Set(VoxtralClauseBoundary.Kind.allCases.filter { $0 != .finish }),
            Set([.semantic, .pause, .speaker, .forced])
        )
    }

    func testSpeakerBoundaryWorksWhenTransitionOrMarkerArrivesFirst() {
        let previous = "前の人"
        let next = "次の人"
        let transition = speakerTransition(changeSample: 24_000)
        let marker = emissionMarker(
            groupStartUTF8: previous.utf8.count,
            proxyEndSample: 30_000
        )
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard

        var transitionFirst = speakerPlanner()
        XCTAssertNil(transitionFirst.observe(
            delta: previous + next,
            fedThrough: fedThrough,
            speakerTransitions: [transition]
        ))
        let afterMarker = transitionFirst.observe(
            fedThrough: fedThrough,
            emissionMarkers: [marker]
        )

        var markerFirst = speakerPlanner()
        XCTAssertNil(markerFirst.observe(
            delta: previous + next,
            fedThrough: fedThrough,
            emissionMarkers: [marker]
        ))
        let afterTransition = markerFirst.observe(
            fedThrough: fedThrough,
            speakerTransitions: [transition]
        )

        XCTAssertEqual(afterMarker, afterTransition)
        XCTAssertEqual(afterMarker?.kind, .speaker)
        XCTAssertEqual(afterMarker?.sourceText, previous)
        XCTAssertEqual(afterMarker?.sampleRange, 0..<transition.changeSample)
        XCTAssertEqual(afterMarker?.endpointDetectedAt, transition.confirmedAtSample)
        XCTAssertEqual(transitionFirst.preview?.sourceText, next)
        XCTAssertEqual(markerFirst.preview?.sourceText, next)
    }

    func testSpeakerMarkerUsesRawUTF8OffsetRatherThanCharacterCount() {
        var planner = speakerPlanner()
        let previous = "姉さん🙂"
        let next = "次の人"
        let transition = speakerTransition(changeSample: 32_000)

        let boundary = planner.observe(
            delta: previous + next,
            fedThrough: transition.changeSample + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 36_000
            )],
            speakerTransitions: [transition]
        )

        XCTAssertNotEqual(previous.utf8.count, previous.count)
        XCTAssertEqual(boundary?.kind, .speaker)
        XCTAssertEqual(boundary?.sourceText, previous)
        XCTAssertEqual(boundary?.sourceCharacterRange, 0..<previous.count)
        XCTAssertEqual(planner.sourceStagedUTF8Count, previous.utf8.count)
        XCTAssertEqual(planner.pendingSourceText, next)
    }

    func testSpeakerBoundaryWinsBeforeLaterPunctuation() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let next = "次の人。"
        let transition = speakerTransition(changeSample: 24_000)
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard

        let speaker = planner.observe(
            delta: previous + next,
            fedThrough: fedThrough,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 30_000
            )],
            speakerTransitions: [transition]
        )
        let semanticCandidateAt = fedThrough + VoxtralClausePlanner.sampleRate
        let semantic = planner.observe(
            fedThrough: semanticCandidateAt
        )

        XCTAssertEqual(speaker?.kind, .speaker)
        XCTAssertEqual(speaker?.sourceText, previous)
        XCTAssertEqual(semantic?.kind, .semantic)
        XCTAssertEqual(semantic?.sourceText, next)
        XCTAssertEqual(speaker?.sampleRange.upperBound, semantic?.sampleRange.lowerBound)
        XCTAssertEqual(
            [speaker?.sourceText, semantic?.sourceText].compactMap { $0 }.joined(),
            previous + next
        )
    }

    func testSpeakerBoundaryWinsWhenPunctuationPrecedesItsMarker() {
        var planner = speakerPlanner()
        let previous = "前の人。まだ前の人"
        let next = "次の人"
        let transition = speakerTransition(changeSample: 24_000)

        let boundary = planner.observe(
            delta: previous + next,
            fedThrough: transition.changeSample + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 30_000
            )],
            speakerTransitions: [transition]
        )

        XCTAssertEqual(boundary?.kind, .speaker)
        XCTAssertEqual(boundary?.sourceText, previous)
        XCTAssertEqual(boundary?.sampleRange, 0..<transition.changeSample)
        XCTAssertEqual(planner.preview?.sourceText, next)
    }

    func testEqualPunctuationAndSpeakerCutIsClassifiedAsSpeaker() {
        var planner = speakerPlanner()
        let previous = "前の人。"
        let next = "次の人"
        let transition = speakerTransition(changeSample: 24_000)

        let boundary = planner.observe(
            delta: previous + next,
            fedThrough: transition.changeSample + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 30_000
            )],
            speakerTransitions: [transition]
        )

        XCTAssertEqual(boundary?.kind, .speaker)
        XCTAssertEqual(boundary?.sourceText, previous)
        XCTAssertEqual(planner.preview?.sourceText, next)
    }

    func testPendingSpeakerTransitionNeverDelaysAReadyPause() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let next = "次の人"
        let speechEnd = 28_000
        let fedThrough = speechEnd + VoxtralClausePlanner.stabilityGuard
        let transition = speakerTransition(
            changeSample: 20_000,
            confirmedAtSample: fedThrough - VoxtralClausePlanner.speakerMarkerWait + 1
        )

        let boundary = planner.observe(
            delta: previous + next,
            fedThrough: fedThrough,
            sourceUpdateThrough: fedThrough,
            speech: [SpeechSampleRange(start: 0, end: speechEnd)],
            speakerTransitions: [transition]
        )
        XCTAssertEqual(boundary?.kind, .pause)
        XCTAssertEqual(boundary?.sourceText, previous + next)
        XCTAssertEqual(boundary?.speakerDecision, .diarizationLagFallback(transition))
    }

    func testDuplicateSpeakerEvidenceCannotCreateDuplicateOrNoncontiguousClauses() {
        var planner = speakerPlanner()
        let firstText = "一人目"
        let secondText = "二人目。"
        let tailText = "最後"
        let transition = speakerTransition(changeSample: 24_000)
        let marker = emissionMarker(
            groupStartUTF8: firstText.utf8.count,
            proxyEndSample: 30_000
        )
        let firstFeed = transition.changeSample + VoxtralClausePlanner.stabilityGuard

        let first = planner.observe(
            delta: firstText + secondText,
            fedThrough: firstFeed,
            emissionMarkers: [marker, marker],
            speakerTransitions: [transition, transition]
        )!
        let secondCandidateAt = firstFeed + VoxtralClausePlanner.sampleRate
        let second = planner.observe(
            fedThrough: secondCandidateAt,
            emissionMarkers: [marker],
            speakerTransitions: [transition]
        )!
        _ = planner.observe(
            delta: tailText,
            fedThrough: firstFeed + VoxtralClausePlanner.sampleRate * 2,
            emissionMarkers: [marker],
            speakerTransitions: [transition]
        )
        let tail = planner.finish(
            fedThrough: firstFeed + VoxtralClausePlanner.sampleRate * 3
        )!

        XCTAssertEqual(first.kind, .speaker)
        XCTAssertEqual(second.kind, .semantic)
        XCTAssertEqual(
            [first.sourceText, second.sourceText, tail.sourceText].joined(),
            firstText + secondText + tailText
        )
        XCTAssertEqual(first.sampleRange.upperBound, second.sampleRange.lowerBound)
        XCTAssertEqual(second.sampleRange.upperBound, tail.sampleRange.lowerBound)
        XCTAssertEqual(
            [first.sampleRange, second.sampleRange, tail.sampleRange]
                .reduce(0) { $0 + $1.count },
            tail.sampleRange.upperBound
        )
        XCTAssertEqual(
            first.sourceCharacterRange.upperBound,
            second.sourceCharacterRange.lowerBound
        )
        XCTAssertEqual(
            second.sourceCharacterRange.upperBound,
            tail.sourceCharacterRange.lowerBound
        )
    }

    func testMissingMarkerNeverDelaysReadyPunctuation() {
        var planner = speakerPlanner()
        let transition = speakerTransition(changeSample: 50_000)
        let firstFallback = transition.confirmedAtSample

        let fallback = planner.observe(
            delta: "前の人次の人。",
            fedThrough: firstFallback,
            speakerTransitions: [transition]
        )
        XCTAssertEqual(fallback?.kind, .semantic)
        XCTAssertEqual(fallback?.speakerDecision, .diarizationLagFallback(transition))
    }

    func testLateSpeakerMarkerCannotReplaceAnAlreadyReadySemanticBoundary() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let next = "次の人。"
        let transition = speakerTransition(changeSample: 32_000)
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard

        let boundary = planner.observe(
            delta: previous + next,
            fedThrough: fedThrough,
            speakerTransitions: [transition]
        )
        let lateMarker = planner.observe(
            fedThrough: fedThrough,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: transition.changeSample
            )]
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, previous + next)
        XCTAssertEqual(boundary?.speakerDecision, .diarizationLagFallback(transition))
        XCTAssertNil(lateMarker)
        XCTAssertTrue(planner.pendingSourceText.isEmpty)
    }

    func testMarkerAtCurrentTextEndWaitsUntilTheNextSpeakerTextArrives() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let next = "次の人"
        let transition = speakerTransition(changeSample: 32_000)
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard
        let marker = emissionMarker(
            groupStartUTF8: previous.utf8.count,
            proxyEndSample: transition.changeSample
        )

        XCTAssertNil(planner.observe(
            delta: previous,
            fedThrough: fedThrough,
            emissionMarkers: [marker],
            speakerTransitions: [transition]
        ))
        let boundary = planner.observe(
            delta: next,
            fedThrough: fedThrough,
            sourceUpdateThrough: fedThrough
        )

        XCTAssertEqual(boundary?.kind, .speaker)
        XCTAssertEqual(boundary?.sourceText, previous)
        XCTAssertEqual(planner.preview?.sourceText, next)
    }

    func testMarkerCandidateExpiresAfterOnePointFiveSecondsWithoutFallback() {
        var planner = speakerPlanner()
        let transition = speakerTransition(changeSample: 32_000)

        XCTAssertNil(planner.observe(
            delta: "前の人次の人",
            fedThrough: transition.confirmedAtSample,
            speakerTransitions: [transition]
        ))
        XCTAssertNil(planner.observe(
            fedThrough: transition.confirmedAtSample + VoxtralClausePlanner.speakerMarkerWait
        ))
        XCTAssertNil(planner.observe(
            fedThrough: transition.confirmedAtSample + VoxtralClausePlanner.speakerMarkerWait,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: "前の人".utf8.count,
                proxyEndSample: transition.changeSample
            )]
        ))
    }

    func testMarkerAtEarlyToleranceStillCreatesSpeakerBoundary() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let transition = speakerTransition(changeSample: 32_000)

        let boundary = planner.observe(
            delta: previous + "次の人",
            fedThrough: transition.changeSample + VoxtralClausePlanner.stabilityGuard,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: transition.changeSample
                    - VoxtralClausePlanner.speakerMarkerEarlyTolerance
            )],
            speakerTransitions: [transition]
        )

        XCTAssertEqual(boundary?.kind, .speaker)
        XCTAssertEqual(boundary?.speakerDecision, .applied(transition))
    }

    func testUnusableMarkerAndUnvalidatedCalibrationNeverSplitSpeakers() {
        let previous = "前の人"
        let transition = speakerTransition(changeSample: 24_000)
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard
        let unusable = emissionMarker(
            groupStartUTF8: previous.utf8.count,
            proxyEndSample: 30_000,
            isUsable: false
        )

        var absent = VoxtralClausePlanner()
        XCTAssertNil(absent.observe(
            delta: previous + "次の人",
            fedThrough: fedThrough,
            emissionMarkers: [unusable],
            speakerTransitions: [transition]
        ))

        var inaccurate = VoxtralClausePlanner(markerCalibration: VoxtralMarkerCalibration(
            biasSamples: 0,
            p95AbsoluteErrorSamples: VoxtralMarkerCalibration.maximumP95ErrorSamples + 1
        ))
        XCTAssertNil(inaccurate.observe(
            delta: previous + "次の人",
            fedThrough: fedThrough,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 30_000
            )],
            speakerTransitions: [transition]
        ))
    }

    func testDiscardSpeakerEvidenceLeavesTranscriptAndClausesUntouched() {
        var planner = speakerPlanner()
        let previous = "前の人"
        let transition = speakerTransition(changeSample: 24_000)
        let fedThrough = transition.changeSample + VoxtralClausePlanner.stabilityGuard

        XCTAssertNil(planner.observe(
            delta: previous + "次の人",
            fedThrough: fedThrough,
            speakerTransitions: [transition]
        ))
        planner.discardSpeakerEvidence()
        let boundary = planner.observe(
            fedThrough: fedThrough + VoxtralClausePlanner.sampleRate,
            emissionMarkers: [emissionMarker(
                groupStartUTF8: previous.utf8.count,
                proxyEndSample: 30_000
            )],
            speakerTransitions: [transition]
        )

        XCTAssertNil(boundary)
        XCTAssertEqual(planner.pendingSourceText, previous + "次の人")
        XCTAssertEqual(planner.sourceStagedThrough, 0)
    }

    func testDiscardingSpeakerAuthorityLeavesPunctuationImmediate() {
        var planner = speakerPlanner()
        planner.discardSpeakerEvidence()

        let boundary = planner.observe(
            delta: "すぐ終わる。",
            fedThrough: 48_000
        )

        XCTAssertEqual(boundary?.kind, .semantic)
        XCTAssertEqual(boundary?.sourceText, "すぐ終わる。")
    }

    func testMarkerCalibrationRoundsBiasToVoxtralFramesAndGatesP95() {
        let accepted = VoxtralMarkerCalibration(
            biasSamples: 1_900,
            p95AbsoluteErrorSamples: VoxtralMarkerCalibration.maximumP95ErrorSamples
        )
        let rejected = VoxtralMarkerCalibration(
            biasSamples: -1_900,
            p95AbsoluteErrorSamples: VoxtralMarkerCalibration.maximumP95ErrorSamples + 1
        )

        XCTAssertEqual(accepted.biasSamples, 1_280)
        XCTAssertEqual(rejected.biasSamples, -1_280)
        XCTAssertTrue(accepted.permitsSpeakerBoundaries)
        XCTAssertFalse(rejected.permitsSpeakerBoundaries)
    }

    func testFinishStagesTheLastShortClauseWithoutARegularBoundary() {
        var planner = VoxtralClausePlanner()
        _ = planner.observe(delta: "最後", fedThrough: 8_000)

        let tail = planner.finish(fedThrough: 9_600)

        XCTAssertEqual(tail?.kind, .finish)
        XCTAssertEqual(tail?.sourceText, "最後")
        XCTAssertEqual(tail?.sampleRange, 0..<9_600)
    }

    func testFinishAppendsTheCommitDeltaAndCoversTheCompleteFinalPCMRange() {
        var planner = VoxtralClausePlanner()
        XCTAssertNil(planner.observe(delta: "最後の言葉", fedThrough: 24_000))

        let finalThrough = 48_000
        let tail = planner.finish(delta: "。", fedThrough: finalThrough)

        XCTAssertEqual(tail?.kind, .finish)
        XCTAssertEqual(tail?.sourceText, "最後の言葉。")
        XCTAssertEqual(tail?.sampleRange, 0..<finalThrough)
        XCTAssertEqual(planner.sourceStagedThrough, finalThrough)
        XCTAssertEqual(planner.pendingSourceText, "")
    }

    func testSemanticClausesAndFinalFlushPreserveAllTextAndPCMExactlyOnce() {
        var planner = VoxtralClausePlanner()
        let firstFeed = 40_000

        let first = planner.observe(
            delta: "最初。次は行か",
            fedThrough: firstFeed,
            speech: [SpeechSampleRange(start: 0, end: firstFeed)]
        )!
        let secondFeed = 80_000
        let second = planner.observe(
            delta: "ない。最後",
            fedThrough: secondFeed,
            speech: [SpeechSampleRange(start: firstFeed, end: secondFeed)]
        )!
        let finalFeed = 90_000
        let tail = planner.finish(fedThrough: finalFeed)!

        XCTAssertEqual(
            [first.sourceText, second.sourceText, tail.sourceText].joined(),
            "最初。次は行かない。最後"
        )
        XCTAssertEqual(first.sampleRange.lowerBound, 0)
        XCTAssertEqual(first.sampleRange.upperBound, second.sampleRange.lowerBound)
        XCTAssertEqual(second.sampleRange.upperBound, tail.sampleRange.lowerBound)
        XCTAssertEqual(tail.sampleRange.upperBound, finalFeed)
        XCTAssertEqual(
            [first.sampleRange, second.sampleRange, tail.sampleRange]
                .reduce(0) { $0 + $1.count },
            finalFeed
        )
        XCTAssertEqual(first.sourceCharacterRange.upperBound, second.sourceCharacterRange.lowerBound)
        XCTAssertEqual(second.sourceCharacterRange.upperBound, tail.sourceCharacterRange.lowerBound)
        XCTAssertEqual(planner.pendingSourceText, "")
        XCTAssertEqual(planner.pendingValidationCount, 3)
    }

    func testWrongValidationCursorDoesNotAdvanceEnglishOrPCMState() {
        var planner = VoxtralClausePlanner()
        let boundary = planner.observe(
            delta: "一文。",
            fedThrough: 42_000,
            speech: [SpeechSampleRange(start: 0, end: 40_000)]
        )!

        XCTAssertFalse(planner.validate(through: boundary.sampleRange.upperBound + 1))
        XCTAssertEqual(planner.englishValidatedThrough, 0)
        XCTAssertEqual(planner.pendingValidationCount, 1)
    }

    private func emissionMarker(
        groupStartUTF8: Int,
        proxyEndSample: Int,
        isUsable: Bool = true
    ) -> VoxtralEmissionMarker {
        VoxtralEmissionMarker(
            generatedIndex: groupStartUTF8,
            decoderPosition: proxyEndSample / 1_280,
            delayFrames: 12,
            proxyEndSample: proxyEndSample,
            groupTextStartUTF8: groupStartUTF8,
            isUsable: isUsable
        )
    }

    private func speakerTransition(
        changeSample: Int,
        confirmedAtSample: Int? = nil
    ) -> LocalSpeakerTransition {
        LocalSpeakerTransition(
            fromSpeaker: 0,
            toSpeaker: 1,
            changeSample: changeSample,
            confirmedAtSample: confirmedAtSample ?? changeSample + 1_600,
            confidence: 0.75,
            wasArmedByOverlap: false
        )
    }

    private func speakerPlanner() -> VoxtralClausePlanner {
        VoxtralClausePlanner(markerCalibration: VoxtralMarkerCalibration(
            biasSamples: 0,
            p95AbsoluteErrorSamples: VoxtralMarkerCalibration.maximumP95ErrorSamples
        ))
    }
}
