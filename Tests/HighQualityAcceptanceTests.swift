import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityAcceptanceTests: XCTestCase {
    func testDiarizerPreparationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_DIARIZER_PREPARATION"] == "1",
              let engine = environment["WHISPERASR_DIARIZER_PREPARATION_ENGINE"],
              let cache = environment["WHISPERASR_DIARIZER_PREPARATION_MODEL_CACHE"] else {
            throw XCTSkip("Set engine and model cache for #61 preparation diagnostics.")
        }
        switch engine {
        case "speakerkit":
            let runtime = HighQualitySpeakerKitRuntime(downloadBase: cache)
            try await runtime.prepare { _, _ in }
            await runtime.unload()
        case "fluid-audio-offline":
            let runtime = HighQualityFluidAudioRuntime(
                modelDirectory: URL(fileURLWithPath: cache, isDirectory: true)
            )
            try await runtime.prepare { _, _ in }
            await runtime.unload()
        default:
            XCTFail("Unknown diarizer engine: \(engine)")
            return
        }
        print("[diarizer-preparation][\(engine)] retained=true")
    }

    func testFluidAudioCancellationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_FLUID_AUDIO_CANCELLATION"] == "1",
              let evidencePath = environment["WHISPERASR_FLUID_CANCELLATION_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_FLUID_CANCELLATION_SOURCE"],
              let outputPath = environment["WHISPERASR_FLUID_CANCELLATION_OUTPUT"],
              let rawJobID = environment["WHISPERASR_FLUID_CANCELLATION_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let modelCachePath = environment["WHISPERASR_FLUID_CANCELLATION_MODEL_CACHE"] else {
            throw XCTSkip("Set frozen inputs, output, job ID and model cache for #61 cancellation.")
        }
        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let diarizer = Self.fluidAudioDiarizer(modelCachePath: modelCachePath)
        let job = Self.frozenDiarizationJob(
            baseline: baseline,
            alignment: alignment,
            diarizer: diarizer,
            enforceMemoryGate: true
        )
        let stages = AsyncStream<HighQualityJobStage>.makeStream()
        let task = Task {
            defer { stages.continuation.finish() }
            _ = try await job.run(.init(
                id: jobID,
                sourceURL: URL(fileURLWithPath: sourcePath),
                deliverables: Set(HighQualityDeliverable.allCases),
                backend: baseline.model.backend,
                speakerLabels: true,
                useExclusiveReconciliation: false,
                speakerConfiguration: .standard,
                outputRoot: URL(fileURLWithPath: outputPath)
            )) { progress in
                stages.continuation.yield(progress.stage)
            }
        }
        for await stage in stages.stream where stage == .diarizing {
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            break
        }
        do {
            _ = try await task.value
            XCTFail("FluidAudio cancellation must fail closed.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }
        let directory = URL(fileURLWithPath: outputPath).appendingPathComponent(jobID.uuidString)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        let raw = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
        XCTAssertEqual(raw.failures.last?.stage, .cancelled)
        let events = raw.modelEvents.filter {
            $0.modelID == HighQualityFluidAudioRuntime.modelID
        }.map(\.kind)
        XCTAssertTrue(events.contains(.loadCompleted))
        XCTAssertTrue(events.contains(.unloadCompleted))
        XCTAssertTrue(events.contains(.memoryReleaseChecked))
        XCTAssertFalse(events.contains(.guardFailed))
        print("[fluid-audio-cancellation] retained=true")
    }

    func testFrozenDiarizerEngineWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_DIARIZER_ENGINE_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_DIARIZER_ENGINE_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_DIARIZER_ENGINE_SOURCE"],
              let outputPath = environment["WHISPERASR_DIARIZER_ENGINE_OUTPUT"],
              let rawJobID = environment["WHISPERASR_DIARIZER_ENGINE_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let engine = environment["WHISPERASR_DIARIZER_ENGINE"],
              let modelCachePath = environment["WHISPERASR_DIARIZER_ENGINE_MODEL_CACHE"] else {
            throw XCTSkip("Set the frozen inputs, engine, output, job ID and model cache for ticket #61.")
        }
        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let result: HighQualityJobResult
        switch engine {
        case "speakerkit":
            result = try await Self.runFrozenSpeakerKitExperiment(
                baseline: baseline,
                alignment: alignment,
                sourcePath: sourcePath,
                outputPath: outputPath,
                jobID: jobID,
                precision: .quantized,
                modelCachePath: modelCachePath,
                enforceMemoryGate: true,
                useExclusiveReconciliation: false,
                clusterDistanceThreshold: 0.60
            )
        case "fluid-audio-offline":
            result = try await Self.runFrozenFluidAudioExperiment(
                baseline: baseline,
                alignment: alignment,
                sourcePath: sourcePath,
                outputPath: outputPath,
                jobID: jobID,
                modelCachePath: modelCachePath
            )
        default:
            XCTFail("Unknown diarizer engine: \(engine)")
            return
        }

        let evidence = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(evidence.modelID, engine == "speakerkit"
            ? HighQualitySpeakerKitRuntime.modelID
            : HighQualityFluidAudioRuntime.modelID)
        XCTAssertEqual(evidence.speakerCountPolicy, .automatic)
        XCTAssertEqual(evidence.useExclusiveReconciliation, false)
        XCTAssertFalse(evidence.rawSpans.isEmpty)
        XCTAssertFalse(evidence.mappings.isEmpty)
        XCTAssertFalse(evidence.configuration?.isEmpty ?? true)
        XCTAssertTrue(evidence.validationDiagnostics.isEmpty)
        let alignedItemCount = alignment.chunks.flatMap(\.rawItems).count
        XCTAssertEqual(evidence.mappings.count, alignedItemCount)
        XCTAssertEqual(
            Set(evidence.mappings.map(\.alignmentItemIndex)),
            Set(0..<alignedItemCount)
        )
        XCTAssertTrue(evidence.mappings.allSatisfy {
            ["longest-overlap", "nearest-span-fallback"].contains($0.attributionReason)
        })
        XCTAssertEqual(result.evidence.sampleCount, baseline.sampleCount)
        XCTAssertEqual(result.manifest.status, .completed)

        let labels = Set(result.turns.compactMap(\.speakerLabel)).sorted()
        XCTAssertFalse(labels.isEmpty)
        let names = Dictionary(uniqueKeysWithValues: labels.enumerated().map {
            ($0.element, "VOICE_\(String(format: "%02d", $0.offset))")
        })
        let renamed = try HighQualityJob.renameSpeakers(in: result, names: names)
        XCTAssertEqual(renamed.evidence, result.evidence)
        XCTAssertEqual(renamed.subtitleCues.map(\.id), result.subtitleCues.map(\.id))
        XCTAssertEqual(renamed.subtitleCues.map(\.start), result.subtitleCues.map(\.start))
        XCTAssertEqual(renamed.subtitleCues.map(\.end), result.subtitleCues.map(\.end))
        XCTAssertEqual(renamed.subtitleCues.map(\.text), result.subtitleCues.map(\.text))
        XCTAssertEqual(
            renamed.subtitleCues.map(\.speakerLabel),
            result.subtitleCues.map(\.speakerLabel)
        )
        let transcript = try String(
            contentsOf: result.directory.appendingPathComponent("english-translation-transcript.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(names.values.contains { transcript.contains("\($0):") })
        print("[diarizer-engine][\(engine)] renameConsistency=true")
    }

    func testFrozenExpectedSpeakerCountWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_SPEAKER_COUNT_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_SPEAKER_COUNT_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_SPEAKER_COUNT_SOURCE"],
              let outputPath = environment["WHISPERASR_SPEAKER_COUNT_OUTPUT"],
              let rawJobID = environment["WHISPERASR_SPEAKER_COUNT_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let rawMode = environment["WHISPERASR_SPEAKER_COUNT_MODE"],
              let modelCachePath = environment["WHISPERASR_SPEAKER_COUNT_MODEL_CACHE"] else {
            throw XCTSkip("Set the frozen inputs, output, job ID, mode and model cache for ticket #59.")
        }
        let policy: HighQualitySpeakerCountPolicy
        switch rawMode {
        case "automatic":
            policy = .automatic
        case "expected":
            guard let rawCount = environment["WHISPERASR_EXPECTED_SPEAKER_COUNT"],
                  let count = Int(rawCount) else {
                XCTFail("Expected mode requires WHISPERASR_EXPECTED_SPEAKER_COUNT.")
                return
            }
            policy = .expected(count)
        default:
            XCTFail("Unknown Speaker-count mode: \(rawMode)")
            return
        }

        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let result = try await Self.runFrozenSpeakerKitExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            precision: .quantized,
            modelCachePath: modelCachePath,
            enforceMemoryGate: true,
            useExclusiveReconciliation: false,
            speakerCountPolicy: policy
        )

        XCTAssertEqual(result.manifest.speakerCountPolicy, policy)
        XCTAssertEqual(result.evidence.speakerCountPolicy, policy)
        XCTAssertEqual(result.evidence.diarization?.speakerCountPolicy, policy)
        XCTAssertEqual(result.evidence.sampleCount, baseline.sampleCount)
        XCTAssertFalse(result.evidence.diarization?.rawSpans.isEmpty ?? true)
        XCTAssertTrue(result.evidence.diarization?.validationDiagnostics.isEmpty == true)
        XCTAssertEqual(result.manifest.status, .completed)
    }

    func testFrozenSpeakerKitThresholdWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_SPEAKERKIT_THRESHOLD_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_SPEAKERKIT_THRESHOLD_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_SPEAKERKIT_THRESHOLD_SOURCE"],
              let outputPath = environment["WHISPERASR_SPEAKERKIT_THRESHOLD_OUTPUT"],
              let rawJobID = environment["WHISPERASR_SPEAKERKIT_THRESHOLD_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let rawThreshold = environment["WHISPERASR_SPEAKERKIT_THRESHOLD"],
              ["0.45", "0.50", "0.55", "0.60"].contains(rawThreshold),
              let threshold = Float(rawThreshold),
              let modelCachePath = environment["WHISPERASR_SPEAKERKIT_MODEL_CACHE"] else {
            throw XCTSkip("Set the frozen inputs, output, job ID and threshold for ticket #60.")
        }

        print("[speakerkit-threshold][\(rawThreshold)] clusterDistanceThreshold=\(rawThreshold)")
        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let result = try await Self.runFrozenSpeakerKitExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            precision: .quantized,
            modelCachePath: modelCachePath,
            enforceMemoryGate: true,
            useExclusiveReconciliation: false,
            clusterDistanceThreshold: threshold
        )

        try Self.assertFrozenSpeakerKitResult(
            result,
            baseline: baseline,
            alignment: alignment
        )
    }

    func testFrozenSpeakerKitPrecisionWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_SPEAKERKIT_PRECISION_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_SPEAKERKIT_PRECISION_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_SPEAKERKIT_PRECISION_SOURCE"],
              let outputPath = environment["WHISPERASR_SPEAKERKIT_PRECISION_OUTPUT"],
              let rawJobID = environment["WHISPERASR_SPEAKERKIT_PRECISION_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let rawPrecision = environment["WHISPERASR_SPEAKERKIT_PRECISION"],
              let precision = HighQualitySpeakerKitRuntime.Precision(rawValue: rawPrecision),
              let modelCachePath = environment["WHISPERASR_SPEAKERKIT_MODEL_CACHE"] else {
            throw XCTSkip("Set the frozen inputs, output, job ID and precision for ticket #58.")
        }

        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let result = try await Self.runFrozenSpeakerKitExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            precision: precision,
            modelCachePath: modelCachePath,
            enforceMemoryGate: true,
            useExclusiveReconciliation: false
        )

        try Self.assertFrozenSpeakerKitResult(
            result,
            baseline: baseline,
            alignment: alignment
        )
        XCTAssertEqual(
            Set(result.manifest.generatedFiles.map(\.path)),
            [
                "english-subtitles.srt", "english-subtitles.vtt",
                "english-translation-transcript.txt", "japanese-transcript.txt",
                "manifest.json", "raw-asr.json",
            ]
        )
    }

    func testDuplicateSpeakerDevelopmentCalibrationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let expectedSpeakerCount: Int?
        if let rawExpectedCount = environment[
            "WHISPERASR_DUPLICATE_SPEAKER_EXPECTED_COUNT"
        ] {
            guard rawExpectedCount == "12" else {
                throw NSError(
                    domain: "HighQualityAcceptanceTests",
                    code: 114,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ticket #114 calibration permits only Expected=12.",
                    ]
                )
            }
            expectedSpeakerCount = 12
        } else {
            expectedSpeakerCount = nil
        }
        let requiredSlot = expectedSpeakerCount == nil ? "114" : "114-CALIBRATION"
        guard environment["WHISPERASR_RUN_DUPLICATE_SPEAKER_DEV"] == "1",
              environment["BENCHMARK_SLOT_GRANTED"] == requiredSlot,
              let manifestPath = environment["WHISPERASR_DUPLICATE_SPEAKER_MANIFEST"],
              let sourcePath = environment["WHISPERASR_DUPLICATE_SPEAKER_SOURCE"],
              let reportPath = environment["WHISPERASR_DUPLICATE_SPEAKER_REPORT"],
              let modelCachePath = environment["WHISPERASR_DUPLICATE_SPEAKER_MODEL_CACHE"],
              let rawJobID = environment["WHISPERASR_DUPLICATE_SPEAKER_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID) else {
            throw XCTSkip("Set the frozen #114 DEV inputs and an explicit benchmark slot.")
        }
        let manifest = try JapaneseBenchmarkSupport.loadManifest(
            at: URL(fileURLWithPath: manifestPath)
        )
        guard manifest.purpose == .development else {
            throw NSError(
                domain: "HighQualityAcceptanceTests",
                code: 114,
                userInfo: [NSLocalizedDescriptionKey: "Ticket #114 calibration is DEV-only."]
            )
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.sha256(at: sourceURL),
            manifest.fixture.sha256
        )
        let samples = try await AudioLoader.loadSamples(url: sourceURL)
        XCTAssertEqual(samples.count, manifest.fixture.sampleCount)
        let runtime = HighQualitySpeakerKitRuntime(
            precision: .quantized,
            downloadBase: modelCachePath
        )
        let startedAt = Date()
        let exchange: HighQualityDiarizationExchange
        let speakerCountPolicy = expectedSpeakerCount.map(
            HighQualitySpeakerCountPolicy.expected
        ) ?? .automatic
        do {
            try await runtime.prepare(progress: { _, _ in })
            exchange = try await runtime.diarize(
                samples: samples,
                speakerCountPolicy: speakerCountPolicy
            )
        } catch {
            await runtime.unload()
            throw error
        }
        await runtime.unload()
        let elapsedSeconds = Date().timeIntervalSince(startedAt)
        let evidence = try HighQualityJob.diarizationEvidence(
            exchange,
            items: [],
            duration: Double(samples.count) / Double(manifest.fixture.sampleRate),
            sourceJobID: jobID
        )
        let report = try Self.duplicateSpeakerDevelopmentReport(
            manifest: manifest,
            evidence: evidence,
            elapsedSeconds: elapsedSeconds,
            sourceSHA256: manifest.fixture.sha256,
            sourceJobID: jobID,
            benchmarkSlot: requiredSlot,
            speakerCountPolicy: speakerCountPolicy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportURL = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: reportURL, options: .atomic)

        XCTAssertGreaterThan(report.centroidCount, 1)
        XCTAssertFalse(report.comparisons.isEmpty)
        print(
            "[#114][DEV] centroids=\(report.centroidCount) "
                + "suggestions=\(report.suggestionCount) "
                + "useful=\(report.usefulSuggestionCount) "
                + "false=\(report.falseSuggestionCount) "
                + "seconds=\(elapsedSeconds) peakBytes=\(report.observedPeakMemoryBytes)"
        )
    }

    func testFrozenExclusiveSpeakerReconciliationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_EXCLUSIVE_RECONCILIATION_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_EXCLUSIVE_RECONCILIATION_EVIDENCE"],
              let sourcePath = environment["WHISPERASR_EXCLUSIVE_RECONCILIATION_SOURCE"],
              let outputPath = environment["WHISPERASR_EXCLUSIVE_RECONCILIATION_OUTPUT"],
              let rawJobID = environment["WHISPERASR_EXCLUSIVE_RECONCILIATION_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID) else {
            throw XCTSkip("Set the frozen evidence, source, output and job ID for ticket #57.")
        }
        let baseline = try Self.frozenEvidence(at: evidencePath)
        let alignment = try XCTUnwrap(baseline.alignment)
        let result = try await Self.runFrozenSpeakerKitExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            precision: .quantized,
            modelCachePath: nil,
            enforceMemoryGate: false,
            useExclusiveReconciliation: true
        )

        let candidate = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(result.evidence.sampleCount, baseline.sampleCount)
        XCTAssertEqual(candidate.useExclusiveReconciliation, true)
        XCTAssertFalse(candidate.rawSpans.isEmpty)
        XCTAssertTrue(candidate.overlapRanges.isEmpty)
        XCTAssertEqual(
            Set(candidate.mappings.map(\.alignmentItemIndex)).count,
            candidate.mappings.count
        )
        XCTAssertEqual(
            result.turns.map(\.japanese).joined(),
            alignment.mergedCues.map(\.text).joined()
        )
    }

    func testFrozenPrincipalSpeakerAttributionWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_PRINCIPAL_SPEAKER_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_PRINCIPAL_SPEAKER_EVIDENCE"],
              let outputPath = environment["WHISPERASR_PRINCIPAL_SPEAKER_OUTPUT"] else {
            throw XCTSkip("Set the principal-Speaker experiment evidence and output paths.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: evidencePath))
        )
        let alignment = try XCTUnwrap(baseline.alignment)
        let diarization = try XCTUnwrap(baseline.diarization)
        let asrChunks = alignment.chunks.map { chunk in
            HighQualityASRChunk(
                index: chunk.index,
                sourceStart: chunk.sourceStart,
                sourceEnd: chunk.sourceEnd,
                transcript: chunk.cues.map(\.text).joined()
            )
        }
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: baseline.sampleCount) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in baseline.rawASR ?? "" },
            transcribeJapaneseAnchored: { _ in
                .init(rawTranscript: baseline.rawASR ?? "", chunks: asrChunks)
            },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: alignment.chunks,
                    modelID: alignment.modelID,
                    revision: alignment.revision,
                    peakMemoryBytes: alignment.peakMemoryBytes
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, _ in
                .init(
                    spans: diarization.rawSpans,
                    modelID: diarization.modelID,
                    revision: diarization.revision,
                    peakMemoryBytes: diarization.peakMemoryBytes,
                    useExclusiveReconciliation: useExclusiveReconciliation
                )
            },
            unloadDiarization: {},
            translateEnglish: { request in
                let translations = request.turns.enumerated().map { index, turn in
                    [
                        "id": turn.id,
                        "text": (request.glossary(for: turn).map(\.english)
                            + ["English \(index + 1)"]).joined(separator: " "),
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "translations": translations,
                ])
                return .init(
                    model: baseline.translation?.model ?? "frozen-translation-fixture",
                    response: String(decoding: data, as: UTF8.self),
                    attempts: []
                )
            }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: evidencePath),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: baseline.model.backend,
            speakerLabels: true,
            outputRoot: URL(fileURLWithPath: outputPath)
        ))

        let candidate = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(candidate.rawSpans, diarization.rawSpans)
        XCTAssertEqual(candidate.overlapRanges.count, diarization.overlapRanges.count)
        XCTAssertEqual(
            Set(candidate.mappings.map(\.alignmentItemIndex)).count,
            candidate.mappings.count
        )
        XCTAssertEqual(
            result.turns.map(\.japanese).joined(),
            alignment.mergedCues.map(\.text).joined()
        )
    }

    func testFrozenSemanticTranslationExperimentWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_SEMANTIC_TRANSLATION_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_SEMANTIC_TRANSLATION_EVIDENCE"],
              let outputPath = environment["WHISPERASR_SEMANTIC_TRANSLATION_OUTPUT"],
              let corpusID = environment["WHISPERASR_TRANSLATOR_CORPUS"],
              let rawTranslator = environment["WHISPERASR_TRANSLATOR_CANDIDATE"],
              let translator = HighQualityTranslator(rawValue: rawTranslator),
              let rawJobID = environment["WHISPERASR_TRANSLATOR_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID) else {
            throw XCTSkip("Set the frozen evidence, corpus, translator, job ID and output paths.")
        }
        if corpusID == "md62mmdz0m" {
            guard environment["WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT"] == "1" else {
                throw XCTSkip("The final holdout requires explicit authorization.")
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: evidencePath))
        )
        let alignment = try XCTUnwrap(baseline.alignment)
        let diarization = try XCTUnwrap(baseline.diarization)
        let frozenTranslation = try XCTUnwrap(baseline.translation)
        XCTAssertEqual(baseline.model.backend, HighQualityASRBackend.qwenJA.model.backend)
        XCTAssertEqual(baseline.model.modelID, HighQualityASRBackend.qwenJA.model.modelID)
        XCTAssertEqual(baseline.model.revision, HighQualityASRBackend.qwenJA.model.revision)
        XCTAssertEqual(alignment.modelID, HighQualityForcedAlignerRuntime.modelID)
        XCTAssertEqual(alignment.revision, HighQualityForcedAlignerRuntime.revision)
        XCTAssertEqual(diarization.modelID, HighQualitySpeakerKitRuntime.modelID)
        XCTAssertEqual(diarization.revision, HighQualitySpeakerKitRuntime.revision)
        XCTAssertEqual(diarization.speakerCountPolicy, .automatic)
        XCTAssertEqual(diarization.useExclusiveReconciliation, false)
        let asrChunks = alignment.chunks.map { chunk in
            HighQualityASRChunk(
                index: chunk.index,
                sourceStart: chunk.sourceStart,
                sourceEnd: chunk.sourceEnd,
                transcript: chunk.cues.map(\.text).joined()
            )
        }
        let baseTurns = HighQualityJob.translationTurns(
            from: baseline.rawASR ?? "",
            asrChunks: asrChunks,
            speakerLabelsByCueID: [:]
        )
        let merged = try HighQualityJob.validatedAlignment(
            alignment.chunks,
            turns: baseTurns,
            duration: Double(baseline.sampleCount) / 16_000,
            fallbackMerges: alignment.fallbackMerges ?? []
        )
        let replayAlignment = HighQualityAlignmentEvidence(
            modelID: alignment.modelID,
            revision: alignment.revision,
            chunks: alignment.chunks,
            mergedCues: merged,
            sourceDuration: alignment.sourceDuration,
            peakMemoryBytes: alignment.peakMemoryBytes,
            validationDiagnostics: [],
            configuration: alignment.configuration,
            fallbackMerges: alignment.fallbackMerges
        )
        let semantic = try HighQualityJob.semanticTranslationUnits(
            alignment: replayAlignment,
            sourceTurns: baseTurns
        )
        XCTAssertEqual(semantic.turns, frozenTranslation.request.turns)
        let jobRequest = HighQualityJobRequest(
            id: jobID,
            sourceURL: URL(fileURLWithPath: evidencePath),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: baseline.model.backend,
            translator: translator,
            speakerLabels: true,
            translationContextPolicy: .productDefault,
            outputRoot: URL(fileURLWithPath: outputPath)
        )
        XCTAssertEqual(jobRequest.translationContextPolicy, .previousAcceptedV1)
        XCTAssertEqual(
            Set(frozenTranslation.request.conversationContextByCueID.values.map(\.policyVersion)),
            [jobRequest.translationContextPolicy.version]
        )
        if environment["WHISPERASR_VALIDATE_SEMANTIC_REPLAY_ONLY"] == "1" { return }

        let translationWorker = HighQualityTranslationWorkerClient(
            candidate: translator.candidate,
            executableURL: highQualityTranslationWorkerExecutableURL()
        )
        let job = HighQualityJob(services: .init(
            loadSource: { _ in Array(repeating: 0, count: baseline.sampleCount) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in baseline.rawASR ?? "" },
            transcribeJapaneseAnchored: { _ in
                .init(rawTranscript: baseline.rawASR ?? "", chunks: asrChunks)
            },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: alignment.chunks,
                    modelID: alignment.modelID,
                    revision: alignment.revision,
                    peakMemoryBytes: alignment.peakMemoryBytes,
                    configuration: alignment.configuration,
                    fallbackMerges: alignment.fallbackMerges
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, _ in },
            diarizeSpeakers: { _, useExclusiveReconciliation, _ in
                .init(
                    spans: diarization.rawSpans,
                    modelID: diarization.modelID,
                    revision: diarization.revision,
                    peakMemoryBytes: diarization.peakMemoryBytes,
                    useExclusiveReconciliation: useExclusiveReconciliation
                )
            },
            unloadDiarization: {},
            prepareTranslation: { try await translationWorker.prepare(progress: $0) },
            translateEnglish: { try await translationWorker.translate($0) },
            unloadTranslation: { await translationWorker.unload() },
            translationWorkerEvidence: { await translationWorker.evidence }
        ))

        let result = try await job.run(jobRequest)

        let units = try XCTUnwrap(result.evidence.alignment?.semanticUnits)
        XCTAssertFalse(units.isEmpty)
        XCTAssertTrue(units.allSatisfy { $0.japanese.count <= 48 })
        XCTAssertEqual(units.map(\.japanese).joined(), alignment.mergedCues.map(\.text).joined())
        XCTAssertTrue(result.evidence.translation?.request.turns.allSatisfy {
            $0.speakerLabel == nil
        } == true)
        let translation = try XCTUnwrap(result.evidence.translation)
        XCTAssertEqual(translation.request.turns, frozenTranslation.request.turns)
        XCTAssertEqual(translation.request.glossary, frozenTranslation.request.glossary)
        XCTAssertEqual(
            translation.request.glossaryByCueID,
            frozenTranslation.request.glossaryByCueID
        )
        XCTAssertEqual(
            Set(translation.request.conversationContextByCueID.keys),
            Set(translation.request.turns.map(\.id))
        )
        XCTAssertEqual(translation.model, translator.model.modelID)
        XCTAssertEqual(translation.revision, translator.model.revision)
        XCTAssertEqual(translation.runtimeVersion, translator.model.runtimeVersion)
        XCTAssertEqual(translation.weightSHA256, translator.model.weightSHA256)
        XCTAssertEqual(translation.worker?.exitStatus, 0)
        XCTAssertFalse(translation.worker?.forcedTermination ?? true)
        XCTAssertEqual(result.evidence.glossary.budget, baseline.glossary.budget)
        XCTAssertEqual(result.evidence.glossary.coverageLimit, baseline.glossary.coverageLimit)
        XCTAssertEqual(result.evidence.diarization?.rawSpans, diarization.rawSpans)
    }

    func testFrozenSourceDecodesThroughTheProductLoaderWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_HIGH_QUALITY_SOURCE_CHECK"] == "1" else {
            throw XCTSkip("Run Scripts/run_high_quality_acceptance.sh for the source check.")
        }
        let input = try Self.input(from: environment)

        let samples = try await AudioLoader.loadSamples(url: input.sourceURL)

        XCTAssertEqual(samples.count, input.manifest.fixture.sampleCount)
        XCTAssertTrue(samples.contains { $0 != 0 })
    }

    func testIssue77ASRAlignmentWindowExperimentWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ISSUE77_ALIGNMENT_WINDOW_EXPERIMENT"] == "1",
              let outputPath = environment["WHISPERASR_ISSUE77_ALIGNMENT_WINDOW_OUTPUT"] else {
            throw XCTSkip("Set the ticket #77 ASR/alignment experiment inputs.")
        }
        let input = try Self.input(from: environment)
        XCTAssertEqual(input.corpusID, "qudu2fx3ncc")
        let samples = try await AudioLoader.loadSamples(url: input.sourceURL)
        let executableURL = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"]
            .map(URL.init(fileURLWithPath:))
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        let asr = HighQualityASRWorkerClient(backend: .qwenJA, executableURL: executableURL)
        let exchange: HighQualityASRExchange
        do {
            try await asr.prepare { _, message in print("[issue-77][asr] \(message)") }
            exchange = try await asr.transcribe(samples, anchored: true)
        } catch {
            await asr.unload()
            throw error
        }
        await asr.unload()
        let asrWorkerEvidence = await asr.evidence
        let asrWorker = try XCTUnwrap(asrWorkerEvidence)

        let turns = HighQualityJob.translationTurns(
            from: exchange.rawTranscript,
            asrChunks: exchange.chunks,
            speakerLabelsByCueID: [:]
        )
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: executableURL
        )
        let alignment: HighQualityAlignmentExchange
        do {
            try await aligner.prepare { _, message in print("[issue-77][alignment] \(message)") }
            alignment = try await aligner.align(samples: samples, turns: turns)
        } catch {
            await aligner.unload()
            throw error
        }
        await aligner.unload()
        let alignmentWorkerEvidence = await aligner.evidence
        let alignmentWorker = try XCTUnwrap(alignmentWorkerEvidence)
        let cues = alignment.chunks.flatMap(\.cues)
        let items = alignment.chunks.flatMap(\.rawItems)
        let maximumWindow = exchange.chunks.map { $0.sourceEnd - $0.sourceStart }.max() ?? 0
        let evidence = Issue77AlignmentWindowEvidence(
            ticket: 77,
            corpusID: input.corpusID,
            sourcePath: input.sourceURL.path,
            sourceSHA256: try JapaneseBenchmarkSupport.sha256(at: input.sourceURL),
            maximumWindowSeconds: HighQualityForcedAlignerRuntime.maximumWindowSeconds,
            observedMaximumWindowSeconds: maximumWindow,
            asr: exchange,
            asrWorker: asrWorker,
            alignment: alignment,
            alignmentWorker: alignmentWorker,
            cueCount: cues.count,
            zeroDurationCueCount: cues.filter { $0.end <= $0.start }.count,
            rawItemCount: items.count,
            zeroDurationRawItemCount: items.filter { $0.end <= $0.start }.count,
            strictlySequential: asrWorker.lifecycle.exitedAt <= alignmentWorker.startedAt
        )
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(evidence).write(to: outputURL, options: .atomic)
        print(
            "[issue-77][result] windows=\(exchange.chunks.count) max=\(maximumWindow)s "
                + "zeroCues=\(evidence.zeroDurationCueCount)/\(evidence.cueCount) "
                + "zeroItems=\(evidence.zeroDurationRawItemCount)/\(evidence.rawItemCount)"
        )
    }

    func testPixITOracleQwenSourcesWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_PIXIT_ORACLE_QWEN"] == "1",
              let inputPath = environment["WHISPERASR_PIXIT_SEPARATOR_EVIDENCE"],
              let outputPath = environment["WHISPERASR_PIXIT_QWEN_EVIDENCE"] else {
            throw XCTSkip("Set the ticket #101/#102 separator and Qwen evidence paths.")
        }
        let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let input = try decoder.decode(
            PixITSeparatorEvidence.self,
            from: Data(contentsOf: inputURL)
        )
        XCTAssertTrue([101, 102].contains(input.ticket))
        XCTAssertEqual(input.corpusID, "qudu2fx3ncc")
        XCTAssertTrue(["smoke", "development"].contains(input.stage))
        XCTAssertFalse(input.files.isEmpty)
        let root = inputURL.deletingLastPathComponent().standardizedFileURL.path + "/"
        for file in input.files {
            let url = URL(fileURLWithPath: file.path).standardizedFileURL
            XCTAssertTrue(url.path.hasPrefix(root))
            XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: url), file.sha256)
        }
        let files = input.files.sorted {
            ($0.windowID, $0.kind == "mixture" ? 0 : 1, $0.sourceIndex ?? 0)
                < ($1.windowID, $1.kind == "mixture" ? 0 : 1, $1.sourceIndex ?? 0)
        }
        let executableURL = environment["WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE"]
            .map(URL.init(fileURLWithPath:))
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let asr = HighQualityASRWorkerClient(backend: .qwenJA, executableURL: executableURL)
        var items: [PixITQwenItem] = []
        do {
            try await asr.prepare { _, message in
                print("[issue-\(input.ticket)][qwen] \(message)")
            }
            for file in files {
                let started = Date()
                let samples = try await AudioLoader.loadSamples(url: URL(fileURLWithPath: file.path))
                let exchange = try await asr.transcribe(samples, anchored: true)
                items.append(.init(
                    windowID: file.windowID,
                    kind: file.kind,
                    sourceIndex: file.sourceIndex,
                    startSample: file.startSample,
                    endSample: file.endSample,
                    audioSHA256: file.sha256,
                    transcript: exchange.rawTranscript,
                    chunks: exchange.chunks,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ))
            }
        } catch {
            await asr.unload()
            throw error
        }
        await asr.unload()
        let workerEvidence = await asr.evidence
        let worker = try XCTUnwrap(workerEvidence)
        let evidence = PixITQwenEvidence(
            ticket: input.ticket,
            stage: input.stage,
            corpusID: input.corpusID,
            inputSHA256: try JapaneseBenchmarkSupport.sha256(at: inputURL),
            items: items,
            worker: worker,
            strictlySequential: input.worker.exitedAt <= worker.lifecycle.startedAt
        )
        XCTAssertTrue(evidence.strictlySequential)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(
            to: URL(fileURLWithPath: outputPath),
            options: .atomic
        )
    }

    func testRealFrozenWorkflowWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Run Scripts/run_high_quality_acceptance.sh for the real workflow.")
        }
        let input = try Self.input(from: environment)
        guard let rawBackend = environment["WHISPERASR_ACCEPTANCE_BACKEND"],
              let backend = HighQualityASRBackend(rawValue: rawBackend),
              let rawJobID = environment["WHISPERASR_ACCEPTANCE_JOB_ID"],
              let jobID = UUID(uuidString: rawJobID),
              let outputPath = environment["WHISPERASR_ACCEPTANCE_OUTPUT_ROOT"] else {
            throw XCTSkip("Backend, job ID and output root are required.")
        }
        if backend == .funASRNanoInt8,
           environment["BENCHMARK_SLOT_GRANTED"] != "88" {
            throw XCTSkip("Fun-ASR DEV requires the serialized benchmark slot #88.")
        }
        if input.corpusID == "md62mmdz0m" {
            guard environment["WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT"] == "1" else {
                throw XCTSkip("The untouched holdout requires explicit authorization.")
            }
        }
        let contextPolicy: HighQualityConversationContextPolicy
        switch environment["WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT"] ?? "none" {
        case "none": contextPolicy = .none
        case "product-default": contextPolicy = .productDefault
        default:
            XCTFail("Unknown translation-context policy.")
            return
        }
        let translator = try XCTUnwrap(HighQualityTranslator(
            rawValue: environment["WHISPERASR_ACCEPTANCE_TRANSLATOR"]
                ?? HighQualityTranslator.productDefault.rawValue
        ))

        let result = try await HighQualityJob().run(.init(
            id: jobID,
            sourceURL: input.sourceURL,
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: backend,
            translator: translator,
            speakerLabels: true,
            translationContextPolicy: contextPolicy,
            outputRoot: URL(fileURLWithPath: outputPath)
        )) { progress in
            print("[acceptance][\(input.corpusID)][\(backend.rawValue)] "
                + "\(progress.stage.rawValue): \(progress.message)")
        }

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.selectedBackend, backend)
        XCTAssertEqual(result.manifest.translationModel, translator.model)
        XCTAssertEqual(result.manifest.speakerConfiguration, .standard)
        XCTAssertEqual(result.evidence.speakerConfiguration, .standard)
        XCTAssertEqual(result.evidence.sampleCount, input.manifest.fixture.sampleCount)
        XCTAssertEqual(result.manifest.dependencies, [
            .sourceNormalization, .japaneseASR, .forcedAlignment,
            .speakerDiarization, .llmTranslation, .export,
        ])
        XCTAssertFalse(result.japaneseTranscript.isEmpty)
        XCTAssertFalse(result.englishTranscript?.isEmpty ?? true)
        XCTAssertFalse(result.subtitleCues.isEmpty)
        XCTAssertTrue(result.subtitleCues.allSatisfy { $0.end > $0.start })
        XCTAssertFalse(result.evidence.rawASR?.isEmpty ?? true)

        let alignment = try XCTUnwrap(result.evidence.alignment)
        XCTAssertEqual(alignment.modelID, HighQualityForcedAlignerRuntime.modelID)
        XCTAssertEqual(alignment.revision, HighQualityForcedAlignerRuntime.revision)
        XCTAssertTrue(alignment.validationDiagnostics.isEmpty)
        XCTAssertFalse(alignment.mergedCues.isEmpty)
        XCTAssertFalse(alignment.chunks.flatMap(\.rawItems).isEmpty)

        let diarization = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(diarization.modelID, HighQualitySpeakerKitRuntime.modelID)
        XCTAssertEqual(diarization.revision, HighQualitySpeakerKitRuntime.revision)
        XCTAssertTrue(diarization.validationDiagnostics.isEmpty)
        XCTAssertFalse(diarization.rawSpans.isEmpty)
        XCTAssertFalse(diarization.mappings.isEmpty)

        let translation = try XCTUnwrap(result.evidence.translation)
        XCTAssertEqual(result.evidence.model.revision, backend.model.revision)
        XCTAssertEqual(translation.model, translator.model.modelID)
        XCTAssertEqual(translation.revision, translator.model.revision)
        XCTAssertEqual(translation.runtimeVersion, LocalMLXTranslator.runtimeVersion)
        XCTAssertTrue(translation.validationFailures.isEmpty)
        XCTAssertFalse(translation.batches.isEmpty)
        if contextPolicy != .none {
            XCTAssertEqual(
                Set(translation.request.conversationContextByCueID.keys),
                Set(translation.request.turns.map(\.id))
            )
            XCTAssertTrue(translation.batches.filter { $0.attemptNumber == 1 }
                .allSatisfy { $0.context != nil })
            XCTAssertTrue(translation.batches.filter { $0.attemptNumber == 2 }
                .allSatisfy { $0.context == nil })
        }
        XCTAssertTrue(translation.batches.allSatisfy {
            !$0.sanitizedPrompt.isEmpty
                && $0.nativePrompt?.isEmpty == false
                && $0.nativeOutput?.isEmpty == false
                && $0.inputTokens <= LocalMLXTranslator.inputTokenLimit
        })

        let workers = [
            try XCTUnwrap(result.evidence.asrWorker?.lifecycle),
            try XCTUnwrap(alignment.worker),
            try XCTUnwrap(diarization.worker),
            try XCTUnwrap(translation.worker),
        ]
        XCTAssertEqual(Set(workers.map(\.processIdentifier)).count, workers.count)
        XCTAssertTrue(workers.allSatisfy {
            $0.exitStatus == 0 && !$0.forcedTermination && !$0.availableMemorySamples.isEmpty
        })
        XCTAssertTrue(zip(workers, workers.dropFirst()).allSatisfy {
            $0.exitedAt <= $1.startedAt
        })

        XCTAssertFalse(result.manifest.modelEvents.contains { $0.kind == .guardFailed })
        for modelID in [
            backend.model.modelID,
            HighQualityForcedAlignerRuntime.modelID,
            HighQualitySpeakerKitRuntime.modelID,
            translator.model.modelID,
        ] {
            let events = result.manifest.modelEvents.filter { $0.modelID == modelID }.map(\.kind)
            XCTAssertTrue(events.contains(.pressureChecked), "Missing pressure check for \(modelID)")
            XCTAssertTrue(events.contains(.loadCompleted), "Missing load for \(modelID)")
            XCTAssertTrue(events.contains(.unloadCompleted), "Missing unload for \(modelID)")
            XCTAssertTrue(events.contains(.memoryReleaseChecked), "Missing release check for \(modelID)")
            let pressure = try XCTUnwrap(result.manifest.modelEvents.first {
                $0.modelID == modelID && $0.kind == .pressureChecked
            })
            XCTAssertTrue(pressure.message?.contains("policy=macos-memory-pressure") == true)
            XCTAssertTrue(pressure.message?.contains("reserve=0") == true)
        }

        let expectedFiles = [
            "english-subtitles.srt", "english-subtitles.vtt",
            "english-translation-transcript.txt", "japanese-transcript.txt",
            "manifest.json", "raw-asr.json",
        ]
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
            expectedFiles
        )
    }

    private static func frozenEvidence(at path: String) throws -> HighQualityRawEvidence {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    }

    private static func assertFrozenSpeakerKitResult(
        _ result: HighQualityJobResult,
        baseline: HighQualityRawEvidence,
        alignment: HighQualityAlignmentEvidence
    ) throws {
        let candidate = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(candidate.useExclusiveReconciliation, false)
        XCTAssertFalse(candidate.rawSpans.isEmpty)
        XCTAssertFalse(candidate.mappings.isEmpty)
        XCTAssertTrue(candidate.validationDiagnostics.isEmpty)
        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.evidence.sampleCount, baseline.sampleCount)
        XCTAssertEqual(
            result.turns.map(\.japanese).joined(),
            alignment.mergedCues.map(\.text).joined()
        )
    }

    private static func runFrozenSpeakerKitExperiment(
        baseline: HighQualityRawEvidence,
        alignment: HighQualityAlignmentEvidence,
        sourcePath: String,
        outputPath: String,
        jobID: UUID,
        precision: HighQualitySpeakerKitRuntime.Precision,
        modelCachePath: String?,
        enforceMemoryGate: Bool,
        useExclusiveReconciliation: Bool,
        speakerCountPolicy: HighQualitySpeakerCountPolicy = .automatic,
        clusterDistanceThreshold: Float? = nil
    ) async throws -> HighQualityJobResult {
        let diarizer = HighQualitySpeakerKitRuntime(
            precision: precision,
            downloadBase: modelCachePath
        )
        return try await runFrozenDiarizationExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            diarizer: .init(
                name: "speakerkit-\(precision.rawValue)",
                modelID: HighQualitySpeakerKitRuntime.modelID,
                declaredPeakMemoryBytes: HighQualitySpeakerKitRuntime.declaredPeakMemoryBytes,
                prepare: { try await diarizer.prepare(progress: $0) },
                diarize: {
                    let exchange = try await diarizer.diarize(
                        samples: $0,
                        useExclusiveReconciliation: $1,
                        speakerCountPolicy: $2,
                        clusterDistanceThreshold: clusterDistanceThreshold
                    )
                    return .init(
                        spans: exchange.spans,
                        modelID: exchange.modelID,
                        revision: exchange.revision,
                        peakMemoryBytes: exchange.peakMemoryBytes,
                        useExclusiveReconciliation: exchange.useExclusiveReconciliation,
                        speakerCountPolicy: exchange.speakerCountPolicy,
                        configuration: [
                            "engine": "speakerkit-pyannote",
                            "runtimeRevision": HighQualitySpeakerKitRuntime.runtimeRevision,
                            "segmenterVariant": precision.segmenterVariant,
                            "embedderVariant": precision.embedderVariant,
                            "clusterDistanceThreshold": clusterDistanceThreshold.map {
                                String($0)
                            } ?? "library-default",
                            "speakerCount": exchange.speakerCountPolicy.expectedCount.map {
                                String($0)
                            } ?? "automatic",
                            "exclusiveReconciliation": String(useExclusiveReconciliation),
                        ],
                        speakerCentroids: exchange.speakerCentroids
                    )
                },
                unload: { await diarizer.unload() }
            ),
            enforceMemoryGate: enforceMemoryGate,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerCountPolicy: speakerCountPolicy
        )
    }

    private static func runFrozenFluidAudioExperiment(
        baseline: HighQualityRawEvidence,
        alignment: HighQualityAlignmentEvidence,
        sourcePath: String,
        outputPath: String,
        jobID: UUID,
        modelCachePath: String
    ) async throws -> HighQualityJobResult {
        let diarizer = fluidAudioDiarizer(modelCachePath: modelCachePath)
        return try await runFrozenDiarizationExperiment(
            baseline: baseline,
            alignment: alignment,
            sourcePath: sourcePath,
            outputPath: outputPath,
            jobID: jobID,
            diarizer: diarizer,
            enforceMemoryGate: true,
            useExclusiveReconciliation: false,
            speakerCountPolicy: .automatic
        )
    }

    private static func fluidAudioDiarizer(modelCachePath: String) -> FrozenDiarizer {
        let diarizer = HighQualityFluidAudioRuntime(
            modelDirectory: URL(fileURLWithPath: modelCachePath, isDirectory: true)
        )
        return .init(
            name: "fluid-audio-offline",
            modelID: HighQualityFluidAudioRuntime.modelID,
            declaredPeakMemoryBytes: HighQualityFluidAudioRuntime.declaredPeakMemoryBytes,
            prepare: { try await diarizer.prepare(progress: $0) },
            diarize: {
                try await diarizer.diarize(
                    samples: $0,
                    useExclusiveReconciliation: $1,
                    speakerCountPolicy: $2
                )
            },
            unload: { await diarizer.unload() }
        )
    }

    private struct FrozenDiarizer: Sendable {
        let name: String
        let modelID: String
        let declaredPeakMemoryBytes: UInt64
        let prepare: @Sendable (@escaping @Sendable (Double, String) -> Void) async throws -> Void
        let diarize: @Sendable (
            [Float], Bool, HighQualitySpeakerCountPolicy
        ) async throws -> HighQualityDiarizationExchange
        let unload: @Sendable () async -> Void
    }

    private struct DuplicateSpeakerDevelopmentReport: Codable {
        let ticket: Int
        let corpusID: String
        let purpose: String
        let holdoutOpened: Bool
        let benchmarkSlot: String
        let sourceJobID: UUID
        let speakerCountPolicy: HighQualitySpeakerCountPolicy
        let calibrationRole: String
        let sourceSHA256: String
        let modelID: String
        let modelRevision: String
        let runtimeRevision: String
        let embeddingVariant: String
        let vectorDimensions: [Int]
        let maximumCosineDistance: Float
        let uncertaintyMargin: Float
        let elapsedSeconds: TimeInterval
        let declaredPeakMemoryBytes: UInt64
        let observedPeakMemoryBytes: UInt64
        let centroidCount: Int
        let suggestionCount: Int
        let usefulSuggestionCount: Int
        let falseSuggestionCount: Int
        let mappings: [DuplicateSpeakerReferenceMapping]
        let comparisons: [DuplicateSpeakerComparison]
        let closestUsefulCandidate: DuplicateSpeakerComparison?
        let closestFalseCandidate: DuplicateSpeakerComparison?
    }

    private struct DuplicateSpeakerReferenceMapping: Codable {
        let speakerID: String
        let referenceSpeaker: String?
        let referenceOverlapSeconds: TimeInterval
        let referenceShare: Double?
    }

    private struct DuplicateSpeakerComparison: Codable {
        let firstSpeakerID: String
        let secondSpeakerID: String
        let cosineDistance: Float
        let firstReferenceSpeaker: String?
        let secondReferenceSpeaker: String?
        let sameReferenceSpeaker: Bool?
        let suggested: Bool
    }

    private static func duplicateSpeakerDevelopmentReport(
        manifest: JapaneseBenchmarkSupport.Manifest,
        evidence: HighQualityDiarizationEvidence,
        elapsedSeconds: TimeInterval,
        sourceSHA256: String,
        sourceJobID: UUID,
        benchmarkSlot: String,
        speakerCountPolicy: HighQualitySpeakerCountPolicy
    ) throws -> DuplicateSpeakerDevelopmentReport {
        let centroids = try XCTUnwrap(evidence.speakerCentroids)
        let mappings = referenceMappings(
            centroids: centroids,
            spans: evidence.rawSpans,
            manifest: manifest
        )
        let references = Dictionary(uniqueKeysWithValues: mappings.map {
            ($0.speakerID, $0.referenceSpeaker)
        })
        let suggestions = HighQualityJob.duplicateSpeakerSuggestions(from: centroids)
        let suggestionKeys = Set(suggestions.map {
            pairKey($0.firstSpeakerID, $0.secondSpeakerID)
        })
        var comparisons: [DuplicateSpeakerComparison] = []
        for leftIndex in centroids.indices {
            for rightIndex in centroids.indices where rightIndex > leftIndex {
                let left = centroids[leftIndex]
                let right = centroids[rightIndex]
                guard let distance = HighQualityJob.cosineDistance(
                    left.vector,
                    right.vector
                ) else { continue }
                let firstReference = references[left.speakerID] ?? nil
                let secondReference = references[right.speakerID] ?? nil
                comparisons.append(.init(
                    firstSpeakerID: left.speakerID,
                    secondSpeakerID: right.speakerID,
                    cosineDistance: distance,
                    firstReferenceSpeaker: firstReference,
                    secondReferenceSpeaker: secondReference,
                    sameReferenceSpeaker: firstReference.flatMap { first in
                        secondReference.map { first == $0 }
                    },
                    suggested: suggestionKeys.contains(pairKey(
                        left.speakerID,
                        right.speakerID
                    ))
                ))
            }
        }
        comparisons.sort {
            ($0.cosineDistance, $0.firstSpeakerID, $0.secondSpeakerID)
                < ($1.cosineDistance, $1.firstSpeakerID, $1.secondSpeakerID)
        }
        let selected = comparisons.filter(\.suggested)
        let first = try XCTUnwrap(centroids.first)
        return .init(
            ticket: 114,
            corpusID: manifest.corpusID,
            purpose: manifest.purpose.rawValue,
            holdoutOpened: false,
            benchmarkSlot: benchmarkSlot,
            sourceJobID: sourceJobID,
            speakerCountPolicy: speakerCountPolicy,
            calibrationRole: speakerCountPolicy.mode == .expected
                ? "over-clustering-pair-generator" : "baseline",
            sourceSHA256: sourceSHA256,
            modelID: first.modelID,
            modelRevision: first.modelRevision,
            runtimeRevision: first.runtimeRevision,
            embeddingVariant: first.embeddingVariant,
            vectorDimensions: Set(centroids.map(\.vectorDimension)).sorted(),
            maximumCosineDistance: HighQualityDuplicateSpeakerSuggestion
                .maximumCosineDistance,
            uncertaintyMargin: HighQualityDuplicateSpeakerSuggestion.uncertaintyMargin,
            elapsedSeconds: elapsedSeconds,
            declaredPeakMemoryBytes: HighQualitySpeakerKitRuntime.declaredPeakMemoryBytes,
            observedPeakMemoryBytes: evidence.peakMemoryBytes,
            centroidCount: centroids.count,
            suggestionCount: selected.count,
            usefulSuggestionCount: selected.filter { $0.sameReferenceSpeaker == true }.count,
            falseSuggestionCount: selected.filter { $0.sameReferenceSpeaker == false }.count,
            mappings: mappings,
            comparisons: comparisons,
            closestUsefulCandidate: comparisons.first { $0.sameReferenceSpeaker == true },
            closestFalseCandidate: comparisons.first { $0.sameReferenceSpeaker == false }
        )
    }

    private static func referenceMappings(
        centroids: [HighQualitySpeakerCentroidEvidence],
        spans: [HighQualityDiarizationSpan],
        manifest: JapaneseBenchmarkSupport.Manifest
    ) -> [DuplicateSpeakerReferenceMapping] {
        let rawIDs = Set(spans.map(\.speakerID)).sorted()
        let rawIDByLabel = Dictionary(uniqueKeysWithValues: rawIDs.enumerated().map {
            (String(format: "SPEAKER_%02d", $0.offset), $0.element)
        })
        return centroids.map { centroid in
            var overlaps: [String: TimeInterval] = [:]
            if let rawID = rawIDByLabel[centroid.speakerID] {
                for span in spans where span.speakerID == rawID {
                    for turn in manifest.annotations.turns {
                        let start = Double(turn.startSample) / Double(manifest.fixture.sampleRate)
                        let end = Double(turn.endSample) / Double(manifest.fixture.sampleRate)
                        let overlap = max(0, min(span.end, end) - max(span.start, start))
                        overlaps[turn.speaker, default: 0] += overlap
                    }
                }
            }
            let ranked = overlaps.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            let total = overlaps.values.reduce(0, +)
            return .init(
                speakerID: centroid.speakerID,
                referenceSpeaker: ranked.first?.key,
                referenceOverlapSeconds: ranked.first?.value ?? 0,
                referenceShare: total > 0 ? (ranked.first?.value ?? 0) / total : nil
            )
        }.sorted { $0.speakerID < $1.speakerID }
    }

    private static func pairKey(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "|")
    }

    private static func frozenDiarizationJob(
        baseline: HighQualityRawEvidence,
        alignment: HighQualityAlignmentEvidence,
        diarizer: FrozenDiarizer,
        enforceMemoryGate: Bool
    ) -> HighQualityJob {
        let asrChunks = alignment.chunks.map { chunk in
            HighQualityASRChunk(
                index: chunk.index,
                sourceStart: chunk.sourceStart,
                sourceEnd: chunk.sourceEnd,
                transcript: chunk.cues.map(\.text).joined()
            )
        }
        let gate = enforceMemoryGate
            ? HeavyweightModelGate(
                currentMemoryBytes: { WhisperKitRuntime.currentMemoryBytes() }
            )
            : nil
        return HighQualityJob(services: .init(
            loadSource: { try await AudioLoader.loadSamples(url: $0) },
            prepareASR: { _ in },
            transcribeJapanese: { _ in baseline.rawASR ?? "" },
            transcribeJapaneseAnchored: { _ in
                .init(rawTranscript: baseline.rawASR ?? "", chunks: asrChunks)
            },
            unloadASR: {},
            prepareAlignment: { _ in },
            alignJapanese: { _, _ in
                .init(
                    chunks: alignment.chunks,
                    modelID: alignment.modelID,
                    revision: alignment.revision,
                    peakMemoryBytes: alignment.peakMemoryBytes
                )
            },
            unloadAlignment: {},
            prepareDiarization: { _, progress in
                try await diarizer.prepare(progress)
            },
            diarizeSpeakers: {
                try await diarizer.diarize($0, $1, $2.countPolicy)
            },
            unloadDiarization: diarizer.unload,
            diarizationModelID: diarizer.modelID,
            diarizationDeclaredPeakMemoryBytes: diarizer.declaredPeakMemoryBytes,
            completeDiarizationAttribution: true,
            currentMemoryBytes: { WhisperKitRuntime.currentMemoryBytes() },
            translateEnglish: { request in
                let translations = request.turns.enumerated().map { index, turn in
                    [
                        "id": turn.id,
                        "text": (request.glossary(for: turn).map(\.english)
                            + ["English \(index + 1)"]).joined(separator: " "),
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "translations": translations,
                ])
                return .init(
                    model: baseline.translation?.model ?? "frozen-translation-fixture",
                    response: String(decoding: data, as: UTF8.self),
                    attempts: []
                )
            },
            heavyweightGate: gate
        ))
    }

    private static func runFrozenDiarizationExperiment(
        baseline: HighQualityRawEvidence,
        alignment: HighQualityAlignmentEvidence,
        sourcePath: String,
        outputPath: String,
        jobID: UUID,
        diarizer: FrozenDiarizer,
        enforceMemoryGate: Bool,
        useExclusiveReconciliation: Bool,
        speakerCountPolicy: HighQualitySpeakerCountPolicy
    ) async throws -> HighQualityJobResult {
        let job = frozenDiarizationJob(
            baseline: baseline,
            alignment: alignment,
            diarizer: diarizer,
            enforceMemoryGate: enforceMemoryGate
        )
        return try await job.run(.init(
            id: jobID,
            sourceURL: URL(fileURLWithPath: sourcePath),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: baseline.model.backend,
            speakerLabels: true,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerConfiguration: .init(
                enhancedPrecision: false,
                sensitiveDetection: false,
                countPolicy: speakerCountPolicy
            ),
            outputRoot: URL(fileURLWithPath: outputPath)
        )) { progress in
            print(
                "[diarizer-engine][\(diarizer.name)] "
                    + "\(progress.stage.rawValue): \(progress.message)"
            )
        }
    }

    private struct Input {
        let corpusID: String
        let sourceURL: URL
        let manifest: JapaneseBenchmarkSupport.Manifest
    }

    private struct Issue77AlignmentWindowEvidence: Codable {
        let ticket: Int
        let corpusID: String
        let sourcePath: String
        let sourceSHA256: String
        let maximumWindowSeconds: Int
        let observedMaximumWindowSeconds: TimeInterval
        let asr: HighQualityASRExchange
        let asrWorker: HighQualityASRWorkerEvidence
        let alignment: HighQualityAlignmentExchange
        let alignmentWorker: HighQualityWorkerEvidence
        let cueCount: Int
        let zeroDurationCueCount: Int
        let rawItemCount: Int
        let zeroDurationRawItemCount: Int
        let strictlySequential: Bool
    }

    private struct PixITSeparatorEvidence: Decodable {
        struct Worker: Decodable { let exitedAt: Date }
        struct File: Decodable {
            let windowID: String
            let kind: String
            let sourceIndex: Int?
            let startSample: Int
            let endSample: Int
            let path: String
            let sha256: String
        }
        let ticket: Int
        let stage: String
        let corpusID: String
        let worker: Worker
        let files: [File]
    }

    private struct PixITQwenItem: Codable {
        let windowID: String
        let kind: String
        let sourceIndex: Int?
        let startSample: Int
        let endSample: Int
        let audioSHA256: String
        let transcript: String
        let chunks: [HighQualityASRChunk]
        let elapsedSeconds: TimeInterval
    }

    private struct PixITQwenEvidence: Codable {
        let ticket: Int
        let stage: String
        let corpusID: String
        let inputSHA256: String
        let items: [PixITQwenItem]
        let worker: HighQualityASRWorkerEvidence
        let strictlySequential: Bool
    }

    private static func input(from environment: [String: String]) throws -> Input {
        guard let corpusID = environment["WHISPERASR_ACCEPTANCE_CORPUS"],
              ["qudu2fx3ncc", "md62mmdz0m"].contains(corpusID),
              let sourcePath = environment["WHISPERASR_ACCEPTANCE_SOURCE"],
              let archivePath = environment["WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE"] else {
            throw XCTSkip("Corpus, source and reference archive are required.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent(
            "docs/japanese-live/corpora/\(corpusID)/manifest.json"
        )
        let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
        XCTAssertEqual(manifest.annotations.status, .complete)
        XCTAssertFalse(manifest.annotations.reviewedBy.isEmpty)

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let archiveURL = URL(fileURLWithPath: archivePath)
        if let experimentalHash = environment["WHISPERASR_ACCEPTANCE_SOURCE_SHA256"] {
            let expected = "8df0e11d06510983dd66b3e0386c5562cf27a8c71bf3acfcf46eb6697b576411"
            guard corpusID == "qudu2fx3ncc",
                  environment["BENCHMARK_SLOT_GRANTED"] == "93",
                  experimentalHash == expected else {
                throw NSError(
                    domain: "HighQualityAcceptanceTests",
                    code: 93,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Experimental audio must be the locked #93 DEV candidate."]
                )
            }
            XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: sourceURL), expected)
        } else {
            try assertHash(sourceURL, label: "source-video", manifest: manifest)
        }
        try assertHash(archiveURL, label: "reference-archive", manifest: manifest)
        for reference in manifest.source.references where URL(string: reference.locator)?.scheme == nil {
            let url = root.appendingPathComponent(reference.locator)
            XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: url), reference.sha256)
        }
        return Input(corpusID: corpusID, sourceURL: sourceURL, manifest: manifest)
    }

    private static func assertHash(
        _ url: URL,
        label: String,
        manifest: JapaneseBenchmarkSupport.Manifest
    ) throws {
        let expected = try XCTUnwrap(manifest.source.references.first { $0.label == label }?.sha256)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: url), expected)
    }
}
