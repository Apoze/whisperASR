import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

final class ReadableSubtitleEvidenceContractTests: XCTestCase {
    func testGOEvidenceMatchesFrozenBudgetsImplementationAndExactReplays() throws {
        let budgetsURL = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/E32-readable-cues/budgets.json"
        )
        let reportURL = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/E32-readable-cues/report.json"
        )
        let budgets = try json(at: budgetsURL)
        let report = try json(at: reportURL)

        XCTAssertEqual(number(budgets, "maximumCharactersPerLine"), 42)
        XCTAssertEqual(number(budgets, "maximumLinesPerCue"), 2)
        XCTAssertEqual(number(budgets, "minimumDurationSeconds"), 1)
        XCTAssertEqual(number(budgets, "maximumDurationSeconds"), 7)
        XCTAssertEqual(number(budgets, "maximumCharactersPerSecond"), 20)
        XCTAssertEqual(number(budgets, "minimumJapanesePauseSeconds"), 0.12)
        XCTAssertEqual(budgets["holdoutStatus"] as? String, "closed")
        XCTAssertEqual(HighQualityReadableSubtitlePolicy.product, .init(
            version: "readable-cues-v2",
            maximumCharactersPerLine: 42,
            maximumLinesPerCue: 2,
            minimumDurationSeconds: 1,
            maximumDurationSeconds: 7,
            maximumCharactersPerSecond: 20,
            minimumJapanesePauseSeconds: 0.12
        ))

        XCTAssertEqual(report["holdoutOpenedAfterBudgetFreeze"] as? Bool, true)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: budgetsURL),
            report["budgetFreezeSHA256"] as? String
        )
        XCTAssertEqual(
            report["budgetFreezePath"] as? String,
            "docs/japanese-live/experiments/evidence/E32-readable-cues/budgets.json"
        )

        let implementation = try dictionary(report, "implementation")
        let commit = try string(implementation, "commit")
        let files = try stringDictionary(implementation, "filesSHA256")
        XCTAssertEqual(Set(files.keys), Set([
            "Sources/HighQualityJob.swift",
            "Sources/HighQualityJobView.swift",
            "Sources/ReadableSubtitleReflow.swift",
            "Tests/HighQualityJobTests.swift",
            "Tests/LiveCaptionTests.swift",
            "Tests/ReadableSubtitleReflowTests.swift",
        ]))
        for (path, expectedSHA256) in files {
            XCTAssertEqual(
                try JapaneseBenchmarkSupport.sha256(at: root.appendingPathComponent(path)),
                expectedSHA256,
                path
            )
            XCTAssertEqual(digest(try git(["show", "\(commit):\(path)"])), expectedSHA256, path)
        }

        let verification = try dictionary(report, "verification")
        let contractPath = try string(verification, "contractTestPath")
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: root.appendingPathComponent(contractPath)),
            verification["contractTestSHA256"] as? String
        )
        let liveGatePath = try string(verification, "liveGatePath")
        let liveGateURL = root.appendingPathComponent(liveGatePath)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: liveGateURL),
            verification["liveGateSHA256"] as? String
        )
        let liveGate = try json(at: liveGateURL)
        XCTAssertEqual(liveGate["implementationCommit"] as? String, commit)
        XCTAssertEqual(liveGate["modelsLoaded"] as? [String], [])
        XCTAssertEqual(liveGate["testPath"] as? String, "Tests/LiveCaptionTests.swift")
        XCTAssertEqual(liveGate["testSHA256"] as? String, files["Tests/LiveCaptionTests.swift"])
        let liveResult = try dictionary(liveGate, "result")
        XCTAssertEqual(number(liveResult, "exitCode"), 0)
        XCTAssertEqual(number(liveResult, "executed"), 1)
        XCTAssertEqual(number(liveResult, "failed"), 0)
        XCTAssertEqual(number(liveResult, "skipped"), 0)
        let sourceDiff = try dictionary(liveGate, "sourceDiff")
        let baseCommit = try string(sourceDiff, "baseCommit")
        XCTAssertEqual(baseCommit, report["baseCommit"] as? String)
        let sourceDiffOutput = try git([
            "diff", "--name-only", "\(baseCommit)...\(commit)", "--", "Sources",
        ])
        let changedSources = String(decoding: sourceDiffOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(changedSources, [
            "Sources/HighQualityJob.swift",
            "Sources/HighQualityJobView.swift",
            "Sources/ReadableSubtitleReflow.swift",
        ])
        XCTAssertEqual(sourceDiff["changedSourceFiles"] as? [String], changedSources)
        XCTAssertEqual(sourceDiff["liveSourceChangedFiles"] as? [String], [])
        XCTAssertEqual(sourceDiff["outputSHA256"] as? String, digest(sourceDiffOutput))
        let gates = try dictionary(report, "gates")
        XCTAssertEqual(gates["cancellationSafe"] as? Bool, true)
        XCTAssertEqual(gates["liveUnchanged"] as? Bool, true)

        try assertSplit(
            try dictionary(report, "development"),
            inputPath: "docs/japanese-live/experiments/evidence/E31/translategemma-12b-it-4bit-qudu2fx3ncc/raw-asr.json.gz",
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
        try assertSplit(
            try dictionary(report, "holdout"),
            inputPath: "docs/japanese-live/experiments/evidence/E31/translategemma-12b-it-4bit-md62mmdz0m/raw-asr.json.gz",
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
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func assertSplit(
        _ report: [String: Any],
        inputPath: String,
        expectedBaseline: [String: Int],
        expectedCandidate: [String: Int],
        expectedSplits: Int,
        expectedUnresolved: Int
    ) throws {
        XCTAssertEqual(report["inputPath"] as? String, inputPath)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: root.appendingPathComponent(inputPath)),
            report["inputSHA256"] as? String
        )
        XCTAssertEqual(number(report, "splitSourceCueCount"), Double(expectedSplits))
        XCTAssertEqual(number(report, "unresolvedSourceCueCount"), Double(expectedUnresolved))
        let baseline = try dictionary(report, "baseline")
        let candidate = try dictionary(report, "candidate")
        XCTAssertEqual(baseline as NSDictionary, expectedBaseline as NSDictionary)
        XCTAssertEqual(candidate as NSDictionary, expectedCandidate as NSDictionary)

        let relativePath = String(inputPath.dropFirst(
            "docs/japanese-live/experiments/evidence/".count
        ))
        let replay = try replay(relativePath)
        XCTAssertEqual(baseline as NSDictionary, metrics(replay.evidence.baseline) as NSDictionary)
        XCTAssertEqual(candidate as NSDictionary, metrics(replay.evidence.candidate) as NSDictionary)
        XCTAssertEqual(replay.evidence.splitSourceCueCount, expectedSplits)
        XCTAssertEqual(replay.evidence.unresolvedSourceCueCount, expectedUnresolved)
    }

    private func metrics(_ value: HighQualityReadableSubtitleMetrics) -> [String: Int] {
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

    private func replay(_ relativePath: String) throws -> HighQualityReadableSubtitleResult {
        let path = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/\(relativePath)"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", path.path]
        process.standardOutput = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(HighQualityRawEvidence.self, from: data)
        let alignment = try XCTUnwrap(raw.alignment)
        let translation = try XCTUnwrap(raw.translation)
        let outputs = Dictionary(uniqueKeysWithValues: translation.integrityVerdicts.map {
            ($0.cueID, $0.generatedOutput)
        })
        let units = try XCTUnwrap(alignment.semanticUnits)
        let fragments = try XCTUnwrap(alignment.semanticFragments)
        XCTAssertEqual(Set(outputs.keys), Set(units.map(\.id)))
        return try HighQualityReadableSubtitleReflow.apply(
            to: units.map { unit in
                HighQualitySubtitleCue(
                    id: unit.id,
                    start: unit.start,
                    end: unit.end,
                    text: outputs[unit.id]!,
                    speakerLabel: unit.speakerLabel
                )
            },
            units: units,
            fragments: fragments
        )
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

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
