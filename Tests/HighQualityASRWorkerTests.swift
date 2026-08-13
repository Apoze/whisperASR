import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityASRWorkerTests: XCTestCase {
    func testDirectBackendMatchesFrozenWorkerOutputWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BENCHMARK_SLOT_GRANTED"] == "72",
              environment["WHISPERASR_RUN_ASR_DIRECT_PARITY"] == "1",
              let rawBackend = environment["WHISPERASR_ASR_WORKER_BACKEND"],
              let backend = HighQualityASRBackend(rawValue: rawBackend),
              let fixturePath = environment["WHISPERASR_HIGH_QUALITY_ASR_FIXTURE"],
              let expectedFixtureSHA256 = environment[
                "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256"
              ] else {
            throw XCTSkip("Grant benchmark slot #72 and set its direct parity environment.")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: fixture),
            expectedFixtureSHA256
        )
        let samples = try await AudioLoader.loadSamples(url: fixture)
        let transcript: String
        var whisperKitWeightSHA256: [String: String]?
        switch backend {
        case .qwenJA:
            let runtime = QwenRuntime()
            try await runtime.prepare(progress: { _, _ in })
            transcript = try await runtime.transcribe(
                audio: samples,
                language: "Japanese",
                preserveRawOutput: true,
                cancellable: true
            )
            await runtime.unload()
        case .parakeetJA:
            let runtime = ParakeetRuntime()
            try await runtime.prepare(progress: { _, _ in })
            transcript = try await runtime.transcribe(
                audio: samples,
                preserveRawOutput: true,
                cancellable: true
            )
            await runtime.unload()
        case .whisperKit:
            let runtime = WhisperKitRuntime()
            try await runtime.prepare(progress: { _, _ in })
            transcript = try await runtime.transcribe(audio: samples)
            await runtime.unload()
            whisperKitWeightSHA256 = try HighQualityASRWeightEvidence.collect(for: backend)
        case .funASRNanoInt8:
            throw XCTSkip("Fun-ASR direct parity uses only the pinned sherpa worker.")
        case .reazonSpeechK2V2:
            throw XCTSkip("ReazonSpeech parity uses its pinned external worker smoke.")
        }
        let exported = transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/benchmarks/issue-72/direct-parity/\(backend.rawValue).txt"
            )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(exported.utf8).write(to: output, options: .atomic)
        let digest = SHA256.hash(data: Data(exported.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if backend == .whisperKit {
            let options = WhisperKitRuntime.decodingOptions
            XCTAssertEqual(options.temperature, 0)
            XCTAssertEqual(options.temperatureIncrementOnFallback, 0.2)
            XCTAssertEqual(options.temperatureFallbackCount, 5)
            XCTAssertEqual(options.topK, 5)
            XCTAssertEqual(whisperKitWeightSHA256, frozenWhisperKitWeightSHA256)
            XCTAssertTrue(transcript.hasPrefix(frozenWhisperKitCommonPrefix))
            if digest != frozenTranscriptSHA256(for: backend) {
                print(
                    "WhisperKit stochastic fallback: direct=\(digest) "
                        + "worker=\(frozenTranscriptSHA256(for: backend))"
                )
            }
        } else {
            XCTAssertEqual(digest, frozenTranscriptSHA256(for: backend))
        }
    }

    func testRealBackendCompletesFrozenJapaneseJobWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let slot = environment["WHISPERASR_ASR_WORKER_SLOT"] ?? "72"
        guard environment["BENCHMARK_SLOT_GRANTED"] == slot,
              environment["WHISPERASR_RUN_ASR_WORKER_SMOKE"] == "1",
              let rawBackend = environment["WHISPERASR_ASR_WORKER_BACKEND"],
              let backend = HighQualityASRBackend(rawValue: rawBackend),
              let fixturePath = environment["WHISPERASR_HIGH_QUALITY_ASR_FIXTURE"],
              let expectedSHA256 = environment[
                "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256"
              ] else {
            throw XCTSkip("Grant the requested benchmark slot and set its worker smoke environment.")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: fixture), expectedSHA256)
        let outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/benchmarks/issue-\(slot)/\(backend.rawValue)",
                isDirectory: true
            )
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/WhisperASR")
        let asr = HighQualityASRWorkerClient(backend: backend, executableURL: executable)
        let job = HighQualityJob(services: .init(
            loadSource: { try await AudioLoader.loadSamples(url: $0) },
            prepareASR: { try await asr.prepare(progress: $0) },
            transcribeJapanese: {
                try await asr.transcribe(
                    $0,
                    anchored: backend == .funASRNanoInt8
                ).rawTranscript
            },
            transcribeJapaneseAnchored: { try await asr.transcribe($0, anchored: true) },
            unloadASR: { await asr.unload() },
            asrWorkerEvidence: { await asr.evidence },
            currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
            heavyweightGate: .shared
        ))

        let result = try await job.run(.init(
            sourceURL: fixture,
            deliverables: [.japaneseTranscript],
            backend: backend,
            outputRoot: outputRoot
        ))

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.selectedBackend, backend)
        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceNormalization, .japaneseASR, .export]
        )
        XCTAssertFalse(result.japaneseTranscript.isEmpty)
        let worker = try XCTUnwrap(result.manifest.asrWorker)
        XCTAssertEqual(worker, result.evidence.asrWorker)
        XCTAssertEqual(worker.backend, backend)
        XCTAssertEqual(worker.model, result.manifest.model)
        XCTAssertFalse(worker.model.weightSHA256?.isEmpty ?? true)
        XCTAssertEqual(worker.lifecycle.exitStatus, 0)
        XCTAssertFalse(worker.lifecycle.forcedTermination)
        XCTAssertGreaterThan(worker.lifecycle.peakPhysicalFootprintBytes, 0)
        XCTAssertNotEqual(kill(worker.lifecycle.processIdentifier, 0), 0)
        let transcriptSHA256 = try JapaneseBenchmarkSupport.sha256(
            at: result.directory.appendingPathComponent("japanese-transcript.txt")
        )
        if backend == .funASRNanoInt8 {
            print("[issue-88][smoke] transcriptSHA256=\(transcriptSHA256)")
        } else {
            XCTAssertEqual(transcriptSHA256, frozenTranscriptSHA256(for: backend))
        }
    }

    func testRealReazonWorkerCompletesTimestampedSmokeWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BENCHMARK_SLOT_GRANTED"] == "89",
              environment["WHISPERASR_RUN_REAZON_SMOKE"] == "1",
              let fixturePath = environment["WHISPERASR_HIGH_QUALITY_ASR_FIXTURE"],
              let expectedSHA256 = environment[
                "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256"
              ],
              let outputPath = environment["WHISPERASR_ACCEPTANCE_OUTPUT_ROOT"] else {
            throw XCTSkip("Grant benchmark slot #89 and set the Reazon smoke environment.")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: fixture), expectedSHA256)
        let backend = HighQualityASRBackend.reazonSpeechK2V2
        let result = try await HighQualityJob().run(.init(
            sourceURL: fixture,
            deliverables: [.japaneseTranscript],
            backend: backend,
            outputRoot: URL(fileURLWithPath: outputPath)
        ))

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.selectedBackend, backend)
        XCTAssertEqual(result.manifest.dependencies, [
            .sourceNormalization, .japaneseASR, .export,
        ])
        let worker = try XCTUnwrap(result.evidence.asrWorker)
        let characters = try XCTUnwrap(worker.characters)
        XCTAssertFalse(characters.isEmpty)
        XCTAssertEqual(characters.map(\.text).joined(), result.evidence.rawASR)
        XCTAssertTrue(characters.allSatisfy {
            $0.sourceStart >= 0 && $0.sourceEnd >= $0.sourceStart
        })
        XCTAssertEqual(worker.model, backend.model.withWeightSHA256([
            "decoder-epoch-99-avg-1.onnx":
                "58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124",
            "encoder-epoch-99-avg-1.int8.onnx":
                "2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d",
            "joiner-epoch-99-avg-1.int8.onnx":
                "49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de",
            "tokens.txt":
                "2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def",
        ]))
        XCTAssertEqual(worker.lifecycle.exitStatus, 0)
        XCTAssertFalse(worker.lifecycle.forcedTermination)
        XCTAssertNotEqual(kill(worker.lifecycle.processIdentifier, 0), 0)
    }

    func testEveryBackendRoundTripsOneTranscriptAndExits() async throws {
        for backend in HighQualityASRBackend.allCases {
            let expected = "\(backend.rawValue)-日本語"
            let fixture = try ASRWorkerFixture(
                backend: backend,
                response: try responseJSON(.init(rawTranscript: expected, chunks: []))
            )
            let worker = fixture.worker(backend: backend)

            try await worker.prepare(progress: { _, _ in })
            let activePID = await worker.processIdentifier
            let pid = try XCTUnwrap(activePID)
            let exchange = try await worker.transcribe([0.25, -0.5], anchored: false)
            XCTAssertEqual(exchange.rawTranscript, expected)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(
                    atPath: fixture.directory.appendingPathComponent("audio-1.f32").path
                )[.size] as? Int,
                2 * MemoryLayout<Float>.size
            )

            await worker.unload()
            XCTAssertNotEqual(kill(pid, 0), 0)
            let recordedEvidence = await worker.evidence
            let evidence = try XCTUnwrap(recordedEvidence)
            XCTAssertEqual(evidence.backend, backend)
            XCTAssertEqual(evidence.model.backend, backend)
            XCTAssertFalse(evidence.model.weightSHA256?.isEmpty ?? true)
            XCTAssertEqual(evidence.lifecycle.exitStatus, 0)
        }
    }

    func testFrozenAnchoredExchangeKeepsExactJapaneseOutput() async throws {
        let frozen = HighQualityASRExchange(
            rawTranscript: "一\n二",
            chunks: [
                .init(index: 0, sourceStart: 0, sourceEnd: 1, transcript: "一"),
                .init(index: 1, sourceStart: 1, sourceEnd: 2, transcript: "二"),
            ]
        )
        let fixture = try ASRWorkerFixture(
            backend: .qwenJA,
            response: try responseJSON(frozen)
        )
        let worker = fixture.worker(backend: .qwenJA)
        try await worker.prepare(progress: { _, _ in })

        let moved = try await worker.transcribe(
            Array(repeating: 0, count: 32_000),
            anchored: true
        )
        await worker.unload()

        XCTAssertEqual(moved, frozen)
    }

    func testAnchoredCharacterTimingFailsClosedWhenNotMonotonic() {
        let chunks = [HighQualityASRChunk(
            index: 0, sourceStart: 0, sourceEnd: 2, transcript: "日本"
        )]
        let valid = HighQualityASRExchange(
            rawTranscript: "日本",
            chunks: chunks,
            characters: [
                .init(chunkIndex: 0, text: "日", sourceStart: 0.2, sourceEnd: 0.8),
                .init(chunkIndex: 0, text: "本", sourceStart: 0.8, sourceEnd: 1.2),
            ]
        )
        let regressing = HighQualityASRExchange(
            rawTranscript: "日本",
            chunks: chunks,
            characters: [
                .init(chunkIndex: 0, text: "日", sourceStart: 0.8, sourceEnd: 1),
                .init(chunkIndex: 0, text: "本", sourceStart: 0.5, sourceEnd: 1.2),
            ]
        )

        XCTAssertTrue(HighQualityASRWorkerClient.isValid(
            valid, sampleCount: 32_000, anchored: true
        ))
        XCTAssertFalse(HighQualityASRWorkerClient.isValid(
            regressing, sampleCount: 32_000, anchored: true
        ))
    }

    func testMalformedOutputFailsAndWorkerTerminates() async throws {
        let malformed = HighQualityASRExchange(
            rawTranscript: "一",
            chunks: [.init(index: 1, sourceStart: 0, sourceEnd: 2, transcript: "一")]
        )
        let fixture = try ASRWorkerFixture(
            backend: .whisperKit,
            response: try responseJSON(malformed)
        )
        let worker = fixture.worker(backend: .whisperKit)
        try await worker.prepare(progress: { _, _ in })
        let activePID = await worker.processIdentifier
        let pid = try XCTUnwrap(activePID)

        do {
            _ = try await worker.transcribe([0], anchored: true)
            XCTFail("Malformed worker output must fail.")
        } catch let error as HighQualityASRWorkerError {
            guard case .protocolFailure = error else {
                return XCTFail("Expected protocol failure, got \(error).")
            }
        }
        await worker.unload()
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testPreparationFailureTerminatesWithDiagnostics() async throws {
        let model = HighQualityASRBackend.parakeetJA.model.withWeightSHA256([
            "weights/fixture.bin": String(repeating: "b", count: 64)
        ])
        struct Failure: Encodable {
            let model: HighQualityModelEvidence
            let error: String
        }
        let fixture = try ASRWorkerFixture(
            backend: .parakeetJA,
            readyOverride: String(decoding: try JSONEncoder().encode(Failure(
                model: model,
                error: "fixture model preparation failed"
            )), as: UTF8.self),
            response: nil,
            exitAfterReady: true
        )
        let worker = fixture.worker(backend: .parakeetJA)

        do {
            try await worker.prepare(progress: { _, _ in })
            XCTFail("Model preparation must fail.")
        } catch let error as HighQualityASRWorkerError {
            XCTAssertTrue(error.localizedDescription.contains("fixture model preparation failed"))
        }
        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)
        XCTAssertEqual(evidence.model, model)
        XCTAssertNotEqual(evidence.lifecycle.exitStatus, 0)
    }

    func testCancellationTerminatesPendingASRWorker() async throws {
        let fixture = try ASRWorkerFixture(
            backend: .qwenJA,
            response: nil
        )
        let worker = fixture.worker(backend: .qwenJA)
        try await worker.prepare(progress: { _, _ in })
        let activePID = await worker.processIdentifier
        let pid = try XCTUnwrap(activePID)
        let transcription = Task { try await worker.transcribe([0], anchored: false) }
        try await Task.sleep(for: .milliseconds(20))
        transcription.cancel()

        do {
            _ = try await transcription.value
            XCTFail("Cancellation must cross the worker boundary.")
        } catch is CancellationError {}
        await worker.unload()

        XCTAssertNotEqual(kill(pid, 0), 0)
        let evidence = await worker.evidence
        XCTAssertNotNil(evidence)
    }

    func testCriticalPressureStopsASRWorkerRecoverably() async throws {
        let pressure = MacMemoryPressureMonitor(native: false)
        let fixture = try ASRWorkerFixture(backend: .qwenJA, response: nil)
        let worker = fixture.worker(backend: .qwenJA, pressure: pressure)
        try await worker.prepare(progress: { _, _ in })

        pressure.record(.critical)
        try await waitUntil { await worker.evidence != nil }
        do {
            _ = try await worker.transcribe([0], anchored: false)
            XCTFail("Critical pressure must stop ASR.")
        } catch let error as HighQualityASRWorkerError {
            XCTAssertEqual(error, .criticalMemoryPressure)
            XCTAssertTrue(error.localizedDescription.contains("recoverable"))
        }
    }

    func testWeightEvidenceHashesOnlyModelWeights() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let weights = directory.appendingPathComponent("compiled/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: weights.appendingPathComponent("weight.bin"))
        try Data("mlx".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("config.json"))

        let hashes = try HighQualityASRWeightEvidence.hashes(in: directory)

        XCTAssertEqual(Set(hashes.keys), ["compiled/weights/weight.bin", "model.safetensors"])
        XCTAssertTrue(hashes.values.allSatisfy { $0.count == 64 })
    }

    func testJobManifestRetainsASRWorkerProvenanceAndPeakMemory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HighQualityASRBackend.qwenJA.model.withWeightSHA256([
            "model.safetensors": String(repeating: "a", count: 64)
        ])
        let workerEvidence = HighQualityASRWorkerEvidence(
            backend: .qwenJA,
            model: model,
            lifecycle: lifecycleEvidence(peak: 4_096)
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "日本語" },
            unloadASR: {},
            asrWorkerEvidence: { workerEvidence }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        XCTAssertEqual(result.manifest.asrWorker, workerEvidence)
        XCTAssertEqual(result.evidence.asrWorker, workerEvidence)
        XCTAssertEqual(result.manifest.model.weightSHA256, model.weightSHA256)
        XCTAssertEqual(result.manifest.peakMemoryBytes, 4_096)
    }

    private func responseJSON(_ exchange: HighQualityASRExchange) throws -> String {
        struct Response: Encodable {
            let exchange: HighQualityASRExchange
        }
        return String(decoding: try JSONEncoder().encode(Response(exchange: exchange)), as: UTF8.self)
    }

    private func frozenTranscriptSHA256(for backend: HighQualityASRBackend) -> String {
        switch backend {
        case .qwenJA:
            "1feb6c346dbe907ea15f6eb4b5b86e1ab329e709afc7ea0d738b9f51ae268863"
        case .parakeetJA:
            "3cad6a614de6a0526a8b96ee07fc142ca1b431fe8c4997319092c7fccbd48bfb"
        case .whisperKit:
            "ce3de9ff8e084329bea612985ce6a60b4d998410071de595e749033c4d2486ad"
        case .funASRNanoInt8:
            preconditionFailure("Fun-ASR has no frozen #72 transcript")
        case .reazonSpeechK2V2:
            preconditionFailure("ReazonSpeech has no frozen heavy output before ticket #89.")
        }
    }

    private var frozenWhisperKitCommonPrefix: String {
        "続いての対処戦ですが、アマユミ、モカ、そして立川来ましたモカさん頑張れ頑張れ頑張れ先程は立川もプロとしての意地を見せましたPCR GTAで人のパンツ覗いてきた人のことなんかボコボコにしてくれんええそうなの?最低だなそうなんやろ私とクロンさんのパンツ覗いてきたから立川さんえぇ許せない"
    }

    private var frozenWhisperKitWeightSHA256: [String: String] {
        [
            "AudioEncoder.mlmodelc/weights/weight.bin":
                "eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457",
            "MelSpectrogram.mlmodelc/weights/weight.bin":
                "97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87",
            "TextDecoder.mlmodelc/weights/weight.bin":
                "680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55"
        ]
    }

    private func lifecycleEvidence(peak: UInt64) -> HighQualityWorkerEvidence {
        let now = Date()
        return .init(
            command: ["fixture-worker"],
            processIdentifier: 1,
            startedAt: now,
            exitedAt: now,
            elapsedSeconds: 0,
            exitStatus: 0,
            terminationReason: "exit",
            forcedTermination: false,
            peakPhysicalFootprintBytes: peak,
            pressureTransitions: [],
            availableMemorySamples: [],
            swapUsedBeforeBytes: 0,
            swapUsedAfterBytes: 0,
            rawLogPath: "/tmp/fixture-worker.log",
            rawLog: ""
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let completed = await predicate()
        XCTAssertTrue(completed)
    }
}

