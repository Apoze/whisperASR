import Foundation
import XCTest
@testable import WhisperASRApp

final class LocalBenchmarkTelemetryTests: XCTestCase {
    func testQwenMetricsClassifyPreviewAndFinalWork() async throws {
        var metric = LocalCaptionMetric(
            kind: .preview,
            engine: LocalEnglishEngine.qwenPseudoLiveApple.rawValue,
            boundaryKind: nil,
            rangeStart: 4_000,
            rangeEnd: 36_000,
            speechEnd: 36_000,
            endpointDetectedAt: -1,
            vadOnlyEndpointAt: -1,
            queueMilliseconds: 10,
            asrMilliseconds: 120,
            translationMilliseconds: 45,
            renderedUptimeNanoseconds: 1_000,
            sourceText: "こんにちは。",
            englishText: "Hello.",
            revision: 2,
            previewLatencyMilliseconds: 2_000,
            speechEndToRenderedMilliseconds: 300,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: 100,
            translationStartedUptimeNanoseconds: 200,
            translationCompletedUptimeNanoseconds: 300
        )
        metric.previewGeneration = 7
        metric.coalescedPreviewTicks = 2
        metric.stalePreviewResults = 1

        let final = LocalCaptionMetric(
            kind: .final,
            engine: LocalEnglishEngine.qwenPseudoLiveApple.rawValue,
            boundaryKind: "pause",
            rangeStart: 4_000,
            rangeEnd: 40_000,
            speechEnd: 39_000,
            endpointDetectedAt: 40_000,
            vadOnlyEndpointAt: 40_000,
            queueMilliseconds: 5,
            asrMilliseconds: 200,
            translationMilliseconds: 80,
            renderedUptimeNanoseconds: 2_000,
            sourceText: "こんにちは。",
            englishText: "Hello.",
            revision: nil,
            previewLatencyMilliseconds: nil,
            firstLexicalUptimeNanoseconds: nil,
            sourceEligibleUptimeNanoseconds: nil,
            translationStartedUptimeNanoseconds: 400,
            translationCompletedUptimeNanoseconds: 480
        )
        let recorder = LocalCaptionMetricRecorder(enabled: true)
        await recorder.append(metric)
        await recorder.append(final)
        let classified = await recorder.snapshot()

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(classified[0]))
                as? [String: Any]
        )
        XCTAssertEqual(json["kind"] as? String, "preview")
        XCTAssertEqual(json["asrMilliseconds"] as? Double, 120)
        XCTAssertEqual(json["translationMilliseconds"] as? Double, 45)
        XCTAssertEqual(json["speechEndToRenderedMilliseconds"] as? Double, 300)
        XCTAssertEqual(json["previewGeneration"] as? Int, 7)
        XCTAssertEqual(json["rangeStart"] as? Int, 4_000)
        XCTAssertEqual(json["rangeEnd"] as? Int, 36_000)
        XCTAssertEqual(json["coalescedPreviewTicks"] as? Int, 2)
        XCTAssertEqual(json["stalePreviewResults"] as? Int, 1)
        XCTAssertEqual(json["qwenPreviewASRMilliseconds"] as? Double, 120)
        XCTAssertEqual(json["qwenPreviewTranslationMilliseconds"] as? Double, 45)
        XCTAssertEqual(json["qwenPreviewAgeMilliseconds"] as? Double, 300)
        XCTAssertEqual(classified[1].qwenFinalASRMilliseconds, 200)
        XCTAssertEqual(classified[1].qwenFinalTranslationMilliseconds, 80)
        XCTAssertNil(classified[1].qwenPreviewASRMilliseconds)
    }

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
        await recorder.appendVoxtralSession(LocalVoxtralSessionMetric(
            startSample: 0,
            targetSample: 16_000,
            endSample: 16_000,
            lastSpeechEndSample: 15_000,
            helperProcessIdentifier: 42,
            acknowledgedThroughSample: 16_000,
            endingBacklogSamples: 0,
            captureBacklogAfterFlushSamples: 0,
            flushMilliseconds: 12,
            captureEnded: false,
            transcriptCharacterCount: 6
        ))
        await recorder.markLastVoxtralSessionCaptureEnded()

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
                ),
                qwenPseudoLiveCadenceSeconds: 2
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
        XCTAssertTrue(csv.contains("qwen_preview_asr_ms"))
        XCTAssertTrue(csv.contains("qwen_final_translation_ms"))
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
        let voxtralSessions = try XCTUnwrap(
            json["voxtralSessions"] as? [[String: Any]]
        )
        XCTAssertEqual(voxtralSessions.first?["endSample"] as? Int, 16_000)
        XCTAssertEqual(voxtralSessions.first?["captureEnded"] as? Bool, true)
        XCTAssertNil(voxtralSessions.first?["targetSample"])
        XCTAssertEqual(
            voxtralSessions.first?["lastSpeechEndSample"] as? Int,
            15_000
        )
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
        XCTAssertEqual(summary["qwenPseudoLiveCadenceSeconds"] as? Int, 2)
    }
}
