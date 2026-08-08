import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityJobTests: XCTestCase {
    func testRejectsJobWithoutDeliverableBeforeProcessing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in await calls.append("source"); return [] },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in await calls.append("asr"); return "" },
            unloadASR: { await calls.append("unload") }
        ))

        do {
            _ = try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/input.wav"),
                deliverables: [],
                outputRoot: root
            ))
            XCTFail("A job without a Deliverable must fail.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .application)
        }

        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        await assertFailure(.application) {
            try await job.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/input.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                speakerLabels: true,
                outputRoot: root
            ))
        }
        let callsAfterSpeakerRequest = await calls.values
        XCTAssertEqual(callsAfterSpeakerRequest, [])
    }

    func testJapaneseTranscriptJobUsesOnlyASRAndWritesCompleteArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0.1, 0.2] },
            prepareASR: { $0(1, "ready") },
            transcribeJapanese: { _ in " こんにちは \n" },
            unloadASR: {},
            currentMemoryBytes: { 123 }
        ))

        let result = try await job.run(.init(
            sourceURL: source,
            deliverables: [.japaneseTranscript],
            outputRoot: root
        ))

        XCTAssertEqual(result.japaneseTranscript, "こんにちは")
        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceNormalization, .japaneseASR, .export]
        )
        XCTAssertEqual(result.manifest.peakMemoryBytes, 123)
        XCTAssertEqual(result.manifest.selectedBackend, .qwenJA)
        XCTAssertFalse(result.manifest.speakerLabels)
        XCTAssertEqual(result.manifest.model.revision, LocalPrototypeModelID.qwenRevision)
        XCTAssertEqual(result.evidence.rawASR, " こんにちは \n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
            ["japanese-transcript.txt", "manifest.json", "raw-asr.json"]
        )
        XCTAssertEqual(
            try String(
                contentsOf: result.directory.appendingPathComponent("japanese-transcript.txt"),
                encoding: .utf8
            ),
            "こんにちは\n"
        )
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: result.directory
                .appendingPathComponent("raw-asr.json"))) as? [String: Any]
        )
        XCTAssertEqual(evidence["rawASR"] as? String, " こんにちは \n")
        XCTAssertEqual(evidence["sampleCount"] as? Int, 2)
        XCTAssertEqual((evidence["source"] as? [String: Any])?["fileName"] as? String, "source.mp4")
        XCTAssertEqual((evidence["generatedFiles"] as? [[String: Any]])?.count, 3)
    }

    func testClassifiesSourceASRAndExportFailuresAtThePrincipalInterface() async throws {
        struct FixtureError: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFailure = HighQualityJob(services: .init(
            loadSource: { _ in throw FixtureError() },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        await assertFailure(.source) {
            try await sourceFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                outputRoot: root
            ))
        }

        let asrFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in throw FixtureError() },
            unloadASR: {}
        ))
        await assertFailure(.asr) {
            try await asrFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                outputRoot: root
            ))
        }

        let exportID = UUID()
        let exportDirectory = root.appendingPathComponent(exportID.uuidString)
        let exportFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in
                try FileManager.default.removeItem(at: exportDirectory)
                return "日本語"
            },
            unloadASR: {}
        ))
        await assertFailure(.export) {
            try await exportFailure.run(.init(
                id: exportID,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                outputRoot: root
            ))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
    }

    func testCancellationFinalizesAJobWithoutDeliverables() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in
                try await Task.sleep(for: .seconds(10))
                return "unused"
            },
            unloadASR: {}
        ))
        let task = Task {
            try await job.run(.init(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                outputRoot: root
            ))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["manifest.json", "raw-asr.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
    }

    private func assertFailure(
        _ expected: HighQualityJobFailureStage,
        operation: () async throws -> HighQualityJobResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected.rawValue) failure.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor CallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