private struct ASRWorkerFixture {
    let directory: URL
    let executable: URL

    init(
        backend: HighQualityASRBackend,
        readyOverride: String? = nil,
        response: String?,
        exitAfterReady: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("worker.sh")
        let model = backend.model.withWeightSHA256([
            "weights/fixture.bin": String(repeating: "a", count: 64)
        ])
        struct Ready: Encodable {
            let ready = true
            let model: HighQualityModelEvidence
        }
        let ready: String
        if let readyOverride {
            ready = readyOverride
        } else {
            ready = String(
                decoding: try JSONEncoder().encode(Ready(model: model)),
                as: UTF8.self
            )
        }
        let responseBlock = response.map {
            """
            while [ ! -f "$directory/request-1.json" ]; do sleep 0.01; done
            printf '%s' '\($0)' > "$directory/response-1.tmp"
            mv "$directory/response-1.tmp" "$directory/response-1.json"
            """
        } ?? ""
        let script = """
        #!/bin/sh
        [ "$2" = "\(backend.rawValue)" ] || exit 64
        directory="$3"
        trap 'exit 75' TERM
        printf '%s' '\(ready)' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        \(exitAfterReady ? "exit 1" : responseBlock)
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
    }

    func worker(
        backend: HighQualityASRBackend,
        pressure: MacMemoryPressureMonitor = MacMemoryPressureMonitor(native: false)
    ) -> HighQualityASRWorkerClient {
        HighQualityASRWorkerClient(
            backend: backend,
            executableURL: executable,
            workingDirectory: directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50),
            launchOverride: (executable, [])
        )
    }
}
