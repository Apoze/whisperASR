import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityJobTests: XCTestCase {
    func testYouTubeSourceUsesAcquiredAudioAndRetainsAcquisitionEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let loadedURL = URLBox()
        let job = HighQualityJob(services: .init(
            loadSource: {
                await loadedURL.set($0)
                return [0.1]
            },
            acquireYouTube: { url, directory in
                let audioURL = directory.appendingPathComponent("source.m4a")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("audio".utf8).write(to: audioURL)
                return HighQualityYouTubeAcquisition(
                    audioURL: audioURL,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "Fixture title",
                        channel: "Fixture channel",
                        description: "Fixture description",
                        ytDLPVersion: "2026.08.08",
                        diagnostics: "fixture format=m4a"
                    )
                )
            },
            prepareASR: { _ in },
            transcribeJapanese: { _ in "日本語" },
            unloadASR: {}
        ))

        let result = try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: [.japaneseTranscript],
            backend: .qwenJA,
            outputRoot: root
        ))

        let normalizedURL = await loadedURL.value
        XCTAssertEqual(normalizedURL?.lastPathComponent, "source.m4a")
        XCTAssertEqual(result.manifest.source.youtube?.title, "Fixture title")
        XCTAssertEqual(result.manifest.source.youtube?.channel, "Fixture channel")
        XCTAssertEqual(result.manifest.source.youtube?.description, "Fixture description")
        XCTAssertEqual(result.manifest.source.youtube?.sourceURL, sourceURL.absoluteString)
        XCTAssertEqual(result.manifest.source.youtube?.ytDLPVersion, "2026.08.08")
        XCTAssertEqual(result.manifest.source.youtube?.diagnostics, "fixture format=m4a")
        XCTAssertEqual(result.evidence.source.youtube, result.manifest.source.youtube)
        XCTAssertTrue(result.manifest.generatedFiles.contains {
            $0.path == "acquisition/source.m4a" && $0.kind == .evidence
        })
        XCTAssertEqual(
            result.manifest.dependencies,
            [.sourceAcquisition, .sourceNormalization, .japaneseASR, .export]
        )
    }

    func testYouTubeValidationAndAcquisitionFailuresStopBeforeModels() async throws {
        struct FixtureError: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CallLog()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in await calls.append("source"); return [] },
            acquireYouTube: { _, directory in
                await calls.append("acquire")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent("source.webm.part")
                )
                throw FixtureError()
            },
            prepareASR: { _ in await calls.append("prepare") },
            transcribeJapanese: { _ in await calls.append("asr"); return "unused" },
            unloadASR: {}
        ))

        for url in [
            "https://example.com/watch?v=abc123",
            "https://www.youtube.com/watch?v=abc123&list=playlist",
            "https://user:password@www.youtube.com/watch?v=abc123",
        ] {
            await assertFailure(.acquisition) {
                try await job.run(.init(
                    sourceURL: try XCTUnwrap(URL(string: url)),
                    deliverables: [.japaneseTranscript],
                    backend: .qwenJA,
                    outputRoot: root
                ))
            }
        }
        let callsAfterValidation = await calls.values
        XCTAssertEqual(callsAfterValidation, [])

        let id = UUID()
        await assertFailure(.acquisition) {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        let callsAfterAcquisition = await calls.values
        XCTAssertEqual(callsAfterAcquisition, ["acquire"])
        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.source.sourceURL, "https://youtu.be/abc123")
    }

    func testCancellingYouTubeAcquisitionRemovesIncompleteDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in XCTFail("Incomplete acquisition must not be normalized."); return [] },
            acquireYouTube: { _, directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent("source.webm.part")
                )
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            },
            prepareASR: { _ in XCTFail("Incomplete acquisition must not reach ASR.") },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        let task = Task {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop YouTube acquisition.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
    }

    func testCancellationAfterYouTubeAcquisitionPreservesCompletedSourceEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            acquireYouTube: { url, directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let audioURL = directory.appendingPathComponent("source.m4a")
                try Data("complete".utf8).write(to: audioURL)
                let acquisition = HighQualityYouTubeAcquisition(
                    audioURL: audioURL,
                    evidence: .init(
                        sourceURL: url.absoluteString,
                        title: "Completed source",
                        channel: "Channel",
                        description: "Description",
                        ytDLPVersion: "fixture",
                        diagnostics: "complete"
                    )
                )
                withUnsafeCurrentTask { $0?.cancel() }
                return acquisition
            },
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
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation immediately after acquisition must stop the job.")
        } catch let error as HighQualityJobError {
            XCTAssertEqual(error.stage, .cancelled)
        }

        let directory = root.appendingPathComponent(id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("acquisition/source.m4a").path
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
        XCTAssertEqual(manifest.source.youtube?.title, "Completed source")
        XCTAssertTrue(manifest.generatedFiles.contains {
            $0.path == "acquisition/source.m4a" && $0.kind == .evidence
        })
    }

    func testYouTubeAcquirerUsesDeterministicExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("acquisition", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --ignore-config "*) ;; *) exit 2 ;; esac
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            case " $* " in *" --no-playlist "*) ;; *) exit 3 ;; esac
            case " $* " in *" --no-simulate "*) ;; *) exit 4 ;; esac
            printf 'audio' > '\(directory.appendingPathComponent("source.m4a").path)'
            printf '%s\\n' '{"title":"Fixture title","channel":"Fixture channel","description":"Fixture description","format_id":"140","ext":"m4a"}'
            printf 'fixture diagnostics\\n' >&2
            """)
        let sourceURL = try XCTUnwrap(URL(string: "https://youtu.be/abc123"))

        let acquisition = try await YouTubeAcquirer.acquire(
            sourceURL,
            to: directory,
            using: executable
        )

        XCTAssertEqual(acquisition.audioURL.lastPathComponent, "source.m4a")
        XCTAssertEqual(acquisition.evidence.title, "Fixture title")
        XCTAssertEqual(acquisition.evidence.channel, "Fixture channel")
        XCTAssertEqual(acquisition.evidence.description, "Fixture description")
        XCTAssertEqual(acquisition.evidence.ytDLPVersion, "fixture-version")
        XCTAssertEqual(acquisition.evidence.diagnostics, "format=140/m4a\nfixture diagnostics")
    }

    func testYouTubeAcquirerTerminatesItsProcessWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("acquisition", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            while :; do :; done
            """)
        let task = Task {
            try await YouTubeAcquirer.acquire(
                XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                to: directory,
                using: executable
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must terminate yt-dlp.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testYouTubeDownloadFailureRetainsVersionAndDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try makeFakeYTDLP(in: root, script: """
            #!/bin/sh
            case " $* " in *" --version "*) printf 'fixture-version\\n'; exit 0 ;; esac
            printf 'private or unsupported source\\n' >&2
            exit 5
            """)
        let id = UUID()
        let job = HighQualityJob(services: .init(
            loadSource: { _ in XCTFail("Failed acquisition must not be normalized."); return [] },
            acquireYouTube: {
                try await YouTubeAcquirer.acquire($0, to: $1, using: executable)
            },
            prepareASR: { _ in XCTFail("Failed acquisition must not reach ASR.") },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))

        await assertFailure(.acquisition) {
            try await job.run(.init(
                id: id,
                sourceURL: try XCTUnwrap(URL(string: "https://youtu.be/abc123")),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            HighQualityJobManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.source.youtube?.ytDLPVersion, "fixture-version")
        XCTAssertEqual(
            manifest.source.youtube?.diagnostics,
            "private or unsupported source"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString)
                .appendingPathComponent("acquisition").path
        ))
    }

    private func makeFakeYTDLP(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("yt-dlp")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

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
                backend: .qwenJA,
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

    func testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(HighQualityASRBackend.allCases, [.qwenJA, .parakeetJA])

        for backend in HighQualityASRBackend.allCases {
            let progress = ProgressLog()
            let expectedRawASR = backend == .qwenJA ? " こんにちは \n" : " 日本語 \n"
            let job = HighQualityJob(servicesForBackend: { selectedBackend in
                .init(
                    loadSource: { _ in [0.1, 0.2] },
                    prepareASR: { $0(1, "ready") },
                    transcribeJapanese: { _ in
                        selectedBackend == .qwenJA ? " こんにちは \n" : " 日本語 \n"
                    },
                    unloadASR: {},
                    currentMemoryBytes: { 123 }
                )
            })
            let result = try await job.run(.init(
                sourceURL: source,
                deliverables: [.japaneseTranscript],
                backend: backend,
                outputRoot: root
            )) { progress.append($0) }

            XCTAssertEqual(result.japaneseTranscript, expectedRawASR
                .trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(result.manifest.status, .completed)
            XCTAssertEqual(
                result.manifest.dependencies,
                [.sourceNormalization, .japaneseASR, .export]
            )
            XCTAssertEqual(result.manifest.peakMemoryBytes, 123)
            XCTAssertEqual(result.manifest.selectedBackend, backend)
            XCTAssertEqual(result.manifest.model.backend, backend)
            XCTAssertFalse(result.manifest.model.revision.isEmpty)
            XCTAssertFalse(result.manifest.speakerLabels)
            XCTAssertEqual(result.evidence.rawASR, expectedRawASR)
            XCTAssertEqual(result.evidence.peakMemoryBytes, 123)
            XCTAssertEqual(result.evidence.modelEvents.map(\.kind), [
                .loadStarted, .loadCompleted, .unloadCompleted,
            ])
            XCTAssertEqual(result.manifest.modelEvents, result.evidence.modelEvents)
            XCTAssertTrue(result.manifest.stageDurations.keys.contains(.preparingASR))
            XCTAssertTrue(result.manifest.stageDurations.keys.contains(.transcribing))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
                ["japanese-transcript.txt", "manifest.json", "raw-asr.json"]
            )
            XCTAssertEqual(
                try String(
                    contentsOf: result.directory.appendingPathComponent("japanese-transcript.txt"),
                    encoding: .utf8
                ),
                expectedRawASR.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            )
            let evidence = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: result.directory
                    .appendingPathComponent("raw-asr.json"))) as? [String: Any]
            )
            XCTAssertEqual(evidence["rawASR"] as? String, expectedRawASR)
            XCTAssertEqual(evidence["sampleCount"] as? Int, 2)
            XCTAssertEqual((evidence["source"] as? [String: Any])?["fileName"] as? String, "source.mp4")
            XCTAssertEqual((evidence["generatedFiles"] as? [[String: Any]])?.count, 3)
            XCTAssertTrue(progress.values.contains {
                $0.stage == .preparingASR && $0.message == "ready"
            })
        }
    }

    func testRealOfflineBackendFunctionalGateWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE"
        ], let expectedSHA256 = ProcessInfo.processInfo.environment[
            "WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256"
        ] else {
            throw XCTSkip(
                "Set WHISPERASR_HIGH_QUALITY_ASR_FIXTURE and its SHA-256 to a long Japanese fixture."
            )
        }
        let sourceURL = URL(fileURLWithPath: path)
        XCTAssertEqual(try JapaneseBenchmarkSupport.sha256(at: sourceURL), expectedSHA256)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for backend in HighQualityASRBackend.allCases {
            let result = try await HighQualityJob().run(.init(
                sourceURL: sourceURL,
                deliverables: [.japaneseTranscript],
                backend: backend,
                outputRoot: root
            ))
            XCTAssertFalse(result.japaneseTranscript.isEmpty)
            XCTAssertEqual(result.manifest.selectedBackend, backend)
            XCTAssertEqual(result.manifest.status, .completed)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: result.directory.path).sorted(),
                ["japanese-transcript.txt", "manifest.json", "raw-asr.json"]
            )

            let startedTranscribing = expectation(
                description: "\(backend.displayName) started transcribing"
            )
            let cancellationID = UUID()
            let task = Task {
                try await HighQualityJob().run(.init(
                    id: cancellationID,
                    sourceURL: sourceURL,
                    deliverables: [.japaneseTranscript],
                    backend: backend,
                    outputRoot: root
                )) { progress in
                    if progress.stage == .transcribing { startedTranscribing.fulfill() }
                }
            }
            await fulfillment(of: [startedTranscribing], timeout: 600)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancelling \(backend.displayName) must stop the job.")
            } catch let error as HighQualityJobError {
                XCTAssertEqual(error.stage, .cancelled)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cancelledManifest = try decoder.decode(
                HighQualityJobManifest.self,
                from: Data(contentsOf: root.appendingPathComponent(cancellationID.uuidString)
                    .appendingPathComponent("manifest.json"))
            )
            XCTAssertEqual(cancelledManifest.status, .cancelled)
            XCTAssertEqual(cancelledManifest.selectedBackend, backend)
        }
    }

    func testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface() async throws {
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
                backend: .qwenJA,
                outputRoot: root
            ))
        }

        let preparationFailure = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in throw FixtureError() },
            transcribeJapanese: { _ in "unused" },
            unloadASR: {}
        ))
        await assertFailure(.modelPreparation) {
            try await preparationFailure.run(.init(
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .parakeetJA,
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
                backend: .qwenJA,
                outputRoot: root
            ))
        }

        let emptyOutputID = UUID()
        let emptyOutput = HighQualityJob(services: .init(
            loadSource: { _ in [0] },
            prepareASR: { _ in },
            transcribeJapanese: { _ in " \n" },
            unloadASR: {}
        ))
        await assertFailure(.asr) {
            try await emptyOutput.run(.init(
                id: emptyOutputID,
                sourceURL: URL(fileURLWithPath: "/tmp/source.wav"),
                deliverables: [.japaneseTranscript],
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let emptyEvidence = try decoder.decode(
            HighQualityRawEvidence.self,
            from: Data(contentsOf: root.appendingPathComponent(emptyOutputID.uuidString)
                .appendingPathComponent("raw-asr.json"))
        )
        XCTAssertEqual(emptyEvidence.rawASR, " \n")

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
                backend: .qwenJA,
                outputRoot: root
            ))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted(),
            ["manifest.json", "raw-asr.json"]
        )
    }

    func testCancellationIsSafeForEveryOfflineBackend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for backend in HighQualityASRBackend.allCases {
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
                    backend: backend,
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
            XCTAssertEqual(manifest.selectedBackend, backend)
            XCTAssertEqual(manifest.modelEvents.last?.kind, .unloadCompleted)
        }
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

private actor URLBox {
    private(set) var value: URL?

    func set(_ value: URL) {
        self.value = value
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HighQualityJobProgress] = []

    var values: [HighQualityJobProgress] {
        lock.withLock { storage }
    }

    func append(_ value: HighQualityJobProgress) {
        lock.withLock { storage.append(value) }
    }
}
