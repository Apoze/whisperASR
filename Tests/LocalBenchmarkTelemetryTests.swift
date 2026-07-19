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
        var metric = LocalCaptionMetric(
            kind: .final,
            engine: "voxtralApple",
            boundaryKind: "pause",
            boundaryDegradation: "degradedForcedBoundary",
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
            speechEndToRenderedMilliseconds: 1.5,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: nil,
            translationStartedUptimeNanoseconds: nil,
            translationCompletedUptimeNanoseconds: nil
        )
        metric.finalSegmentIndex = 0
        await recorder.append(metric)
        await recorder.observe(
            combinedResidentBytes: 4_000,
            helperBacklogSamples: 320,
            helperProcessIdentifier: 42,
            endpointFIFOCount: 2
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
                committedSampleCount: 16_000,
                sourceFinalizedThrough: 16_000,
                captureTiming: AudioCaptureTiming(
                    firstPresentationSample48k: 0,
                    lastPresentationEndSample48k: 48_000,
                    firstPresentationUptimeNanoseconds: 1,
                    firstBufferUptimeNanoseconds: 1,
                    callbackCount: 100,
                    invalidPresentationTimestampCount: 0,
                    gapCount: 0,
                    gapSampleCount48k: 0,
                    overlapCount: 0,
                    overlapSampleCount48k: 0,
                    restartCount: 0
                )
            ),
            whisperModelSelection: LocalWhisperModelSelection(
                candidate: "turbo",
                modelID: "large-v3-turbo",
                revision: "revision",
                displayName: "Turbo",
                fileURL: pcm,
                expectedSHA256: "model-sha"
            ),
            voxtralConfiguration: .init(model: .q6, delay: .milliseconds1200),
            japaneseGlossary: JapaneseGlossary(entries: [
                .init(recognized: "配給", canonical: "ハイキュー"),
            ]),
            outputDirectory: root
        )
        let metrics = try XCTUnwrap(metricsURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: metrics.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(stem)-metrics.csv").path
        ))
        let metricJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metrics))
                as? [[String: Any]]
        )
        XCTAssertEqual(
            metricJSON.first?["boundaryDegradation"] as? String,
            "degradedForcedBoundary"
        )
        XCTAssertEqual(metricJSON.first?["finalSegmentIndex"] as? Int, 0)
        let csv = try String(
            contentsOf: root.appendingPathComponent("\(stem)-metrics.csv"),
            encoding: .utf8
        )
        XCTAssertTrue(csv.contains("boundary_degradation"))
        XCTAssertTrue(csv.contains("final_segment_index"))
        XCTAssertTrue(csv.contains("degradedForcedBoundary"))
        let sessionURL = root.appendingPathComponent("\(stem)-session.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL))
                as? [String: Any]
        )
        XCTAssertEqual(json["helperProcessIdentifier"] as? Int, 42)
        XCTAssertEqual(json["maximumCombinedResidentBytes"] as? Int, 4_000)
        XCTAssertEqual(json["maximumHelperBacklogSamples"] as? Int, 320)
        XCTAssertEqual(json["maximumEndpointFIFOCount"] as? Int, 2)
        XCTAssertEqual(json["whisperCandidate"] as? String, "turbo")
        XCTAssertEqual(json["whisperModelSHA256"] as? String, "model-sha")
        XCTAssertEqual(json["voxtralModelID"] as? String, VoxtralModelVariant.q6.modelID)
        XCTAssertEqual(json["voxtralDelayMilliseconds"] as? Int, 1_200)
        XCTAssertFalse((json["japaneseGlossarySHA256"] as? String ?? "").isEmpty)
        XCTAssertEqual(
            json["voxtralConversionSourceRevision"] as? String,
            VoxtralModelVariant.q6.conversionSource?.revision
        )
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
