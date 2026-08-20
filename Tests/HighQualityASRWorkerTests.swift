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
        let backendResult = try XCTUnwrap(worker.result)
        XCTAssertEqual(backendResult.rawTranscript, result.evidence.rawASR)
        XCTAssertEqual(backendResult.model, worker.model)
        switch backend {
        case .qwenJA:
            XCTAssertNil(backendResult.confidence)
            XCTAssertNil(backendResult.averageLogProbability)
            XCTAssertNil(backendResult.segments)
            XCTAssertNil(backendResult.tokenTimings)
            XCTAssertNil(backendResult.wordTimings)
        case .parakeetJA:
            XCTAssertNotNil(backendResult.confidence)
            let tokenTimings = try XCTUnwrap(backendResult.tokenTimings)
            XCTAssertFalse(tokenTimings.isEmpty)
            XCTAssertTrue(tokenTimings.contains { $0.confidence != nil })
        case .whisperKit:
            XCTAssertNotNil(backendResult.averageLogProbability)
            let segments = try XCTUnwrap(backendResult.segments)
            XCTAssertFalse(segments.isEmpty)
            XCTAssertTrue(segments.allSatisfy { $0.noSpeechProbability == nil })
            XCTAssertFalse(try XCTUnwrap(backendResult.wordTimings).isEmpty)
        case .funASRNanoInt8, .reazonSpeechK2V2:
            break
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedManifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: result.directory.appendingPathComponent("manifest.json"))
        )
        let persistedEvidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: result.directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(persistedManifest.asrWorker?.result, backendResult)
        XCTAssertEqual(persistedEvidence.asrWorker?.result, backendResult)
        let transcriptSHA256 = try JapaneseBenchmarkSupport.sha256(
            at: result.directory.appendingPathComponent("japanese-transcript.txt")
        )
        if backend == .funASRNanoInt8 {
            print("[issue-88][smoke] transcriptSHA256=\(transcriptSHA256)")
        } else if backend == .whisperKit {
            XCTAssertTrue(result.japaneseTranscript.hasPrefix(frozenWhisperKitCommonPrefix))
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
            let backendResult = switch backend {
            case .qwenJA:
                HighQualityASRExchange(
                    rawTranscript: expected,
                    chunks: [],
                    diagnostics: .init(emptyOutput: false)
                )
            case .parakeetJA:
                HighQualityASRExchange(
                    rawTranscript: expected,
                    chunks: [],
                    tokenTimings: [.init(
                        text: "日本語",
                        tokenIDs: [42],
                        sourceStart: 0.1,
                        sourceEnd: 0.4,
                        confidence: 0.87
                    )],
                    confidence: 0.81,
                    diagnostics: .init(emptyOutput: false)
                )
            case .whisperKit:
                HighQualityASRExchange(
                    rawTranscript: expected,
                    chunks: [],
                    segments: [.init(
                        index: 0,
                        text: "日本語",
                        tokenIDs: [10, 11],
                        sourceStart: 0.1,
                        sourceEnd: 0.4,
                        averageLogProbability: -0.42,
                        noSpeechProbability: 0.08,
                        compressionRatio: 1.1
                    )],
                    wordTimings: [.init(
                        text: "日本語",
                        tokenIDs: [10, 11],
                        sourceStart: 0.1,
                        sourceEnd: 0.4,
                        confidence: 0.76
                    )],
                    averageLogProbability: -0.42,
                    diagnostics: .init(emptyOutput: false)
                )
            case .funASRNanoInt8, .reazonSpeechK2V2:
                fatalError("Experimental backends must stay out of Standard.")
            }
            let fixture = try ASRWorkerFixture(
                backend: backend,
                response: try responseJSON(backendResult)
            )
            let worker = fixture.worker(backend: backend)

            try await worker.prepare(progress: { _, _ in })
            let activePID = await worker.processIdentifier
            let pid = try XCTUnwrap(activePID)
            let exchange = try await worker.transcribe(
                Array(repeating: 0, count: 16_000),
                anchored: false
            )
            XCTAssertEqual(exchange.rawTranscript, expected)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(
                    atPath: fixture.directory.appendingPathComponent("audio-1.f32").path
                )[.size] as? Int,
                16_000 * MemoryLayout<Float>.size
            )
            XCTAssertEqual(exchange.model?.backend, backend)
            if backend == .qwenJA {
                XCTAssertNil(exchange.confidence)
                XCTAssertNil(exchange.averageLogProbability)
                XCTAssertNil(exchange.segments)
                XCTAssertNil(exchange.tokenTimings)
                XCTAssertNil(exchange.wordTimings)
            }

            await worker.unload()
            XCTAssertNotEqual(kill(pid, 0), 0)
            let recordedEvidence = await worker.evidence
            let evidence = try XCTUnwrap(recordedEvidence)
            XCTAssertEqual(evidence.backend, backend)
            XCTAssertEqual(evidence.model.backend, backend)
            XCTAssertEqual(evidence.result, exchange)
            XCTAssertFalse(evidence.model.weightSHA256?.isEmpty ?? true)
            XCTAssertEqual(evidence.lifecycle.exitStatus, 0)
        }
    }

    func testParakeetResultRetainsNativeConfidenceAndTokenTimings() throws {
        let exchange = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            model: HighQualityASRBackend.parakeetJA.model,
            tokenTimings: [
                .init(
                    text: "日本",
                    tokenIDs: [42],
                    sourceStart: 0.12,
                    sourceEnd: 0.34,
                    confidence: 0.87
                ),
            ],
            confidence: 0.81,
            diagnostics: .init(emptyOutput: false)
        )

        let decoded = try JSONDecoder().decode(
            HighQualityASRExchange.self,
            from: JSONEncoder().encode(exchange)
        )

        XCTAssertEqual(decoded, exchange)
    }

    func testWorkerEvidenceSurvivesExitWithStandardizedResult() async throws {
        let exchange = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            tokenTimings: [
                .init(
                    text: "日本",
                    tokenIDs: [42],
                    sourceStart: 0.12,
                    sourceEnd: 0.34,
                    confidence: 0.87
                ),
            ],
            confidence: 0.81,
            diagnostics: .init(emptyOutput: false)
        )
        let fixture = try ASRWorkerFixture(
            backend: .parakeetJA,
            response: try responseJSON(exchange)
        )
        let worker = fixture.worker(backend: .parakeetJA)
        try await worker.prepare(progress: { _, _ in })

        let result = try await worker.transcribe(
            Array(repeating: 0, count: 16_000),
            anchored: false
        )
        await worker.unload()
        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)

        XCTAssertEqual(evidence.result, result)
        XCTAssertEqual(result.model, evidence.model)
    }

    func testWhisperKitResultRetainsNativeLogProbabilityAndTimings() throws {
        let exchange = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            model: HighQualityASRBackend.whisperKit.model,
            segments: [
                .init(
                    index: 7,
                    text: "日本語",
                    tokenIDs: [10, 11],
                    sourceStart: 0.2,
                    sourceEnd: 0.9,
                    averageLogProbability: -0.42,
                    noSpeechProbability: nil,
                    compressionRatio: 1.1
                ),
            ],
            wordTimings: [
                .init(
                    text: "日本語",
                    tokenIDs: [10, 11],
                    sourceStart: 0.2,
                    sourceEnd: 0.9,
                    confidence: 0.76
                ),
            ],
            averageLogProbability: -0.42,
            diagnostics: .init(emptyOutput: false)
        )

        let data = try JSONEncoder().encode(exchange)
        let decoded = try JSONDecoder().decode(
            HighQualityASRExchange.self,
            from: data
        )

        XCTAssertEqual(decoded, exchange)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertNil(segments[0]["noSpeechProbability"])
    }

    func testAnchoredASRRetainsBackendEvidenceAndPromotesModel() async throws {
        let backendResult = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            model: HighQualityASRBackend.parakeetJA.model,
            tokenTimings: [
                .init(
                    text: "日本",
                    tokenIDs: [42],
                    sourceStart: 0.12,
                    sourceEnd: 0.34,
                    confidence: 0.87
                ),
            ],
            confidence: 0.81,
            diagnostics: .init(emptyOutput: false)
        )

        let anchored = try await HighQualityJob.Services.chunkedASR(
            Array(repeating: 0, count: 16_000),
            transcribe: { _ in backendResult }
        )

        XCTAssertEqual(anchored.model, backendResult.model)
        XCTAssertNil(anchored.tokenTimings)
        XCTAssertNil(anchored.confidence)
        XCTAssertNil(anchored.diagnostics)
        var expectedWindow = backendResult
        expectedWindow.model = nil
        XCTAssertEqual(anchored.windows?.first?.result, expectedWindow)
        XCTAssertTrue(HighQualityASRWorkerClient.isValid(
            anchored,
            sampleCount: 16_000,
            anchored: true
        ))
    }

    func testAnchoredASRRetainsWhisperKitEvidenceInRawWindow() async throws {
        let backendResult = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            model: HighQualityASRBackend.whisperKit.model,
            segments: [
                .init(
                    index: 7,
                    text: "日本語",
                    tokenIDs: [10, 11],
                    sourceStart: 0.2,
                    sourceEnd: 0.9,
                    averageLogProbability: -0.42,
                    noSpeechProbability: nil,
                    compressionRatio: 1.1
                ),
            ],
            wordTimings: [
                .init(
                    text: "日本語",
                    tokenIDs: [10, 11],
                    sourceStart: 0.2,
                    sourceEnd: 0.9,
                    confidence: 0.76
                ),
            ],
            averageLogProbability: -0.42,
            diagnostics: .init(emptyOutput: false)
        )

        let anchored = try await HighQualityJob.Services.chunkedASR(
            Array(repeating: 0, count: 16_000),
            transcribe: { _ in backendResult }
        )

        XCTAssertNil(anchored.segments)
        XCTAssertNil(anchored.wordTimings)
        XCTAssertNil(anchored.averageLogProbability)
        var expectedWindow = backendResult
        expectedWindow.model = nil
        XCTAssertEqual(anchored.windows?.first?.result, expectedWindow)
    }

    func testAnchoredASRSeparatesSelectedTranscriptFromExactBackendEvidence() async throws {
        let backendResult = HighQualityASRExchange(
            rawTranscript: "  日本語!?  ",
            chunks: [],
            model: HighQualityASRBackend.parakeetJA.model,
            confidence: 0.81,
            diagnostics: .init(emptyOutput: false)
        )

        let anchored = try await HighQualityJob.Services.chunkedASR(
            Array(repeating: 0, count: 16_000),
            transcribe: { _ in backendResult }
        )

        XCTAssertEqual(anchored.rawTranscript, "日本語!?")
        XCTAssertNil(anchored.confidence)
        XCTAssertNil(anchored.diagnostics)
        XCTAssertEqual(anchored.windows?.count, 1)
        let window = try XCTUnwrap(anchored.windows?.first)
        var expectedWindow = backendResult
        expectedWindow.model = nil
        XCTAssertEqual(window.result, expectedWindow)
    }

    func testReazonAnchoredASRKeepsClientModelOutOfRawWindows() async throws {
        let backendResult = HighQualityASRExchange(rawTranscript: "日本語", chunks: [])
        let fixture = try ASRWorkerFixture(
            backend: .reazonSpeechK2V2,
            response: try responseJSON(backendResult),
            responseCount: 2
        )
        let worker = fixture.worker(backend: .reazonSpeechK2V2)
        try await worker.prepare(progress: { _, _ in })

        let anchored: HighQualityASRExchange
        do {
            anchored = try await worker.transcribe(
                Array(repeating: 0.1, count: 21 * 16_000),
                anchored: true
            )
        } catch {
            await worker.unload()
            throw error
        }
        await worker.unload()

        XCTAssertEqual(anchored.windows?.count, 2)
        XCTAssertEqual(anchored.model?.backend, .reazonSpeechK2V2)
        XCTAssertTrue(anchored.windows?.allSatisfy {
            $0.result.model == nil
        } ?? false)
    }

    func testLegacyASRExchangeDecodesWithNewEvidenceAbsent() throws {
        let legacy = Data(#"{"rawTranscript":"旧","chunks":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(HighQualityASRExchange.self, from: legacy)

        XCTAssertEqual(decoded.rawTranscript, "旧")
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.segments)
        XCTAssertNil(decoded.tokenTimings)
        XCTAssertNil(decoded.wordTimings)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.averageLogProbability)
        XCTAssertNil(decoded.diagnostics)
        XCTAssertNil(decoded.windows)
    }

    func testAnchoredASRPreservesOverlappingWindowEvidenceWithoutFlattening() async throws {
        let results = ASRExchangeSequence([
            .init(
                rawTranscript: "一",
                chunks: [],
                tokenTimings: [.init(
                    text: "一",
                    tokenIDs: [41],
                    sourceStart: 19.5,
                    sourceEnd: 19.6,
                    confidence: 0.8
                )],
                confidence: 0.8,
                diagnostics: .init(emptyOutput: false)
            ),
            .init(
                rawTranscript: "二",
                chunks: [],
                tokenTimings: [.init(
                    text: "二",
                    tokenIDs: [42],
                    sourceStart: 0.1,
                    sourceEnd: 0.2,
                    confidence: 0.7
                )],
                confidence: 0.7,
                diagnostics: .init(emptyOutput: false)
            ),
        ])

        let anchored = try await HighQualityJob.Services.chunkedASR(
            Array(repeating: 0.1, count: 21 * 16_000),
            transcribe: { _ in await results.next() }
        )

        XCTAssertNil(anchored.tokenTimings)
        XCTAssertNil(anchored.confidence)
        XCTAssertNil(anchored.diagnostics)
        let windows = try XCTUnwrap(anchored.windows)
        XCTAssertEqual(windows.map(\.sourceStart), [0, 18])
        XCTAssertEqual(windows.map(\.sourceEnd), [20, 21])
        XCTAssertEqual(windows.map { $0.result.tokenTimings?.first?.sourceStart }, [19.5, 0.1])
        XCTAssertTrue(HighQualityASRWorkerClient.isValid(
            anchored, sampleCount: 21 * 16_000, anchored: true
        ))
    }

    func testUnavailableBackendEvidenceStaysAbsentInJSON() throws {
        let qwen = HighQualityASRExchange(
            rawTranscript: "日本語",
            chunks: [],
            diagnostics: .init(emptyOutput: false)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(qwen))
                as? [String: Any]
        )

        for key in [
            "confidence", "averageLogProbability", "segments", "tokenTimings", "wordTimings",
            "windows",
        ] {
            XCTAssertNil(object[key])
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

        XCTAssertEqual(moved.rawTranscript, frozen.rawTranscript)
        XCTAssertEqual(moved.chunks, frozen.chunks)
        XCTAssertEqual(moved.model?.backend, .qwenJA)
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
        XCTAssertEqual(
            HighQualityASRWorkerClient.validationFailure(
                regressing, sampleCount: 32_000, anchored: true
            ),
            .invalidCandidateEvidence(.invalidTimestamps)
        )
    }

    func testAnchoredChunksKeepLegacyNonMonotonicStartContract() {
        let exchange = HighQualityASRExchange(
            rawTranscript: "後\n前",
            chunks: [
                .init(index: 0, sourceStart: 2, sourceEnd: 3, transcript: "後"),
                .init(index: 1, sourceStart: 0, sourceEnd: 1, transcript: "前"),
            ]
        )

        XCTAssertTrue(HighQualityASRWorkerClient.isValid(
            exchange,
            sampleCount: 4 * 16_000,
            anchored: true
        ))
    }

    func testMalformedBackendEvidenceFailsClosedAtWorkerBoundary() async throws {
        let timing = HighQualityASRTimingEvidence(
            text: "日",
            tokenIDs: [42],
            sourceStart: 0.1,
            sourceEnd: 0.2,
            confidence: 0.8
        )
        let invalidResults = [
            HighQualityASRExchange(
                rawTranscript: "日",
                chunks: [],
                tokenTimings: [timing],
                confidence: 1.1
            ),
            HighQualityASRExchange(
                rawTranscript: "日",
                chunks: [],
                segments: [.init(
                    index: 0,
                    text: "日",
                    tokenIDs: [42],
                    sourceStart: 0.1,
                    sourceEnd: 0.2,
                    averageLogProbability: -0.4,
                    noSpeechProbability: 1.1,
                    compressionRatio: 1
                )]
            ),
            HighQualityASRExchange(
                rawTranscript: "日",
                chunks: [],
                tokenTimings: [.init(
                    text: "日",
                    tokenIDs: [-1],
                    sourceStart: 0.1,
                    sourceEnd: 0.2,
                    confidence: 0.8
                )]
            ),
            HighQualityASRExchange(
                rawTranscript: "日",
                chunks: [],
                diagnostics: .init(emptyOutput: true)
            ),
        ]

        for invalid in invalidResults {
            try await assertProtocolFailure(invalid, anchored: false, sampleCount: 16_000)
        }

        let invalidTiming = HighQualityASRExchange(
            rawTranscript: "日",
            chunks: [],
            wordTimings: [.init(
                text: "日",
                tokenIDs: [42],
                sourceStart: -0.1,
                sourceEnd: 0.2,
                confidence: 0.8
            )]
        )
        let fixture = try ASRWorkerFixture(
            backend: .whisperKit,
            response: try responseJSON(invalidTiming)
        )
        let worker = fixture.worker(backend: .whisperKit)
        try await worker.prepare(progress: { _, _ in })
        do {
            _ = try await worker.transcribe(
                Array(repeating: 0, count: 16_000), anchored: false
            )
            XCTFail("Invalid candidate timestamps must not cross the worker boundary.")
        } catch let error as HighQualityASRWorkerError {
            XCTAssertEqual(error, .invalidCandidateEvidence(.invalidTimestamps))
        }
        await worker.unload()
    }

    func testAudioDataWriteFailureRoutesAsInfrastructure() async throws {
        let fixture = try ASRWorkerFixture(
            backend: .whisperKit,
            response: nil
        )
        let worker = fixture.worker(backend: .whisperKit)
        try await worker.prepare(progress: { _, _ in })
        try FileManager.default.removeItem(at: fixture.directory)

        do {
            _ = try await worker.transcribe(
                Array(repeating: 0, count: 16_000),
                anchored: false
            )
            XCTFail("An audio Data.write failure must abort as infrastructure.")
        } catch {
            XCTAssertEqual(HighQualityAdaptiveASR.route(error), .infrastructure)
        }
        await worker.unload()
    }

    func testMalformedWindowEvidenceFailsClosedAtWorkerBoundary() async throws {
        let first = HighQualityASRExchange(
            rawTranscript: "一",
            chunks: [],
            tokenTimings: [.init(
                text: "一",
                tokenIDs: [41],
                sourceStart: 0.1,
                sourceEnd: 0.2,
                confidence: 0.8
            )],
            diagnostics: .init(emptyOutput: false)
        )
        let second = HighQualityASRExchange(
            rawTranscript: "二",
            chunks: [],
            tokenTimings: [.init(
                text: "二",
                tokenIDs: [42],
                sourceStart: 0.1,
                sourceEnd: 0.2,
                confidence: 0.7
            )],
            diagnostics: .init(emptyOutput: false)
        )
        let chunks = [
            HighQualityASRChunk(index: 0, sourceStart: 0, sourceEnd: 1, transcript: "一"),
            HighQualityASRChunk(index: 1, sourceStart: 1, sourceEnd: 2, transcript: "二"),
        ]
        let windows = [
            HighQualityASRWindowEvidence(sourceStart: 0, sourceEnd: 1, result: first),
            HighQualityASRWindowEvidence(sourceStart: 1, sourceEnd: 2, result: second),
        ]
        let invalidResults = [
            HighQualityASRExchange(
                rawTranscript: "",
                chunks: [],
                windows: []
            ),
            HighQualityASRExchange(
                rawTranscript: "一\n二",
                chunks: chunks,
                tokenTimings: first.tokenTimings,
                windows: windows
            ),
            HighQualityASRExchange(
                rawTranscript: "一\n二",
                chunks: chunks,
                model: HighQualityASRBackend.parakeetJA.model,
                windows: [
                    .init(
                        sourceStart: 0,
                        sourceEnd: 1,
                        result: .init(
                            rawTranscript: "一",
                            chunks: [],
                            model: HighQualityASRBackend.whisperKit.model
                        )
                    ),
                    windows[1],
                ]
            ),
            HighQualityASRExchange(
                rawTranscript: "一\n二",
                chunks: chunks,
                windows: [
                    .init(
                        sourceStart: 0,
                        sourceEnd: 1,
                        result: .init(
                            rawTranscript: "一",
                            chunks: [],
                            windows: windows
                        )
                    ),
                    windows[1],
                ]
            ),
        ]

        for invalid in invalidResults {
            try await assertProtocolFailure(invalid, anchored: true, sampleCount: 32_000)
        }
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
            _ = try await worker.transcribe(
                Array(repeating: 0, count: 2 * 16_000), anchored: true
            )
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
            lifecycle: lifecycleEvidence(peak: 4_096),
            result: .init(
                rawTranscript: "日本語",
                chunks: [],
                model: model,
                diagnostics: .init(emptyOutput: false)
            )
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
        XCTAssertEqual(
            result.manifest.schemaVersion,
            HighQualityJobManifest.currentSchemaVersion
        )
        XCTAssertEqual(result.manifest.model.weightSHA256, model.weightSHA256)
        XCTAssertEqual(result.manifest.peakMemoryBytes, 4_096)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: result.directory.appendingPathComponent("manifest.json"))
        )
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: result.directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(manifest.asrWorker?.result, workerEvidence.result)
        XCTAssertEqual(evidence.asrWorker?.result, workerEvidence.result)

        let saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopened = try HighQualityJob.reopen(saved)
        XCTAssertEqual(
            reopened.manifest.schemaVersion,
            HighQualityJobManifest.currentSchemaVersion
        )
        XCTAssertNotNil(reopened.manifest.rawEvidenceSHA256)
        XCTAssertEqual(reopened.evidence.asrWorker, reopened.manifest.asrWorker)
        XCTAssertEqual(reopened.evidence.asrWorker?.result, workerEvidence.result)

        func legacyData(at url: URL, schemaVersion: Int? = nil) throws -> Data {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            if let schemaVersion { object["schemaVersion"] = schemaVersion }
            object.removeValue(forKey: "selectedASRMode")
            object.removeValue(forKey: "adaptiveASR")
            var worker = try XCTUnwrap(object["asrWorker"] as? [String: Any])
            worker.removeValue(forKey: "result")
            object["asrWorker"] = worker
            return try JSONSerialization.data(withJSONObject: object)
        }
        let legacyManifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: legacyData(
                at: result.directory.appendingPathComponent("manifest.json"),
                schemaVersion: 2
            )
        )
        let legacyEvidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: legacyData(at: result.directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(legacyManifest.schemaVersion, 2)
        XCTAssertNil(legacyManifest.selectedASRMode)
        XCTAssertNil(legacyEvidence.adaptiveASR)
        XCTAssertNil(legacyManifest.asrWorker?.result)
        XCTAssertNil(legacyEvidence.asrWorker?.result)

        let manifestURL = result.directory.appendingPathComponent("manifest.json")
        var issue116Manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        issue116Manifest["schemaVersion"] = 3
        issue116Manifest.removeValue(forKey: "rawEvidenceSHA256")
        issue116Manifest.removeValue(forKey: "selectedASRMode")
        try JSONSerialization.data(withJSONObject: issue116Manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
        let evidenceURL = result.directory.appendingPathComponent("raw-asr.json")
        var issue116Evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        ["resultTurns", "subtitleCues", "japaneseTranscript", "englishTranscript"]
            .forEach { issue116Evidence.removeValue(forKey: $0) }
        issue116Evidence.removeValue(forKey: "adaptiveASR")
        try JSONSerialization.data(withJSONObject: issue116Evidence, options: [.sortedKeys])
            .write(to: evidenceURL, options: .atomic)

        let issue116Saved = try XCTUnwrap(HighQualityJob.savedResults(in: root).first)
        let reopenedIssue116 = try HighQualityJob.reopen(issue116Saved)
        XCTAssertEqual(reopenedIssue116.manifest.schemaVersion, 3)
        XCTAssertNil(reopenedIssue116.manifest.rawEvidenceSHA256)
        XCTAssertEqual(
            reopenedIssue116.evidence.asrWorker,
            reopenedIssue116.manifest.asrWorker
        )
        XCTAssertEqual(reopenedIssue116.evidence.asrWorker?.result, workerEvidence.result)
        XCTAssertEqual(reopenedIssue116.japaneseTranscript, result.japaneseTranscript)
    }

    private func responseJSON(_ exchange: HighQualityASRExchange) throws -> String {
        struct Response: Encodable {
            let exchange: HighQualityASRExchange
        }
        return String(decoding: try JSONEncoder().encode(Response(exchange: exchange)), as: UTF8.self)
    }

    private func assertProtocolFailure(
        _ exchange: HighQualityASRExchange,
        anchored: Bool,
        sampleCount: Int
    ) async throws {
        let fixture = try ASRWorkerFixture(
            backend: .parakeetJA,
            response: try responseJSON(exchange)
        )
        let worker = fixture.worker(backend: .parakeetJA)
        try await worker.prepare(progress: { _, _ in })
        do {
            _ = try await worker.transcribe(
                Array(repeating: 0, count: sampleCount),
                anchored: anchored
            )
            XCTFail("Malformed backend evidence must fail at the worker boundary.")
        } catch let error as HighQualityASRWorkerError {
            guard case .protocolFailure = error else {
                return XCTFail("Expected protocol failure, got \(error).")
            }
        }
        await worker.unload()
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

private actor ASRExchangeSequence {
    private var results: [HighQualityASRExchange]

    init(_ results: [HighQualityASRExchange]) {
        self.results = results
    }

    func next() -> HighQualityASRExchange {
        results.removeFirst()
    }
}

private struct ASRWorkerFixture {
    let directory: URL
    let executable: URL

    init(
        backend: HighQualityASRBackend,
        readyOverride: String? = nil,
        response: String?,
        responseCount: Int = 1,
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
        let responseBlock = response.map { response in
            (1...responseCount).map { sequence in
                """
                while [ ! -f "$directory/request-\(sequence).json" ]; do sleep 0.01; done
                printf '%s' '\(response)' > "$directory/response-\(sequence).tmp"
                mv "$directory/response-\(sequence).tmp" "$directory/response-\(sequence).json"
                """
            }.joined(separator: "\n")
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
