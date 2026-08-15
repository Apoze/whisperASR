import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

final class ReadableSubtitleEvidenceContractTests: XCTestCase {
    func testEvidenceSchemasChronologyLogsAndReplaysAreExact() throws {
        let budgetsURL = evidenceURL("budgets.json")
        let developmentURL = evidenceURL("development.json")
        let reportURL = evidenceURL("report.json")
        let budgets = try json(at: budgetsURL)
        let development = try json(at: developmentURL)
        let report = try json(at: reportURL)

        assertKeys(budgets, [
            "schemaVersion", "ticket", "experiment", "chronology", "split",
            "freezeKind", "createdAtUTC", "implementationCommit", "sourceCorpus",
            "sourceArtifact", "sourceArtifactSHA256", "maximumCharactersPerLine",
            "maximumLinesPerCue", "minimumDurationSeconds", "maximumDurationSeconds",
            "maximumCharactersPerSecond", "minimumJapanesePauseSeconds",
            "boundaryEvidence", "timingPolicy", "textPolicy", "fallbackPolicy",
            "developmentGate", "historicalHoldoutWasAlreadyKnown", "chronologyClaim",
            "holdoutReplayStatus",
        ])
        XCTAssertEqual(number(budgets, "schemaVersion"), 2)
        XCTAssertEqual(number(budgets, "ticket"), 120)
        XCTAssertEqual(budgets["experiment"] as? String, "readable-cues-v2")
        XCTAssertEqual(budgets["chronology"] as? String, "prospective-revalidation-2026-08-15")
        XCTAssertEqual(budgets["split"] as? String, "development")
        XCTAssertEqual(budgets["freezeKind"] as? String, "prospective-revalidation")
        XCTAssertEqual(budgets["createdAtUTC"] as? String, "2026-08-15T15:46:15Z")
        XCTAssertEqual(budgets["sourceCorpus"] as? String, "qudu2fx3ncc")
        XCTAssertEqual(
            budgets["sourceArtifact"] as? String,
            "docs/japanese-live/experiments/evidence/E31/"
                + "translategemma-12b-it-4bit-qudu2fx3ncc/raw-asr.json.gz"
        )
        XCTAssertEqual(
            budgets["sourceArtifactSHA256"] as? String,
            "bd0c6dcac367851d5ff13057b424fdff3bdde3b27077117fa2b4c7e6b1ec9a1a"
        )
        XCTAssertEqual(number(budgets, "maximumCharactersPerLine"), 42)
        XCTAssertEqual(number(budgets, "maximumLinesPerCue"), 2)
        XCTAssertEqual(number(budgets, "minimumDurationSeconds"), 1)
        XCTAssertEqual(number(budgets, "maximumDurationSeconds"), 7)
        XCTAssertEqual(number(budgets, "maximumCharactersPerSecond"), 20)
        XCTAssertEqual(number(budgets, "minimumJapanesePauseSeconds"), 0.12)
        XCTAssertEqual(budgets["boundaryEvidence"] as? [String], [
            "Japanese pause", "Japanese punctuation", "source cue change",
        ])
        XCTAssertNotNil(budgets["timingPolicy"] as? String)
        XCTAssertNotNil(budgets["textPolicy"] as? String)
        XCTAssertNotNil(budgets["fallbackPolicy"] as? String)
        XCTAssertNotNil(budgets["developmentGate"] as? String)
        XCTAssertEqual(budgets["historicalHoldoutWasAlreadyKnown"] as? Bool, true)
        XCTAssertEqual(
            budgets["chronologyClaim"] as? String,
            "This freeze starts a new exact replay chronology. It does not claim that the "
                + "historically opened holdout is blind or prove the earlier chronology "
                + "retroactively."
        )
        XCTAssertEqual(
            budgets["holdoutReplayStatus"] as? String,
            "not-run-in-this-chronology"
        )
        XCTAssertEqual(HighQualityReadableSubtitlePolicy.product, .init(
            version: "readable-cues-v2",
            maximumCharactersPerLine: 42,
            maximumLinesPerCue: 2,
            minimumDurationSeconds: 1,
            maximumDurationSeconds: 7,
            maximumCharactersPerSecond: 20,
            minimumJapanesePauseSeconds: 0.12
        ))

        assertKeys(development, [
            "schemaVersion", "ticket", "experiment", "chronology", "evaluationKind",
            "executedAtUTC", "executedCommit", "budgetPath", "command", "input",
            "implementationFilesSHA256", "harnessFilesSHA256", "result", "metrics",
            "gates", "modelsLoaded",
        ])
        XCTAssertEqual(number(development, "schemaVersion"), 1)
        XCTAssertEqual(number(development, "ticket"), 120)
        XCTAssertEqual(development["experiment"] as? String, "readable-cues-v2")
        XCTAssertEqual(
            development["chronology"] as? String,
            budgets["chronology"] as? String
        )
        XCTAssertEqual(development["evaluationKind"] as? String, "development")
        XCTAssertEqual(development["executedAtUTC"] as? String, "2026-08-15T15:46:09Z")
        XCTAssertEqual(development["modelsLoaded"] as? [String], [])
        XCTAssertEqual(
            development["budgetPath"] as? String,
            "docs/japanese-live/experiments/evidence/E32-readable-cues/budgets.json"
        )
        XCTAssertTrue((development["command"] as? String)?.contains(
            "testFrozenDevelopmentReplayImprovesReadabilityWithoutRegression"
        ) == true)
        let developmentInput = try dictionary(development, "input")
        assertKeys(developmentInput, ["corpus", "path", "sha256"])
        XCTAssertEqual(developmentInput["corpus"] as? String, "qudu2fx3ncc")
        let developmentResult = try dictionary(development, "result")
        assertResult(developmentResult, testSeconds: 0.411, wallSeconds: 10.27)
        assertBooleanMap(try dictionary(development, "gates"), [
            "readableGain", "noMetricRegression", "exactNormalizedEnglishIdentity",
            "exactWordOrder", "exactTimingCoverage", "exactInterCueGaps",
            "speakerMetadataPreserved", "noNewOverlap", "srtVttTimestampsIdentical",
        ])

        assertKeys(report, [
            "schemaVersion", "ticket", "decision", "claimScope", "baseCommit",
            "implementationCommit", "freeze", "holdout", "implementationFilesSHA256",
            "verificationFilesSHA256", "liveGatePath", "liveGateSHA256",
            "translatorSpeakerMatrix", "gates", "modelsLoaded", "routing",
        ])
        XCTAssertEqual(number(report, "schemaVersion"), 2)
        XCTAssertEqual(number(report, "ticket"), 120)
        XCTAssertEqual(report["decision"] as? String, "GO-beta")
        XCTAssertEqual(
            report["claimScope"] as? String,
            "Prospective exact-replay revalidation after a fresh DEV freeze; the historical "
                + "holdout result was already known, so this is not a blind-holdout claim."
        )
        XCTAssertEqual(report["modelsLoaded"] as? [String], [])

        let freeze = try dictionary(report, "freeze")
        assertKeys(freeze, [
            "commit", "parentCommit", "budgetsPath", "budgetsSHA256",
            "developmentPath", "developmentSHA256", "changedFiles",
        ])
        let freezeCommit = try string(freeze, "commit")
        let parentCommit = try string(freeze, "parentCommit")
        XCTAssertEqual(freezeCommit, "c44df8420e830f8014473b9e6135969c8439ceea")
        XCTAssertEqual(parentCommit, "6f74780974264d08ad4382ce5c94ab44a7ea85f1")
        XCTAssertEqual(report["implementationCommit"] as? String, parentCommit)
        XCTAssertEqual(budgets["implementationCommit"] as? String, parentCommit)
        XCTAssertEqual(development["executedCommit"] as? String, parentCommit)
        XCTAssertEqual(trimmed(try git(["rev-parse", "\(freezeCommit)^"])), parentCommit)
        _ = try git(["merge-base", "--is-ancestor", freezeCommit, "HEAD"])

        let frozenPaths = [
            "docs/japanese-live/experiments/evidence/E32-readable-cues/budgets.json",
            "docs/japanese-live/experiments/evidence/E32-readable-cues/development.json",
        ]
        XCTAssertEqual(Set(freeze["changedFiles"] as? [String] ?? []), Set(frozenPaths))
        let committedPaths = lines(try git([
            "diff-tree", "--no-commit-id", "--name-only", "-r", freezeCommit,
        ]))
        XCTAssertEqual(Set(committedPaths), Set(frozenPaths))
        XCTAssertEqual(committedPaths.count, 2)
        try assertFrozenFile(
            url: budgetsURL,
            path: frozenPaths[0],
            sha256: try string(freeze, "budgetsSHA256"),
            commit: freezeCommit
        )
        try assertFrozenFile(
            url: developmentURL,
            path: frozenPaths[1],
            sha256: try string(freeze, "developmentSHA256"),
            commit: freezeCommit
        )

        let implementationFiles = try stringDictionary(report, "implementationFilesSHA256")
        XCTAssertEqual(Set(implementationFiles.keys), Set([
            "Sources/HighQualityJob.swift",
            "Sources/HighQualityJobView.swift",
            "Sources/ReadableSubtitleReflow.swift",
            "Tests/HighQualityJobTests.swift",
            "Tests/LiveCaptionTests.swift",
        ]))
        try assertFiles(implementationFiles, commit: parentCommit, current: true)
        XCTAssertEqual(
            try stringDictionary(development, "implementationFilesSHA256")
                .filter { $0.key != "Tests/LiveCaptionTests.swift" },
            implementationFiles.filter { $0.key != "Tests/LiveCaptionTests.swift" }
        )
        try assertFiles(
            try stringDictionary(development, "harnessFilesSHA256"),
            commit: parentCommit,
            current: false
        )

        let verificationFiles = try stringDictionary(report, "verificationFilesSHA256")
        XCTAssertEqual(Set(verificationFiles.keys), Set([
            "Tests/ReadableSubtitleEvidenceContractTests.swift",
            "Tests/ReadableSubtitleReflowTests.swift",
            "Tests/ReadableSubtitleReplaySupport.swift",
        ]))
        try assertFiles(verificationFiles, commit: nil, current: true)

        let developmentMetrics = try dictionary(development, "metrics")
        try assertReplay(
            metrics: developmentMetrics,
            input: developmentInput,
            expectedBaseline: [
                "cueCount": 307, "readableCueCount": 119, "over84Characters": 37,
                "over20CPS": 156, "under1Second": 74, "over7Seconds": 11,
                "gapCount": 165, "overlapCount": 0,
            ],
            expectedCandidate: [
                "cueCount": 318, "readableCueCount": 141, "over84Characters": 29,
                "over20CPS": 156, "under1Second": 74, "over7Seconds": 3,
                "gapCount": 165, "overlapCount": 0,
            ],
            expectedSplits: 11,
            expectedUnresolved: 177
        )

        let holdout = try dictionary(report, "holdout")
        assertKeys(holdout, [
            "replayedAfterFreeze", "blind", "historicalResultWasKnown", "executedAtUTC",
            "executedCommit", "command", "input", "result", "metrics", "log",
        ])
        XCTAssertEqual(holdout["replayedAfterFreeze"] as? Bool, true)
        XCTAssertEqual(holdout["blind"] as? Bool, false)
        XCTAssertEqual(holdout["historicalResultWasKnown"] as? Bool, true)
        XCTAssertEqual(holdout["executedAtUTC"] as? String, "2026-08-15T15:47:49Z")
        XCTAssertEqual(holdout["executedCommit"] as? String, freezeCommit)
        XCTAssertTrue((holdout["command"] as? String)?.contains(
            "testFrozenHoldoutReplayImprovesReadabilityWithoutRegression"
        ) == true)
        let holdoutResult = try dictionary(holdout, "result")
        assertResult(holdoutResult, testSeconds: 0.624, wallSeconds: 2.15)
        let holdoutInput = try dictionary(holdout, "input")
        assertKeys(holdoutInput, ["corpus", "path", "sha256"])
        XCTAssertEqual(holdoutInput["corpus"] as? String, "md62mmdz0m")
        try assertReplay(
            metrics: try dictionary(holdout, "metrics"),
            input: holdoutInput,
            expectedBaseline: [
                "cueCount": 260, "readableCueCount": 97, "over84Characters": 41,
                "over20CPS": 129, "under1Second": 65, "over7Seconds": 17,
                "gapCount": 168, "overlapCount": 0,
            ],
            expectedCandidate: [
                "cueCount": 286, "readableCueCount": 146, "over84Characters": 21,
                "over20CPS": 129, "under1Second": 65, "over7Seconds": 2,
                "gapCount": 168, "overlapCount": 0,
            ],
            expectedSplits: 23,
            expectedUnresolved: 140
        )
        try assertLog(
            try dictionary(holdout, "log"),
            containing: [
                "testFrozenHoldoutReplayImprovesReadabilityWithoutRegression",
                "Executed 1 test, with 0 failures",
                "READABLE_SUBTITLE_HOLDOUT: cues 260->286",
            ]
        )

        let formatter = ISO8601DateFormatter()
        let freezeDate = try XCTUnwrap(formatter.date(from: trimmed(try git([
            "show", "-s", "--format=%cI", freezeCommit,
        ]))))
        let developmentDate = try XCTUnwrap(formatter.date(
            from: try string(development, "executedAtUTC")
        ))
        let holdoutDate = try XCTUnwrap(formatter.date(from: try string(holdout, "executedAtUTC")))
        XCTAssertLessThan(developmentDate, freezeDate)
        XCTAssertGreaterThan(holdoutDate, freezeDate)

        let liveGatePath = try string(report, "liveGatePath")
        let liveGateURL = root.appendingPathComponent(liveGatePath)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: liveGateURL),
            report["liveGateSHA256"] as? String
        )
        let liveGate = try json(at: liveGateURL)
        assertKeys(liveGate, [
            "schemaVersion", "ticket", "freezeCommit", "evaluatedCommit", "command",
            "executedAtUTC", "result", "test", "log", "sourceDiff", "modelsLoaded",
        ])
        XCTAssertEqual(number(liveGate, "schemaVersion"), 2)
        XCTAssertEqual(number(liveGate, "ticket"), 120)
        XCTAssertEqual(liveGate["freezeCommit"] as? String, freezeCommit)
        XCTAssertEqual(liveGate["evaluatedCommit"] as? String, freezeCommit)
        XCTAssertEqual(liveGate["executedAtUTC"] as? String, "2026-08-15T15:47:57Z")
        XCTAssertEqual(liveGate["modelsLoaded"] as? [String], [])
        XCTAssertTrue((liveGate["command"] as? String)?.contains(
            "testReadableSubtitleBetaOptionIsOfflineOnlyAndLeavesLiveDefaults"
        ) == true)
        assertResult(try dictionary(liveGate, "result"), testSeconds: 0.005, wallSeconds: 1.50)
        let liveTest = try dictionary(liveGate, "test")
        assertKeys(liveTest, ["path", "sha256"])
        XCTAssertEqual(liveTest["path"] as? String, "Tests/LiveCaptionTests.swift")
        XCTAssertEqual(liveTest["sha256"] as? String, implementationFiles["Tests/LiveCaptionTests.swift"])
        try assertLog(
            try dictionary(liveGate, "log"),
            containing: [
                "testReadableSubtitleBetaOptionIsOfflineOnlyAndLeavesLiveDefaults",
                "Executed 1 test, with 0 failures",
            ]
        )

        let sourceDiff = try dictionary(liveGate, "sourceDiff")
        assertKeys(sourceDiff, [
            "baseCommit", "evaluatedCommit", "command", "changedSourceFiles",
            "liveSourceChangedFiles", "outputSHA256",
        ])
        let baseCommit = try string(sourceDiff, "baseCommit")
        XCTAssertEqual(baseCommit, report["baseCommit"] as? String)
        XCTAssertEqual(sourceDiff["evaluatedCommit"] as? String, freezeCommit)
        let sourceDiffOutput = try git([
            "diff", "--name-only", "\(baseCommit)...\(freezeCommit)", "--", "Sources",
        ])
        let changedSources = lines(sourceDiffOutput)
        XCTAssertEqual(changedSources, [
            "Sources/HighQualityJob.swift",
            "Sources/HighQualityJobView.swift",
            "Sources/ReadableSubtitleReflow.swift",
        ])
        XCTAssertEqual(sourceDiff["changedSourceFiles"] as? [String], changedSources)
        XCTAssertEqual(sourceDiff["liveSourceChangedFiles"] as? [String], [])
        XCTAssertEqual(sourceDiff["outputSHA256"] as? String, digest(sourceDiffOutput))

        let matrix = try dictionary(report, "translatorSpeakerMatrix")
        assertKeys(matrix, ["12B", "4B"])
        let matrixPaths = [
            "12B": [
                "development": "docs/japanese-live/experiments/evidence/E31/"
                    + "translategemma-12b-it-4bit-qudu2fx3ncc/raw-asr.json.gz",
                "holdout": "docs/japanese-live/experiments/evidence/E31/"
                    + "translategemma-12b-it-4bit-md62mmdz0m/raw-asr.json.gz",
            ],
            "4B": [
                "development": "docs/japanese-live/experiments/evidence/"
                    + "E31-translation-only-4b/"
                    + "translategemma-4b-it-4bit-qudu2fx3ncc/raw-asr.json.gz",
                "holdout": "docs/japanese-live/experiments/evidence/"
                    + "E31-translation-only-4b/"
                    + "translategemma-4b-it-4bit-md62mmdz0m/raw-asr.json.gz",
            ],
        ]
        for translator in ["12B", "4B"] {
            let splits = try dictionary(matrix, translator)
            assertKeys(splits, ["development", "holdout"])
            for split in ["development", "holdout"] {
                let cell = try dictionary(splits, split)
                assertKeys(cell, ["inputPath", "inputSHA256", "speakerOn", "speakerOff"])
                let inputPath = try XCTUnwrap(matrixPaths[translator]?[split])
                XCTAssertEqual(cell["inputPath"] as? String, inputPath)
                XCTAssertEqual(
                    try JapaneseBenchmarkSupport.sha256(
                        at: root.appendingPathComponent(inputPath)
                    ),
                    cell["inputSHA256"] as? String
                )
                XCTAssertEqual(cell["speakerOn"] as? Bool, true)
                XCTAssertEqual(cell["speakerOff"] as? Bool, true)
            }
        }
        assertBooleanMap(try dictionary(report, "gates"), [
            "developmentReadableGain", "holdoutReadableGain",
            "exactNormalizedEnglishIdentity", "exactWordOrder", "exactTimingCoverage",
            "exactInterCueGaps", "speakerMatrixPassed", "speakerMetadataPreserved",
            "noNewOverlap", "noMetricRegression", "srtVttTimestampsIdentical",
            "cancellationSafe", "lastValidResultPreserved", "liveUnchanged", "defaultOff",
        ])
        assertKeys(try dictionary(report, "routing"), ["infra", "harness", "candidate"])
    }

    private let evidenceDirectory =
        "docs/japanese-live/experiments/evidence/E32-readable-cues"

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func evidenceURL(_ name: String) -> URL {
        root.appendingPathComponent("\(evidenceDirectory)/\(name)")
    }

    private func assertReplay(
        metrics reported: [String: Any],
        input: [String: Any],
        expectedBaseline: [String: Int],
        expectedCandidate: [String: Int],
        expectedSplits: Int,
        expectedUnresolved: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        assertKeys(reported, [
            "splitSourceCueCount", "unresolvedSourceCueCount", "baseline", "candidate",
        ], file: file, line: line)
        let baseline = try dictionary(reported, "baseline")
        let candidate = try dictionary(reported, "candidate")
        assertKeys(baseline, Array(expectedBaseline.keys), file: file, line: line)
        assertKeys(candidate, Array(expectedCandidate.keys), file: file, line: line)
        XCTAssertEqual(baseline as NSDictionary, expectedBaseline as NSDictionary, file: file, line: line)
        XCTAssertEqual(candidate as NSDictionary, expectedCandidate as NSDictionary, file: file, line: line)
        XCTAssertEqual(number(reported, "splitSourceCueCount"), Double(expectedSplits), file: file, line: line)
        XCTAssertEqual(number(reported, "unresolvedSourceCueCount"), Double(expectedUnresolved), file: file, line: line)

        let inputPath = try string(input, "path")
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: root.appendingPathComponent(inputPath)),
            input["sha256"] as? String,
            file: file,
            line: line
        )
        let prefix = "docs/japanese-live/experiments/evidence/"
        XCTAssertTrue(inputPath.hasPrefix(prefix), file: file, line: line)
        let replay = try ReadableSubtitleReplaySupport.replay(String(inputPath.dropFirst(prefix.count)))
        XCTAssertEqual(baseline as NSDictionary, metricDictionary(replay.evidence.baseline) as NSDictionary, file: file, line: line)
        XCTAssertEqual(candidate as NSDictionary, metricDictionary(replay.evidence.candidate) as NSDictionary, file: file, line: line)
        XCTAssertEqual(replay.evidence.splitSourceCueCount, expectedSplits, file: file, line: line)
        XCTAssertEqual(replay.evidence.unresolvedSourceCueCount, expectedUnresolved, file: file, line: line)
    }

    private func assertResult(
        _ result: [String: Any],
        testSeconds: Double,
        wallSeconds: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertKeys(result, [
            "exitCode", "executed", "failed", "skipped", "testSeconds", "wallSeconds",
        ], file: file, line: line)
        XCTAssertEqual(number(result, "exitCode"), 0, file: file, line: line)
        XCTAssertEqual(number(result, "executed"), 1, file: file, line: line)
        XCTAssertEqual(number(result, "failed"), 0, file: file, line: line)
        XCTAssertEqual(number(result, "skipped"), 0, file: file, line: line)
        XCTAssertEqual(number(result, "testSeconds"), testSeconds, file: file, line: line)
        XCTAssertEqual(number(result, "wallSeconds"), wallSeconds, file: file, line: line)
    }

    private func assertBooleanMap(
        _ object: [String: Any],
        _ keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertKeys(object, keys, file: file, line: line)
        for key in keys {
            XCTAssertEqual(object[key] as? Bool, true, key, file: file, line: line)
        }
    }

    private func assertFrozenFile(
        url: URL,
        path: String,
        sha256: String,
        commit: String
    ) throws {
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: url), sha256, path)
        XCTAssertEqual(digest(try git(["show", "\(commit):\(path)"])), sha256, path)
    }

    private func assertFiles(
        _ files: [String: String],
        commit: String?,
        current: Bool
    ) throws {
        for (path, sha256) in files {
            if current {
                XCTAssertEqual(
                    try JapaneseBenchmarkSupport.sha256(at: root.appendingPathComponent(path)),
                    sha256,
                    path
                )
            }
            if let commit {
                XCTAssertEqual(digest(try git(["show", "\(commit):\(path)"])), sha256, path)
            }
        }
    }

    private func assertLog(
        _ log: [String: Any],
        containing fragments: [String]
    ) throws {
        assertKeys(log, ["path", "sha256"])
        let path = try string(log, "path")
        let url = root.appendingPathComponent(path)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: url),
            log["sha256"] as? String
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        for fragment in fragments { XCTAssertTrue(contents.contains(fragment), fragment) }
    }

    private func assertKeys(
        _ object: [String: Any],
        _ keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(object.keys), Set(keys), file: file, line: line)
    }

    private func metricDictionary(
        _ value: HighQualityReadableSubtitleMetrics
    ) -> [String: Int] {
        [
            "cueCount": value.cueCount,
            "readableCueCount": value.readableCueCount,
            "over84Characters": value.overMaximumCharactersCount,
            "over20CPS": value.overMaximumCharactersPerSecondCount,
            "under1Second": value.underMinimumDurationCount,
            "over7Seconds": value.overMaximumDurationCount,
            "gapCount": value.gapCount,
            "overlapCount": value.overlapCount,
        ]
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any], key)
    }

    private func stringDictionary(
        _ object: [String: Any],
        _ key: String
    ) throws -> [String: String] {
        try XCTUnwrap(object[key] as? [String: String], key)
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func number(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    private func git(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return data
    }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
