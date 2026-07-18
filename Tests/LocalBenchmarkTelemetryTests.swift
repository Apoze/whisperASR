import Foundation
import XCTest
@testable import WhisperASRApp

final class LocalBenchmarkTelemetryTests: XCTestCase {
    func testOptInReportKeepsMetricsAudioAndSessionProvenanceTogether() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pcm = root.appendingPathComponent("capture.wav")
        try Data("canonical-pcm".utf8).write(to: pcm)

        let recorder = LocalCaptionMetricRecorder(enabled: true)
        await recorder.reset()
        await recorder.append(LocalCaptionMetric(
            kind: .final,
            engine: "voxtralApple",
            boundaryKind: "pause",
            rangeStart: 0,
            rangeEnd: 16_000,
            speechEnd: 15_000,
            endpointDetectedAt: 16_000,
            vadOnlyEndpointAt: 16_000,
            queueMilliseconds: 1,
            asrMilliseconds: 2,
            translationMilliseconds: 3,
            renderedUptimeNanoseconds: 4,
            sourceText: "こんにちは。",
            englishText: "Hello.",
            revision: nil,
            previewLatencyMilliseconds: nil,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: nil,
            translationStartedUptimeNanoseconds: nil,
            translationCompletedUptimeNanoseconds: nil
        ))
        await recorder.observe(
            combinedResidentBytes: 4_000,
            helperBacklogSamples: 320,
            helperProcessIdentifier: 42
        )

        let sessionID = UUID()
        let stem = LocalBenchmarkOutput.stem(
            sessionID: sessionID,
            date: Date(timeIntervalSince1970: 0)
        )
        let metricsURL = try await recorder.writeOptInReport(
            stem: stem,
            canonicalPCMURL: pcm,
            summary: LocalCaptionBenchmarkSummary(
                sessionID: sessionID,
                engine: "voxtralApple",
                translationMode: "adaptive",
                finalSampleCount: 16_000,
                pcmComplete: true,
                m4aDroppedSampleCount: 0,
                helperSentThrough: 16_000,
                helperAcknowledgedThrough: 16_000,
                endingHelperBacklogSamples: 0,
                sourceStagedThrough: 16_000,
                englishValidatedThrough: 16_000,
                committedSampleCount: 16_000
            ),
            outputDirectory: root
        )
        let metrics = try XCTUnwrap(metricsURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: metrics.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(stem)-metrics.csv").path
        ))
        let sessionURL = root.appendingPathComponent("\(stem)-session.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL))
                as? [String: Any]
        )
        XCTAssertEqual(json["helperProcessIdentifier"] as? Int, 42)
        XCTAssertEqual(json["maximumCombinedResidentBytes"] as? Int, 4_000)
        XCTAssertEqual(json["maximumHelperBacklogSamples"] as? Int, 320)
        XCTAssertFalse((json["applicationExecutableSHA256"] as? String ?? "").isEmpty)
        XCTAssertEqual(json["canonicalPCMFile"] as? String, pcm.lastPathComponent)
        XCTAssertEqual(
            json["metricsSHA256"] as? String,
            try LocalBenchmarkOutput.sha256(metrics)
        )
        XCTAssertEqual(
            json["canonicalPCMSHA256"] as? String,
            try LocalBenchmarkOutput.sha256(pcm)
        )
        let summary = try XCTUnwrap(json["summary"] as? [String: Any])
        XCTAssertEqual(summary["finalSampleCount"] as? Int, 16_000)
        XCTAssertEqual(summary["pcmComplete"] as? Bool, true)
        XCTAssertEqual(summary["helperAcknowledgedThrough"] as? Int, 16_000)
    }
}
