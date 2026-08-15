import Foundation
import XCTest
@testable import WhisperASRApp

final class ReadableSubtitleReflowTests: XCTestCase {
    func testRawItemsEmptySyntheticTimingDoesNotCreateInternalBoundary() throws {
        let japanese = "前半、後半。"
        let turn = HighQualityTranslationTurn(
            id: "cue-0001",
            japanese: japanese,
            precedingJapanese: [],
            followingJapanese: [],
            speakerLabel: nil,
            sourceStart: 0,
            sourceEnd: 6
        )
        let chunk = HighQualityAlignmentChunk(
            index: 0,
            sourceStart: 0,
            sourceEnd: 6,
            cues: [.init(id: turn.id, text: japanese, start: 0, end: 6)],
            rawItems: []
        )
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: .init(
                modelID: "fixture",
                revision: "fixture",
                chunks: [chunk],
                mergedCues: chunk.cues,
                sourceDuration: 6,
                peakMemoryBytes: 0,
                validationDiagnostics: []
            ),
            sourceTurns: [turn]
        )
        let unit = try XCTUnwrap(semantic.units.first)
        XCTAssertEqual(semantic.units.count, 1)
        XCTAssertTrue(semantic.fragments.allSatisfy { $0.alignmentItemIndex == nil })

        let text = "The first measured subtitle clause stays clear and calm as "
            + "the second measured clause remains equally easy to read."
        let source = HighQualitySubtitleCue(
            id: unit.id,
            start: 0,
            end: 6,
            text: text
        )

        let result = try HighQualityReadableSubtitleReflow.apply(
            to: [source],
            units: semantic.units,
            fragments: semantic.fragments
        )

