import XCTest
@testable import WhisperASRApp

final class HighQualityLocalTranslationTests: XCTestCase {
    func testTranslateGemmaIsPinnedAndUsesOnlyTheCurrentJapaneseAsItsPrompt() throws {
        XCTAssertEqual(LocalMLXTranslator.Candidate.productDefault, .translateGemma12B)
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma12B.revision,
            "f3dcfd54df14672fbcf0731086fb47a797a943ae"
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.qwen3_14B.revision,
            "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4"
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma12B.weightSHA256,
            [
                "bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af",
                "c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89",
            ]
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.qwen3_14B.weightSHA256,
            [
                "5795efcfc7c96fd273e600562e8b111bfcc427415de9001d0a07e70cd99cff19",
                "2814562d654fe2d541fd4682804a0ccaa400e79701872c8e9f5998cf9481fdf8",
            ]
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma12B.extraEOSTokens,
            ["<end_of_turn>"]
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.qwen3_14B.extraEOSTokens,
            ["<|im_end|>"]
        )

        let batch = HighQualityTranslationBatch(
            source: .init(
                path: "frozen/qudu2fx3ncc",
                fileName: "qudu2fx3ncc",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: .init(
                    sourceURL: "https://www.youtube.com/watch?v=QUdu2fx3NCc",
                    title: "Frozen development reference",
                    channel: "Frozen reference channel",
                    description: "Frozen metadata",
                    ytDLPVersion: "reference-only",
                    diagnostics: ""
                )
            ),
            turns: [.init(
                id: "cue-0001",
                japanese: "続いての大将戦ですが、甘結もか、そして立川。",
                precedingJapanese: ["前の発話"],
                followingJapanese: ["次の発話"],
                speakerLabel: "SPEAKER_01"
            )],
            glossary: [.init(
                id: "amayui-moka",
                japanese: ["甘結もか"],
                english: "Amayui Moka",
                englishAliases: []
            )]
        )
        let prompt = LocalMLXTranslator.frozenPrompt(for: batch.turns[0])
        XCTAssertEqual(prompt, "続いての大将戦ですが、甘結もか、そして立川。")
        XCTAssertFalse(prompt.contains("cue-0001"))
        XCTAssertFalse(prompt.contains("Frozen metadata"))
        XCTAssertFalse(prompt.contains("Amayui Moka"))
        XCTAssertFalse(prompt.contains("SPEAKER_01"))
        XCTAssertFalse(prompt.contains("前の発話"))
        XCTAssertFalse(prompt.contains("次の発話"))
        XCTAssertEqual(
            try LocalMLXTranslator.directNativePrompt(
                for: "続いての大将戦ですが、甘結もか、そして立川。"
            ),
            #"[{"content":[{"source_lang_code":"ja","target_lang_code":"en","text":"続いての大将戦ですが、甘結もか、そして立川。","type":"text"}],"role":"user"}]"#
        )
        XCTAssertEqual(LocalMLXTranslator.inputTokenLimit, 2_048)
        XCTAssertEqual(LocalMLXTranslator.generationParameters.temperature, 0)

        let retryPrompt = try LocalMLXTranslator.retryNativePrompt(
            for: batch.turns[0],
            glossary: batch.glossary
        )
        XCTAssertNotEqual(retryPrompt, try LocalMLXTranslator.directNativePrompt(
            for: batch.turns[0].japanese
        ))
        XCTAssertTrue(retryPrompt.contains("Amayui Moka"))
        XCTAssertFalse(retryPrompt.contains("Moka Amayui"))
        XCTAssertFalse(retryPrompt.contains("Frozen metadata"))
        XCTAssertFalse(retryPrompt.contains("SPEAKER_01"))
        XCTAssertFalse(retryPrompt.contains("前の発話"))
        XCTAssertFalse(retryPrompt.contains("次の発話"))

