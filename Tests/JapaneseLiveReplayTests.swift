import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseLiveReplayTests: XCTestCase {
    private typealias StressWindow = JapaneseBenchmarkSupport.StressWindow

    private struct SourceEvent: Codable, Sendable {
        let sequence: Int
        let stability: String
        let text: String
        let localStartSample: Int?
        let localEndSample: Int?
        let absoluteStartSample: Int?
        let absoluteEndSample: Int?
        let isFinal: Bool
        let receivedMilliseconds: Double
    }

    private struct FinalTranslationEvent: Codable, Sendable {
        let finalID: String
        let sourceSequence: Int
        let japanese: String
        let english: String
        let localStartSample: Int
        let localEndSample: Int
        let sourceReceivedMilliseconds: Double
        let translationStartedMilliseconds: Double
        let acceptedMilliseconds: Double
        let endpointToAcceptedMilliseconds: Double
        let error: String?
    }

    private struct SessionReport: Codable, Sendable {
        let sessionID: String
        let source: String
        let corpusID: String
        let windowID: String
        let replay: Int
        let windowStartSample: Int
        let windowEndSample: Int
        let expectedSampleCount: Int
        let sentSampleCount: Int
        let readyToStopReceived: Bool
        let finalBoundaryMode: String
        let maximumSendLatenessMilliseconds: Double
        let sourceEvents: [SourceEvent]
        let volatileEvents: [SourceEvent]
        let previewEvents: [BenchmarkPreviewTranslationEvent]
        let finalEvents: [FinalTranslationEvent]
        let japaneseFinal: String
        let japaneseCER: Double?
        let highConfidenceCERLowerBound: Double?
        let highConfidenceCERUpperBound: Double?
        let highConfidenceSourceCoverage: Double
        let highConfidencePreviewCoverage: Double
        let highConfidenceFinalCoverage: Double
        let lastAnnotatedSpeechPresent: Bool
        let confirmedPrefixRewriteCount: Int
        let previewRevisionCount: Int
        let previewSourceFirstLatencyMilliseconds: [Double]
        let previewFirstLatencyMilliseconds: [Double]
        let previewTranslationMilliseconds: [Double]
        let finalEndpointLatencyMilliseconds: [Double]
        let maximumProcessingBacklogSeconds: Double
        let endingProcessingBacklogSeconds: Double
        let maximumPolicyLagSeconds: Double
        let endingPolicyLagSeconds: Double
        let maximumObservedResidentBytes: UInt64?
        let averageCPUPercent: Double?
        let thermalStateBefore: String
        let thermalStateAfter: String
        let errors: [String]
    }

    private struct CorpusProvenance: Codable, Sendable {
        let corpusID: String
        let manifestSHA256: String
        let audioSHA256: String
        let annotationStatus: String
    }

    private struct LiveReport: Codable, Sendable {
        let schemaVersion: Int
        let runID: String
        let gitCommit: String
        let sourceTreeSHA256: String
        let runtimeSHA256: String
        let worktreeDirty: Bool
        let remoteNetworkDeniedForXCTest: Bool
        let generatedAt: String
        let macOSVersion: String
        let macOSBuild: String
        let replayCount: Int
        let blockSamples: Int
        let modelRecipesSHA256: String
        let matrixAttempted: Bool
        let matrixComplete: Bool
        let promotionEligible: Bool
        let whisperLiveKitVersion: String
        let whisperLiveKitCommit: String
        let whisperLiveKitArchitecture: String
        let whisperLiveKitUVLockSHA256: String
        let whisperLiveKitEncoderConfigSHA256: String
        let whisperLiveKitEncoderWeightsSHA256: String
        let whisperLiveKitDecoderSHA256: String?
        let whisperLiveKitWarmupSHA256: String
        let whisperLiveKitConfiguration: [String: String]
        let memoryMeasurementScope: String
        let setupErrors: [String]
        let corpora: [CorpusProvenance]
        let sessions: [SessionReport]
    }

    private struct WLKConfig: Decodable {
        let type: String
        let useAudioWorklet: Bool
        let mode: String?
    }

    private struct WLKLine: Codable, Equatable, Sendable {
        let speaker: Int
        let text: String?
        let start: String?
        let end: String?
    }

    private struct WLKUpdate: Decodable, Sendable {
        let type: String?
        let lines: [WLKLine]?
        let sequence: Int?
        let lineCount: Int?
        let linesPruned: Int?
        let newLines: [WLKLine]?
        let bufferTranscription: String?
        let remainingTimeTranscription: Double?
        let remainingTimeTranscriptionProcessing: Double?
        let remainingTimeTranscriptionPolicy: Double?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type, lines, error
            case sequence = "seq"
            case lineCount = "n_lines"
            case linesPruned = "lines_pruned"
            case newLines = "new_lines"
            case bufferTranscription = "buffer_transcription"
            case remainingTimeTranscription = "remaining_time_transcription"
            case remainingTimeTranscriptionProcessing = "remaining_time_transcription_processing"
            case remainingTimeTranscriptionPolicy = "remaining_time_transcription_policy"
        }
    }

    private struct ProcessUsage {
        let residentBytes: UInt64
        let cpuNanoseconds: UInt64
    }

    private struct FinalSummary {
        let events: [FinalTranslationEvent]
    }

    private static let blockSamples = 1_600
    private static let windows = JapaneseBenchmarkSupport.correctiveStressWindows

    @available(macOS 26.4, *)
    func testWhisperLiveKitDiffReconstructsRewrittenSuffix() throws {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(WLKUpdate.self, from: Data("""
        {
          "seq": 1,
          "n_lines": 2,
          "lines": [
            {"speaker": 0, "text": "前", "start": "00:00:00.000", "end": "00:00:01.000"},
            {"speaker": 0, "text": "古い", "start": "00:00:01.000", "end": "00:00:02.000"}
          ]
        }
        """.utf8))
        let changed = try decoder.decode(WLKUpdate.self, from: Data("""
        {
          "seq": 2,
          "n_lines": 2,
          "lines_pruned": 0,
          "new_lines": [
            {"speaker": 0, "text": "新しい", "start": "00:00:01.000", "end": "00:00:02.200"}
          ]
        }
        """.utf8))
        let initial = try XCTUnwrap(WLKCollector.reconstructWireLines([], update: snapshot))
        let result = try XCTUnwrap(WLKCollector.reconstructWireLines(initial, update: changed))
        XCTAssertEqual(result.compactMap(\.text), ["前", "新しい"])

        let pruned = try decoder.decode(WLKUpdate.self, from: Data("""
        {
          "seq": 3,
          "n_lines": 1,
          "lines_pruned": 1
        }
        """.utf8))
        let prunedResult = try XCTUnwrap(
            WLKCollector.reconstructWireLines(result, update: pruned)
        )
        XCTAssertEqual(prunedResult.compactMap(\.text), ["新しい"])
    }

    func testPCM16WireEncodingPreservesCanonicalExtremes() {
        let values: [Float] = [-1, -0.5, 0, 0.5, 1]
        let data = pcmS16LE(values[...])
        let decoded = data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(decoded, [-32_768, -16_384, 0, 16_384, 32_767])
    }

    @MainActor
    func testStressSourcesWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_L6_LIVE_REPLAY"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_live_replay.sh after preparing L6.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("The L6 live replay requires Apple Speech and Translation.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelRecipesSHA256 = try JapaneseBenchmarkSupport.sha256(
            at: root.appendingPathComponent("docs/japanese-live/model-recipes.json")
        )
        let replayCount = max(1, Int(environment["WHISPERASR_L6_REPLAY_COUNT"] ?? "1") ?? 1)
        let windowLimit = min(
            Self.windows.count,
            max(1, Int(environment["WHISPERASR_L6_WINDOW_LIMIT"] ?? "1") ?? 1)
        )
        let windows = Array(Self.windows.prefix(windowLimit))
        let requestedSources = Set((environment["WHISPERASR_L6_SOURCES"]
            ?? "apple-speech,whisperlivekit").split(separator: ",").map(String.init))
        guard !requestedSources.isEmpty,
              requestedSources.isSubset(of: ["apple-speech", "whisperlivekit"]) else {
            throw inputError("Unknown or empty WHISPERASR_L6_SOURCES.")
        }
        let whisperLiveKitPolicy = environment["WHISPERASR_WLK_POLICY"] ?? "simulstreaming"
        guard ["simulstreaming", "localagreement"].contains(whisperLiveKitPolicy) else {
            throw inputError("Unknown WHISPERASR_WLK_POLICY.")
        }
        let whisperLiveKitMinChunk = environment["WHISPERASR_WLK_MIN_CHUNK_SECONDS"]
            ?? "0.1"
        guard let minimumChunkSeconds = Double(whisperLiveKitMinChunk),
              minimumChunkSeconds >= 0.1,
              minimumChunkSeconds <= 5 else {
            throw inputError("Invalid WHISPERASR_WLK_MIN_CHUNK_SECONDS.")
        }
        let inputs = try await loadInputs(root: root)

        let low = AppleTranslationService()
        try await low.configure(sourceLocale: "ja", mode: .lowLatencyOnly)
        try await low.warmup(highFidelity: false)
        var high: AppleTranslationService?
        var setupErrors: [String] = []
        if requestedSources.contains("whisperlivekit") {
            let candidate = AppleTranslationService()
            do {
                try await candidate.configure(sourceLocale: "ja", mode: .highFidelityOnly)
                try await candidate.warmup(highFidelity: true)
                high = candidate
            } catch {
                setupErrors.append("Apple highFidelity unavailable with WhisperLiveKit loaded: \(error)")
            }
        }
        defer {
            Task {
                await low.cancel()
                if let high { await high.cancel() }
            }
        }

        var sessions: [SessionReport] = []
        if requestedSources.contains("apple-speech") {
            let speech = AppleSpeechService()
            try await speech.prepare(localeIdentifier: "ja-JP") { _ in }
            for replay in 1...replayCount {
                for window in windows {
                    sessions.append(try await replayAppleSpeech(
                        sessionID: "apple-speech:\(window.id):r\(replay)",
                        window: window,
                        replay: replay,
                        samples: inputs.samples[window.corpusID]!,
                        manifest: inputs.manifests[window.corpusID]!,
                        speech: speech,
                        low: low
                    ))
                }
            }
        }

        if requestedSources.contains("whisperlivekit") {
            guard let url = URL(string: environment["WHISPERASR_WLK_URL"]
                ?? "ws://127.0.0.1:8765/asr?language=ja&mode=diff") else {
                throw inputError("Invalid WHISPERASR_WLK_URL.")
            }
            let serverPID = Int32(environment["WHISPERASR_WLK_PID"] ?? "") ?? 0
            guard serverPID > 0 else { throw inputError("Missing WHISPERASR_WLK_PID.") }
            for replay in 1...replayCount {
                for window in windows {
                    sessions.append(try await replayWhisperLiveKit(
                        sessionID: "whisperlivekit-\(whisperLiveKitPolicy):\(window.id):r\(replay)",
                        window: window,
                        replay: replay,
                        allSamples: inputs.samples[window.corpusID]!,
                        manifest: inputs.manifests[window.corpusID]!,
                        url: url,
                        policy: whisperLiveKitPolicy,
                        serverPID: serverPID,
                        low: low,
                        high: high,
                        setupErrors: setupErrors
                    ))
                }
            }
        }

        var whisperLiveKitConfiguration = [
            "backendPolicy": whisperLiveKitPolicy,
            "backend": "mlx-whisper",
            "model": "large-v3-turbo",
            "encoderRevision": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
            "language": "ja",
            "mode": "diff",
            "retentionSeconds": "300",
            "transportBlockSamples": "1600",
            "minChunkSeconds": String(minimumChunkSeconds),
            "vacChunkSeconds": "0.04",
            "vac": "Silero ONNX CPU",
            "vadFlagEffective": "false",
            "pcmInput": "s16le-16k-mono",
            "eosTimeoutSeconds": "120",
        ]
        if whisperLiveKitPolicy == "simulstreaming" {
            whisperLiveKitConfiguration["decoder"] = "beam"
            whisperLiveKitConfiguration["beams"] = "1"
            whisperLiveKitConfiguration["frameThreshold"] = "25"
            whisperLiveKitConfiguration["audioMaxSeconds"] = "30"
            whisperLiveKitConfiguration["audioMinSeconds"] = "0"
        } else {
            whisperLiveKitConfiguration["bufferTrimming"] = "segment"
            whisperLiveKitConfiguration["bufferTrimmingSeconds"] = "15"
            whisperLiveKitConfiguration["wordTimestamps"] = "true"
            whisperLiveKitConfiguration["conditionOnPreviousText"] = "true"
        }
        let expectedAttemptKeys = Set(Self.windows.flatMap { window in
            (1...3).map { "\(window.id):\($0)" }
        })
        let actualAttemptKeys = sessions.map { "\($0.windowID):\($0.replay)" }
        let matrixAttempted = requestedSources == ["whisperlivekit"]
            && replayCount == 3
            && windowLimit == Self.windows.count
            && sessions.count == 12
            && Set(actualAttemptKeys) == expectedAttemptKeys
            && Set(actualAttemptKeys).count == actualAttemptKeys.count
        let matrixComplete = matrixAttempted
            && sessions.allSatisfy {
                $0.errors.isEmpty
                    && !$0.japaneseFinal.isEmpty
                    && $0.sentSampleCount == $0.expectedSampleCount
                    && $0.readyToStopReceived
            }
        let report = LiveReport(
            schemaVersion: 7,
            runID: environment["WHISPERASR_L6_RUN_ID"] ?? "l6-live",
            gitCommit: environment["WHISPERASR_BENCHMARK_COMMIT"] ?? "unknown",
            sourceTreeSHA256: environment["WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256"]
                ?? "unknown",
            runtimeSHA256: environment["WHISPERASR_BENCHMARK_RUNTIME_SHA256"]
                ?? "unknown",
            worktreeDirty: environment["WHISPERASR_BENCHMARK_DIRTY"] == "1",
            remoteNetworkDeniedForXCTest:
                environment["WHISPERASR_REMOTE_NETWORK_DENIED"] == "1",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: environment["WHISPERASR_MACOS_VERSION"]
                ?? ProcessInfo.processInfo.operatingSystemVersionString,
            macOSBuild: environment["WHISPERASR_MACOS_BUILD"] ?? "unknown",
            replayCount: replayCount,
            blockSamples: Self.blockSamples,
            modelRecipesSHA256: modelRecipesSHA256,
            matrixAttempted: matrixAttempted,
            matrixComplete: matrixComplete,
            promotionEligible: false,
            whisperLiveKitVersion: "0.2.24",
            whisperLiveKitCommit: "5874bdeeaddf968ab73e005eb287e1b597b0eb37",
            whisperLiveKitArchitecture: whisperLiveKitPolicy == "simulstreaming"
                ? "SimulStreaming: MLX encoder + PyTorch CPU decoder/alignment"
                : "LocalAgreement: MLX Whisper + longest common prefix",
            whisperLiveKitUVLockSHA256:
                "06750b16caa60432e7d1a9427cd2196e6bf926f20fc15d3c77cba78469e99ec1",
            whisperLiveKitEncoderConfigSHA256:
                "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379",
            whisperLiveKitEncoderWeightsSHA256:
                "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6",
            whisperLiveKitDecoderSHA256: whisperLiveKitPolicy == "simulstreaming"
                ? "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a"
                : nil,
            whisperLiveKitWarmupSHA256:
                "82df6b6ad5cebc55f727443d4a1c5c4a11d2c26cb75ef43e9ee091b8b7029ae5",
            whisperLiveKitConfiguration: whisperLiveKitConfiguration,
            memoryMeasurementScope:
                "Peak sampled sum of XCTest and explicit ASR server PIDs; Apple system services excluded.",
            setupErrors: setupErrors,
            corpora: inputs.provenance,
            sessions: sessions
        )
        try write(report: report, root: root)

        XCTAssertFalse(sessions.isEmpty)
        XCTAssertTrue(sessions.allSatisfy { $0.maximumObservedResidentBytes != nil })
        if requestedSources == ["whisperlivekit"], replayCount == 3,
           windowLimit == Self.windows.count {
            XCTAssertEqual(sessions.count, 12)
            XCTAssertTrue(matrixAttempted)
        }
    }

    @MainActor
    @available(macOS 26.4, *)
    private func replayAppleSpeech(
        sessionID: String,
        window: StressWindow,
        replay: Int,
        samples: [Float],
        manifest: JapaneseBenchmarkSupport.Manifest,
        speech: AppleSpeechService,
        low: AppleTranslationService
    ) async throws -> SessionReport {
        let localSamples = Array(samples[window.startSample..<window.endSample])
        let started = DispatchTime.now().uptimeNanoseconds
        let pids = [getpid()]
        let usageBefore = processUsage(pids: pids)
        let resourceSampler = startResourceSampler(pids: pids)
        defer { resourceSampler.cancel() }
        let thermalBefore = thermalState()
        let preview = BenchmarkPreviewTranslator(service: low, highFidelity: false)
        var planner = LocalPreviewPlanner()
        var sourceEvents: [SourceEvent] = []
        var sequence = 0
        var failure: Error?
        var submissions: [Task<Void, Never>] = []

        try await speech.start(
            localeIdentifier: "ja-JP",
            priority: .userInitiated,
            onUpdate: { update in
                let received = DispatchTime.now().uptimeNanoseconds
                sequence += 1
                let localStart = max(0, Int((update.segment.start * 16_000).rounded()))
                let localEnd = min(
                    window.sampleCount,
                    max(localStart, Int(((update.segment.end ?? update.segment.start) * 16_000).rounded()))
                )
                sourceEvents.append(SourceEvent(
                    sequence: sequence,
                    stability: update.isFinal ? "final" : "revisable",
                    text: update.segment.text,
                    localStartSample: localStart,
                    localEndSample: localEnd,
                    absoluteStartSample: window.startSample + localStart,
                    absoluteEndSample: window.startSample + localEnd,
                    isFinal: update.isFinal,
                    receivedMilliseconds: elapsedMilliseconds(received, after: started)
                ))
                planner.submit(update, receivedUptimeNanoseconds: received)
                if let work = planner.takeLatest() {
                    let startSample = max(
                        0,
                        Int((work.update.segment.start * 16_000).rounded())
                    )
                    let endSample = min(
                        window.sampleCount,
                        max(startSample, Int(((work.update.segment.end
                            ?? work.update.segment.start) * 16_000).rounded()))
                    )
                    submissions.append(Task {
                        await preview.submit(
                            source: work.update.segment.text,
                            phraseKey: UInt64(work.generation),
                            phraseStartUptimeNanoseconds: started
                                + UInt64(startSample) * 1_000_000_000 / 16_000,
                            receivedUptimeNanoseconds: received,
                            sourceStartSample: window.startSample + startSample,
                            sourceEndSample: window.startSample + endSample
                        )
                    })
                }
                if update.isFinal {
                    planner.advanceBoundary(through: max(localEnd, update.finalizedThroughSample))
                }
            },
            onFailure: { failure = $0 }
        )
        let finalizer = Task { @MainActor in
            var target = LocalAppleSpeechFeedState.progressiveFinalizationInterval
            while target < localSamples.count {
                try await sleep(until: started + UInt64(target) * 1_000_000_000 / 16_000)
                try await speech.finalizeAvailableAudio()
                target += LocalAppleSpeechFeedState.progressiveFinalizationInterval
            }
        }
        let send = try await replayInRealTime(localSamples, sessionStart: started) {
            samples, range in
            try await speech.send(samples: Array(samples), startSample: range.lowerBound)
        }
        try await finalizer.value
        try await speech.finish()
        for task in submissions { await task.value }
        let previewSummary = await preview.finish()
        resourceSampler.cancel()
        let maximumResidentBytes = await resourceSampler.value
        if let failure { throw failure }

        let finalFragments = sourceEvents.filter(\.isFinal).compactMap {
            fragment(from: $0, id: $0.sequence)
        }
        return sessionReport(
            sessionID: sessionID,
            source: "apple-speech",
            window: window,
            replay: replay,
            manifest: manifest,
            sentSampleCount: send.sent,
            readyToStopReceived: true,
            finalBoundaryMode: "not-applicable-preview-source",
            maximumSendLatenessMilliseconds: send.maximumLateness,
            sourceEvents: sourceEvents,
            volatileEvents: [],
            preview: previewSummary,
            final: FinalSummary(events: []),
            finalFragments: finalFragments,
            confirmedPrefixRewriteCount: 0,
            maximumProcessingBacklogSeconds: 0,
            endingProcessingBacklogSeconds: 0,
            maximumPolicyLagSeconds: 0,
            endingPolicyLagSeconds: 0,
            maximumObservedResidentBytes: maximumResidentBytes,
            usageBefore: usageBefore,
            usageAfter: processUsage(pids: pids),
            thermalBefore: thermalBefore,
            thermalAfter: thermalState(),
            started: started,
            errors: []
        )
    }

    @MainActor
    @available(macOS 26.4, *)
    private func replayWhisperLiveKit(
        sessionID: String,
        window: StressWindow,
        replay: Int,
        allSamples: [Float],
        manifest: JapaneseBenchmarkSupport.Manifest,
        url: URL,
        policy: String,
        serverPID: Int32,
        low: AppleTranslationService,
        high: AppleTranslationService?,
        setupErrors: [String]
    ) async throws -> SessionReport {
        let samples = Array(allSamples[window.startSample..<window.endSample])
        let pids = [getpid(), serverPID]
        let usageBefore = processUsage(pids: pids)
        let resourceSampler = startResourceSampler(pids: pids)
        defer { resourceSampler.cancel() }
        let thermalBefore = thermalState()
        let preview = BenchmarkPreviewTranslator(service: low, highFidelity: false)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 70
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let configData = try await messageData(socket.receive())
        let config = try JSONDecoder().decode(WLKConfig.self, from: configData)
        guard config.type == "config", config.useAudioWorklet, config.mode == "diff" else {
            throw inputError("WhisperLiveKit did not accept raw PCM diff mode.")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let collector = WLKCollector(
            window: window,
            sessionStart: started,
            preview: preview
        )

        let receiver = Task {
            while !Task.isCancelled {
                let data = try await messageData(socket.receive())
                let update = try JSONDecoder().decode(WLKUpdate.self, from: data)
                if update.type == "ready_to_stop" {
                    await collector.accept(update, received: DispatchTime.now().uptimeNanoseconds)
                    await collector.finish(received: DispatchTime.now().uptimeNanoseconds)
                    return
                }
                await collector.accept(update, received: DispatchTime.now().uptimeNanoseconds)
            }
        }
        var sentSampleCount = 0
        var maximumSendLateness = 0.0
        var transportErrors = setupErrors
        do {
            let send = try await replayInRealTime(samples, sessionStart: started) {
                samples, _ in
                try await socket.send(.data(pcmS16LE(samples)))
            }
            sentSampleCount = send.sent
            maximumSendLateness = send.maximumLateness
            try await socket.send(.data(Data()))
            let timeout = Task {
                try await Task.sleep(for: .seconds(120))
                socket.cancel(with: .goingAway, reason: Data("timeout".utf8))
            }
            defer { timeout.cancel() }
            try await receiver.value
        } catch {
            transportErrors.append("WhisperLiveKit transport: \(error.localizedDescription)")
            socket.cancel(with: .goingAway, reason: Data("session-failed".utf8))
            receiver.cancel()
            _ = await receiver.result
        }

        let snapshot = await collector.snapshot()
        let previewSummary = await preview.finish()
        let finalSummary = await translateEOSFinal(
            service: high,
            sessionID: sessionID,
            sessionStart: started,
            window: window,
            snapshot: snapshot,
            unavailableReason: setupErrors.first
        )
        resourceSampler.cancel()
        let maximumResidentBytes = await resourceSampler.value
        return sessionReport(
            sessionID: sessionID,
            source: policy == "simulstreaming"
                ? "whisperlivekit-simulstreaming-mlx-encoder-pytorch-cpu-decoder"
                : "whisperlivekit-localagreement-mlx",
            window: window,
            replay: replay,
            manifest: manifest,
            sentSampleCount: sentSampleCount,
            readyToStopReceived: snapshot.readyReceivedAt != nil,
            finalBoundaryMode: "window-eos-only-no-live-phrase-final",
            maximumSendLatenessMilliseconds: maximumSendLateness,
            sourceEvents: snapshot.sourceEvents,
            volatileEvents: snapshot.volatileEvents,
            preview: previewSummary,
            final: finalSummary,
            finalFragments: snapshot.finalFragments,
            confirmedPrefixRewriteCount: snapshot.confirmedPrefixRewrites,
            maximumProcessingBacklogSeconds: snapshot.maximumProcessingBacklog,
            endingProcessingBacklogSeconds: snapshot.lastReportedProcessingBacklog,
            maximumPolicyLagSeconds: snapshot.maximumPolicyLag,
            endingPolicyLagSeconds: snapshot.lastReportedPolicyLag,
            maximumObservedResidentBytes: maximumResidentBytes,
            usageBefore: usageBefore,
            usageAfter: processUsage(pids: pids),
            thermalBefore: thermalBefore,
            thermalAfter: thermalState(),
            started: started,
            errors: snapshot.errors + transportErrors
        )
    }

    @available(macOS 26.4, *)
    private func translateEOSFinal(
        service: AppleTranslationService?,
        sessionID: String,
        sessionStart: UInt64,
        window: StressWindow,
        snapshot: WLKCollector.Snapshot,
        unavailableReason: String?
    ) async -> FinalSummary {
        let japanese = snapshot.finalFragments.map(\.text).joined(separator: " ")
        let received = snapshot.readyReceivedAt ?? DispatchTime.now().uptimeNanoseconds
        let translationStarted = DispatchTime.now().uptimeNanoseconds
        var english = ""
        var failure: String?
        if japanese.isEmpty {
            failure = "WhisperLiveKit returned an empty EOS transcript."
        } else if let service {
            do {
                english = try EnglishSubtitleValidator.requireEnglish(
                    try await service.translate(japanese, highFidelity: true)
                )
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = unavailableReason ?? "Apple highFidelity unavailable"
        }
        let completed = DispatchTime.now().uptimeNanoseconds
        let endpoint = sessionStart
            + UInt64(window.sampleCount) * 1_000_000_000 / 16_000
        let event = FinalTranslationEvent(
            finalID: "\(sessionID):eos",
            sourceSequence: snapshot.sourceEvents.last?.sequence ?? 0,
            japanese: japanese,
            english: english,
            localStartSample: 0,
            localEndSample: window.sampleCount,
            sourceReceivedMilliseconds: elapsedMilliseconds(received, after: sessionStart),
            translationStartedMilliseconds: elapsedMilliseconds(
                translationStarted,
                after: sessionStart
            ),
            acceptedMilliseconds: elapsedMilliseconds(completed, after: sessionStart),
            endpointToAcceptedMilliseconds: elapsedMilliseconds(completed, after: endpoint),
            error: failure
        )
        return FinalSummary(events: [event])
    }

    @available(macOS 26.4, *)
    private actor WLKCollector {
        enum DiffError: Error {
            case count, pruned, suffix
        }

        struct Snapshot {
            let sourceEvents: [SourceEvent]
            let volatileEvents: [SourceEvent]
            let finalFragments: [ManyToManyTurnScorer.Fragment]
            let confirmedPrefixRewrites: Int
            let maximumProcessingBacklog: Double
            let lastReportedProcessingBacklog: Double
            let maximumPolicyLag: Double
            let lastReportedPolicyLag: Double
            let readyReceivedAt: UInt64?
            let errors: [String]
        }

        private let window: StressWindow
        private let sessionStart: UInt64
        private let preview: BenchmarkPreviewTranslator
        private var wireLines: [WLKLine] = []
        private var lines: [WLKLine] = []
        private var sourceEvents: [SourceEvent] = []
        private var volatileEvents: [SourceEvent] = []
        private var lastBuffer = ""
        private var sequence = 0
        private var lastWireSequence: Int?
        private var confirmedPrefixRewrites = 0
        private var maximumProcessingBacklog = 0.0
        private var lastReportedProcessingBacklog = 0.0
        private var maximumPolicyLag = 0.0
        private var lastReportedPolicyLag = 0.0
        private var readyReceivedAt: UInt64?
        private var errors: [String] = []

        init(
            window: StressWindow,
            sessionStart: UInt64,
            preview: BenchmarkPreviewTranslator
        ) {
            self.window = window
            self.sessionStart = sessionStart
            self.preview = preview
        }

        nonisolated static func reconstructWireLines(
            _ current: [WLKLine],
            update: WLKUpdate
        ) throws -> [WLKLine]? {
            if let snapshot = update.lines {
                guard update.lineCount == nil || update.lineCount == snapshot.count else {
                    throw DiffError.count
                }
                return snapshot
            }
            guard let count = update.lineCount,
                  update.linesPruned != nil || update.newLines != nil else {
                return nil
            }
            let newLines = update.newLines ?? []
            let pruned = update.linesPruned ?? 0
            guard pruned >= 0, pruned <= current.count else { throw DiffError.pruned }
            let retained = Array(current.dropFirst(pruned))
            let prefixCount = count - newLines.count
            guard prefixCount >= 0, prefixCount <= retained.count else {
                throw DiffError.suffix
            }
            let result = Array(retained.prefix(prefixCount)) + newLines
            guard result.count == count else { throw DiffError.count }
            return result
        }

        func accept(_ update: WLKUpdate, received: UInt64) async {
            if let error = update.error, !error.isEmpty { errors.append(error) }
            let processing = max(
                0,
                update.remainingTimeTranscriptionProcessing
                    ?? update.remainingTimeTranscription ?? 0
            )
            let policy = max(0, update.remainingTimeTranscriptionPolicy ?? 0)
            maximumProcessingBacklog = max(maximumProcessingBacklog, processing)
            lastReportedProcessingBacklog = processing
            maximumPolicyLag = max(maximumPolicyLag, policy)
            lastReportedPolicyLag = policy

            if let rawBuffer = update.bufferTranscription {
                let buffer = rawBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if buffer != lastBuffer {
                    sequence += 1
                    volatileEvents.append(SourceEvent(
                        sequence: sequence,
                        stability: "volatile-buffer-diagnostic",
                        text: buffer,
                        localStartSample: nil,
                        localEndSample: nil,
                        absoluteStartSample: nil,
                        absoluteEndSample: nil,
                        isFinal: false,
                        receivedMilliseconds: elapsedMilliseconds(received, after: sessionStart)
                    ))
                    lastBuffer = buffer
                }
            }

            if let wireSequence = update.sequence {
                if let previous = lastWireSequence, wireSequence != previous + 1 {
                    errors.append(
                        "WhisperLiveKit diff sequence gap: expected \(previous + 1), got \(wireSequence)."
                    )
                    return
                }
                lastWireSequence = wireSequence
            }

            do {
                guard let reconstructed = try Self.reconstructWireLines(
                    wireLines,
                    update: update
                ) else { return }
                wireLines = reconstructed
            } catch {
                errors.append("WhisperLiveKit diff reconstruction failed: \(error).")
                return
            }

            let current = wireLines.filter {
                $0.speaker != -2
                    && $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            let sharedCount = min(lines.count, current.count)
            for index in 0..<sharedCount where !isCompatibleUpdate(
                from: lines[index],
                to: current[index]
            ) {
                confirmedPrefixRewrites += 1
            }
            if current.count < lines.count {
                confirmedPrefixRewrites += lines.count - current.count
            }

            if current.last != lines.last,
               let line = current.last,
               let text = normalizedText(line),
               let start = sample(from: line.start),
               let end = sample(from: line.end),
               end > start {
                sequence += 1
                sourceEvents.append(SourceEvent(
                    sequence: sequence,
                    stability: "confirmed-prefix",
                    text: text,
                    localStartSample: start,
                    localEndSample: end,
                    absoluteStartSample: window.startSample + start,
                    absoluteEndSample: window.startSample + end,
                    isFinal: false,
                    receivedMilliseconds: elapsedMilliseconds(received, after: sessionStart)
                ))
                await preview.submit(
                    source: text,
                    phraseKey: UInt64(start),
                    phraseStartUptimeNanoseconds: sessionStart
                        + UInt64(start) * 1_000_000_000 / 16_000,
                    receivedUptimeNanoseconds: received,
                    sourceStartSample: window.startSample + start,
                    sourceEndSample: window.startSample + end
                )
            }
            lines = current
        }

        func finish(received: UInt64) {
            readyReceivedAt = received
            appendFinalEvents(received: received)
        }

        func snapshot() -> Snapshot {
            let fragments = lines.enumerated().compactMap { index, line -> ManyToManyTurnScorer.Fragment? in
                guard let text = line.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      let start = sample(from: line.start),
                      let end = sample(from: line.end),
                      end > start else { return nil }
                return ManyToManyTurnScorer.Fragment(
                    id: index + 1,
                    startSample: window.startSample + start,
                    endSample: window.startSample + end,
                    text: text
                )
            }
            return Snapshot(
                sourceEvents: sourceEvents,
                volatileEvents: volatileEvents,
                finalFragments: fragments,
                confirmedPrefixRewrites: confirmedPrefixRewrites,
                maximumProcessingBacklog: maximumProcessingBacklog,
                lastReportedProcessingBacklog: lastReportedProcessingBacklog,
                maximumPolicyLag: maximumPolicyLag,
                lastReportedPolicyLag: lastReportedPolicyLag,
                readyReceivedAt: readyReceivedAt,
                errors: errors
            )
        }

        private func appendFinalEvents(received: UInt64) {
            for line in lines {
                guard let text = normalizedText(line),
                      let start = sample(from: line.start),
                      let end = sample(from: line.end),
                      end > start else { continue }
                sequence += 1
                sourceEvents.append(SourceEvent(
                    sequence: sequence,
                    stability: "eos-final",
                    text: text,
                    localStartSample: start,
                    localEndSample: end,
                    absoluteStartSample: window.startSample + start,
                    absoluteEndSample: window.startSample + end,
                    isFinal: true,
                    receivedMilliseconds: elapsedMilliseconds(received, after: sessionStart)
                ))
            }
        }

        private func isCompatibleUpdate(
            from old: WLKLine,
            to new: WLKLine
        ) -> Bool {
            guard old.start == new.start,
                  let oldText = normalizedText(old),
                  let newText = normalizedText(new) else { return old == new }
            guard newText.hasPrefix(oldText),
                  let oldEnd = sample(from: old.end),
                  let newEnd = sample(from: new.end) else { return false }
            return newEnd >= oldEnd
        }

        private func normalizedText(_ line: WLKLine) -> String? {
            guard let text = line.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }

        private func sample(from timestamp: String?) -> Int? {
            guard let timestamp else { return nil }
            let parts = timestamp.split(separator: ":")
            guard parts.count == 3,
                  let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            let value = Int(((hours * 3_600 + minutes * 60 + seconds) * 16_000).rounded())
            return min(window.sampleCount, max(0, value))
        }
    }

    private func sessionReport(
        sessionID: String,
        source: String,
        window: StressWindow,
        replay: Int,
        manifest: JapaneseBenchmarkSupport.Manifest,
        sentSampleCount: Int,
        readyToStopReceived: Bool,
        finalBoundaryMode: String,
        maximumSendLatenessMilliseconds: Double,
        sourceEvents: [SourceEvent],
        volatileEvents: [SourceEvent],
        preview: BenchmarkPreviewTranslationSummary,
        final: FinalSummary,
        finalFragments: [ManyToManyTurnScorer.Fragment],
        confirmedPrefixRewriteCount: Int,
        maximumProcessingBacklogSeconds: Double,
        endingProcessingBacklogSeconds: Double,
        maximumPolicyLagSeconds: Double,
        endingPolicyLagSeconds: Double,
        maximumObservedResidentBytes: UInt64?,
        usageBefore: ProcessUsage?,
        usageAfter: ProcessUsage?,
        thermalBefore: String,
        thermalAfter: String,
        started: UInt64,
        errors: [String]
    ) -> SessionReport {
        let turns = JapaneseBenchmarkSupport.referenceTurns(
            manifest: manifest,
            window: window
        )
        let cer = ContinuousJapaneseCER.score(
            turns: turns,
            finalSourceFragments: finalFragments
        )
        let review = ManyToManyTurnScorer.reviewGroups(
            turns: turns,
            candidatesByRole: ["source": finalFragments]
        )
        let primary = review.filter { $0.highConfidenceTurnCount == 1 }
        let sourceCoverage = coverage(primary, role: "source")
        let previewFragments = preview.events.enumerated().compactMap {
            index, event -> ManyToManyTurnScorer.Fragment? in
            guard event.error == nil,
                  let start = event.sourceStartSample,
                  let end = event.sourceEndSample,
                  end > start else { return nil }
            return ManyToManyTurnScorer.Fragment(
                id: index + 1,
                startSample: start,
                endSample: end,
                text: event.english
            )
        }
        let previewReview = ManyToManyTurnScorer.reviewGroups(
            turns: turns,
            candidatesByRole: ["preview": previewFragments]
        ).filter { $0.highConfidenceTurnCount == 1 }
        let finalTranslationFragments = final.events.enumerated().compactMap {
            index, event -> ManyToManyTurnScorer.Fragment? in
            guard event.error == nil, !event.english.isEmpty,
                  event.localEndSample > event.localStartSample else { return nil }
            return ManyToManyTurnScorer.Fragment(
                id: index + 1,
                startSample: window.startSample + event.localStartSample,
                endSample: window.startSample + event.localEndSample,
                text: event.english
            )
        }
        let finalReview = ManyToManyTurnScorer.reviewGroups(
            turns: turns,
            candidatesByRole: ["final": finalTranslationFragments]
        ).filter { $0.highConfidenceTurnCount == 1 }
        let lastTurn = turns.max { $0.endSample < $1.endSample }
        let lastPresent = lastTurn.map {
            JapaneseBenchmarkSupport.lastSpeechEvidence(
                turn: $0,
                fragments: finalFragments
            ).heuristicPresent
        } ?? false
        let cpuPercent: Double?
        if let before = usageBefore, let after = usageAfter,
           after.cpuNanoseconds >= before.cpuNanoseconds {
            let elapsed = max(1, DispatchTime.now().uptimeNanoseconds - started)
            cpuPercent = Double(after.cpuNanoseconds - before.cpuNanoseconds)
                / Double(elapsed) * 100
        } else {
            cpuPercent = nil
        }
        return SessionReport(
            sessionID: sessionID,
            source: source,
            corpusID: window.corpusID,
            windowID: window.id,
            replay: replay,
            windowStartSample: window.startSample,
            windowEndSample: window.endSample,
            expectedSampleCount: window.sampleCount,
            sentSampleCount: sentSampleCount,
            readyToStopReceived: readyToStopReceived,
            finalBoundaryMode: finalBoundaryMode,
            maximumSendLatenessMilliseconds: maximumSendLatenessMilliseconds,
            sourceEvents: sourceEvents,
            volatileEvents: volatileEvents,
            previewEvents: preview.events,
            finalEvents: final.events,
            japaneseFinal: finalFragments.map(\.text).joined(),
            japaneseCER: cer?.overall.rate,
            highConfidenceCERLowerBound: cer?.highConfidence.rateLowerBound,
            highConfidenceCERUpperBound: cer?.highConfidence.rateUpperBound,
            highConfidenceSourceCoverage: sourceCoverage,
            highConfidencePreviewCoverage: coverage(previewReview, role: "preview"),
            highConfidenceFinalCoverage: min(
                sourceCoverage,
                coverage(finalReview, role: "final")
            ),
            lastAnnotatedSpeechPresent: lastPresent,
            confirmedPrefixRewriteCount: confirmedPrefixRewriteCount,
            previewRevisionCount: preview.revisions.reduce(0) {
                $0 + max(0, $1 - 1)
            },
            previewSourceFirstLatencyMilliseconds: preview.sourceLatencies,
            previewFirstLatencyMilliseconds: preview.firstLatencies,
            previewTranslationMilliseconds: preview.translationLatencies,
            finalEndpointLatencyMilliseconds: final.events.map(\.endpointToAcceptedMilliseconds),
            maximumProcessingBacklogSeconds: maximumProcessingBacklogSeconds,
            endingProcessingBacklogSeconds: endingProcessingBacklogSeconds,
            maximumPolicyLagSeconds: maximumPolicyLagSeconds,
            endingPolicyLagSeconds: endingPolicyLagSeconds,
            maximumObservedResidentBytes: maximumObservedResidentBytes,
            averageCPUPercent: cpuPercent,
            thermalStateBefore: thermalBefore,
            thermalStateAfter: thermalAfter,
            errors: errors + preview.events.compactMap(\.error)
                + final.events.compactMap(\.error)
        )
    }

    private func loadInputs(root: URL) async throws -> (
        manifests: [String: JapaneseBenchmarkSupport.Manifest],
        samples: [String: [Float]],
        provenance: [CorpusProvenance]
    ) {
        var manifests: [String: JapaneseBenchmarkSupport.Manifest] = [:]
        var samples: [String: [Float]] = [:]
        var provenance: [CorpusProvenance] = []
        for corpusID in ["qudu2fx3ncc", "md62mmdz0m"] {
            let manifestURL = root.appendingPathComponent(
                "docs/japanese-live/corpora/\(corpusID)/manifest.json"
            )
            let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
            let audioURL = root.appendingPathComponent(manifest.fixture.path)
            let audioSHA = try JapaneseBenchmarkSupport.sha256(at: audioURL)
            guard audioSHA == manifest.fixture.sha256 else {
                throw inputError("Audio SHA mismatch for \(corpusID).")
            }
            let loaded = try await AudioLoader.loadSamples(url: audioURL)
            guard loaded.count == manifest.fixture.sampleCount else {
                throw inputError("Audio sample count mismatch for \(corpusID).")
            }
            manifests[corpusID] = manifest
            samples[corpusID] = loaded
            provenance.append(CorpusProvenance(
                corpusID: corpusID,
                manifestSHA256: try JapaneseBenchmarkSupport.sha256(at: manifestURL),
                audioSHA256: audioSHA,
                annotationStatus: manifest.annotations.status.rawValue
            ))
        }
        return (manifests, samples, provenance)
    }

    @MainActor
    @available(macOS 26.0, *)
    private func replayInRealTime(
        _ samples: [Float],
        sessionStart: UInt64,
        send: (ArraySlice<Float>, Range<Int>) async throws -> Void
    ) async throws -> (sent: Int, maximumLateness: Double) {
        var sent = 0
        var maximumLateness = 0.0
        for start in stride(from: 0, to: samples.count, by: Self.blockSamples) {
            let end = min(samples.count, start + Self.blockSamples)
            let deadline = sessionStart + UInt64(end) * 1_000_000_000 / 16_000
            try await sleep(until: deadline)
            try await send(samples[start..<end], start..<end)
            sent = end
            maximumLateness = max(
                maximumLateness,
                elapsedMilliseconds(DispatchTime.now().uptimeNanoseconds, after: deadline)
            )
        }
        return (sent, maximumLateness)
    }

    private func coverage(_ groups: [ManyToManyTurnScorer.Group], role: String) -> Double {
        guard !groups.isEmpty else { return 0 }
        let present = groups.filter {
            $0.candidates.first(where: { $0.role == role })?.text.isEmpty == false
        }.count
        return Double(present) / Double(groups.count)
    }

    private func fragment(
        from event: SourceEvent,
        id: Int
    ) -> ManyToManyTurnScorer.Fragment? {
        guard let start = event.absoluteStartSample,
              let end = event.absoluteEndSample,
              end > start,
              !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ManyToManyTurnScorer.Fragment(
            id: id,
            startSample: start,
            endSample: end,
            text: event.text
        )
    }

    private func pcmS16LE(_ samples: ArraySlice<Float>) -> Data {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            let scaled = Int((min(1, max(-1, sample)) * 32_768).rounded())
            pcm.append(Int16(clamping: scaled).littleEndian)
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    private func messageData(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> Data {
        switch message {
        case .data(let data): data
        case .string(let string): Data(string.utf8)
        @unknown default: throw inputError("Unknown WhisperLiveKit WebSocket message.")
        }
    }

    private func sleep(until deadline: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
    }

    @MainActor
    private func startResourceSampler(pids: [Int32]) -> Task<UInt64?, Never> {
        Task { @MainActor in
            var maximum: UInt64?
            while true {
                if let resident = processUsage(pids: pids)?.residentBytes {
                    maximum = max(maximum ?? 0, resident)
                }
                if Task.isCancelled { return maximum }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return maximum
                }
            }
        }
    }

    private func processUsage(pids: [Int32]) -> ProcessUsage? {
        var residentBytes: UInt64 = 0
        var cpuNanoseconds: UInt64 = 0
        for pid in pids {
            guard let usage = processUsage(pid: pid) else { return nil }
            residentBytes += usage.residentBytes
            cpuNanoseconds += usage.cpuNanoseconds
        }
        return ProcessUsage(residentBytes: residentBytes, cpuNanoseconds: cpuNanoseconds)
    }

    private func processUsage(pid: Int32) -> ProcessUsage? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            UnsafeMutableRawPointer(pointer).withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return ProcessUsage(
            residentBytes: info.ri_phys_footprint,
            cpuNanoseconds: info.ri_user_time + info.ri_system_time
        )
    }

    private func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private func write(report: LiveReport, root: URL) throws {
        let output = root.appendingPathComponent(
            ".build/benchmarks/japanese-live/runs/\(report.runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: output.appendingPathComponent("live-replay.json"),
            options: .atomic
        )
        try frenchReport(report).write(
            to: output.appendingPathComponent("live-report-fr.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func frenchReport(_ report: LiveReport) -> String {
        let includesWhisperLiveKit = report.sessions.contains {
            $0.source.hasPrefix("whisperlivekit-")
        }
        var lines = [
            "# L6 — Replay live japonais → anglais",
            "",
            "Run `\(report.runID)`, commit `\(report.gitCommit)`, worktree "
                + (report.worktreeDirty ? "modifié" : "propre") + ".",
            includesWhisperLiveKit
                ? "WhisperLiveKit : \(report.whisperLiveKitArchitecture)."
                : "WhisperLiveKit : non exécuté dans ce run.",
            "Qualité : exploratoire tant que les références restent `pending-human-review`.",
            report.promotionEligible
                ? "Matrice promotable : 3 replays × 4 fenêtres, commit propre, réseau distant bloqué."
                : "Run diagnostique non promotable (matrice, annotations, propreté ou isolation incomplètes).",
            report.setupErrors.isEmpty
                ? "Initialisation : OK."
                : "Initialisation : " + report.setupErrors.joined(separator: "; "),
            "",
            "| Source | Sessions | CER japonais | Couverture source | Preview EN cov / p50 / p95 / pire | Final EN cov / p95 | Révisions / réécritures | Traitement / stabilisation fin | Pic RSS observé | Verdict |",
            "| --- | ---: | ---: | ---: | --- | --- | ---: | --- | ---: | --- |",
        ]
        for source in Set(report.sessions.map(\.source)).sorted() {
            let sessions = report.sessions.filter { $0.source == source }
            let cer = percentile(sessions.compactMap(\.japaneseCER).sorted(), 0.50)
            let sourceCoverage = sessions.map(\.highConfidenceSourceCoverage).min()
            let previewCoverage = sessions.map(\.highConfidencePreviewCoverage).min()
            let finalCoverage = sessions.map(\.highConfidenceFinalCoverage).min()
            let previewP50 = percentile(
                sessions.flatMap(\.previewFirstLatencyMilliseconds).sorted(),
                0.50
            )
            let previewP95 = percentile(
                sessions.flatMap(\.previewFirstLatencyMilliseconds).sorted(),
                0.95
            )
            let finalP95 = percentile(
                sessions.flatMap(\.finalEndpointLatencyMilliseconds).sorted(),
                0.95
            )
            let previewWorst = sessions.flatMap(\.previewFirstLatencyMilliseconds).max()
            let revisions = sessions.reduce(0) { $0 + $1.previewRevisionCount }
            let rewrites = sessions.reduce(0) { $0 + $1.confirmedPrefixRewriteCount }
            let endingProcessing = sessions.map(\.endingProcessingBacklogSeconds).max() ?? 0
            let endingPolicy = sessions.map(\.endingPolicyLagSeconds).max() ?? 0
            let maximumResident = sessions.compactMap(\.maximumObservedResidentBytes).max()
            var failures: [String] = []
            if sessions.contains(where: {
                $0.sentSampleCount != $0.expectedSampleCount
                    || !$0.readyToStopReceived
                    || !$0.lastAnnotatedSpeechPresent
            }) {
                failures.append("intégrité PCM")
            }
            if sessions.contains(where: { !$0.errors.isEmpty }) { failures.append("erreurs") }
            if (previewCoverage ?? 0) < 0.95
                || (previewP50 ?? .infinity) > 1_000
                || (previewP95 ?? .infinity) > 1_800
                || (previewWorst ?? .infinity) > 3_000 {
                failures.append("preview")
            }
            if source != "apple-speech" {
                if (finalCoverage ?? 0) < 0.95 || (finalP95 ?? .infinity) > 1_500 {
                    failures.append("final")
                }
                if sessions.contains(where: { $0.finalBoundaryMode != "phrase" }) {
                    failures.append("final EOS seulement")
                }
                if rewrites > 0 { failures.append("préfixe réécrit") }
                if endingProcessing > 0.1 { failures.append("backlog") }
            }
            if (maximumResident ?? .max) > 5_028_000_000 {
                failures.append("mémoire")
            }
            let verdict = failures.isEmpty
                ? "SLO techniques OK; qualité humaine à juger"
                : "écarté : " + failures.joined(separator: ", ")
            lines.append(
                "| \(source) | \(sessions.count) | \(percent(cer)) | "
                    + "\(percent(sourceCoverage)) | \(percent(previewCoverage)) / "
                    + "\(milliseconds(previewP50)) / \(milliseconds(previewP95)) / "
                    + "\(milliseconds(previewWorst)) | \(percent(finalCoverage)) / "
                    + "\(milliseconds(finalP95)) | \(revisions) / \(rewrites) | "
                    + "\(String(format: "%.2f s", endingProcessing)) / "
                    + "\(String(format: "%.2f s", endingPolicy)) | "
                    + "\(bytes(maximumResident)) | \(verdict) |"
            )
        }
        lines += [
            "",
            "Apple Speech est la preview commune des moteurs batch; leurs finales sont comparées dans l'oracle Apple séparé.",
            includesWhisperLiveKit
                ? "Pour WhisperLiveKit, `buffer_transcription` reste diagnostique : la preview anglaise utilise seulement les préfixes confirmés. Sans frontière locale fiable, la seule finale acceptée est le transcript complet à EOS; ce mode ne peut donc pas être promu."
                : "",
            "Mémoire : \(report.memoryMeasurementScope)",
            "Un test XCTest vert valide la collecte et le protocole, pas la promotion du candidat.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.2f %%", $0 * 100) } ?? "n/a"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "n/a"
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "n/a" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func inputError(_ message: String) -> NSError {
        NSError(
            domain: "JapaneseLiveReplay",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private func elapsedMilliseconds(_ value: UInt64, after start: UInt64) -> Double {
    value >= start
        ? Double(value - start) / 1_000_000
        : -Double(start - value) / 1_000_000
}
