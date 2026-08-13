import Foundation
import XCTest
@testable import WhisperASRApp

final class AdaptiveASRExperimentTests: XCTestCase {
    private struct Plan: Decodable {
        struct Window: Decodable {
            let id: String
            let startSample: Int
            let endSample: Int
        }

        let ticket: Int
        let audioSHA256: String
        let sampleCount: Int
        let windows: [Window]
    }

    private struct BackendRun: Encodable {
        let ticket: Int
        let status: String
        let backend: HighQualityASRBackend
        let sourceSHA256: String
        let planSHA256: String
        let windows: [String]
        let worker: HighQualityASRWorkerEvidence?
        let failure: String?
    }

    private struct CombinedWindow: Encodable {
        let id: String
        let startSample: Int
        let endSample: Int
        let qwen: String
        let parakeet: String
    }

    private struct ASRRun: Encodable {
        let schemaVersion = 1
        let ticket = 94
        let status: String
        let sourceSHA256: String
        let planSHA256: String
        let strictlySequential: Bool
        let windows: [CombinedWindow]
        let workers: [HighQualityASRWorkerEvidence]
    }

    private struct Selection: Decodable {
        struct Window: Decodable {
            let startSample: Int
            let endSample: Int
            let selectedText: String
        }

        let ticket: Int
        let developmentEligibleJapanese: Bool
        let sourceSHA256: String
        let rawTranscript: String
        let windows: [Window]
    }

    private struct WhisperKitTriggerPlan: Decodable {
        struct Window: Decodable {
            let id: String
            let startSample: Int
            let endSample: Int
        }

        let ticket: Int
        let sourceSHA256: String
        let windows: [Window]
    }

    private struct WhisperKitWindow: Codable {
        let id: String
        let startSample: Int
        let endSample: Int
        let text: String
        let averageLogProbability: Double
    }

    private struct WhisperKitRun: Encodable {
        let schemaVersion = 1
        let ticket = 95
        let status: String
        let sourceSHA256: String
        let triggerPlanSHA256: String
        let windows: [WhisperKitWindow]
        let worker: HighQualityASRWorkerEvidence?
        let failure: String?
    }

    func testWhisperKitConfidenceRoundTripsThroughASRExchange() throws {
        let exchange = HighQualityASRExchange(
            rawTranscript: "仮説",
            chunks: [],
            averageLogProbability: -0.42
        )

        let decoded = try JSONDecoder().decode(
            HighQualityASRExchange.self,
            from: JSONEncoder().encode(exchange)
        )

        XCTAssertEqual(decoded.rawTranscript, "仮説")
        XCTAssertEqual(decoded.averageLogProbability, -0.42)
    }

    func testTargetedWhisperKitASRWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TARGETED_WHISPERKIT_DEV"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == "95",
              let audioPath = environment["WHISPERASR_TARGETED_WHISPERKIT_AUDIO"],
              let planPath = environment["WHISPERASR_TARGETED_WHISPERKIT_PLAN"],
              let outputPath = environment["WHISPERASR_TARGETED_WHISPERKIT_OUTPUT"],
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #95 and set the frozen targeted inputs.")
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        let planURL = URL(fileURLWithPath: planPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let plan = try JSONDecoder().decode(
            WhisperKitTriggerPlan.self,
            from: Data(contentsOf: planURL)
        )
        let audioSHA256 = try JapaneseBenchmarkSupport.sha256(at: audioURL)
        let planSHA256 = try JapaneseBenchmarkSupport.sha256(at: planURL)
        XCTAssertEqual(plan.ticket, 95)
        XCTAssertEqual(plan.sourceSHA256, audioSHA256)
        XCTAssertEqual(plan.windows.count, 6)

        let samples = try await AudioLoader.loadSamples(url: audioURL)
        let worker = HighQualityASRWorkerClient(
            backend: .whisperKit,
            executableURL: URL(fileURLWithPath: workerPath)
        )
        var windows: [WhisperKitWindow] = []
        do {
            try await worker.prepare { _, message in print("[issue-95] \(message)") }
            for window in plan.windows {
                let exchange = try await worker.transcribe(
                    Array(samples[window.startSample..<window.endSample]),
                    anchored: false
                )
                let confidence = try XCTUnwrap(exchange.averageLogProbability)
                XCTAssertTrue(confidence.isFinite)
                windows.append(.init(
                    id: window.id,
                    startSample: window.startSample,
                    endSample: window.endSample,
                    text: exchange.rawTranscript,
                    averageLogProbability: confidence
                ))
            }
            await worker.unload()
            try Self.write(WhisperKitRun(
                status: "completed",
                sourceSHA256: audioSHA256,
                triggerPlanSHA256: planSHA256,
                windows: windows,
                worker: await worker.evidence,
                failure: nil
            ), to: outputURL)
        } catch {
            await worker.unload()
            try Self.write(WhisperKitRun(
                status: "failed",
                sourceSHA256: audioSHA256,
                triggerPlanSHA256: planSHA256,
                windows: windows,
                worker: await worker.evidence,
                failure: error.localizedDescription
            ), to: outputURL)
            throw error
        }
        XCTAssertEqual(windows.count, plan.windows.count)
    }

