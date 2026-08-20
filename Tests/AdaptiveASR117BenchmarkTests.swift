import Foundation
import XCTest
@testable import WhisperASRApp

final class AdaptiveASR117BenchmarkTests: XCTestCase {
    private struct Algorithm: Codable {
        let activeFrameDBFS: Double
        let boundary: String
        let frameMilliseconds: Int
        let maximumSeconds: Int
        let minimumSeconds: Int
        let usesReference: Bool
    }

    private struct Plan: Codable {
        let schemaVersion: Int
        let ticket: Int
        let corpusID: String
        let corpusRole: String
        let holdoutOpened: Bool
        let audioSHA256: String
        let sampleRate: Int
        let sampleCount: Int
        let algorithm: Algorithm
        let segments: [HighQualityAdaptiveASRSegment]
    }

    private struct Window: Codable {
        let segment: HighQualityAdaptiveASRSegment
        let qwen: HighQualityASRExchange
        let qwenAssessment: HighQualityAdaptiveASRAssessment
        let qwenDuration: TimeInterval
        var parakeet: HighQualityASRExchange?
        var parakeetAssessment: HighQualityAdaptiveASRAssessment?
        var parakeetDuration: TimeInterval?
        var vetoes: [HighQualityAdaptiveASRVeto]
        var error: HighQualityAdaptiveASRErrorEvidence?
    }

    private struct Run: Codable {
        let schemaVersion: Int
        let ticket: Int
        let status: String
        let corpusID: String
        let corpusRole: String
        let sourceSHA256: String
        let planSHA256: String
        let strictlySequential: Bool
        let windows: [Window]
        let workers: [HighQualityASRWorkerEvidence]
        let errors: [HighQualityAdaptiveASRErrorEvidence]
    }

    private struct Window118: Codable {
        let segment: HighQualityAdaptiveASRSegment
        let qwen: HighQualityASRExchange
        let qwenAssessment: HighQualityAdaptiveASRAssessment
        let qwenDuration: TimeInterval
        let parakeet: HighQualityASRExchange?
        let parakeetAssessment: HighQualityAdaptiveASRAssessment?
        let parakeetDuration: TimeInterval?
        let parakeetVetoes: [HighQualityAdaptiveASRVeto]
        let parakeetError: HighQualityAdaptiveASRErrorEvidence?
        var whisperKit: HighQualityASRExchange?
        var whisperKitAssessment: HighQualityAdaptiveASRAssessment?
        var whisperKitDuration: TimeInterval?
        let whisperKitLaunch: HighQualityAdaptiveASRWhisperKitLaunch?
        var whisperKitVetoes: [HighQualityAdaptiveASRVeto]
        var whisperKitError: HighQualityAdaptiveASRErrorEvidence?
    }

    private struct Run118: Codable {
        let schemaVersion: Int
        let ticket: Int
        let status: String
        let corpusID: String
        let corpusRole: String
        let sourceSHA256: String
        let planSHA256: String
        let baseRunSHA256: String
        let parakeetCalibrationSHA256: String
        let strictlySequential: Bool
        let windows: [Window118]
        let workers: [HighQualityASRWorkerEvidence]
        let errors: [HighQualityAdaptiveASRErrorEvidence]
    }

