import Foundation
import XCTest
@testable import WhisperASRApp

final class LocalPrototypeBenchmarkTests: XCTestCase {
    func testExportBenchmarkClipWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["WHISPERASR_EXPORT_CLIP_SOURCE"],
              let outputPath = environment["WHISPERASR_EXPORT_CLIP_OUTPUT"],
              let startText = environment["WHISPERASR_EXPORT_CLIP_START_SAMPLE"],
              let startSample = Int(startText),
              let countText = environment["WHISPERASR_EXPORT_CLIP_SAMPLE_COUNT"],
              let sampleCount = Int(countText) else {
            throw XCTSkip("Set the WHISPERASR_EXPORT_CLIP_* variables to export a canonical clip.")
        }

        let samples = try await AudioLoader.loadSamples(
            url: URL(fileURLWithPath: sourcePath)
        )
        let endSample = startSample + sampleCount
        guard startSample >= 0, sampleCount > 0, endSample <= samples.count else {
            XCTFail("Requested [\(startSample), \(endSample)) outside 0..<\(samples.count).")
            return
        }

        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PCM16WAV.data(samples: Array(samples[startSample..<endSample])).write(
            to: output,
            options: .atomic
        )
        XCTAssertEqual(sampleCount, 40 * LocalEndpointPlanner.sampleRate)
    }

    private struct DiarizationReplayReport: Codable {
        let sampleCount: Int
        let blockSamples: Int
        let transitionChangeSamples: [Int]
        let transitionConfirmedSamples: [Int]
        let overlapUpdateCount: Int
        let processingP95Milliseconds: Double
        let processingWorstMilliseconds: Double
        let realTimeFactor: Double
    }

    private struct CandidateOutput: Codable {
        let passageID: Int
        let startSample: Int
        let endSample: Int
        let engine: String
        let source: String?
        let english: String
        let asrMilliseconds: Double
        let translationMilliseconds: Double
        let elapsedMilliseconds: Double
        let residentBytes: UInt64
    }

    private struct BlindOutput: Codable {
        let passageID: Int
        let candidate: String
        let english: String
    }

    private struct SmokeOutput: Codable {
        let voxtral: String
        let cohere: String
        let residentBytes: UInt64
    }

    private struct VoxtralEmissionMarkerReport: Codable {
        let generatedIndex: Int
        let decoderPosition: Int
        let delayFrames: Int
        let groupTextStartUTF8: Int
        let proxyEndSample: Int
        let isUsable: Bool
        let arrivalOrder: Int
        let arrivalMilliseconds: Double
        let transcriptUTF8CountAtArrival: Int
    }

    private struct VoxtralContinuousRun: Codable {
        let replayCount: Int
        let modelVariant: VoxtralModelVariant
        let blockMilliseconds: Int
        let transcriptionDelayMilliseconds: Int
        // Legacy FireRed-derived fields retained for older report readers.
        let firstSpeechSample: Int?
        let firstDeltaMilliseconds: Double?
        let firstDeltaAfterSpeechMilliseconds: Double?
        let detectedSpeechStartSample: Int?
        let annotatedSpeechStartSample: Int?
        let firstDeltaAfterDetectedSpeechStartMilliseconds: Double?
        let firstDeltaAfterAnnotatedSpeechStartMilliseconds: Double?
        let firstEligiblePrefixMilliseconds: Double?
        let firstEligiblePrefixAfterAnnotatedSpeechStartMilliseconds: Double?
        let lastDeltaMilliseconds: Double?
        let appendP50Milliseconds: Double
        let appendP95Milliseconds: Double
        let appendWorstMilliseconds: Double
        let appendCount: Int
        let deltaCount: Int
        let acknowledgementCount: Int
        let emissionMarkerCount: Int
        let usableEmissionMarkerCount: Int
        let emissionMarkers: [VoxtralEmissionMarkerReport]
        let maxBacklogMilliseconds: Double
        let endingBacklogMilliseconds: Double
        let backlogAtReplayEndMilliseconds: [Double]
        let maxHelperBacklogSamples: Int
        let endingHelperBacklogSamples: Int
        let flushMilliseconds: Double
        let fedSamples: Int
        let totalSamples: Int
        let appRSSBytes: UInt64
        let helperRSSBytes: UInt64
        let combinedRSSBytes: UInt64
        let completedEventReceived: Bool
        let deltaTranscriptMatchesFinal: Bool
        let transcript: String
    }

    private struct VoxtralEventSummary {
        let firstDeltaMilliseconds: Double?
        let firstEligiblePrefixMilliseconds: Double?
        let lastDeltaMilliseconds: Double?
        let deltaCount: Int
        let acknowledgementCount: Int
        let emissionMarkers: [VoxtralEmissionMarkerReport]
        let accumulatedTranscript: String
        let completedTranscript: String?
    }

    private struct AppleTranslationLatencyReport: Codable {
        let previewCount: Int
        let finalCount: Int
        let lowLatencyMilliseconds: [Double]
        let highFidelityMilliseconds: [Double]
        let lowLatencyP95Milliseconds: Double
        let highFidelityP95Milliseconds: Double
    }

    private struct RealtimeOutput: Codable {
        let buildVariant: String
        let engine: String
        let transcriptionDelayMilliseconds: Int
        let cohereQuantization: String
        let previewsEnabled: Bool
        let maxIngestBacklogMilliseconds: Double
        let endingIngestBacklogMilliseconds: Double
        let previewCount: Int
        let previewRevisionsPerPhrase: [Int]
        let previewSourceP50Milliseconds: Double?
        let previewSourceP95Milliseconds: Double?
        let previewSourceWorstMilliseconds: Double?
        let previewTranslationP50Milliseconds: Double?
        let previewTranslationP95Milliseconds: Double?
        let previewTranslationWorstMilliseconds: Double?
        let previewP50Milliseconds: Double?
        let previewP95Milliseconds: Double?
        let previewWorstMilliseconds: Double?
        let finalCount: Int
        let degradedFinalCount: Int
        let endpointToSourceP50Milliseconds: Double
        let endpointToSourceP95Milliseconds: Double
        let endpointToSourceWorstMilliseconds: Double
        let finalTranslationP50Milliseconds: Double
        let finalTranslationP95Milliseconds: Double
        let finalTranslationWorstMilliseconds: Double
        let endpointToFinalP50Milliseconds: Double
        let endpointToFinalP95Milliseconds: Double
        let maxEndpointToFinalMilliseconds: Double
        let measuredBytes: UInt64
    }

    private struct FinalTiming: Sendable {
        let endpointToSourceMilliseconds: Double
        let translationMilliseconds: Double
        let endpointToFinalMilliseconds: Double
        let degraded: Bool
    }


    @MainActor
    func testVoxtralRawStreamingWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_STREAM_BENCHMARK_WAV"
        ] else {
            throw XCTSkip("Set WHISPERASR_VOXTRAL_STREAM_BENCHMARK_WAV to profile raw Voxtral streaming.")
        }

        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let manager = LocalEnglishModelManager()
        await manager.selectContinuousVoxtralConfiguration(
            Self.requestedContinuousVoxtralConfiguration()
        )
        try await manager.prepare(.voxtralApple)
        defer { Task { await manager.shutdown() } }
        let report = try await continuousVoxtralRun(
            samples: samples,
            replayCount: 1,
            manager: manager
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: url.deletingLastPathComponent().appendingPathComponent(
                "voxtral-helper-stream-\(report.modelVariant.rawValue)-\(report.transcriptionDelayMilliseconds)ms-\(report.blockMilliseconds)ms.json"
            ),
            options: .atomic
        )
        validateContinuousVoxtralReport(report)
    }

    /// Multiple wall-clock replays in one uncommitted helper session. With the
    /// canonical 40-second fixture this crosses Voxtral's 4,096-position
    /// boundary and remains the production gate for cumulative backlog and
    /// stream-tail loss.
    @MainActor
    func testVoxtralContinuousHelperEnduranceWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_HELPER_ENDURANCE_WAV"
        ] else {
            throw XCTSkip("Set WHISPERASR_VOXTRAL_HELPER_ENDURANCE_WAV to run the configured helper endurance test.")
        }
        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let manager = LocalEnglishModelManager()
        await manager.selectContinuousVoxtralConfiguration(
            Self.requestedContinuousVoxtralConfiguration()
        )
        try await manager.prepare(.voxtralApple)
        defer { Task { await manager.shutdown() } }

        let replayCount = max(2, Int(ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_ENDURANCE_REPLAY_COUNT"
        ] ?? "10") ?? 10)

        let report = try await continuousVoxtralRun(
            samples: samples,
            replayCount: replayCount,
            manager: manager
        )
        XCTAssertNotNil(
            report.annotatedSpeechStartSample,
            "The endurance gate requires WHISPERASR_TRUE_SPEECH_START_SAMPLE; FireRed may trigger on music."
        )
        validateContinuousVoxtralReport(report)
        XCTAssertLessThanOrEqual(report.maxBacklogMilliseconds, 1_000)
        XCTAssertLessThanOrEqual(
            report.flushMilliseconds,
            15_000,
            "The production helper has a 15-second final-flush deadline."
        )
        let totalSeconds = Double(report.totalSamples)
            / Double(VoxtralClausePlanner.sampleRate)
        if totalSeconds > 6 * 60 {
            // Voxtral advances one streaming position every 80 ms. A useful
            // delta after this point proves the session crossed position 4,096.
            XCTAssertGreaterThan(report.lastDeltaMilliseconds ?? 0, 4_096 * 80)
        } else {
            // The four-replay fail-fast gate still has to emit in its final replay.
            let oneReplayMilliseconds = totalSeconds * 1_000
                / Double(report.replayCount)
            XCTAssertGreaterThan(
                report.lastDeltaMilliseconds ?? 0,
                oneReplayMilliseconds * Double(report.replayCount - 1)
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: url.deletingLastPathComponent().appendingPathComponent(
                "voxtral-helper-endurance-\(report.modelVariant.rawValue)-\(replayCount)x-crosses-4096-positions-\(report.transcriptionDelayMilliseconds)ms-\(report.blockMilliseconds)ms.json"
            ),
            options: .atomic
        )
    }

    /// Run explicitly with:
    /// Scripts/run_local_benchmark.sh .build/benchmarks/canonical-firefox-16k-mono.wav
    ///
    /// It intentionally downloads/loads large models and is therefore skipped
    /// during normal unit tests.
    @MainActor
    func testCanonicalQualityBenchmarkWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK_WAV"] else {
            throw XCTSkip("Set WHISPERASR_BENCHMARK_WAV to run the local model comparison.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple high-fidelity translation requires macOS 26.4 or later.")
        }

        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let voxtralDelay = Int(ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_DELAY_MS"
        ] ?? "960") ?? 960
        let modelManager = LocalEnglishModelManager()
        try await modelManager.prepare(.whisperTurboApple)
        let passages = try await endpointPassages(samples: samples, manager: modelManager)
        XCTAssertFalse(passages.isEmpty)
        print("[QualityBenchmark] passages=" + passages.map {
            "\($0.id):\(String(format: "%.2f", Double($0.endSample - $0.startSample) / 16_000))s"
        }.joined(separator: ","))
        XCTAssertTrue(passages.allSatisfy {
            let seconds = Double($0.endSample - $0.startSample) / 16_000
            return seconds >= 3 && seconds <= 16
        })

        let whisper = TranscriptionService()
        let translation = AppleTranslationService()
        try await translation.configure(sourceLocale: "ja", mode: .highFidelityOnly)

        let originalSelection = ModelManager.shared.selectedFileName
        defer { ModelManager.shared.selectedFileName = originalSelection }
        var outputs: [CandidateOutput] = []

        let candidates: [LocalEnglishEngine] = [
            .whisperTurboApple,
            .voxtralApple,
            .voxtralCohereApple,
        ]
        for engine in candidates {
            if engine == .whisperTurboApple {
                guard let turbo = ModelCatalog.model(id: "large-v3-turbo"),
                      ModelManager.shared.isDownloaded(turbo) else {
                    XCTFail("Whisper Large v3 Turbo must be downloaded before the opt-in benchmark.")
                    return
                }
                ModelManager.shared.selectedFileName = turbo.fileName
                try await whisper.preloadModel(requireEnglishTranslation: false)
            } else {
                await whisper.unloadModel()
            }
            try await modelManager.prepare(engine)
            let resident: UInt64
            if case .ready(let bytes) = modelManager.phase(for: engine) {
                resident = bytes
            } else {
                XCTFail("\(engine.label) was not ready")
                return
            }

            for passage in passages {
                let audio = Array(samples[passage.startSample..<passage.endSample])
                let started = DispatchTime.now().uptimeNanoseconds
                let source: String?
                switch engine {
                case .whisperTurboApple:
                    let result = try await whisper.transcribeChunk(
                        samples: audio,
                        language: "ja",
                        translate: false
                    )
                    source = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .voxtralApple:
                    let events = try await modelManager.startContinuousVoxtral()
                    let collector = Task {
                        for await _ in events {}
                    }
                    for start in stride(from: 0, to: audio.count, by: 5_120) {
                        let end = min(audio.count, start + 5_120)
                        try await modelManager.feedContinuousVoxtral(
                            samples: Array(audio[start..<end]),
                            range: start..<end
                        )
                    }
                    source = try await modelManager.finishContinuousVoxtral()
                    await collector.value
                case .voxtralCohereApple:
                    source = try await modelManager.transcribeCohere(
                        audio: audio,
                        language: "ja"
                    )
                case .cohereApple:
                    source = try await modelManager.transcribeCohere(
                        audio: audio,
                        language: "ja"
                    )
                case .qwenApple:
                    XCTFail("Qwen is intentionally outside this three-candidate bakeoff.")
                    return
                case .voxtralQwenApple, .voxtralTurboApple:
                    XCTFail("Dual-model live engines are intentionally outside this three-candidate bakeoff.")
                    return
                case .whisperLargeV3Direct:
                    XCTFail("Direct-English engines are intentionally outside this Japanese-source bakeoff.")
                    return
                }
                let asrFinished = DispatchTime.now().uptimeNanoseconds
                let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // An empty ASR output is an omission to score, not a benchmark
                // harness failure and not a request Apple can translate.
                let english = normalizedSource.isEmpty
                    ? ""
                    : try await translation.translate(normalizedSource, highFidelity: true)
                let finished = DispatchTime.now().uptimeNanoseconds
                guard !EnglishSubtitleValidator.containsSourceScript(english) else {
                    XCTFail("\(engine.label) returned source script for passage \(passage.id)")
                    return
                }
                let helperBytes = engine == .voxtralApple
                    ? await modelManager.continuousVoxtralProgress().helperRSSBytes ?? 0
                    : 0
                outputs.append(CandidateOutput(
                    passageID: passage.id,
                    startSample: passage.startSample,
                    endSample: passage.endSample,
                    engine: engine.rawValue,
                    source: source,
                    english: english,
                    asrMilliseconds: Double(asrFinished - started) / 1_000_000,
                    translationMilliseconds: Double(finished - asrFinished) / 1_000_000,
                    elapsedMilliseconds: Double(finished - started) / 1_000_000,
                    residentBytes: max(
                        resident,
                        modelManager.currentMemoryBytes() + helperBytes
                    )
                ))
            }
        }

        await modelManager.shutdown()
        whisper.shutdown()
        try writeReports(
            outputs,
            nextTo: url,
            suffix: voxtralDelay == 960 ? "" : "-\(voxtralDelay)ms"
        )
    }

    /// Downloads and exercises both native Swift runtimes without launching
    /// the application. It also verifies that both models remain resident
    /// below the absolute process-memory gate.
    @MainActor
    func testVoxtralCohereSmokeWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_MODEL_SMOKE"] == "1",
              let path = ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK_WAV"] else {
            throw XCTSkip("Set WHISPERASR_MODEL_SMOKE=1 and WHISPERASR_BENCHMARK_WAV to run the model smoke test.")
        }
        let url = URL(fileURLWithPath: path)
        let allSamples = try await AudioLoader.loadSamples(url: url)
        let manager = LocalEnglishModelManager()
        defer { Task { await manager.shutdown() } }
        try await manager.prepare(.voxtralCohereApple)
        guard case .ready(let residentBytes) = manager.phase(for: .voxtralCohereApple) else {
            XCTFail("Voxtral and Cohere did not become ready together.")
            return
        }
        let passages = try await endpointPassages(samples: allSamples, manager: manager)
        guard let passage = passages.first else {
            XCTFail("FireRedVAD found no complete utterance in the canonical PCM.")
            return
        }
        let samples = Array(allSamples[passage.startSample..<passage.endSample])

        _ = try await manager.startVoxtral()
        for start in stride(from: 0, to: samples.count, by: 5_120) {
            _ = try await manager.feedVoxtral(
                samples: Array(samples[start..<min(samples.count, start + 5_120)])
            )
        }
        let voxtral = try await manager.finishVoxtral()
        let cohere = try await manager.transcribeCohere(audio: samples, language: "ja")
        XCTAssertFalse(voxtral.isEmpty)
        XCTAssertFalse(cohere.isEmpty)
        let measuredBytes = max(residentBytes, manager.currentMemoryBytes())
        XCTAssertLessThanOrEqual(measuredBytes, 10 * 1_024 * 1_024 * 1_024)

        let report = SmokeOutput(
            voxtral: voxtral,
            cohere: cohere,
            residentBytes: measuredBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: url.deletingLastPathComponent().appendingPathComponent("model-smoke.json"),
            options: .atomic
        )
    }

    /// Four wall-clock replays exercise the concurrency that offline RTF
    /// cannot: Cohere finalization may run while Voxtral ingests the next phrase.
    @MainActor
    func testVoxtralRealtimeBacklogWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_REALTIME_BENCHMARK_WAV"
        ] else {
            throw XCTSkip("Set WHISPERASR_REALTIME_BENCHMARK_WAV to run wall-clock Voxtral replays.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple high-fidelity translation requires macOS 26.4 or later.")
        }

        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let manager = LocalEnglishModelManager()
        let delay = Int(ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_DELAY_MS"
        ] ?? "960") ?? 960
        let buildVariant = ProcessInfo.processInfo.environment[
            "WHISPERASR_BENCHMARK_VARIANT"
        ] ?? "debug"
        let cohereQuantization = CoherePrototypeQuantization(
            rawValue: ProcessInfo.processInfo.environment[
                "WHISPERASR_COHERE_QUANTIZATION"
            ] ?? "q8"
        ) ?? .q8
        try await manager.prepare(.whisperTurboApple)
        let passages = try await endpointPassages(samples: samples, manager: manager)
        XCTAssertFalse(passages.isEmpty)

        var reports: [RealtimeOutput] = []
        let requestedEngine = ProcessInfo.processInfo.environment[
            "WHISPERASR_REALTIME_ENGINE"
        ].flatMap(LocalEnglishEngine.init(rawValue:))
        if let requestedEngine, requestedEngine != .voxtralCohereApple {
            throw XCTSkip(
                "This replay measures only Voxtral live + Cohere final. Use the dedicated ASR bakeoff for \(requestedEngine.label)."
            )
        }
        let engines: [LocalEnglishEngine] = requestedEngine.map { [$0] }
            ?? [.voxtralCohereApple]
        for engine in engines {
            for previewsEnabled in [false, true] {
                reports.append(try await realtimeReplay(
                    engine: engine,
                    buildVariant: buildVariant,
                    transcriptionDelayMilliseconds: delay,
                    cohereQuantization: cohereQuantization,
                    previewsEnabled: previewsEnabled,
                    samples: samples,
                    passages: passages,
                    manager: manager
                ))
            }
        }
        await manager.shutdown()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(
            to: url.deletingLastPathComponent().appendingPathComponent(
                "realtime-\(buildVariant)-\(delay)ms-\(cohereQuantization.rawValue).json"
            ),
            options: .atomic
        )
        XCTAssertTrue(reports.allSatisfy { $0.finalCount == passages.count })
        XCTAssertTrue(reports.allSatisfy {
            $0.measuredBytes <= 10 * 1_024 * 1_024 * 1_024
        })
    }

    /// Replays the canonical PCM at wall-clock speed through the exact Apple
    /// preview service. This catches timestamp discontinuities that an offline
    /// file transcription cannot expose.
    @MainActor
    func testApplePreviewStreamingWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_PREVIEW_BENCHMARK_WAV"
        ] else {
            throw XCTSkip("Set WHISPERASR_PREVIEW_BENCHMARK_WAV to test Apple streaming previews.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple streaming previews require macOS 26.4 or later.")
        }

        let samples = try await AudioLoader.loadSamples(url: URL(fileURLWithPath: path))
        let service = AppleSpeechService()
        try await service.prepare(localeIdentifier: "ja-JP") { _ in }

        var updates: [LiveSourceUpdate] = []
        var updateTimes: [Double] = []
        var failure: Error?
        let started = DispatchTime.now().uptimeNanoseconds
        try await service.start(
            localeIdentifier: "ja-JP",
            onUpdate: {
                updates.append($0)
                updateTimes.append(Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000_000)
            },
            onFailure: { failure = $0 }
        )
        defer { Task { await service.cancel() } }

        let frame = 1_600
        let forceEvery = 24_000
        let feeder = Task { @MainActor in
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + frame)
                try await service.send(
                    samples: Array(samples[offset..<end]),
                    startSample: offset
                )
                offset = end
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        var target = forceEvery
        while target < samples.count {
            try await Task.sleep(for: .milliseconds(1_500))
            try await service.finalizeAvailableAudio()
            target += forceEvery
        }
        try await feeder.value
        try await service.finalizeAvailableAudio()
        try await Task.sleep(for: .milliseconds(500))
        await service.cancel()

        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(updates.count, 3)
        XCTAssertTrue(updates.allSatisfy {
            ($0.segment.end ?? $0.segment.start) >= $0.segment.start
        })
        if let overlapping = updates.first(where: {
            ($0.segment.end ?? $0.segment.start) - $0.segment.start > 0.2
        }) {
            let cutoff = Int((
                (overlapping.segment.start + (overlapping.segment.end ?? overlapping.segment.start))
                    / 2 * 16_000
            ).rounded())
            var planner = LocalPreviewPlanner()
            planner.suspend(through: cutoff)
            planner.resume(through: cutoff)
            planner.submit(overlapping)
            XCTAssertGreaterThanOrEqual(
                planner.takeLatest()?.update.segment.start ?? 0,
                Double(cutoff) / 16_000
            )
        } else {
            XCTFail("Apple Speech returned no timestamped result spanning the test boundary.")
        }
        print("[PreviewBenchmark] updates=\(updates.count) seconds=\(updateTimes)")
        for index in updates.indices where index == 0
            || updates[index].isFinal
            || updateTimes[index] - updateTimes[index - 1] > 0.2 {
            let update = updates[index]
            print(
                "[PreviewBenchmark] t=\(updateTimes[index]) "
                + "range=\(update.segment.start)-\(update.segment.end ?? update.segment.start) "
                + "final=\(update.isFinal) text=\(update.segment.text)"
            )
        }
        let timeline = updates.indices.map { index in
            let update = updates[index]
            return "\(updateTimes[index])\t\(update.segment.start)\t"
                + "\(update.segment.end ?? update.segment.start)\t"
                + "\(update.isFinal)\t\(update.segment.text)"
        }.joined(separator: "\n")
        try timeline.write(
            to: URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent("apple-preview-timeline.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    func testAppleTranslationStrategiesWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_APPLE_TRANSLATION_SOURCE_JSON"
        ] else {
            throw XCTSkip(
                "Set WHISPERASR_APPLE_TRANSLATION_SOURCE_JSON to a Voxtral helper report."
            )
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple translation strategies require macOS 26.4 or later.")
        }

        let input = URL(fileURLWithPath: path)
        let report = try JSONDecoder().decode(
            VoxtralContinuousRun.self,
            from: Data(contentsOf: input)
        )
        let clauses = japaneseClauses(report.transcript)
        XCTAssertFalse(clauses.isEmpty)

        let previewService = AppleTranslationService()
        let finalService = AppleTranslationService()
        try await previewService.configure(sourceLocale: "ja", mode: .lowLatencyOnly)
        try await finalService.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        try await previewService.warmup(highFidelity: false)
        try await finalService.warmup(highFidelity: true)
        defer {
            Task {
                await previewService.cancel()
                await finalService.cancel()
            }
        }

        var low: [Double] = []
        var high: [Double] = []
        var previewCount = 0
        for clause in clauses {
            let characters = Array(clause)
            let prefixLengths = Set([
                max(1, characters.count / 3),
                max(1, characters.count * 2 / 3),
                characters.count,
            ]).sorted()
            for length in prefixLengths {
                let source = String(characters.prefix(length))
                let started = DispatchTime.now().uptimeNanoseconds
                let english = try await previewService.translate(
                    source,
                    highFidelity: false
                )
                low.append(Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000)
                XCTAssertFalse(english.isEmpty)
                XCTAssertFalse(EnglishSubtitleValidator.containsSourceScript(english))
                previewCount += 1
            }

            let started = DispatchTime.now().uptimeNanoseconds
            let english = try await finalService.translate(
                clause,
                highFidelity: true
            )
            high.append(Double(
                DispatchTime.now().uptimeNanoseconds - started
            ) / 1_000_000)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(EnglishSubtitleValidator.containsSourceScript(english))
        }
        await previewService.cancel()
        await finalService.cancel()

        let result = AppleTranslationLatencyReport(
            previewCount: previewCount,
            finalCount: clauses.count,
            lowLatencyMilliseconds: low,
            highFidelityMilliseconds: high,
            lowLatencyP95Milliseconds: percentile(low, 0.95) ?? .infinity,
            highFidelityP95Milliseconds: percentile(high, 0.95) ?? .infinity
        )
        let output = input.deletingLastPathComponent()
            .appendingPathComponent("apple-translation-strategies.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output, options: .atomic)

        XCTAssertLessThan(result.lowLatencyP95Milliseconds, 200)
        XCTAssertLessThan(result.highFidelityP95Milliseconds, 500)
    }


    private func writeReports(
        _ outputs: [CandidateOutput],
        nextTo wav: URL,
        suffix: String = ""
    ) throws {
        let root = wav.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outputs).write(
            to: root.appendingPathComponent("quality\(suffix)-full.json"),
            options: .atomic
        )

        let names = ["A", "B", "C"]
        var blind: [BlindOutput] = []
        var key: [String: String] = [:]
        for passageID in Set(outputs.map(\.passageID)).sorted() {
            let candidates = outputs.filter { $0.passageID == passageID }
            for (index, output) in candidates.enumerated() {
                let label = names[(index + passageID) % names.count]
                blind.append(BlindOutput(
                    passageID: passageID,
                    candidate: label,
                    english: output.english
                ))
                key["\(passageID)-\(label)"] = output.engine
            }
        }
        blind.sort { ($0.passageID, $0.candidate) < ($1.passageID, $1.candidate) }
        try encoder.encode(blind).write(
            to: root.appendingPathComponent("quality\(suffix)-blind.json"),
            options: .atomic
        )
        try encoder.encode(key).write(
            to: root.appendingPathComponent("quality\(suffix)-key.json"),
            options: .atomic
        )
    }

    private func japaneseClauses(_ text: String) -> [String] {
        let punctuation = Set("。！？!?")
        var clauses: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if punctuation.contains(character) {
                let clause = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty { clauses.append(clause) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }
        return clauses
    }

    @MainActor
    @available(macOS 26.4, *)
    private func realtimeReplay(
        engine: LocalEnglishEngine,
        buildVariant: String,
        transcriptionDelayMilliseconds: Int,
        cohereQuantization: CoherePrototypeQuantization,
        previewsEnabled: Bool,
        samples: [Float],
        passages: [CanonicalBenchmarkPassage],
        manager: LocalEnglishModelManager
    ) async throws -> RealtimeOutput {
        if engine.usesCohereFinal {
            await manager.selectCohereQuantization(cohereQuantization)
        }
        try await manager.prepare(engine)
        try await manager.setVoxtralTranscriptionDelay(transcriptionDelayMilliseconds)
        let previewService = AppleTranslationService()
        let finalService = AppleTranslationService()
        if previewsEnabled {
            try await previewService.configure(
                sourceLocale: "ja",
                mode: engine.usesAppleSpeechPreview ? .lowLatencyOnly : .highFidelityOnly
            )
        }
        try await finalService.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        let previewWorker = BenchmarkPreviewTranslator(
            service: previewService,
            highFidelity: engine.usesVoxtralSourcePreview
        )
        let runStart = DispatchTime.now().uptimeNanoseconds
        let appleSpeech: AppleSpeechService? = previewsEnabled && engine.usesAppleSpeechPreview
            ? AppleSpeechService() : nil
        if let appleSpeech {
            try await appleSpeech.prepare(localeIdentifier: "ja-JP") { _ in }
            try await appleSpeech.start(
                localeIdentifier: "ja-JP",
                priority: .utility,
                onUpdate: { update in
                    let source = update.segment.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !source.isEmpty else { return }
                    let endSample = Int((
                        (update.segment.end ?? update.segment.start) * 16_000
                    ).rounded())
                    let passage = passages.first {
                        endSample > $0.startSample && endSample <= $0.endSample
                    } ?? passages.last
                    guard let passage else { return }
                    Task {
                        await previewWorker.submit(
                            source: source,
                            phraseKey: UInt64(passage.startSample),
                            phraseStartUptimeNanoseconds: runStart
                                + UInt64(max(
                                    passage.startSample,
                                    Int((update.segment.start * 16_000).rounded())
                                )) * 1_000_000_000 / 16_000
                        )
                    }
                },
                onFailure: { error in
                    XCTFail("Apple Speech preview failed: \(error.localizedDescription)")
                }
            )
        }
        defer {
            if let appleSpeech { Task { await appleSpeech.cancel() } }
        }
        let appleFeeder = appleSpeech.map { speech in
            Task { @MainActor in
                var offset = 0
                while offset < samples.count {
                    let end = min(samples.count, offset + 1_600)
                    let deadline = runStart + UInt64(end) * 1_000_000_000 / 16_000
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < deadline {
                        try await Task.sleep(nanoseconds: deadline - now)
                    }
                    try await speech.send(
                        samples: Array(samples[offset..<end]),
                        startSample: offset
                    )
                    offset = end
                }
            }
        }
        let appleFinalizer = appleSpeech.map { speech in
            Task { @MainActor in
                var target = LocalAppleSpeechFeedState.progressiveFinalizationInterval
                while target < samples.count {
                    let deadline = runStart + UInt64(target) * 1_000_000_000 / 16_000
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < deadline {
                        try await Task.sleep(nanoseconds: deadline - now)
                    }
                    try await speech.finalizeAvailableAudio()
                    target += LocalAppleSpeechFeedState.progressiveFinalizationInterval
                }
            }
        }
        var maxBacklog: UInt64 = 0
        var endingBacklog: UInt64 = 0
        var finalTasks: [Task<FinalTiming?, Never>] = []
        var streamCursor = 0
        _ = try await manager.startVoxtral()

        for (passageIndex, passage) in passages.enumerated() {
            var source = ""
            while streamCursor < passage.endSample {
                let end = min(passage.endSample, streamCursor + 5_120)
                let deadline = runStart + UInt64(end) * 1_000_000_000 / 16_000
                let now = DispatchTime.now().uptimeNanoseconds
                if now < deadline {
                    try await Task.sleep(nanoseconds: deadline - now)
                }
                source = try await manager.feedVoxtral(
                    samples: Array(samples[streamCursor..<end])
                ).transcript
                streamCursor = end
                let completed = DispatchTime.now().uptimeNanoseconds
                endingBacklog = completed > deadline ? completed - deadline : 0
                maxBacklog = max(maxBacklog, endingBacklog)
                if previewsEnabled, engine.usesVoxtralSourcePreview, !source.isEmpty {
                    await previewWorker.submit(
                        source: source,
                        phraseKey: UInt64(passage.startSample),
                        phraseStartUptimeNanoseconds: runStart
                            + UInt64(passage.startSample) * 1_000_000_000 / 16_000
                    )
                }
            }
            source = try await manager.finishVoxtral()
            let finalSource = source
            let sourceReadyUptime = DispatchTime.now().uptimeNanoseconds
            let audio = Array(samples[passage.startSample..<passage.endSample])
            let endpointUptime = runStart
                + UInt64(passage.endSample) * 1_000_000_000 / 16_000

            // The next stateful stream is ready before the old phrase enters
            // Cohere/Apple finalization, exactly like the app pipeline.
            if passageIndex + 1 < passages.count {
                _ = try await manager.startVoxtral()
            }
            finalTasks.append(Task { @MainActor in
                do {
                    let selection: LocalFinalSourceSelection
                    if engine.usesCohereFinal {
                        let cohere = try? await manager.transcribeCohere(
                            audio: audio,
                            language: "ja"
                        )
                        selection = try LocalFinalSourceSelector.hybrid(
                            cohere: cohere,
                            voxtral: finalSource
                        )
                    } else {
                        selection = LocalFinalSourceSelection(
                            text: finalSource,
                            degraded: false
                        )
                    }
                    let sourceCompleted = engine.usesCohereFinal
                        ? DispatchTime.now().uptimeNanoseconds
                        : sourceReadyUptime
                    guard !selection.text.isEmpty else { return nil }
                    let translationStarted = DispatchTime.now().uptimeNanoseconds
                    let english = try await finalService.translate(
                        selection.text,
                        highFidelity: true
                    )
                    guard !EnglishSubtitleValidator.containsSourceScript(english) else { return nil }
                    let completed = DispatchTime.now().uptimeNanoseconds
                    return FinalTiming(
                        endpointToSourceMilliseconds: sourceCompleted > endpointUptime
                            ? Double(sourceCompleted - endpointUptime) / 1_000_000 : 0,
                        translationMilliseconds: Double(
                            completed - translationStarted
                        ) / 1_000_000,
                        endpointToFinalMilliseconds: completed > endpointUptime
                            ? Double(completed - endpointUptime) / 1_000_000 : 0,
                        degraded: selection.degraded
                    )
                } catch {
                    return nil
                }
            })
        }
        XCTAssertEqual(streamCursor, samples.count, "The real-time replay must feed every PCM sample.")

        if let appleFeeder { try await appleFeeder.value }
        if let appleFinalizer { try await appleFinalizer.value }
        if let appleSpeech { try await appleSpeech.finish() }

        var finalTimings: [FinalTiming] = []
        for task in finalTasks {
            if let timing = await task.value { finalTimings.append(timing) }
        }
        let preview = previewsEnabled
            ? await previewWorker.finish() : BenchmarkPreviewTranslationSummary.empty
        await previewService.cancel()
        await finalService.cancel()
        let previewSourceLatencies = preview.sourceLatencies
        let previewLatencies = preview.firstLatencies
        let previewTranslationLatencies = preview.translationLatencies
        let sourceLatencies = finalTimings.map(\.endpointToSourceMilliseconds)
        let translationLatencies = finalTimings.map(\.translationMilliseconds)
        let finalLatencies = finalTimings.map(\.endpointToFinalMilliseconds)
        return RealtimeOutput(
            buildVariant: buildVariant,
            engine: engine.rawValue,
            transcriptionDelayMilliseconds: transcriptionDelayMilliseconds,
            cohereQuantization: cohereQuantization.rawValue,
            previewsEnabled: previewsEnabled,
            maxIngestBacklogMilliseconds: Double(maxBacklog) / 1_000_000,
            endingIngestBacklogMilliseconds: Double(endingBacklog) / 1_000_000,
            previewCount: preview.count,
            previewRevisionsPerPhrase: preview.revisions,
            previewSourceP50Milliseconds: percentile(previewSourceLatencies, 0.50),
            previewSourceP95Milliseconds: percentile(previewSourceLatencies, 0.95),
            previewSourceWorstMilliseconds: previewSourceLatencies.max(),
            previewTranslationP50Milliseconds: percentile(previewTranslationLatencies, 0.50),
            previewTranslationP95Milliseconds: percentile(previewTranslationLatencies, 0.95),
            previewTranslationWorstMilliseconds: previewTranslationLatencies.max(),
            previewP50Milliseconds: percentile(previewLatencies, 0.50),
            previewP95Milliseconds: percentile(previewLatencies, 0.95),
            previewWorstMilliseconds: previewLatencies.max(),
            finalCount: finalLatencies.count,
            degradedFinalCount: finalTimings.filter(\.degraded).count,
            endpointToSourceP50Milliseconds: percentile(sourceLatencies, 0.50) ?? 0,
            endpointToSourceP95Milliseconds: percentile(sourceLatencies, 0.95) ?? 0,
            endpointToSourceWorstMilliseconds: sourceLatencies.max() ?? 0,
            finalTranslationP50Milliseconds: percentile(translationLatencies, 0.50) ?? 0,
            finalTranslationP95Milliseconds: percentile(translationLatencies, 0.95) ?? 0,
            finalTranslationWorstMilliseconds: translationLatencies.max() ?? 0,
            endpointToFinalP50Milliseconds: percentile(finalLatencies, 0.50) ?? 0,
            endpointToFinalP95Milliseconds: percentile(finalLatencies, 0.95) ?? 0,
            maxEndpointToFinalMilliseconds: finalLatencies.max() ?? 0,
            measuredBytes: manager.currentMemoryBytes()
        )
    }

    @MainActor
    private func continuousVoxtralRun(
        samples: [Float],
        replayCount: Int,
        manager: LocalEnglishModelManager
    ) async throws -> VoxtralContinuousRun {
        let blockSamples = VoxtralClausePlanner.sampleRate
            * VoxtralHelperManifest.transportBlockMilliseconds / 1_000
        let detectedSpeechStartSample = try await manager.detectSpeech(
            audio: samples,
            windowStart: 0
        ).first?.start
        let annotatedSpeechStartSample: Int?
        if let rawValue = ProcessInfo.processInfo.environment[
            "WHISPERASR_TRUE_SPEECH_START_SAMPLE"
        ] {
            guard let value = Int(rawValue), (0..<samples.count).contains(value) else {
                throw NSError(
                    domain: "WhisperASRBenchmark",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "WHISPERASR_TRUE_SPEECH_START_SAMPLE must be a 16 kHz sample index inside the benchmark WAV."
                    ]
                )
            }
            annotatedSpeechStartSample = value
        } else {
            annotatedSpeechStartSample = nil
        }
        let events = try await manager.startContinuousVoxtral()
        let started = DispatchTime.now().uptimeNanoseconds
        let collector = Task { () -> VoxtralEventSummary in
            var firstDeltaMilliseconds: Double?
            var firstEligiblePrefixMilliseconds: Double?
            var lastDeltaMilliseconds: Double?
            var accumulatedText = ""
            var deltaCount = 0
            var acknowledgementCount = 0
            var emissionMarkers: [VoxtralEmissionMarkerReport] = []
            var completedTranscript: String?
            for await event in events {
                switch event {
                case .acknowledged:
                    acknowledgementCount += 1
                case .emissionMarker(let marker):
                    emissionMarkers.append(VoxtralEmissionMarkerReport(
                        generatedIndex: marker.generatedIndex,
                        decoderPosition: marker.decoderPosition,
                        delayFrames: marker.delayFrames,
                        groupTextStartUTF8: marker.groupTextStartUTF8,
                        proxyEndSample: marker.proxyEndSample,
                        isUsable: marker.isUsable,
                        arrivalOrder: emissionMarkers.count,
                        arrivalMilliseconds: Double(
                            DispatchTime.now().uptimeNanoseconds - started
                        ) / 1_000_000,
                        transcriptUTF8CountAtArrival: accumulatedText.utf8.count
                    ))
                case .delta(let text, _):
                    deltaCount += 1
                    accumulatedText.append(text)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let elapsedMilliseconds = Double(
                            DispatchTime.now().uptimeNanoseconds - started
                        ) / 1_000_000
                        if firstDeltaMilliseconds == nil {
                            firstDeltaMilliseconds = elapsedMilliseconds
                        }
                        lastDeltaMilliseconds = elapsedMilliseconds
                        if firstEligiblePrefixMilliseconds == nil,
                           LocalPreviewPlanner.isEligibleSource(accumulatedText) {
                            firstEligiblePrefixMilliseconds = elapsedMilliseconds
                        }
                    }
                case .completed(let transcript, _):
                    completedTranscript = transcript
                case .ready, .failed:
                    break
                }
            }
            return VoxtralEventSummary(
                firstDeltaMilliseconds: firstDeltaMilliseconds,
                firstEligiblePrefixMilliseconds: firstEligiblePrefixMilliseconds,
                lastDeltaMilliseconds: lastDeltaMilliseconds,
                deltaCount: deltaCount,
                acknowledgementCount: acknowledgementCount,
                emissionMarkers: emissionMarkers,
                accumulatedTranscript: accumulatedText,
                completedTranscript: completedTranscript
            )
        }

        var absoluteOffset = 0
        var appendMilliseconds: [Double] = []
        var maxBacklogNanoseconds: UInt64 = 0
        var endingBacklogNanoseconds: UInt64 = 0
        var backlogAtReplayEndMilliseconds: [Double] = []
        var maxHelperBacklogSamples = 0
        var maxAppRSSBytes = manager.currentMemoryBytes()
        var maxHelperRSSBytes: UInt64 = 0
        var maxCombinedRSSBytes: UInt64 = 0

        for _ in 0..<replayCount {
            var sourceOffset = 0
            while sourceOffset < samples.count {
                let sourceEnd = min(samples.count, sourceOffset + blockSamples)
                let count = sourceEnd - sourceOffset
                let absoluteEnd = absoluteOffset + count
                let deadline = started + UInt64(absoluteEnd) * 1_000_000_000 / 16_000
                let now = DispatchTime.now().uptimeNanoseconds
                if now < deadline {
                    try await Task.sleep(nanoseconds: deadline - now)
                }

                let appendStarted = DispatchTime.now().uptimeNanoseconds
                try await manager.feedContinuousVoxtral(
                    samples: Array(samples[sourceOffset..<sourceEnd]),
                    range: absoluteOffset..<absoluteEnd
                )
                let completed = DispatchTime.now().uptimeNanoseconds
                appendMilliseconds.append(Double(completed - appendStarted) / 1_000_000)
                endingBacklogNanoseconds = completed > deadline ? completed - deadline : 0
                maxBacklogNanoseconds = max(maxBacklogNanoseconds, endingBacklogNanoseconds)

                let progress = await manager.continuousVoxtralProgress()
                maxHelperBacklogSamples = max(
                    maxHelperBacklogSamples,
                    progress.maximumBacklogSamples
                )
                let appRSS = manager.currentMemoryBytes()
                let helperRSS = progress.helperRSSBytes ?? 0
                maxAppRSSBytes = max(maxAppRSSBytes, appRSS)
                maxHelperRSSBytes = max(maxHelperRSSBytes, helperRSS)
                maxCombinedRSSBytes = max(maxCombinedRSSBytes, appRSS + helperRSS)

                sourceOffset = sourceEnd
                absoluteOffset = absoluteEnd
            }
            backlogAtReplayEndMilliseconds.append(
                Double(endingBacklogNanoseconds) / 1_000_000
            )
        }

        let flushStarted = DispatchTime.now().uptimeNanoseconds
        let transcript = try await manager.finishContinuousVoxtral()
        let flushMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - flushStarted
        ) / 1_000_000
        let summary = await collector.value
        let finalProgress = await manager.continuousVoxtralProgress()
        let finalAppRSS = manager.currentMemoryBytes()
        let finalHelperRSS = finalProgress.helperRSSBytes ?? 0
        maxAppRSSBytes = max(maxAppRSSBytes, finalAppRSS)
        maxHelperRSSBytes = max(maxHelperRSSBytes, finalHelperRSS)
        maxCombinedRSSBytes = max(maxCombinedRSSBytes, finalAppRSS + finalHelperRSS)

        return VoxtralContinuousRun(
            replayCount: replayCount,
            modelVariant: manager.continuousVoxtralConfiguration.model,
            blockMilliseconds: VoxtralHelperManifest.transportBlockMilliseconds,
            transcriptionDelayMilliseconds:
                manager.continuousVoxtralConfiguration.delay.rawValue,
            firstSpeechSample: detectedSpeechStartSample,
            firstDeltaMilliseconds: summary.firstDeltaMilliseconds,
            firstDeltaAfterSpeechMilliseconds: summary.firstDeltaMilliseconds.map {
                max(0, $0 - Double(detectedSpeechStartSample ?? 0) / 16)
            },
            detectedSpeechStartSample: detectedSpeechStartSample,
            annotatedSpeechStartSample: annotatedSpeechStartSample,
            firstDeltaAfterDetectedSpeechStartMilliseconds: summary.firstDeltaMilliseconds.flatMap {
                firstDelta in detectedSpeechStartSample.map {
                    max(0, firstDelta - Double($0) / 16)
                }
            },
            firstDeltaAfterAnnotatedSpeechStartMilliseconds: summary.firstDeltaMilliseconds.flatMap {
                firstDelta in annotatedSpeechStartSample.map {
                    firstDelta - Double($0) / 16
                }
            },
            firstEligiblePrefixMilliseconds: summary.firstEligiblePrefixMilliseconds,
            firstEligiblePrefixAfterAnnotatedSpeechStartMilliseconds: summary.firstEligiblePrefixMilliseconds.flatMap {
                firstEligible in annotatedSpeechStartSample.map {
                    firstEligible - Double($0) / 16
                }
            },
            lastDeltaMilliseconds: summary.lastDeltaMilliseconds,
            appendP50Milliseconds: percentile(appendMilliseconds, 0.50) ?? 0,
            appendP95Milliseconds: percentile(appendMilliseconds, 0.95) ?? 0,
            appendWorstMilliseconds: appendMilliseconds.max() ?? 0,
            appendCount: appendMilliseconds.count,
            deltaCount: summary.deltaCount,
            acknowledgementCount: summary.acknowledgementCount,
            emissionMarkerCount: summary.emissionMarkers.count,
            usableEmissionMarkerCount: summary.emissionMarkers.filter(\.isUsable).count,
            emissionMarkers: summary.emissionMarkers,
            maxBacklogMilliseconds: Double(maxBacklogNanoseconds) / 1_000_000,
            endingBacklogMilliseconds: Double(endingBacklogNanoseconds) / 1_000_000,
            backlogAtReplayEndMilliseconds: backlogAtReplayEndMilliseconds,
            maxHelperBacklogSamples: maxHelperBacklogSamples,
            endingHelperBacklogSamples: finalProgress.backlogSamples,
            flushMilliseconds: flushMilliseconds,
            fedSamples: absoluteOffset,
            totalSamples: samples.count * replayCount,
            appRSSBytes: maxAppRSSBytes,
            helperRSSBytes: maxHelperRSSBytes,
            combinedRSSBytes: maxCombinedRSSBytes,
            completedEventReceived: summary.completedTranscript == transcript,
            deltaTranscriptMatchesFinal: summary.accumulatedTranscript == transcript,
            transcript: transcript
        )
    }

    private static func requestedContinuousVoxtralConfiguration()
        -> VoxtralContinuousConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["WHISPERASR_VOXTRAL_HELPER_VARIANT"]
            .flatMap(VoxtralModelVariant.init(rawValue:)) ?? .q4
        let delay = environment["WHISPERASR_VOXTRAL_HELPER_DELAY_MS"]
            .flatMap(Int.init)
            .flatMap(VoxtralTranscriptionDelay.init(rawValue:)) ?? .milliseconds960
        return VoxtralContinuousConfiguration(model: model, delay: delay)
    }

    private func validateContinuousVoxtralReport(_ report: VoxtralContinuousRun) {
        let environment = ProcessInfo.processInfo.environment
        let maximumFirstDeltaMilliseconds = environment[
            "WHISPERASR_VOXTRAL_MAX_FIRST_DELTA_MS"
        ].flatMap(Double.init) ?? 2_500
        let maximumEligiblePrefixMilliseconds = environment[
            "WHISPERASR_VOXTRAL_MAX_ELIGIBLE_PREFIX_MS"
        ].flatMap(Double.init) ?? 3_000
        XCTAssertEqual(
            report.blockMilliseconds,
            VoxtralHelperManifest.transportBlockMilliseconds
        )
        XCTAssertTrue(
            VoxtralTranscriptionDelay.allCases.map(\.rawValue)
                .contains(report.transcriptionDelayMilliseconds)
        )
        XCTAssertEqual(report.fedSamples, report.totalSamples)
        XCTAssertEqual(report.acknowledgementCount, report.appendCount)
        XCTAssertEqual(report.endingHelperBacklogSamples, 0)
        XCTAssertLessThanOrEqual(report.maxHelperBacklogSamples, 16_000)
        XCTAssertGreaterThan(report.acknowledgementCount, 0)
        XCTAssertGreaterThan(report.deltaCount, 0)
        XCTAssertEqual(report.emissionMarkerCount, report.emissionMarkers.count)
        let usableMarkers = report.emissionMarkers.filter(\.isUsable)
        XCTAssertEqual(report.usableEmissionMarkerCount, usableMarkers.count)
        XCTAssertGreaterThan(usableMarkers.count, 0)
        XCTAssertEqual(
            report.emissionMarkers.map(\.arrivalOrder),
            Array(report.emissionMarkers.indices)
        )
        for marker in usableMarkers {
            XCTAssertEqual(
                marker.decoderPosition,
                marker.generatedIndex + marker.delayFrames + 33
            )
            XCTAssertGreaterThanOrEqual(marker.groupTextStartUTF8, 0)
            XCTAssertLessThanOrEqual(marker.groupTextStartUTF8, report.transcript.utf8.count)
            XCTAssertGreaterThanOrEqual(marker.proxyEndSample, 0)
            XCTAssertLessThanOrEqual(marker.proxyEndSample, report.totalSamples)
        }
        for (previous, current) in zip(usableMarkers, usableMarkers.dropFirst()) {
            XCTAssertGreaterThan(current.generatedIndex, previous.generatedIndex)
            XCTAssertGreaterThan(current.decoderPosition, previous.decoderPosition)
            XCTAssertGreaterThan(current.proxyEndSample, previous.proxyEndSample)
            XCTAssertGreaterThanOrEqual(
                current.groupTextStartUTF8,
                previous.groupTextStartUTF8
            )
            XCTAssertGreaterThanOrEqual(current.arrivalMilliseconds, previous.arrivalMilliseconds)
        }
        XCTAssertNotNil(report.firstDeltaMilliseconds)
        XCTAssertNotNil(report.firstEligiblePrefixMilliseconds)
        if let firstAfterAnnotatedSpeech = report.firstDeltaAfterAnnotatedSpeechStartMilliseconds {
            XCTAssertGreaterThanOrEqual(firstAfterAnnotatedSpeech, 0)
            XCTAssertLessThanOrEqual(
                firstAfterAnnotatedSpeech,
                maximumFirstDeltaMilliseconds
            )
        }
        if let eligibleAfterAnnotatedSpeech =
            report.firstEligiblePrefixAfterAnnotatedSpeechStartMilliseconds {
            XCTAssertGreaterThanOrEqual(eligibleAfterAnnotatedSpeech, 0)
            XCTAssertLessThanOrEqual(
                eligibleAfterAnnotatedSpeech,
                maximumEligiblePrefixMilliseconds
            )
        }
        XCTAssertTrue(report.completedEventReceived)
        XCTAssertTrue(report.deltaTranscriptMatchesFinal)
        XCTAssertFalse(report.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThan(report.combinedRSSBytes, 10 * 1_024 * 1_024 * 1_024)
        if let first = report.backlogAtReplayEndMilliseconds.first,
           let last = report.backlogAtReplayEndMilliseconds.last {
            XCTAssertLessThanOrEqual(last, max(250, first + 200))
        }
    }

    func testVoxtralMarkerCalibrationWhenOptedIn() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_MARKER_CALIBRATION_PROOF"
        ], !path.isEmpty else {
            throw XCTSkip(
                "Set WHISPERASR_VOXTRAL_MARKER_CALIBRATION_PROOF to a human-reviewed JSON dataset with independent 20-point calibration and validation splits."
            )
        }
        let report = try VoxtralMarkerCalibrationProof.evaluate(
            data: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("voxtral-marker-calibration.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)

        print("Marker proof: bias=\(report.biasSamples), validation p95=\(report.validationP95AbsoluteErrorSamples), drift=\(report.medianOffsetDriftSamples), dataset=\(report.datasetSHA256)")
        XCTAssertTrue(
            report.permitsBoundaries,
            "Speaker boundaries must remain shadow-only: \(report.violations.joined(separator: ", "))."
        )
    }

    @MainActor
    func testDiarizationShadowReplayWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_DIARIZATION_BENCHMARK_WAV"
        ], !path.isEmpty else {
            throw XCTSkip(
                "Set WHISPERASR_DIARIZATION_BENCHMARK_WAV to replay LS-EEND without changing subtitle boundaries."
            )
        }

        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let diarization = LocalDiarizationShadow()
        await diarization.prepare()
        let status = await diarization.status()
        guard status.isReady else {
            XCTFail(status.failureReason ?? "LS-EEND did not become ready.")
            return
        }
        await diarization.reset()

        let block = 1_600
        var processingMilliseconds: [Double] = []
        var transitions: [LocalSpeakerTransition] = []
        var overlapUpdateCount = 0
        let started = DispatchTime.now().uptimeNanoseconds
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + block)
            let blockStarted = DispatchTime.now().uptimeNanoseconds
            let updates = await diarization.append(
                samples: Array(samples[start..<end]),
                range: start..<end
            )
            processingMilliseconds.append(
                Double(DispatchTime.now().uptimeNanoseconds - blockStarted) / 1_000_000
            )
            transitions.append(contentsOf: updates.compactMap(\.transition))
            overlapUpdateCount += updates.filter {
                !$0.overlappingSpeakers.isEmpty
            }.count
            start = end
        }
        let tail = await diarization.finish()
        transitions.append(contentsOf: tail.compactMap(\.transition))
        overlapUpdateCount += tail.filter { !$0.overlappingSpeakers.isEmpty }.count
        let elapsedSeconds = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000_000
        let audioSeconds = Double(samples.count) / 16_000
        let report = DiarizationReplayReport(
            sampleCount: samples.count,
            blockSamples: block,
            transitionChangeSamples: transitions.map(\.changeSample),
            transitionConfirmedSamples: transitions.map(\.confirmedAtSample),
            overlapUpdateCount: overlapUpdateCount,
            processingP95Milliseconds: percentile(processingMilliseconds, 0.95) ?? 0,
            processingWorstMilliseconds: processingMilliseconds.max() ?? 0,
            realTimeFactor: audioSeconds > 0 ? elapsedSeconds / audioSeconds : .infinity
        )

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = ProcessInfo.processInfo.environment[
            "WHISPERASR_DIARIZATION_BENCHMARK_OUTPUT"
        ].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(
                "diarization-\(url.deletingPathExtension().lastPathComponent).json"
            )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)

        print("LS-EEND replay: \(transitions.count) transitions, RTF \(report.realTimeFactor)")
        XCTAssertLessThan(report.realTimeFactor, 1)
        XCTAssertLessThan(report.processingP95Milliseconds, 100)
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    /// Derives one shared set of production-like utterance boundaries. Every
    /// candidate receives these exact sample ranges; only the ASR changes.
    @MainActor
    private func endpointPassages(
        samples: [Float],
        manager: LocalEnglishModelManager
    ) async throws -> [CanonicalBenchmarkPassage] {
        var planner = LocalEndpointPlanner()
        var passages: [CanonicalBenchmarkPassage] = []
        let frame = 1_600
        let vadWindow = 48_000
        var total = 0

        while total < samples.count {
            total = min(samples.count, total + frame)
            let windowStart = max(0, total - vadWindow)
            let speech = try await manager.detectSpeech(
                audio: Array(samples[windowStart..<total]),
                windowStart: windowStart
            )
            if let decision = planner.observe(totalSample: total, speech: speech) {
                passages.append(CanonicalBenchmarkPassage(
                    id: passages.count + 1,
                    startSample: decision.audioStart,
                    endSample: decision.audioEnd
                ))
                planner.stage(decision)
                planner.accept(decision)
            }
        }

        let tailStart = max(0, samples.count - vadWindow)
        let tailSpeech = try await manager.detectSpeech(
            audio: Array(samples[tailStart..<samples.count]),
            windowStart: tailStart
        )
        if let decision = planner.observe(
            totalSample: samples.count,
            speech: tailSpeech,
            finishing: true
        ) {
            passages.append(CanonicalBenchmarkPassage(
                id: passages.count + 1,
                startSample: decision.audioStart,
                endSample: decision.audioEnd
            ))
        }
        return mergeShortPassages(passages)
    }

    private func mergeShortPassages(
        _ passages: [CanonicalBenchmarkPassage]
    ) -> [CanonicalBenchmarkPassage] {
        var result: [CanonicalBenchmarkPassage] = []
        for passage in passages {
            if let previous = result.last {
                let previousDuration = previous.endSample - previous.startSample
                let duration = passage.endSample - passage.startSample
                let combinedDuration = passage.endSample - previous.startSample
                if (previousDuration < 48_000 || duration < 48_000),
                   combinedDuration <= 16_000 * 16 {
                    result[result.count - 1] = CanonicalBenchmarkPassage(
                        id: previous.id,
                        startSample: previous.startSample,
                        endSample: passage.endSample
                    )
                    continue
                }
            }
            result.append(CanonicalBenchmarkPassage(
                id: result.count + 1,
                startSample: passage.startSample,
                endSample: passage.endSample
            ))
        }
        return result.enumerated().map {
            CanonicalBenchmarkPassage(
                id: $0.offset + 1,
                startSample: $0.element.startSample,
                endSample: $0.element.endSample
            )
        }
    }
}