        let retryWithoutTerms = try LocalMLXTranslator.retryNativePrompt(
            for: .init(
                id: "cue-0002",
                japanese: "今日は晴れです。",
                precedingJapanese: [],
                followingJapanese: [],
                speakerLabel: nil
            ),
            glossary: []
        )
        XCTAssertNotEqual(
            retryWithoutTerms,
            try LocalMLXTranslator.directNativePrompt(for: "今日は晴れです。")
        )
        XCTAssertEqual(
            retryWithoutTerms.components(separatedBy: #""source_lang_code""#).count - 1,
            1
        )
        XCTAssertTrue(retryWithoutTerms.contains(#""messages""#))
        XCTAssertTrue(retryWithoutTerms.contains(#""max_tokens":128"#))
        XCTAssertTrue(retryWithoutTerms.contains(#""source_lang_code":"ja-JP""#))
        XCTAssertTrue(retryWithoutTerms.contains(#""temperature":0"#))
        XCTAssertTrue(retryWithoutTerms.contains("今日は晴れです。"))
        XCTAssertEqual(LocalMLXTranslator.retryGenerationParameters.maxTokens, 128)

        let aliasPrompt = try LocalMLXTranslator.retryNativePrompt(
            for: .init(
                id: "cue-0003",
                japanese: "甘いモカが来ました。",
                precedingJapanese: [],
                followingJapanese: [],
                speakerLabel: nil
            ),
            glossary: [.init(
                id: "amayui-moka",
                japanese: ["甘結もか", "甘いモカ"],
                english: "Amayui Moka",
                englishAliases: []
            )]
        )
        XCTAssertTrue(aliasPrompt.contains(#"甘いモカ = 甘結もか = Amayui Moka\n甘いモカが来ました。"#))
    }

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
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            prepareTranslation: { _ in await sequence.append("prepare-translation") },
            translateEnglish: { request in
                await sequence.append("translate")
                return .init(
                    model: LocalMLXTranslator.modelID,
                    response: #"{"translations":[{"id":"unit-0001","text":"Good morning."}]}"#,
                    attempts: [.init(number: 1, duration: 0.1, outcome: "success")],
                    revision: LocalMLXTranslator.revision,
                    runtimeVersion: LocalMLXTranslator.runtimeVersion,
                    batches: [.init(
                        cueIDs: request.turns.map(\.id),
                        sanitizedPrompt: "cue=cue-0001 text=おはよう。",
                        model: LocalMLXTranslator.modelID,
                        revision: LocalMLXTranslator.revision,
                        sanitizedOutput: "Good morning.",
                        inputTokens: 32,
                        duration: 0.02
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
        XCTAssertEqual(
            result.evidence.translation?.batches.first?.model,
            LocalMLXTranslator.modelID
        )
        XCTAssertEqual(
            result.evidence.translation?.batches.first?.revision,
            LocalMLXTranslator.revision
        )
        XCTAssertEqual(result.evidence.translation?.batches.first?.duration, 0.02)
        XCTAssertLessThanOrEqual(
            result.evidence.translation?.batches.first?.inputTokens ?? .max,
            LocalMLXTranslator.inputTokenLimit
        )
    }

    func testMissingLegacyMarkersNeverAcceptTheWholeModelResponse() {
        let turn = HighQualityTranslationTurn(
            id: "unit-0001",
            japanese: "おはよう。",
            precedingJapanese: [],
            followingJapanese: [],
            speakerLabel: nil
        )

        XCTAssertNil(LocalMLXTranslator.translationText(
            "Here is the translation: Good morning.",
            for: turn,
            candidate: .qwen3_14B
        ))
        XCTAssertEqual(
            LocalMLXTranslator.translationText(
                "<<<CURRENT:unit-0001>>>Good morning.<<<END_CURRENT:unit-0001>>>",
                for: turn,
                candidate: .qwen3_14B
            ),
            "Good morning."
        )
        XCTAssertEqual(
            LocalMLXTranslator.translationText(
                "  Good morning.\n",
                for: turn,
                candidate: .translateGemma12B
            ),
            "Good morning."
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
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
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
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
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
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
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
                    precedingJapanese: ["前の発話です。"],
                    followingJapanese: ["次の発話です。"],
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
            let output = try XCTUnwrap(exchange.batches.first?.sanitizedOutput)
            XCTAssertFalse(output.contains("SPEAKER_01"))
            XCTAssertFalse(output.localizedCaseInsensitiveContains("previous utterance"))
            XCTAssertFalse(output.localizedCaseInsensitiveContains("next utterance"))
            XCTAssertTrue(exchange.batches.allSatisfy {
                $0.inputTokens <= LocalMLXTranslator.inputTokenLimit
            })
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    func testOfficialDirectProtocolOnFrozenSemanticUnitsWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_DIRECT_TRANSLATION_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_DIRECT_TRANSLATION_EVIDENCE"],
              let outputPath = environment["WHISPERASR_DIRECT_TRANSLATION_OUTPUT"] else {
            throw XCTSkip("Set the direct-translation experiment evidence and output paths.")
        }
        if evidencePath.contains("holdout") {
            XCTAssertEqual(environment["WHISPERASR_DIRECT_TRANSLATION_ALLOW_HOLDOUT"], "1")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: evidencePath))
        )
        let request = try XCTUnwrap(baseline.translation?.request)
        let translator = LocalMLXTranslator()
        do {
            try await translator.prepare(progress: { _, _ in })
            let exchange = try await translator.translate(request)
            await translator.unload()
            let evidence = HighQualityTranslationEvidence(
                request: request,
                response: exchange.response,
                model: exchange.model,
                attempts: exchange.attempts,
                revision: exchange.revision,
                runtimeVersion: exchange.runtimeVersion,
                batches: exchange.batches,
                peakMemoryBytes: exchange.peakMemoryBytes,
                validationFailures: []
            )
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: outputURL, options: .atomic)

            XCTAssertEqual(evidence.batches.count, request.turns.count)
            XCTAssertTrue(evidence.batches.allSatisfy {
                $0.cueIDs.count == 1
                    && $0.model == LocalMLXTranslator.modelID
                    && $0.revision == LocalMLXTranslator.revision
                    && $0.duration != nil
                    && !$0.sanitizedOutput.isEmpty
            })
        } catch {
            await translator.unload()
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