    func testDevelopmentASRWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_ASR_DEV"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == "94",
              let audioPath = environment["WHISPERASR_ADAPTIVE_AUDIO"],
              let planPath = environment["WHISPERASR_ADAPTIVE_PLAN"],
              let outputPath = environment["WHISPERASR_ADAPTIVE_ASR_OUTPUT"],
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Grant benchmark slot #94 and set the frozen DEV inputs.")
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        let planURL = URL(fileURLWithPath: planPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
        let audioSHA256 = try JapaneseBenchmarkSupport.sha256(at: audioURL)
        let planSHA256 = try JapaneseBenchmarkSupport.sha256(at: planURL)
        XCTAssertEqual(plan.ticket, 94)
        XCTAssertEqual(plan.audioSHA256, audioSHA256)
        XCTAssertTrue(plan.windows.allSatisfy { $0.endSample - $0.startSample <= 8 * 16_000 })

        let samples = try await AudioLoader.loadSamples(url: audioURL)
        XCTAssertEqual(samples.count, plan.sampleCount)
        let partialRoot = outputURL.deletingLastPathComponent()
        let executableURL = URL(fileURLWithPath: workerPath)
        let qwen = try await Self.run(
            backend: .qwenJA,
            samples: samples,
            plan: plan,
            sourceSHA256: audioSHA256,
            planSHA256: planSHA256,
            executableURL: executableURL,
            outputURL: partialRoot.appendingPathComponent("qwen-short-windows.json")
        )
        let parakeet = try await Self.run(
            backend: .parakeetJA,
            samples: samples,
            plan: plan,
            sourceSHA256: audioSHA256,
            planSHA256: planSHA256,
            executableURL: executableURL,
            outputURL: partialRoot.appendingPathComponent("parakeet-short-windows.json")
        )
        let qwenWorker = try XCTUnwrap(qwen.worker)
        let parakeetWorker = try XCTUnwrap(parakeet.worker)
        let windows = zip(plan.windows, zip(qwen.windows, parakeet.windows)).map {
            CombinedWindow(
                id: $0.0.id,
                startSample: $0.0.startSample,
                endSample: $0.0.endSample,
                qwen: $0.1.0,
                parakeet: $0.1.1
            )
        }
        let evidence = ASRRun(
            status: "completed",
            sourceSHA256: audioSHA256,
            planSHA256: planSHA256,
            strictlySequential: qwenWorker.lifecycle.exitedAt <= parakeetWorker.lifecycle.startedAt,
            windows: windows,
            workers: [qwenWorker, parakeetWorker]
        )
        try Self.write(evidence, to: outputURL)
        XCTAssertTrue(evidence.strictlySequential)
    }

    func testSingleDownstreamTranslationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ADAPTIVE_TRANSLATION_DEV"] == "1",
              let benchmarkTicket = Int(environment["BENCHMARK_SLOT_GRANTED"] ?? ""),
              [94, 95].contains(benchmarkTicket),
              benchmarkTicket == 94 || environment["BENCHMARK_SLOT_CONFIRMED_BY_USER"] == "95",
              let audioPath = environment["WHISPERASR_ADAPTIVE_AUDIO"],
              let selectionPath = environment["WHISPERASR_ADAPTIVE_SELECTION"],
              let outputRoot = environment["WHISPERASR_ADAPTIVE_TRANSLATION_OUTPUT"],
              let rawJobID = environment["WHISPERASR_ADAPTIVE_TRANSLATION_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let workerPath = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"] else {
            throw XCTSkip("Set the selected transcript and translation output.")
        }
        let selection = try JSONDecoder().decode(
            Selection.self,
            from: Data(contentsOf: URL(fileURLWithPath: selectionPath))
        )
        XCTAssertEqual(selection.ticket, benchmarkTicket)
        XCTAssertTrue(selection.developmentEligibleJapanese)
        let audioURL = URL(fileURLWithPath: audioPath)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: audioURL), selection.sourceSHA256)
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        let chunks = selection.windows.enumerated().compactMap { index, window in
            window.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil :
                HighQualityASRChunk(
                    index: index,
                    sourceStart: Double(window.startSample) / 16_000,
                    sourceEnd: Double(window.endSample) / 16_000,
                    transcript: window.selectedText
                )
        }
        let executableURL = URL(fileURLWithPath: workerPath)
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: executableURL
        )
        let translator = HighQualityTranslationWorkerClient(
            candidate: .translateGemma12B,
            executableURL: executableURL
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in samples },
            prepareASR: { _ in },
            transcribeJapanese: { _ in selection.rawTranscript },
            transcribeJapaneseAnchored: { _ in
                .init(rawTranscript: selection.rawTranscript, chunks: chunks)
            },
            unloadASR: {},
            prepareAlignment: { try await aligner.prepare(progress: $0) },
            alignJapanese: { try await aligner.align(samples: $0, turns: $1) },
            unloadAlignment: { await aligner.unload() },
            alignmentWorkerEvidence: { await aligner.evidence },
            currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
            prepareTranslation: { try await translator.prepare(progress: $0) },
            translateEnglish: { try await translator.translate($0) },
            unloadTranslation: { await translator.unload() },
            translationWorkerEvidence: { await translator.evidence }
        ))
        let result = try await job.run(.init(
            id: jobID,
            sourceURL: audioURL,
            deliverables: [.japaneseTranscript, .englishTranslationTranscript],
            backend: .qwenJA,
            translator: .translateGemma12B,
            outputRoot: URL(fileURLWithPath: outputRoot)
        ))
        XCTAssertEqual(result.evidence.rawASR, selection.rawTranscript)
        XCTAssertNil(result.evidence.asrWorker)
        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.evidence.translation?.worker?.exitStatus, 0)
    }

    private static func run(
        backend: HighQualityASRBackend,
        samples: [Float],
        plan: Plan,
        sourceSHA256: String,
        planSHA256: String,
        executableURL: URL,
        outputURL: URL
    ) async throws -> BackendRun {
        let worker = HighQualityASRWorkerClient(backend: backend, executableURL: executableURL)
        var outputs: [String] = []
        do {
            try await worker.prepare { _, message in print("[issue-94] \(message)") }
            for window in plan.windows {
                outputs.append(try await worker.transcribe(
                    Array(samples[window.startSample..<window.endSample]),
                    anchored: false
                ).rawTranscript)
            }
            await worker.unload()
            let result = BackendRun(
                ticket: 94,
                status: "completed",
                backend: backend,
                sourceSHA256: sourceSHA256,
                planSHA256: planSHA256,
                windows: outputs,
                worker: await worker.evidence,
                failure: nil
            )
            try write(result, to: outputURL)
            return result
        } catch {
            await worker.unload()
            try write(BackendRun(
                ticket: 94,
                status: "failed",
                backend: backend,
                sourceSHA256: sourceSHA256,
                planSHA256: planSHA256,
                windows: outputs,
                worker: await worker.evidence,
                failure: error.localizedDescription
            ), to: outputURL)
            throw error
        }
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
}
