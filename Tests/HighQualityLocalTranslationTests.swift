import XCTest
@testable import WhisperASRApp

final class HighQualityLocalTranslationTests: XCTestCase {
    func testLocalTranslationRunsOnlyAfterASRUnloadWithoutHostedCredentials() async throws {
        let sequence = TranslationSequence()
        let gate = testGate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.removeObject(forKey: "translationAPIKey")

        let result = try await HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in await sequence.append("prepare-asr") },
            transcribeJapanese: { _ in
                await sequence.append("transcribe-asr")
                return "おはよう。"
            },
            unloadASR: { await sequence.append("unload-asr") },
            prepareTranslation: { _ in await sequence.append("prepare-translation") },
            translateEnglish: { request in
                await sequence.append("translate")
                return .init(
                    model: LocalMLXTranslator.modelID,
                    response: #"{"translations":[{"id":"cue-0001","text":"Good morning."}]}"#,
                    attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
                    revision: LocalMLXTranslator.revision,
                    runtimeVersion: LocalMLXTranslator.runtimeVersion,
                    batches: [.init(
                        cueIDs: request.turns.map(\.id),
                        sanitizedPrompt: "cue=cue-0001 text=おはよう。",
                        sanitizedOutput: "Good morning.",
                        inputTokens: 32
                    )],
                    peakMemoryBytes: 123
                )
            },
            unloadTranslation: { await sequence.append("unload-translation") },
            heavyweightGate: gate
        )).run(.init(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        let events = await sequence.values
        XCTAssertEqual(events, [
            "prepare-asr", "transcribe-asr", "unload-asr",
            "prepare-translation", "translate", "unload-translation",
        ])
        XCTAssertEqual(result.englishTranscript, "Good morning.")
        XCTAssertEqual(result.evidence.translation?.model, LocalMLXTranslator.modelID)
        XCTAssertEqual(result.evidence.translation?.revision, LocalMLXTranslator.revision)
        XCTAssertEqual(result.evidence.translation?.batches.first?.inputTokens, 32)
        XCTAssertLessThanOrEqual(
            result.evidence.translation?.batches.first?.inputTokens ?? .max,
            LocalMLXTranslator.inputTokenLimit
        )
    }

    func testFailedTranslationLoadUnloadsAndReleasesOfflineWorkflow() async throws {
        let unloads = TranslationCounter()
        let gate = testGate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareTranslation: { _ in throw TranslationTestError.failedLoad },
            unloadTranslation: { await unloads.increment() },
            heavyweightGate: gate
        ))

        do {
            _ = try await job.run(request)
            XCTFail("A failed local model load must fail the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .translation)
        }

        let unloadCount = await unloads.value
        XCTAssertEqual(unloadCount, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: root
                .appendingPathComponent(request.id.uuidString)
                .appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(evidence.translation?.model, LocalMLXTranslator.modelID)
        XCTAssertEqual(evidence.translation?.revision, LocalMLXTranslator.revision)
        let live = try await gate.beginWorkflow(.live)
        try await gate.endWorkflow(live)
    }

    func testTranslationCancellationUnloadsAndReleasesOfflineWorkflow() async throws {
        let unloads = TranslationCounter()
        let gate = testGate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "translation started")
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            translateEnglish: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                throw TranslationTestError.unreachable
            },
            unloadTranslation: { await unloads.increment() },
            heavyweightGate: gate
        ))
        let task = Task {
            try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishTranslationTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop local translation.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }
        let unloadCount = await unloads.value
        XCTAssertEqual(unloadCount, 1)
        let live = try await gate.beginWorkflow(.live)
        try await gate.endWorkflow(live)
    }

    func testLegacyEvidenceDecodesWithoutNewLocalTranslationFields() throws {
        let request = HighQualityTranslationBatch(
            source: .init(
                path: "/tmp/source.wav",
                fileName: "source.wav",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: nil
            ),
            turns: [],
            glossary: []
        )
        let evidence = HighQualityTranslationEvidence(
            request: request,
            response: nil,
            model: "legacy-model",
            attempts: [],
            revision: nil,
            runtimeVersion: nil,
            batches: [],
            peakMemoryBytes: 0,
            validationFailures: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any]
        )
        object.removeValue(forKey: "revision")
        object.removeValue(forKey: "runtimeVersion")
        object.removeValue(forKey: "batches")
        object.removeValue(forKey: "peakMemoryBytes")

        let decoded = try JSONDecoder().decode(
            HighQualityTranslationEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.model, "legacy-model")
        XCTAssertEqual(decoded.batches, [])
        XCTAssertEqual(decoded.peakMemoryBytes, 0)

        let event = try JSONDecoder().decode(
            HighQualityModelEvent.self,
            from: Data(#"{"kind":"load-started","backend":"qwen-ja","at":0}"#.utf8)
        )
        XCTAssertEqual(event.modelID, HighQualityASRBackend.qwenJA.model.modelID)
    }

    func testCleanupMemoryFailureIsRecordedAsGuardEvidence() async throws {
        let memory = TranslationMemoryReading(1_000)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
            reserveBytes: HeavyweightModelGate.systemReserveBytes,
            releaseToleranceBytes: 1,
            releaseTimeout: .milliseconds(5),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { await memory.value }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            outputRoot: root
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            translateEnglish: { _ in
                await memory.set(2_000)
                throw TranslationTestError.unreachable
            },
            unloadTranslation: {},
            heavyweightGate: gate
        ))

        do {
            _ = try await job.run(request)
            XCTFail("The translation failure must fail the job.")
        } catch is HighQualityJobError {}

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: root
                .appendingPathComponent(request.id.uuidString)
                .appendingPathComponent("raw-asr.json"))
        )
        XCTAssertTrue(evidence.modelEvents.contains {
            $0.kind == .guardFailed && $0.modelID == LocalMLXTranslator.modelID
        })
    }

    func testRealTranslateGemmaDevelopmentSmokeWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_RUN_TRANSLATEGEMMA_SMOKE"] == "1" else {
            throw XCTSkip("Set WHISPERASR_RUN_TRANSLATEGEMMA_SMOKE=1 for the local 12B smoke run.")
        }
        let runtime = LocalMLXTranslator()
        do {
            try await runtime.prepare(progress: { _, _ in })
            let exchange = try await runtime.translate(.init(
                source: .init(
                    path: "qudu2fx3ncc",
                    fileName: "qudu2fx3ncc",
                    byteCount: nil,
                    modifiedAt: nil,
                    sourceURL: nil,
                    youtube: nil
                ),
                turns: [.init(
                    id: "cue-0001",
                    japanese: "続いての大将戦ですが、甘結もか、そして立川。",
                    precedingJapanese: [],
                    followingJapanese: [],
                    speakerLabel: "SPEAKER_01"
                )],
                glossary: [.init(
                    id: "amayui-moka",
                    japanese: ["甘結もか"],
                    english: "Amayui Moka",
                    englishAliases: []
                )]
            ))
            XCTAssertEqual(exchange.revision, LocalMLXTranslator.revision)
            XCTAssertFalse(exchange.response.isEmpty)
            XCTAssertTrue(exchange.batches.allSatisfy {
                $0.inputTokens <= LocalMLXTranslator.inputTokenLimit
            })
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    private func testGate() -> HeavyweightModelGate {
        HeavyweightModelGate(
            totalMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
            reserveBytes: HeavyweightModelGate.systemReserveBytes,
            releaseToleranceBytes: 1,
            releaseTimeout: .milliseconds(20),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { 1_000 }
        )
    }
}

private enum TranslationTestError: Error {
    case failedLoad
    case unreachable
}

private actor TranslationSequence {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor TranslationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor TranslationMemoryReading {
    private(set) var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func set(_ value: UInt64) { self.value = value }
}