    func testIssue117RunnerProvenanceFailsClosed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appendingPathComponent("Scripts/run_adaptive_asr_117.sh").path,
            "self-test",
        ]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let message = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(message.contains("provenance self-test: PASS"), message)
    }

    func testIssue118RunnerProvenanceFailsClosed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appendingPathComponent("Scripts/run_adaptive_asr_118.sh").path,
            "self-test",
        ]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let message = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(message.contains("issue-118 provenance self-test: PASS"), message)
        XCTAssertTrue(
            message.contains("issue-118 non-final control fail-closed self-test: PASS"),
            message
        )
    }

    func testIssue117RawRunOnlyCompletesCandidateFailures() throws {
        XCTAssertThrowsError(try Self.candidateEvidence(
            for: HighQualityASRWorkerError.protocolFailure("bad response"),
            stage: "parakeet-transcription",
            segmentID: "segment-0001"
        ))
        let evidence = try Self.candidateEvidence(
            for: HighQualityASRWorkerError.invalidCandidateEvidence(.invalidHypothesis),
            stage: "parakeet-transcription",
            segmentID: "segment-0001"
        )
        XCTAssertEqual(evidence.route, .candidate)
        XCTAssertEqual(evidence.candidateReason, .invalidHypothesis)
    }

    func testIssue118InvalidWhisperKitTimingIsAnAuditedCandidateFailure() throws {
        let evidence = try Self.candidateEvidence(
            for: HighQualityASRWorkerError.invalidCandidateEvidence(.invalidTimestamps),
            stage: "whisperkit-transcription",
            segmentID: "segment-0001"
        )
        XCTAssertEqual(evidence.route, .candidate)
        XCTAssertEqual(evidence.candidateReason, .invalidTimestamps)
        XCTAssertThrowsError(try Self.candidateEvidence(
            for: HighQualityASRWorkerError.protocolFailure("bad JSON"),
            stage: "whisperkit-transcription",
            segmentID: "segment-0001"
        ))
    }

    func testIssue117CanonicalPythonPlanMatchesSwiftPlannerWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_117_PLAN"] == "1",
              let audioPath = environment["WHISPERASR_ADAPTIVE_117_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_117_PLAN"] else {
            throw XCTSkip("Provide frozen DEV audio and plan for the model-free check.")
        }
        _ = try await verifiedPlan(audioPath: audioPath, planPath: planPath)
    }

    func testIssue117RawASRWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let slot = environment["BENCHMARK_SLOT_GRANTED"]
        let authorized = slot == "117" || (
            slot == "118" && environment["WHISPERASR_ADAPTIVE_117_BASE_FOR_118"] == "1"
        )
        guard environment["WHISPERASR_RUN_ADAPTIVE_117_ASR"] == "1",
              authorized,
              let audioPath = environment["WHISPERASR_ADAPTIVE_117_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_117_PLAN"],
              let outputPath = environment["WHISPERASR_ADAPTIVE_117_RUN"],
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #117 and provide frozen ASR inputs.")
        }
        let planURL = URL(fileURLWithPath: planPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let (plan, samples) = try await verifiedPlan(
            audioPath: audioPath,
            planPath: planPath
        )

        let executableURL = URL(fileURLWithPath: workerPath)
        let qwen = HighQualityASRWorkerClient(
            backend: .qwenJA,
            executableURL: executableURL
        )
        var windows: [Window] = []
        do {
            try await qwen.prepare { _, message in print("[issue-117/qwen] \(message)") }
            for segment in plan.segments {
                let started = Date()
                let exchange = try await qwen.transcribe(
                    Array(samples[segment.startSample..<segment.endSample]),
                    anchored: false
                )
                windows.append(.init(
                    segment: segment,
                    qwen: exchange,
                    qwenAssessment: HighQualityAdaptiveASR.assess(
                        exchange: exchange,
                        segment: segment,
                        scopedTerms: []
                    ),
                    qwenDuration: Date().timeIntervalSince(started),
                    parakeet: nil,
                    parakeetAssessment: nil,
                    parakeetDuration: nil,
                    vetoes: [],
                    error: nil
                ))
            }
        } catch {
            await qwen.unload()
            throw error
        }
        await qwen.unload()
        let recordedQwenEvidence = await qwen.evidence
        let qwenEvidence = try XCTUnwrap(recordedQwenEvidence)
        var workers = [qwenEvidence]
        let suspectIndices = windows.indices.filter { windows[$0].qwenAssessment.isSuspect }
        if !suspectIndices.isEmpty {
            let parakeet = HighQualityASRWorkerClient(
                backend: .parakeetJA,
                executableURL: executableURL
            )
            var infrastructureError: (any Error)?
            do {
                try await parakeet.prepare { _, message in
                    print("[issue-117/parakeet] \(message)")
                }
                for index in suspectIndices {
                    do {
                        let started = Date()
                        let segment = windows[index].segment
                        let exchange = try await parakeet.transcribe(
                            Array(samples[segment.startSample..<segment.endSample]),
                            anchored: false
                        )
                        windows[index].parakeet = exchange
                        windows[index].parakeetDuration = Date().timeIntervalSince(started)
                        windows[index].parakeetAssessment = HighQualityAdaptiveASR.assess(
                            exchange: exchange,
                            segment: windows[index].segment,
                            scopedTerms: []
                        )
                        windows[index].vetoes = HighQualityAdaptiveASR.vetoes(
                            baseline: windows[index].qwen,
                            candidate: exchange,
                            segment: windows[index].segment,
                            scopedTerms: []
                        )
                    } catch is CancellationError {
                        infrastructureError = CancellationError()
                        break
                    } catch {
                        do {
                            windows[index].error = try Self.candidateEvidence(
                                for: error,
                                stage: "parakeet-transcription",
                                segmentID: windows[index].segment.id
                            )
                        } catch {
                            infrastructureError = error
                            break
                        }
                    }
                }
            } catch {
                do {
                    let evidence = try Self.candidateEvidence(
                        for: error,
                        stage: "parakeet-preparation",
                        segmentID: nil
                    )
                    for index in suspectIndices where windows[index].parakeet == nil {
                        windows[index].error = .init(
                            route: evidence.route,
                            stage: evidence.stage,
                            segmentID: windows[index].segment.id,
                            message: evidence.message
                        )
                    }
                } catch {
                    infrastructureError = error
                }
            }
            await parakeet.unload()
            if let evidence = await parakeet.evidence { workers.append(evidence) }
            if let infrastructureError { throw infrastructureError }
        }
        let errors = windows.compactMap(\.error)
        let strictlySequential = workers.count < 2
            || workers[0].lifecycle.exitedAt <= workers[1].lifecycle.startedAt
        let run = Run(
            schemaVersion: 1,
            ticket: 117,
            status: "completed",
            corpusID: plan.corpusID,
            corpusRole: plan.corpusRole,
            sourceSHA256: plan.audioSHA256,
            planSHA256: try JapaneseBenchmarkSupport.sha256(at: planURL),
            strictlySequential: strictlySequential,
            windows: windows,
            workers: workers,
            errors: errors
        )
        try Self.write(run, to: outputURL)
        XCTAssertTrue(strictlySequential)
        XCTAssertEqual(windows.count, plan.segments.count)
        XCTAssertEqual(
            windows.filter { $0.parakeet != nil || $0.error != nil }.count,
            suspectIndices.count
        )
    }

    func testIssue118TargetedWhisperKitWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_118_WHISPERKIT"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == "118",
              let audioPath = environment["WHISPERASR_ADAPTIVE_118_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_118_PLAN"],
              let baseRunPath = environment["WHISPERASR_ADAPTIVE_118_BASE_RUN"],
              let parakeetCalibrationPath = environment[
                "WHISPERASR_ADAPTIVE_118_PARAKEET_CALIBRATION"
              ],
              let outputPath = environment["WHISPERASR_ADAPTIVE_118_RUN"],
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #118 and provide frozen WhisperKit inputs.")
        }
        let (plan, samples) = try await verifiedPlan(
            audioPath: audioPath,
            planPath: planPath
        )
        let decoder = Self.decoder()
        let baseRunURL = URL(fileURLWithPath: baseRunPath)
        let calibrationURL = URL(fileURLWithPath: parakeetCalibrationPath)
        let base = try decoder.decode(Run.self, from: Data(contentsOf: baseRunURL))
        let calibration = try decoder.decode(
            HighQualityAdaptiveASRCalibration.self,
            from: Data(contentsOf: calibrationURL)
        )
        XCTAssertEqual(base.ticket, 117)
        XCTAssertEqual(base.status, "completed")
        XCTAssertEqual(base.planSHA256, try JapaneseBenchmarkSupport.sha256(
            at: URL(fileURLWithPath: planPath)
        ))
        XCTAssertTrue(calibration.isStable)
        XCTAssertTrue(calibration.isWhisperKitStable)
        var windows = base.windows.map { window in
            let decision = HighQualityAdaptiveASR.decide(
                segment: window.segment,
                qwen: window.qwen,
                qwenDuration: window.qwenDuration,
                parakeet: window.parakeet,
                parakeetDuration: window.parakeetDuration,
                scopedTerms: [],
                calibration: calibration,
                alternateError: window.error
            )
            return Window118(
                segment: window.segment,
                qwen: window.qwen,
                qwenAssessment: window.qwenAssessment,
                qwenDuration: window.qwenDuration,
                parakeet: window.parakeet,
                parakeetAssessment: window.parakeetAssessment,
                parakeetDuration: window.parakeetDuration,
                parakeetVetoes: window.vetoes,
                parakeetError: window.error,
                whisperKit: nil,
                whisperKitAssessment: nil,
                whisperKitDuration: nil,
                whisperKitLaunch: decision.whisperKitLaunch,
                whisperKitVetoes: [],
                whisperKitError: nil
            )
        }
        let targets = windows.indices.filter { index in
            windows[index].whisperKitLaunch?.shouldLaunch == true
        }
        XCTAssertFalse(targets.isEmpty)
        XCTAssertLessThan(Double(targets.count) / Double(windows.count), 0.25)
        XCTAssertTrue(targets.allSatisfy {
            windows[$0].segment.endSample - windows[$0].segment.startSample <= 8 * 16_000
        })

        let whisperKit = HighQualityASRWorkerClient(
            backend: .whisperKit,
            executableURL: URL(fileURLWithPath: workerPath)
        )
        var infrastructureError: (any Error)?
        do {
            try await whisperKit.prepare { _, message in
                print("[issue-118/whisperkit] \(message)")
            }
            for index in targets {
                do {
                    let started = Date()
                    let segment = windows[index].segment
                    let exchange = try await whisperKit.transcribe(
                        Array(samples[segment.startSample..<segment.endSample]),
                        anchored: false
                    )
                    windows[index].whisperKit = exchange
                    windows[index].whisperKitDuration = Date().timeIntervalSince(started)
                    windows[index].whisperKitAssessment = HighQualityAdaptiveASR.assess(
                        exchange: exchange,
                        segment: segment,
                        scopedTerms: []
                    )
                    windows[index].whisperKitVetoes = HighQualityAdaptiveASR.vetoes(
                        baseline: windows[index].qwen,
                        candidate: exchange,
                        segment: segment,
                        scopedTerms: []
                    )
                } catch is CancellationError {
                    infrastructureError = CancellationError()
                    break
                } catch {
                    do {
                        windows[index].whisperKitError = try Self.candidateEvidence(
                            for: error,
                            stage: "whisperkit-transcription",
                            segmentID: windows[index].segment.id
                        )
                    } catch {
                        infrastructureError = error
                        break
                    }
                }
            }
        } catch {
            do {
                let evidence = try Self.candidateEvidence(
                    for: error,
                    stage: "whisperkit-preparation",
                    segmentID: nil
                )
                for index in targets where windows[index].whisperKit == nil {
                    windows[index].whisperKitError = .init(
                        route: evidence.route,
                        stage: evidence.stage,
                        segmentID: windows[index].segment.id,
                        message: evidence.message,
                        candidateReason: evidence.candidateReason
                    )
                }
            } catch {
                infrastructureError = error
            }
        }
        await whisperKit.unload()
        if let infrastructureError { throw infrastructureError }
        let recordedWhisperKitEvidence = await whisperKit.evidence
        let whisperKitEvidence = try XCTUnwrap(recordedWhisperKitEvidence)
        var workers = base.workers
        workers.append(whisperKitEvidence)
        let strictlySequential = zip(workers, workers.dropFirst()).allSatisfy {
            $0.lifecycle.exitedAt <= $1.lifecycle.startedAt
        }
        let errors = windows.flatMap {
            [$0.parakeetError, $0.whisperKitError].compactMap { $0 }
        }
        try Self.write(Run118(
            schemaVersion: 1,
            ticket: 118,
            status: "completed",
            corpusID: plan.corpusID,
            corpusRole: plan.corpusRole,
            sourceSHA256: plan.audioSHA256,
            planSHA256: try JapaneseBenchmarkSupport.sha256(
                at: URL(fileURLWithPath: planPath)
            ),
            baseRunSHA256: try JapaneseBenchmarkSupport.sha256(at: baseRunURL),
            parakeetCalibrationSHA256: try JapaneseBenchmarkSupport.sha256(at: calibrationURL),
            strictlySequential: strictlySequential,
            windows: windows,
            workers: workers,
            errors: errors
        ), to: URL(fileURLWithPath: outputPath))
        XCTAssertTrue(strictlySequential)
        XCTAssertEqual(
            windows.filter { $0.whisperKit != nil || $0.whisperKitError != nil }.count,
            targets.count
        )
    }

    func testIssue117SelectedDownstreamWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_117_DOWNSTREAM"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == "117",
              let audioPath = environment["WHISPERASR_ADAPTIVE_117_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_117_PLAN"],
              let runPath = environment["WHISPERASR_ADAPTIVE_117_RUN"],
              let calibrationPath = environment["WHISPERASR_ADAPTIVE_117_CALIBRATION"],
              let outputRoot = environment["WHISPERASR_ADAPTIVE_117_OUTPUT"],
              let rawJobID = environment["WHISPERASR_ADAPTIVE_117_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #117 and provide frozen downstream inputs.")
        }
        let decoder = Self.decoder()
        let plan = try decoder.decode(
            Plan.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath))
        )
        let run = try decoder.decode(
            Run.self,
            from: Data(contentsOf: URL(fileURLWithPath: runPath))
        )
        let calibration = try decoder.decode(
            HighQualityAdaptiveASRCalibration.self,
            from: Data(contentsOf: URL(fileURLWithPath: calibrationPath))
        )
        XCTAssertEqual(run.status, "completed")
        XCTAssertEqual(run.planSHA256, try JapaneseBenchmarkSupport.sha256(
            at: URL(fileURLWithPath: planPath)
        ))
        let audioURL = URL(fileURLWithPath: audioPath)
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        XCTAssertEqual(samples.count, plan.sampleCount)
        let qwen = AdaptiveASR117Replay(
            windows: run.windows.map { ($0.segment, .success($0.qwen)) }
        )
        let parakeet = AdaptiveASR117Replay(windows: run.windows.compactMap { window in
            guard window.qwenAssessment.isSuspect else { return nil }
            if let exchange = window.parakeet {
                return (window.segment, .success(exchange))
            }
            return (
                window.segment,
                .failure(window.error?.message ?? "Parakeet evidence is missing.")
            )
        })
        let executableURL = URL(fileURLWithPath: workerPath)
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: executableURL
        )
        let translator = HighQualityTranslationWorkerClient(
            candidate: .translateGemma12B,
            executableURL: executableURL
        )
        let translationCalls = AdaptiveASR117Counter()
        let qwenEvidence = run.workers.first { $0.backend == .qwenJA }
        let parakeetEvidence = run.workers.first { $0.backend == .parakeetJA }
        let job = HighQualityJob(servicesForBackend: { backend in
            let replay = backend == .qwenJA ? qwen : parakeet
            return .init(
                loadSource: { _ in samples },
                prepareASR: { _ in },
                transcribeJapanese: { _ in
                    throw AdaptiveASR117ReplayError.unexpectedStringTranscript
                },
                transcribeJapaneseEvidence: { try await replay.next(samples: $0) },
                unloadASR: {},
                asrWorkerEvidence: {
                    backend == .qwenJA ? qwenEvidence : parakeetEvidence
                },
                prepareAlignment: { try await aligner.prepare(progress: $0) },
                alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                unloadAlignment: { await aligner.unload() },
                alignmentWorkerEvidence: { await aligner.evidence },
                currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
                prepareTranslation: { try await translator.prepare(progress: $0) },
                translateEnglish: {
                    await translationCalls.increment()
                    return try await translator.translate($0)
                },
                unloadTranslation: { await translator.unload() },
                translationWorkerEvidence: { await translator.evidence },
                heavyweightGate: .shared
            )
        })
        let result = try await job.run(.init(
            id: jobID,
            sourceURL: audioURL,
            deliverables: [.japaneseTranscript, .englishTranslationTranscript],
            asrMode: .adaptiveQwenParakeet,
            translator: .translateGemma12B,
            adaptiveCalibration: calibration,
            outputRoot: URL(fileURLWithPath: outputRoot)
        ))
        let translationCallCount = await translationCalls.value
        let remainingQwen = await qwen.remaining
        let remainingParakeet = await parakeet.remaining
        XCTAssertEqual(translationCallCount, 1)
        XCTAssertEqual(remainingQwen, 0)
        XCTAssertEqual(remainingParakeet, 0)
        XCTAssertEqual(result.manifest.selectedASRMode, .adaptiveQwenParakeet)
        XCTAssertEqual(result.evidence.adaptiveASR?.calibration, calibration)
        XCTAssertTrue(result.evidence.adaptiveASR?.decisions.allSatisfy {
            $0.selectedText == $0.qwen.rawTranscript
                || $0.selectedText == $0.parakeet?.rawTranscript
        } == true)
    }

    func testIssue118SelectedDownstreamWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_118_DOWNSTREAM"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == "118",
              let audioPath = environment["WHISPERASR_ADAPTIVE_118_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_118_PLAN"],
              let runPath = environment["WHISPERASR_ADAPTIVE_118_RUN"],
              let calibrationPath = environment["WHISPERASR_ADAPTIVE_118_CALIBRATION"],
              let outputRoot = environment["WHISPERASR_ADAPTIVE_118_OUTPUT"],
              let rawJobID = environment["WHISPERASR_ADAPTIVE_118_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #118 and provide frozen downstream inputs.")
        }
        let decoder = Self.decoder()
        let plan = try decoder.decode(
            Plan.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath))
        )
        let run = try decoder.decode(
            Run118.self,
            from: Data(contentsOf: URL(fileURLWithPath: runPath))
        )
        let calibration = try decoder.decode(
            HighQualityAdaptiveASRCalibration.self,
            from: Data(contentsOf: URL(fileURLWithPath: calibrationPath))
        )
        XCTAssertEqual(run.ticket, 118)
        XCTAssertEqual(run.status, "completed")
        XCTAssertTrue(run.strictlySequential)
        XCTAssertEqual(run.planSHA256, try JapaneseBenchmarkSupport.sha256(
            at: URL(fileURLWithPath: planPath)
        ))
        XCTAssertTrue(calibration.isWhisperKitStable)
        XCTAssertFalse(calibration.isStable)

        let audioURL = URL(fileURLWithPath: audioPath)
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        XCTAssertEqual(samples.count, plan.sampleCount)
        let qwen = AdaptiveASR117Replay(
            windows: run.windows.map { ($0.segment, .success($0.qwen)) }
        )
        let parakeet = AdaptiveASR117Replay(windows: run.windows.compactMap { window in
            guard window.qwenAssessment.isSuspect else { return nil }
            if let exchange = window.parakeet {
                return (window.segment, .success(exchange))
            }
            return (
                window.segment,
                .failure(window.parakeetError?.message ?? "Parakeet evidence is missing.")
            )
        })
        let whisperKit = AdaptiveASR117Replay(windows: run.windows.compactMap { window in
            guard window.whisperKitLaunch?.shouldLaunch == true else { return nil }
            if let exchange = window.whisperKit {
                return (window.segment, .success(exchange))
            }
            return (
                window.segment,
                .failure(window.whisperKitError?.message ?? "WhisperKit evidence is missing.")
            )
        })
        let executableURL = URL(fileURLWithPath: workerPath)
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: executableURL
        )
        let translator = HighQualityTranslationWorkerClient(
            candidate: .translateGemma12B,
            executableURL: executableURL
        )
        let translationCalls = AdaptiveASR117Counter()
        let job = HighQualityJob(servicesForBackend: { backend in
            let replay: AdaptiveASR117Replay
            switch backend {
            case .qwenJA: replay = qwen
            case .parakeetJA: replay = parakeet
            case .whisperKit: replay = whisperKit
            case .funASRNanoInt8, .reazonSpeechK2V2: replay = qwen
            }
            return .init(
                loadSource: { _ in samples },
                prepareASR: { _ in },
                transcribeJapanese: { _ in
                    throw AdaptiveASR117ReplayError.unexpectedStringTranscript
                },
                transcribeJapaneseEvidence: { try await replay.next(samples: $0) },
                unloadASR: {},
                asrWorkerEvidence: { run.workers.first { $0.backend == backend } },
                prepareAlignment: { try await aligner.prepare(progress: $0) },
                alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
                unloadAlignment: { await aligner.unload() },
                alignmentWorkerEvidence: { await aligner.evidence },
                currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
                prepareTranslation: { try await translator.prepare(progress: $0) },
                translateEnglish: {
                    await translationCalls.increment()
                    return try await translator.translate($0)
                },
                unloadTranslation: { await translator.unload() },
                translationWorkerEvidence: { await translator.evidence },
                heavyweightGate: .shared
            )
        })
        let result = try await job.run(.init(
            id: jobID,
            sourceURL: audioURL,
            deliverables: [.japaneseTranscript, .englishTranslationTranscript],
            asrMode: .adaptiveQwenParakeet,
            translator: .translateGemma12B,
            adaptiveCalibration: calibration,
            outputRoot: URL(fileURLWithPath: outputRoot)
        ))
        let translationCallCount = await translationCalls.value
        let remainingQwen = await qwen.remaining
        let remainingParakeet = await parakeet.remaining
        let remainingWhisperKit = await whisperKit.remaining
        XCTAssertEqual(translationCallCount, 1)
        XCTAssertEqual(remainingQwen, 0)
        XCTAssertEqual(remainingParakeet, 0)
        XCTAssertEqual(remainingWhisperKit, 0)
        XCTAssertEqual(result.manifest.selectedASRMode, .adaptiveQwenParakeet)
        XCTAssertEqual(result.evidence.adaptiveASR?.calibration, calibration)
        XCTAssertTrue(result.evidence.adaptiveASR?.decisions.allSatisfy {
            $0.selectedText == $0.qwen.rawTranscript
                || $0.selectedText == $0.whisperKit?.rawTranscript
        } == true)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func candidateEvidence(
        for error: any Error,
        stage: String,
        segmentID: String?
    ) throws -> HighQualityAdaptiveASRErrorEvidence {
        let route = HighQualityAdaptiveASR.route(error)
        guard route == .candidate else { throw error }
        return .init(
            route: route,
            stage: stage,
            segmentID: segmentID,
            message: error.localizedDescription,
            candidateReason: HighQualityAdaptiveASR.candidateReason(error)
        )
    }

    private func verifiedPlan(
        audioPath: String,
        planPath: String
    ) async throws -> (Plan, [Float]) {
        let audioURL = URL(fileURLWithPath: audioPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "algorithm", "audioSHA256", "corpusID", "corpusRole", "holdoutOpened",
            "sampleCount", "sampleRate", "schemaVersion", "segments", "ticket",
        ])
        XCTAssertEqual(plan.ticket, 117)
        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertEqual(plan.sampleRate, 16_000)
        XCTAssertEqual(plan.audioSHA256, try JapaneseBenchmarkSupport.sha256(at: audioURL))
        XCTAssertEqual(plan.algorithm.activeFrameDBFS, -42)
        XCTAssertEqual(plan.algorithm.boundary, "lowest-energy-frame-latest-tie")
        XCTAssertEqual(plan.algorithm.frameMilliseconds, 20)
        XCTAssertEqual(plan.algorithm.minimumSeconds, 3)
        XCTAssertEqual(plan.algorithm.maximumSeconds, 8)
        XCTAssertFalse(plan.algorithm.usesReference)
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        XCTAssertEqual(samples.count, plan.sampleCount)
        let runtime = HighQualityAdaptiveASR.plan(samples: samples)
        XCTAssertEqual(runtime.map(\.id), plan.segments.map(\.id))
        XCTAssertEqual(runtime.map(\.startSample), plan.segments.map(\.startSample))
        XCTAssertEqual(runtime.map(\.endSample), plan.segments.map(\.endSample))
        for (observed, frozen) in zip(runtime, plan.segments) {
            XCTAssertEqual(observed.rmsDBFS, frozen.rmsDBFS, accuracy: 0.0001)
            XCTAssertEqual(observed.activeFrameRatio, frozen.activeFrameRatio, accuracy: 0.0001)
        }
        return (plan, samples)
    }
}

