import CryptoKit
import XCTest
@testable import WhisperASRApp

final class HighQualityLocalTranslationTests: XCTestCase {
    func testCueBoundaryClearsCacheAfterSuccessRetryFailureCancellationAndUnload() async throws {
        let events = LockedTranslationEvents()
        let translator = LocalMLXTranslator(
            candidate: .translateGemma12B,
            clearCache: { events.append("cleanup") },
            cueGenerator: { turn, batch in
                events.append("generate-\(turn.id)-\(batch.retryReasonCodes == nil ? "first" : "retry")")
                if turn.id == "error" { throw TranslationTestError.failedLoad }
                if turn.id == "cancel" { try await Task.sleep(for: .seconds(5)) }
                let output = turn.id == "two" ? "Second" : "First"
                return ("native-prompt", output, 8, 2, "stop")
            }
        )
        let source = HighQualitySourceProvenance(
            path: "/tmp/frozen.json",
            fileName: "frozen.json",
            byteCount: nil,
            modifiedAt: nil,
            sourceURL: nil,
            youtube: nil
        )
        let turn: (String) -> HighQualityTranslationTurn = {
            .init(
                id: $0,
                japanese: "日本語",
                precedingJapanese: [],
                followingJapanese: [],
                speakerLabel: nil
            )
        }

        let success = try await translator.translate(.init(
            source: source,
            turns: [turn("one"), turn("two")],
            glossary: []
        ))
        XCTAssertEqual(success.batches.map(\.sanitizedOutput), ["First", "Second"])
        _ = try await translator.translate(.init(
            source: source,
            turns: [turn("one")],
            glossary: [],
            retryReasonCodes: ["one": [.emptyOutput]]
        ))

        do {
            _ = try await translator.translate(.init(
                source: source,
                turns: [turn("error")],
                glossary: []
            ))
            XCTFail("The cue failure must cross the cleanup boundary.")
        } catch is HighQualityTranslationServiceError {}

        let cancelled = Task {
            try await translator.translate(.init(
                source: source,
                turns: [turn("cancel")],
                glossary: []
            ))
        }
        while !events.values.contains("generate-cancel-first") {
            try await Task.sleep(for: .milliseconds(1))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancellation must cross the cleanup boundary.")
        } catch is HighQualityTranslationServiceError {}

        await translator.unload()
        XCTAssertEqual(events.values, [
            "generate-one-first", "cleanup",
            "generate-two-first", "cleanup", "cleanup",
            "generate-one-retry", "cleanup", "cleanup",
            "generate-error-first", "cleanup", "cleanup",
            "generate-cancel-first", "cleanup", "cleanup",
            "cleanup",
        ])
    }

    func testEveryTranslationRequestClearsCacheBeforeTheNextRequest() async throws {
        let cleanups = LockedTranslationCounter()
        let translator = LocalMLXTranslator(
            candidate: .translateGemma4B,
            clearCache: { cleanups.increment() }
        )
        let request = HighQualityTranslationBatch(
            source: .init(
                path: "/tmp/frozen.json",
                fileName: "frozen.json",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: nil
            ),
            turns: [],
            glossary: []
        )

        for _ in 0..<3 {
            do {
                _ = try await translator.translate(request)
                XCTFail("An unprepared translator must fail without loading a model.")
            } catch is HighQualityTranslationServiceError {}
        }

        XCTAssertEqual(cleanups.value, 3)
    }