        XCTAssertEqual(result.cues.map(\.id), [source.id])
        XCTAssertEqual(result.cues.map(\.text), [text])
        XCTAssertEqual(result.evidence.splitSourceCueCount, 0)
        XCTAssertEqual(result.evidence.decisions.first?.boundaries, [])
        XCTAssertEqual(result.evidence.unresolvedSourceCueCount, 1)
    }

    func testImpossibleCueRemainsValidAndIsAudited() throws {
        let source = HighQualitySubtitleCue(
            id: "unit-0001",
            start: 0,
            end: 0.5,
            text: "This dense subtitle cannot be made readable.",
            speakerLabel: "SPEAKER_01"
        )
        let unit = HighQualitySemanticUnitEvidence(
            id: source.id,
            japanese: "前半、後半。",
            sourceFragmentIndices: [0, 1],
            sourceCueIDs: ["cue-0001"],
            start: source.start,
            end: source.end,
            decisions: [],
            speakerLabel: source.speakerLabel,
            speakerMappingIndices: []
        )
        let fragments = [
            HighQualitySemanticFragmentEvidence(
                index: 0,
                alignmentItemIndex: 0,
                sourceCueID: "cue-0001",
                text: "前半、",
                start: 0,
                end: 0.2
            ),
            HighQualitySemanticFragmentEvidence(
                index: 1,
                alignmentItemIndex: 1,
                sourceCueID: "cue-0001",
                text: "後半。",
                start: 0.3,
                end: 0.5
            ),
        ]

        let result = try HighQualityReadableSubtitleReflow.apply(
            to: [source],
            units: [unit],
            fragments: fragments
        )

        XCTAssertEqual(result.cues.map(\.id), [source.id])
        XCTAssertEqual(result.cues.map(\.text), [source.text])
        XCTAssertEqual(result.cues.map(\.start), [source.start])
        XCTAssertEqual(result.cues.map(\.end), [source.end])
        XCTAssertEqual(result.cues.map(\.speakerLabel), [source.speakerLabel])
        XCTAssertEqual(result.evidence.unresolvedSourceCueCount, 1)
        XCTAssertTrue(result.evidence.decisions[0].unresolvedViolations.contains(.minimumDuration))
        XCTAssertTrue(result.evidence.integrityPassed)
    }

    func testContractIsTranslatorAndSpeakerIndependent() throws {
        for (text, speaker) in [
            ("A compact output from the twelve billion parameter translator.", "SPEAKER_01"),
            ("A compact output from the four billion parameter translator.", nil),
        ] {
            let source = HighQualitySubtitleCue(
                id: "unit-0001",
                start: 1,
                end: 5,
                text: text,
                speakerLabel: speaker
            )
            let unit = HighQualitySemanticUnitEvidence(
                id: source.id,
                japanese: "短い文。",
                sourceFragmentIndices: [],
                sourceCueIDs: ["cue-0001"],
                start: source.start,
                end: source.end,
                decisions: [],
                speakerLabel: speaker,
                speakerMappingIndices: []
            )

            let result = try HighQualityReadableSubtitleReflow.apply(
                to: [source],
                units: [unit],
                fragments: []
            )

            XCTAssertEqual(result.cues.flatMap { $0.text.split(whereSeparator: \.isWhitespace) },
                           text.split(whereSeparator: \.isWhitespace))
            XCTAssertEqual(result.cues.map(\.speakerLabel), [speaker])
            XCTAssertTrue(result.evidence.integrityPassed)
        }
    }

    func testCancellationStopsReflow() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HighQualityReadableSubtitleReflow.apply(
                to: [.init(id: "unit-0001", start: 0, end: 2, text: "Cancelled")],
                units: [],
                fragments: []
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop readable subtitle reflow.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLateCancellationDuringLastCueDPPreservesLastValidResult() throws {
        let first = HighQualitySubtitleCue(
            id: "unit-0001",
            start: 0,
            end: 2,
            text: "A valid cue."
        )
        let last = HighQualitySubtitleCue(
            id: "unit-0002",
            start: 2,
            end: 8,
            text: "The first measured subtitle clause stays clear and calm as "
                + "the second measured clause remains equally easy to read."
        )
        let unit = HighQualitySemanticUnitEvidence(
            id: last.id,
            japanese: "前半、後半。",
            sourceFragmentIndices: [0, 1],
            sourceCueIDs: ["cue-0002"],
            start: last.start,
            end: last.end,
            decisions: [],
            speakerMappingIndices: []
        )
        let fragments = [
            HighQualitySemanticFragmentEvidence(
                index: 0,
                alignmentItemIndex: 0,
                sourceCueID: "cue-0002",
                text: "前半、",
                start: 2,
                end: 4.5
            ),
            HighQualitySemanticFragmentEvidence(
                index: 1,
                alignmentItemIndex: 1,
                sourceCueID: "cue-0002",
                text: "後半。",
                start: 5,
                end: 8
            ),
        ]
        let lastValid = try HighQualityReadableSubtitleReflow.apply(
            to: [first],
            units: [],
            fragments: []
        )
        var visibleResult = lastValid
        var checks = 0

        XCTAssertThrowsError(try {
            visibleResult = try HighQualityReadableSubtitleReflow.apply(
                to: [first, last],
                units: [unit],
                fragments: fragments,
                cancellationCheck: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        }()) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(checks, 3)
        XCTAssertEqual(visibleResult.cues, lastValid.cues)
        XCTAssertEqual(visibleResult.evidence, lastValid.evidence)
    }

    func testCancellationIsCheckedImmediatelyBeforeReturningResult() {
        var checks = 0

        XCTAssertThrowsError(try HighQualityReadableSubtitleReflow.apply(
            to: [.init(id: "unit-0001", start: 0, end: 2, text: "A valid cue.")],
            units: [],
            fragments: [],
            cancellationCheck: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 2)
    }

    func testFrozenDevelopmentReplayImprovesReadabilityWithoutRegression() throws {
        let replay = try ReadableSubtitleReplaySupport.replay(
            "E31/translategemma-12b-it-4bit-qudu2fx3ncc/raw-asr.json.gz"
        )

        assertQualityGate(replay)
        printReport("READABLE_SUBTITLE_DEV", replay.evidence)
    }

    func testFrozenHoldoutReplayImprovesReadabilityWithoutRegression() throws {
        let replay = try ReadableSubtitleReplaySupport.replay(
            "E31/translategemma-12b-it-4bit-md62mmdz0m/raw-asr.json.gz"
        )

        assertQualityGate(replay)
        printReport("READABLE_SUBTITLE_HOLDOUT", replay.evidence)
    }

    func testFrozen12BAnd4BReplaysPreserveContractWithSpeakersOnAndOff() throws {
        let matrix = [
            "12B": [
                "E31/translategemma-12b-it-4bit-qudu2fx3ncc/raw-asr.json.gz",
                "E31/translategemma-12b-it-4bit-md62mmdz0m/raw-asr.json.gz",
            ],
            "4B": [
                "E31-translation-only-4b/translategemma-4b-it-4bit-qudu2fx3ncc/raw-asr.json.gz",
                "E31-translation-only-4b/translategemma-4b-it-4bit-md62mmdz0m/raw-asr.json.gz",
            ],
        ]
        var combinationCount = 0

        for paths in matrix.values {
            for path in paths {
                let speakerOn = try ReadableSubtitleReplaySupport.replay(path)
                let speakerOff = try ReadableSubtitleReplaySupport.replay(
                    path,
                    includeSpeakers: false
                )
                combinationCount += 2

                for replay in [speakerOn, speakerOff] {
                    XCTAssertTrue(replay.evidence.integrityPassed)
                    XCTAssertTrue(replay.evidence.exactWordOrder)
                    XCTAssertTrue(replay.evidence.exactTimingCoverage)
                    XCTAssertTrue(replay.evidence.exactInterCueGaps)
                    XCTAssertTrue(replay.evidence.speakerMetadataPreserved)
                }
                XCTAssertEqual(speakerOff.cues.map(\.text), speakerOn.cues.map(\.text))
                XCTAssertEqual(speakerOff.cues.map(\.start), speakerOn.cues.map(\.start))
                XCTAssertEqual(speakerOff.cues.map(\.end), speakerOn.cues.map(\.end))
                XCTAssertEqual(
                    speakerOff.cues.map(\.renderedLines),
                    speakerOn.cues.map(\.renderedLines)
                )
                XCTAssertTrue(speakerOff.cues.allSatisfy { $0.speakerLabel == nil })
                XCTAssertEqual(speakerOff.evidence.baseline, speakerOn.evidence.baseline)
                XCTAssertEqual(speakerOff.evidence.candidate, speakerOn.evidence.candidate)
            }
        }
        XCTAssertEqual(combinationCount, 8)
    }

    private func printReport(_ name: String, _ evidence: HighQualityReadableSubtitleEvidence) {
        print(
            "\(name): cues \(evidence.baseline.cueCount)->\(evidence.candidate.cueCount), "
                + "readable \(evidence.baseline.readableCueCount)"
                + "->\(evidence.candidate.readableCueCount), "
                + ">84 \(evidence.baseline.overMaximumCharactersCount)"
                + "->\(evidence.candidate.overMaximumCharactersCount), "
                + ">20cps \(evidence.baseline.overMaximumCharactersPerSecondCount)"
                + "->\(evidence.candidate.overMaximumCharactersPerSecondCount), "
                + "short \(evidence.baseline.underMinimumDurationCount)"
                + "->\(evidence.candidate.underMinimumDurationCount), "
                + "long \(evidence.baseline.overMaximumDurationCount)"
                + "->\(evidence.candidate.overMaximumDurationCount), "
                + "splits \(evidence.splitSourceCueCount)"
        )
    }

    private func assertProductionExports(_ replay: HighQualityReadableSubtitleResult) {
        let srt = HighQualityJob.srt(replay.cues)
        let vtt = HighQualityJob.webVTT(replay.cues)
        let srtTimings = srt.split(separator: "\n").filter {
            $0.contains(" --> ")
        }.map { $0.replacingOccurrences(of: ",", with: ".") }
        let vttTimings = vtt.split(separator: "\n").filter {
            $0.contains(" --> ")
        }.map(String.init)
        let expectedWords = replay.cues.flatMap {
            $0.text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        XCTAssertEqual(srtTimings.count, replay.evidence.candidate.cueCount)
        XCTAssertEqual(srtTimings, vttTimings)
        XCTAssertEqual(exportedWords(srt, webVTT: false), expectedWords)
        XCTAssertEqual(exportedWords(vtt, webVTT: true), expectedWords)
    }

    private func assertQualityGate(_ replay: HighQualityReadableSubtitleResult) {
        let baseline = replay.evidence.baseline
        let candidate = replay.evidence.candidate
        XCTAssertTrue(replay.evidence.integrityPassed)
        XCTAssertGreaterThan(replay.evidence.splitSourceCueCount, 0)
        XCTAssertGreaterThan(candidate.readableCueCount, baseline.readableCueCount)
        XCTAssertLessThanOrEqual(
            candidate.overMaximumCharactersCount,
            baseline.overMaximumCharactersCount
        )
        XCTAssertLessThanOrEqual(
            candidate.overMaximumCharactersPerSecondCount,
            baseline.overMaximumCharactersPerSecondCount
        )
        XCTAssertLessThanOrEqual(
            candidate.underMinimumDurationCount + candidate.overMaximumDurationCount,
            baseline.underMinimumDurationCount + baseline.overMaximumDurationCount
        )
        assertProductionExports(replay)
    }

    private func exportedWords(_ contents: String, webVTT: Bool) -> [String] {
        let body = webVTT ? String(contents.dropFirst("WEBVTT\n\n".count)) : contents
        return body.components(separatedBy: "\n\n").flatMap { block -> [String] in
            let lines = block.split(separator: "\n").map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains(" --> ") }),
                  timing + 1 < lines.count else { return [] }
            var text = lines[(timing + 1)...].joined(separator: " ")
            if webVTT, text.hasPrefix("<v "), let end = text.firstIndex(of: ">") {
                text.removeSubrange(text.startIndex...end)
            } else if !webVTT, text.hasPrefix("["), let end = text.firstIndex(of: "]") {
                text.removeSubrange(text.startIndex...end)
            }
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }
}
