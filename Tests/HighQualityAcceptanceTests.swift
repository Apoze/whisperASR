import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityAcceptanceTests: XCTestCase {
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
            prepareDiarization: { _ in },
            diarizeSpeakers: { _ in
                .init(
                    spans: diarization.rawSpans,
                    modelID: diarization.modelID,
                    revision: diarization.revision,
                    peakMemoryBytes: diarization.peakMemoryBytes
                )
            },
            unloadDiarization: {},
            translateEnglish: { request in
                let translations = request.turns.map {
                    ["id": $0.id, "text": "translation-\($0.id)"]
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
            alignment.chunks.flatMap(\.rawItems).map(\.text).joined()
        )
    }

    func testFrozenSemanticTranslationExperimentWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_SEMANTIC_TRANSLATION_EXPERIMENT"] == "1",
              let evidencePath = environment["WHISPERASR_SEMANTIC_TRANSLATION_EVIDENCE"],
              let outputPath = environment["WHISPERASR_SEMANTIC_TRANSLATION_OUTPUT"] else {
            throw XCTSkip("Set the semantic-translation experiment evidence and output paths.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: URL(fileURLWithPath: evidencePath))
        )
        let alignment = try XCTUnwrap(baseline.alignment)
        let diarization = try XCTUnwrap(baseline.diarization)
        let translator = LocalMLXTranslator()
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
            prepareDiarization: { _ in },
            diarizeSpeakers: { _ in
                .init(
                    spans: diarization.rawSpans,
                    modelID: diarization.modelID,
                    revision: diarization.revision,
                    peakMemoryBytes: diarization.peakMemoryBytes
                )
            },
            unloadDiarization: {},
            prepareTranslation: { try await translator.prepare(progress: $0) },
            translateEnglish: { try await translator.translate($0) },
            unloadTranslation: { await translator.unload() }
        ))

        let result = try await job.run(.init(
            sourceURL: URL(fileURLWithPath: evidencePath),
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: baseline.model.backend,
            speakerLabels: true,
            outputRoot: URL(fileURLWithPath: outputPath)
        ))

        let units = try XCTUnwrap(result.evidence.alignment?.semanticUnits)
        XCTAssertFalse(units.isEmpty)
        XCTAssertTrue(units.allSatisfy { $0.japanese.count <= 48 })
        XCTAssertEqual(units.map(\.japanese).joined(), alignment.mergedCues.map(\.text).joined())
        XCTAssertTrue(result.evidence.translation?.request.turns.allSatisfy {
            $0.speakerLabel == nil
        } == true)
        XCTAssertEqual(result.evidence.translation?.model, LocalMLXTranslator.modelID)
        XCTAssertEqual(result.evidence.translation?.revision, LocalMLXTranslator.revision)
        XCTAssertEqual(result.evidence.translation?.runtimeVersion, LocalMLXTranslator.runtimeVersion)
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
        if input.corpusID == "md62mmdz0m" {
            guard environment["WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT"] == "1" else {
                throw XCTSkip("The untouched holdout requires explicit authorization.")
            }
        }

        let result = try await HighQualityJob().run(.init(
            id: jobID,
            sourceURL: input.sourceURL,
            deliverables: Set(HighQualityDeliverable.allCases),
            backend: backend,
            speakerLabels: true,
            outputRoot: URL(fileURLWithPath: outputPath)
        )) { progress in
            print("[acceptance][\(input.corpusID)][\(backend.rawValue)] "
                + "\(progress.stage.rawValue): \(progress.message)")
        }

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.selectedBackend, backend)
        XCTAssertEqual(result.evidence.sampleCount, input.manifest.fixture.sampleCount)
        XCTAssertEqual(result.manifest.dependencies, [
            .sourceNormalization, .japaneseASR, .forcedAlignment,
            .speakerDiarization, .llmTranslation, .export,
        ])
        XCTAssertFalse(result.japaneseTranscript.isEmpty)
        XCTAssertFalse(result.englishTranscript?.isEmpty ?? true)
        XCTAssertFalse(result.subtitleCues.isEmpty)
        XCTAssertFalse(result.evidence.rawASR?.isEmpty ?? true)

        let alignment = try XCTUnwrap(result.evidence.alignment)
        XCTAssertEqual(alignment.modelID, HighQualityForcedAlignerRuntime.modelID)
        XCTAssertTrue(alignment.validationDiagnostics.isEmpty)
        XCTAssertFalse(alignment.mergedCues.isEmpty)
        XCTAssertFalse(alignment.chunks.flatMap(\.rawItems).isEmpty)

        let diarization = try XCTUnwrap(result.evidence.diarization)
        XCTAssertEqual(diarization.modelID, HighQualitySpeakerKitRuntime.modelID)
        XCTAssertTrue(diarization.validationDiagnostics.isEmpty)
        XCTAssertFalse(diarization.rawSpans.isEmpty)
        XCTAssertFalse(diarization.mappings.isEmpty)

        let translation = try XCTUnwrap(result.evidence.translation)
        XCTAssertEqual(translation.model, LocalMLXTranslator.modelID)
        XCTAssertEqual(translation.revision, LocalMLXTranslator.revision)
        XCTAssertEqual(translation.runtimeVersion, LocalMLXTranslator.runtimeVersion)
        XCTAssertTrue(translation.validationFailures.isEmpty)
        XCTAssertFalse(translation.batches.isEmpty)
        XCTAssertTrue(translation.batches.allSatisfy {
            !$0.sanitizedPrompt.isEmpty
                && $0.nativePrompt?.isEmpty == false
                && $0.nativeOutput?.isEmpty == false
                && $0.inputTokens <= LocalMLXTranslator.inputTokenLimit
        })

        XCTAssertFalse(result.manifest.modelEvents.contains { $0.kind == .guardFailed })
        for modelID in [
            backend.model.modelID,
            HighQualityForcedAlignerRuntime.modelID,
            HighQualitySpeakerKitRuntime.modelID,
            LocalMLXTranslator.modelID,
        ] {
            let events = result.manifest.modelEvents.filter { $0.modelID == modelID }.map(\.kind)
            XCTAssertTrue(events.contains(.reserveChecked), "Missing reserve check for \(modelID)")
            XCTAssertTrue(events.contains(.loadCompleted), "Missing load for \(modelID)")
            XCTAssertTrue(events.contains(.unloadCompleted), "Missing unload for \(modelID)")
            XCTAssertTrue(events.contains(.memoryReleaseChecked), "Missing release check for \(modelID)")
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

    private struct Input {
        let corpusID: String
        let sourceURL: URL
        let manifest: JapaneseBenchmarkSupport.Manifest
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
        try assertHash(sourceURL, label: "source-video", manifest: manifest)
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