    func testTranslateGemmaModelsArePinnedAndUseTheSameTranslationContract() throws {
        XCTAssertEqual(LocalMLXTranslator.Candidate.productDefault, .translateGemma12B)
        XCTAssertEqual(HighQualityTranslator.productDefault, .translateGemma12B)
        XCTAssertEqual(HighQualityTranslator.translateGemma4B.displayName, "TranslateGemma 4B (Bêta)")
        XCTAssertEqual(
            HighQualityTranslator.allCases,
            [.translateGemma12B, .translateGemma4B]
        )
        XCTAssertEqual(
            HighQualityTranslator.translateGemma12B.detail,
            "Meilleure qualité — plus lent et plus gourmand en mémoire"
        )
        XCTAssertEqual(
            HighQualityTranslator.translateGemma4B.detail,
            "Bêta — plus rapide et léger, qualité en cours de comparaison"
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma12B.revision,
            "f3dcfd54df14672fbcf0731086fb47a797a943ae"
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma4B.modelID,
            "mlx-community/translategemma-4b-it-4bit"
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma4B.revision,
            "5788ec08c047f3f2e17808101b8d9566ac930d58"
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
            LocalMLXTranslator.Candidate.translateGemma4B.weightSHA256,
            ["113acb0c29997a3015af84bec2c8f967cb7b15f8959d1c26b9628b921e324c40"]
        )
        XCTAssertEqual(
            LocalMLXTranslator.Candidate.translateGemma4B.weightFileNames,
            ["model.safetensors"]
        )
        for candidate in LocalMLXTranslator.Candidate.allCases {
            XCTAssertEqual(candidate.weightFileNames.count, candidate.weightSHA256.count)
        }
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
        XCTAssertTrue(LocalMLXTranslator.Candidate.translateGemma12B.usesTranslateGemmaContract)
        XCTAssertTrue(LocalMLXTranslator.Candidate.translateGemma4B.usesTranslateGemmaContract)
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

    func testBothTranslateGemmaSelectionsProduceEnglishDeliverablesAndEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for selection in HighQualityTranslator.allCases {
            let model = selection.model
            let job = HighQualityJob(services: .init(
                loadSource: { _ in Array(repeating: 0, count: 16_000) },
                prepareASR: { _ in },
                transcribeJapanese: { _ in "おはよう。" },
                unloadASR: {},
                prepareAlignment: { _ in },
                alignJapanese: highQualityFixtureAlignment,
                translateEnglish: { request in
                    .init(
                        model: model.modelID,
                        response: #"{"translations":[{"id":"unit-0001","text":"Good morning."}]}"#,
                        attempts: [.init(number: 1, duration: 0.01, outcome: "success")],
                        revision: model.revision,
                        runtimeVersion: model.runtimeVersion,
                        batches: [.init(
                            cueIDs: request.turns.map(\.id),
                            sanitizedPrompt: "おはよう。",
                            nativePrompt: "おはよう。",
                            nativeOutput: "Good morning.",
                            model: model.modelID,
                            revision: model.revision,
                            sanitizedOutput: "Good morning.",
                            inputTokens: 8,
                            outputTokens: 3,
                            finishReason: "stop",
                            duration: 0.01
                        )],
                        peakMemoryBytes: 123
                    )
                },
                unloadTranslation: {}
            ))

            let result = try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.englishTranslationTranscript, .englishSubtitles],
                backend: .qwenJA,
                translator: selection,
                outputRoot: root
            ))

            XCTAssertEqual(result.manifest.schemaVersion, 2)
            XCTAssertEqual(result.manifest.translationModel, model)
            XCTAssertEqual(result.evidence.translation?.model, model.modelID)
            XCTAssertEqual(result.evidence.translation?.revision, model.revision)
            XCTAssertEqual(result.evidence.translation?.runtimeVersion, model.runtimeVersion)
            XCTAssertEqual(result.evidence.translation?.weightSHA256, model.weightSHA256)
            XCTAssertEqual(result.englishTranscript, "Good morning.")
            XCTAssertEqual(result.subtitleCues.map(\.text), ["Good morning."])
        }
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
        XCTAssertEqual(
            LocalMLXTranslator.translationText(
                "  Good morning.\n",
                for: turn,
                candidate: .translateGemma4B
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
        object.removeValue(forKey: "weightSHA256")
        object.removeValue(forKey: "batches")
        object.removeValue(forKey: "peakMemoryBytes")

        let decoded = try JSONDecoder().decode(
            HighQualityTranslationEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.model, "legacy-model")
        XCTAssertEqual(decoded.batches, [])
        XCTAssertEqual(decoded.weightSHA256, [])
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
            currentMemoryBytes: { await memory.value },
            currentAvailableMemoryBytes: { 24 * 1_024 * 1_024 * 1_024 }
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
            currentMemoryBytes: { await memory.value },
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
        } catch let error as HighQualityJobError {
            XCTAssertTrue(error.localizedDescription.contains("quit and reopen WhisperASR"))
        }

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

    func testTranslationCriticalPressureSurvivesContextAndUnloads() async throws {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let memory = TranslationMemoryReading(gib)
        let available = TranslationMemoryReading(20 * gib)
        let pressure = MacMemoryPressureMonitor(native: false)
        let unloads = TranslationCounter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24 * gib,
            reserveBytes: 8 * gib,
            releaseToleranceBytes: gib / 10,
            releaseTimeout: .milliseconds(50),
            releasePollInterval: .milliseconds(1),
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await memory.value },
            currentAvailableMemoryBytes: { await available.value },
            memoryPressure: pressure
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = HighQualityJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
            deliverables: [.englishTranslationTranscript],
            backend: .qwenJA,
            translationContextPolicy: .previousAcceptedV1,
            outputRoot: root
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "一。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            currentMemoryBytes: { await memory.value },
            translateEnglish: { _ in
                pressure.record(.critical)
                while true { try await Task.sleep(for: .milliseconds(1)) }
            },
            unloadTranslation: {
                await unloads.increment()
                await memory.set(gib)
            },
            heavyweightGate: gate
        ))

        do {
            _ = try await job.run(request)
            XCTFail("TranslateGemma must stop on critical macOS memory pressure.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .translation)
        }

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
        XCTAssertTrue(evidence.modelEvents.contains {
            $0.kind == .memoryReleaseChecked
                && $0.modelID == LocalMLXTranslator.modelID
                && $0.message?.contains("runtimePeak=") == true
        })
        let unloadCount = await unloads.value
        XCTAssertEqual(unloadCount, 1)
        pressure.record(.normal)
        let live = try await gate.beginWorkflow(.live)
        try await gate.endWorkflow(live)
    }

    func testRealTranslateGemmaDevelopmentSmokeWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_RUN_TRANSLATEGEMMA_SMOKE"] == "1" else {
            throw XCTSkip("Set WHISPERASR_RUN_TRANSLATEGEMMA_SMOKE=1 for the local 12B smoke run.")
        }
        let runtime = HighQualityTranslationWorkerClient(
            executableURL: highQualityTranslationWorkerExecutableURL()
        )
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

    func testRealTranslateGemmaWorkerMemorySmokeWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TRANSLATEGEMMA_WORKER_SMOKE"] == "1" else {
            throw XCTSkip("Run the ticket #71 bounded TranslateGemma worker smoke.")
        }
        guard environment["BENCHMARK_SLOT_GRANTED"] == "71" else {
            XCTFail("The ticket #71 benchmark slot is required.")
            return
        }
        let inputPath = try XCTUnwrap(environment["WHISPERASR_TRANSLATEGEMMA_SMOKE_INPUT"])
        let outputPath = try XCTUnwrap(environment["WHISPERASR_TRANSLATEGEMMA_SMOKE_OUTPUT"])
        guard !inputPath.localizedCaseInsensitiveContains("md62mmdz0m"),
              !inputPath.localizedCaseInsensitiveContains("holdout") else {
            XCTFail("The bounded development smoke must not open the holdout.")
            return
        }

        let input = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(HighQualityRawEvidence.self, from: input)
        let baseline = try XCTUnwrap(raw.translation?.request)
        let turns = Array(baseline.turns.prefix(8))
        guard turns.count == 8 else {
            XCTFail("The bounded memory smoke requires exactly eight frozen cues.")
            return
        }
        let cueIDs = Set(turns.map(\.id))
        let request = HighQualityTranslationBatch(
            source: baseline.source,
            turns: turns,
            glossary: baseline.glossary,
            glossaryByCueID: baseline.glossaryByCueID.filter { cueIDs.contains($0.key) }
        )
        let integrityGlossary = request.glossaryByCueID.mapValues { terms in
            terms.map { HighQualityTranslationIntegrityGlossaryTerm($0, critical: false) }
        }
        var artifact = TranslateGemmaMemorySmokeArtifact(
            schemaVersion: 3,
            ticket: 71,
            modelID: LocalMLXTranslator.modelID,
            revision: LocalMLXTranslator.revision,
            inputSHA256: SHA256.hash(data: input).map {
                String(format: "%02x", $0)
            }.joined(),
            cueCount: turns.count,
            baselineMemoryBytes: nil,
            availableBeforeLoadBytes: nil,
            runtimePeakMemoryBytes: nil,
            minimumAvailableMemoryBytes: nil,
            maximumMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            reserveBytes: 0,
            releasedMemoryBytes: nil,
            modelReportedPeakMemoryBytes: nil,
            durationSeconds: nil,
            batches: [],
            response: nil,
            primaryFailure: nil,
            cleanupFailure: nil,
            startedAt: Date(),
            finishedAt: nil,
            worker: nil
        )
        let output = URL(fileURLWithPath: outputPath)
        let workerDirectory = output.deletingLastPathComponent()
            .appendingPathComponent("worker-runtime", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: workerDirectory.path) else {
            XCTFail("Worker evidence directory already exists: \(workerDirectory.path)")
            return
        }
        let runtime = HighQualityTranslationWorkerClient(
            executableURL: highQualityTranslationWorkerExecutableURL(),
            workingDirectory: workerDirectory
        )
        let gate = HeavyweightModelGate()
        var workflow: HeavyweightWorkflowLease?
        var model: HeavyweightModelLease?
        let started = ContinuousClock.now

        do {
            workflow = try await gate.beginWorkflow(.offline(UUID()))
            model = try await gate.acquireModel(
                workflow: workflow!,
                modelID: LocalMLXTranslator.modelID,
                declaredPeakBytes: LocalMLXTranslator.declaredPeakMemoryBytes
            )
            let activeModel = model!
            artifact.baselineMemoryBytes = activeModel.baselineMemoryBytes
            artifact.availableBeforeLoadBytes = activeModel.availableMemoryBytes
            try await gate.withMemoryGuard(activeModel) {
                try await runtime.prepare(progress: { _, _ in })
            }
            try await gate.markLoaded(activeModel)
            let pass = try await HighQualityJob.firstTranslationPass(
                request: request,
                contextPolicy: .previousAcceptedV1,
                resetReasons: [:],
                integrityGlossaryByCueID: integrityGlossary,
                translate: { batch in
                    try await gate.withMemoryGuard(activeModel) {
                        try await runtime.translate(batch)
                    }
                }
            )
            artifact.modelReportedPeakMemoryBytes = pass.exchange.peakMemoryBytes
            artifact.batches = pass.exchange.batches
            artifact.response = pass.exchange.response
            artifact.releasedMemoryBytes = try await gate.releaseModel(
                activeModel,
                unload: { await runtime.unload() }
            )
            artifact.worker = await runtime.evidence
            artifact.runtimePeakMemoryBytes = artifact.worker?.peakPhysicalFootprintBytes
            artifact.minimumAvailableMemoryBytes = artifact.worker?.availableMemorySamples
                .map(\.availableMemoryBytes).min()
            model = nil
            try await gate.endWorkflow(workflow!)
            workflow = nil
            artifact.durationSeconds = Self.seconds(since: started)
            artifact.finishedAt = Date()
            try Self.writeMemorySmoke(artifact, to: output)

            let worker = try XCTUnwrap(artifact.worker)
            XCTAssertEqual(worker.exitStatus, 0)
            XCTAssertFalse(worker.forcedTermination)
            XCTAssertNotEqual(kill(worker.processIdentifier, 0), 0)
            XCTAssertEqual(pass.exchange.batches.count, turns.count)
        } catch let primaryError {
            artifact.primaryFailure = primaryError.localizedDescription
            if let model {
                do {
                    artifact.releasedMemoryBytes = try await gate.releaseModel(
                        model,
                        unload: { await runtime.unload() }
                    )
                } catch let cleanupError {
                    artifact.cleanupFailure = cleanupError.localizedDescription
                }
            } else {
                await runtime.unload()
            }
            artifact.worker = await runtime.evidence
            artifact.runtimePeakMemoryBytes = artifact.worker?.peakPhysicalFootprintBytes
            artifact.minimumAvailableMemoryBytes = artifact.worker?.availableMemorySamples
                .map(\.availableMemoryBytes).min()
            if let workflow { try? await gate.endWorkflow(workflow) }
            if let translationError = primaryError as? HighQualityTranslationServiceError {
                artifact.modelReportedPeakMemoryBytes = translationError.peakMemoryBytes
                artifact.batches = translationError.batches
                artifact.response = translationError.response
            }
            artifact.durationSeconds = Self.seconds(since: started)
            artifact.finishedAt = Date()
            try Self.writeMemorySmoke(artifact, to: output)
            throw primaryError
        }
    }

    func testRealTranslateGemma4BWorkerDeliverablesWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TRANSLATEGEMMA_4B_SMOKE"] == "1" else {
            throw XCTSkip("Run the ticket #74 bounded TranslateGemma 4B smoke.")
        }
        guard environment["BENCHMARK_SLOT_GRANTED"] == "74" else {
            XCTFail("The ticket #74 benchmark slot is required.")
            return
        }
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(
            environment["WHISPERASR_TRANSLATEGEMMA_4B_SMOKE_OUTPUT_ROOT"]
        ), isDirectory: true)
        let jobID = try XCTUnwrap(
            UUID(uuidString: "74000000-0000-4000-8000-000000000074")
        )
        let resultDirectory = outputRoot.appendingPathComponent(jobID.uuidString)
        let source = outputRoot.appendingPathComponent("\(jobID.uuidString)-japanese-source.txt")
        guard !FileManager.default.fileExists(atPath: resultDirectory.path),
              !FileManager.default.fileExists(atPath: source.path) else {
            XCTFail("Smoke evidence already exists under: \(outputRoot.path)")
            return
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try "おはようございます。\n".write(to: source, atomically: true, encoding: .utf8)

        let candidate = LocalMLXTranslator.Candidate.translateGemma4B
        let worker = HighQualityTranslationWorkerClient(
            candidate: candidate,
            executableURL: highQualityTranslationWorkerExecutableURL(),
            workingDirectory: resultDirectory.appendingPathComponent("worker-runtime")
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: 16_000) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "おはようございます。" },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: highQualityFixtureAlignment,
            unloadAlignment: {},
            currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() },
            prepareTranslation: { try await worker.prepare(progress: $0) },
            translateEnglish: { try await worker.translate($0) },
            unloadTranslation: { await worker.unload() },
            translationWorkerEvidence: { await worker.evidence },
            heavyweightGate: HeavyweightModelGate()
        ))

        do {
            let result = try await job.run(.init(
                id: jobID,
                sourceURL: source,
                deliverables: [.englishTranslationTranscript, .englishSubtitles],
                backend: .qwenJA,
                translator: .translateGemma4B,
                outputRoot: outputRoot
            ))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try decoder.decode(
                HighQualityRawEvidence.self,
                from: Data(contentsOf: result.directory.appendingPathComponent("raw-asr.json"))
            )
            let recordedWorker = try XCTUnwrap(raw.translation?.worker)

            XCTAssertEqual(result.manifest.status, .completed)
            XCTAssertEqual(
                result.manifest.translationModel,
                HighQualityTranslator.translateGemma4B.model
            )
            XCTAssertEqual(raw.translation?.model, candidate.modelID)
            XCTAssertEqual(raw.translation?.revision, candidate.revision)
            XCTAssertEqual(raw.translation?.weightSHA256, candidate.weightSHA256)
            XCTAssertEqual(
                try LocalTranslatorBakeoffTests.cachedWeightHashes(candidate),
                candidate.weightSHA256
            )
            XCTAssertEqual(recordedWorker.command.last, candidate.rawValue)
            XCTAssertEqual(recordedWorker.exitStatus, 0)
            XCTAssertFalse(recordedWorker.forcedTermination)
            XCTAssertGreaterThan(recordedWorker.peakPhysicalFootprintBytes, 1_024 * 1_024 * 1_024)
            XCTAssertFalse(try XCTUnwrap(result.englishTranscript).isEmpty)
            XCTAssertFalse(result.subtitleCues.isEmpty)
            for name in [
                "english-translation-transcript.txt",
                "english-subtitles.srt",
                "english-subtitles.vtt",
                "manifest.json",
                "raw-asr.json",
            ] {
                XCTAssertGreaterThan(
                    try Data(contentsOf: result.directory.appendingPathComponent(name)).count,
                    0
                )
            }
        } catch {
            await worker.unload()
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
        let frozenRequest: HighQualityTranslationBatch
        if let requestPath = environment["WHISPERASR_DIRECT_TRANSLATION_REQUEST"] {
            frozenRequest = try JSONDecoder().decode(
                HighQualityTranslationBatch.self,
                from: Data(contentsOf: URL(fileURLWithPath: requestPath))
            )
        } else {
            frozenRequest = try XCTUnwrap(baseline.translation?.request)
        }
        let cueLimit = environment["WHISPERASR_DIRECT_TRANSLATION_CUE_LIMIT"]
            .flatMap(Int.init) ?? frozenRequest.turns.count
        guard (1...frozenRequest.turns.count).contains(cueLimit) else {
            XCTFail("The direct translation cue limit must fit the frozen request.")
            return
        }
        let turns = Array(frozenRequest.turns.prefix(cueLimit))
        let cueIDs = Set(turns.map(\.id))
        let request = HighQualityTranslationBatch(
            source: frozenRequest.source,
            turns: turns,
            glossary: frozenRequest.glossary,
            glossaryByCueID: frozenRequest.glossaryByCueID.filter {
                cueIDs.contains($0.key)
            },
            conversationContextByCueID: frozenRequest.conversationContextByCueID.filter {
                cueIDs.contains($0.key)
            },
            retryReasonCodes: frozenRequest.retryReasonCodes?.filter {
                cueIDs.contains($0.key)
            }
        )
        XCTAssertEqual(request.turns, Array(frozenRequest.turns.prefix(cueLimit)))
        XCTAssertEqual(request.turns.count, cueLimit)
        if environment["WHISPERASR_VALIDATE_DIRECT_TRANSLATION_ONLY"] == "1" { return }
        let translator = HighQualityTranslationWorkerClient(
            executableURL: highQualityTranslationWorkerExecutableURL()
        )
        do {
            try await translator.prepare(progress: { _, _ in })
            let exchange = try await translator.translate(request)
            await translator.unload()
            let worker = await translator.evidence
            let evidence = HighQualityTranslationEvidence(
                request: request,
                response: exchange.response,
                model: exchange.model,
                attempts: exchange.attempts,
                revision: exchange.revision,
                runtimeVersion: exchange.runtimeVersion,
                batches: exchange.batches,
                peakMemoryBytes: exchange.peakMemoryBytes,
                validationFailures: [],
                worker: worker
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

    private static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func writeMemorySmoke(
        _ artifact: TranslateGemmaMemorySmokeArtifact,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: url, options: .atomic)
    }
}

private struct TranslateGemmaMemorySmokeArtifact: Codable {
    let schemaVersion: Int
    let ticket: Int
    let modelID: String
    let revision: String
    let inputSHA256: String
    let cueCount: Int
    var baselineMemoryBytes: UInt64?
    var availableBeforeLoadBytes: UInt64?
    var runtimePeakMemoryBytes: UInt64?
    var minimumAvailableMemoryBytes: UInt64?
    var maximumMemoryBytes: UInt64?
    let reserveBytes: UInt64
    var releasedMemoryBytes: UInt64?
    var modelReportedPeakMemoryBytes: UInt64?
    var durationSeconds: Double?
    var batches: [HighQualityLocalTranslationBatch]
    var response: String?
    var primaryFailure: String?
    var cleanupFailure: String?
    let startedAt: Date
    var finishedAt: Date?
    var worker: HighQualityTranslationWorkerEvidence?
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

private final class LockedTranslationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class LockedTranslationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
