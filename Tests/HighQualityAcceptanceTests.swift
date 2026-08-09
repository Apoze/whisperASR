import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityAcceptanceTests: XCTestCase {
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