private enum AdaptiveASR117ReplayError: LocalizedError {
    case unexpectedStringTranscript
    case exhausted
    case sampleCount(Int, Int)
    case recorded(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedStringTranscript: "Adaptive replay requested a string-only transcript."
        case .exhausted: "Adaptive replay requested an unrecorded segment."
        case .sampleCount(let actual, let expected):
            "Adaptive replay segment has \(actual) samples; expected \(expected)."
        case .recorded(let message): message
        }
    }
}

private actor AdaptiveASR117Replay {
    enum Result: Sendable {
        case success(HighQualityASRExchange)
        case failure(String)
    }

    private var windows: [(HighQualityAdaptiveASRSegment, Result)]

    init(windows: [(HighQualityAdaptiveASRSegment, Result)]) {
        self.windows = windows
    }

    var remaining: Int { windows.count }

    func next(samples: [Float]) throws -> HighQualityASRExchange {
        guard !windows.isEmpty else { throw AdaptiveASR117ReplayError.exhausted }
        let (segment, result) = windows.removeFirst()
        let expected = segment.endSample - segment.startSample
        guard samples.count == expected else {
            throw AdaptiveASR117ReplayError.sampleCount(samples.count, expected)
        }
        switch result {
        case .success(let exchange): return exchange
        case .failure(let message): throw AdaptiveASR117ReplayError.recorded(message)
        }
    }
}

private actor AdaptiveASR117Counter {
    private(set) var value = 0

    func increment() { value += 1 }
}
