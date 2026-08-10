import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

final class HighQualityAlignmentSpeakerWorkerTests: XCTestCase {
    func testRealWorkersWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_ISSUE73_REAL_WORKERS"] == "1" else {
            throw XCTSkip("Set WHISPERASR_RUN_ISSUE73_REAL_WORKERS=1 to run real workers.")
        }
        guard let alignmentPath = environment["WHISPERASR_ISSUE73_ALIGNMENT_FIXTURE"],
              let alignmentSHA256 = environment["WHISPERASR_ISSUE73_ALIGNMENT_SHA256"],
              let speakerPath = environment["WHISPERASR_ISSUE73_SPEAKER_FIXTURE"],
              let speakerSHA256 = environment["WHISPERASR_ISSUE73_SPEAKER_SHA256"] else {
            XCTFail("The opted-in #73 worker smoke requires both frozen fixtures and SHA-256 values.")
            return
        }
        let alignmentURL = URL(fileURLWithPath: alignmentPath)
        let speakerURL = URL(fileURLWithPath: speakerPath)
        guard try JapaneseBenchmarkSupport.sha256(at: alignmentURL) == alignmentSHA256,
              try JapaneseBenchmarkSupport.sha256(at: speakerURL) == speakerSHA256 else {
            XCTFail("A frozen #73 worker fixture failed SHA-256 validation.")
            return
        }

        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/WhisperASR")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let artifactRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks/issue-73-real-workers", isDirectory: true)
        let root = artifactRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.write([
            "alignmentFixturePath": alignmentURL.path,
            "alignmentFixtureSHA256": alignmentSHA256,
            "alignmentText": "東京は",
            "speakerFixturePath": speakerURL.path,
            "speakerFixtureSHA256": speakerSHA256,
        ], to: root.appendingPathComponent("provenance.json"))
        let pressure = MacMemoryPressureMonitor.shared
        let gate = HeavyweightModelGate(releaseTimeout: .seconds(30), memoryPressure: pressure)
        let workflow = try await gate.beginWorkflow(.offline(UUID()))

        let alignmentDirectory = root.appendingPathComponent("alignment", isDirectory: true)
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: executable,
            workingDirectory: alignmentDirectory,
            pressure: pressure
        )
        let alignmentLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: HighQualityForcedAlignerRuntime.modelID,
            declaredPeakBytes: HighQualityForcedAlignerRuntime.declaredPeakMemoryBytes
        )
        let alignment: HighQualityAlignmentExchange
        do {
            let samples = try await AudioLoader.loadSamples(url: alignmentURL)
            try await aligner.prepare(progress: { _, message in print("[#73][alignment] \(message)") })
            let startedPID = await aligner.processIdentifier
            let pid = try XCTUnwrap(startedPID)
            try await gate.markLoaded(alignmentLease)
            alignment = try await gate.withMemoryGuard(alignmentLease) {
                try await aligner.align(samples: samples, turns: [.init(
                    id: "cue-0001",
                    japanese: "東京は",
                    precedingJapanese: [],
                    followingJapanese: [],
                    speakerLabel: nil,
                    sourceStart: 0,
                    sourceEnd: Double(samples.count) / 16_000
                )])
            }
            _ = try await gate.releaseModel(alignmentLease) { await aligner.unload() }
            let finalEvidence = await aligner.evidence
            let evidence = try XCTUnwrap(finalEvidence)
            XCTAssertEqual(evidence.processIdentifier, pid)
            XCTAssertEqual(evidence.exitStatus, 0)
            XCTAssertFalse(evidence.forcedTermination)
            let exitedPID = await aligner.processIdentifier
            XCTAssertNil(exitedPID)
            XCTAssertFalse(alignment.chunks.flatMap(\.cues).isEmpty)
            XCTAssertFalse(evidence.pressureTransitions.contains { $0.level == .critical })
            try Self.write(alignment, to: alignmentDirectory.appendingPathComponent("result.json"))
            try Self.write(evidence, to: alignmentDirectory.appendingPathComponent("lifecycle.json"))
            print("[#73][alignment] pid=\(pid) exit=0 seconds=\(evidence.elapsedSeconds) peakBytes=\(evidence.peakPhysicalFootprintBytes) cues=\(alignment.chunks.flatMap(\.cues).count)")
        } catch {
            _ = try? await gate.releaseModel(alignmentLease) { await aligner.unload() }
            if let evidence = await aligner.evidence {
                try? Self.write(
                    evidence,
                    to: alignmentDirectory.appendingPathComponent("lifecycle.json")
                )
            }
            try? await gate.endWorkflow(workflow)
            throw error
        }

        let speakerDirectory = root.appendingPathComponent("diarization", isDirectory: true)
        let diarizer = HighQualityAlignmentSpeakerWorkerClient(
            stage: .diarization,
            executableURL: executable,
            workingDirectory: speakerDirectory,
            pressure: pressure
        )
        let diarizationLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: HighQualitySpeakerKitRuntime.modelID,
            declaredPeakBytes: HighQualitySpeakerKitRuntime.declaredPeakMemoryBytes
        )
        do {
            let samples = try await AudioLoader.loadSamples(url: speakerURL)
            try await diarizer.prepare(progress: { _, message in print("[#73][diarization] \(message)") })
            let startedPID = await diarizer.processIdentifier
            let pid = try XCTUnwrap(startedPID)
            try await gate.markLoaded(diarizationLease)
            let diarization = try await gate.withMemoryGuard(diarizationLease) {
                try await diarizer.diarize(
                    samples: samples,
                    useExclusiveReconciliation: false,
                    speakerCountPolicy: .automatic
                )
            }
            _ = try await gate.releaseModel(diarizationLease) { await diarizer.unload() }
            try await gate.endWorkflow(workflow)
            let finalEvidence = await diarizer.evidence
            let evidence = try XCTUnwrap(finalEvidence)
            XCTAssertEqual(evidence.processIdentifier, pid)
            XCTAssertEqual(evidence.exitStatus, 0)
            XCTAssertFalse(evidence.forcedTermination)
            let exitedPID = await diarizer.processIdentifier
            XCTAssertNil(exitedPID)
            XCTAssertFalse(diarization.spans.isEmpty)
            XCTAssertFalse(evidence.pressureTransitions.contains { $0.level == .critical })
            try Self.write(diarization, to: speakerDirectory.appendingPathComponent("result.json"))
            try Self.write(evidence, to: speakerDirectory.appendingPathComponent("lifecycle.json"))
            print("[#73][diarization] pid=\(pid) exit=0 seconds=\(evidence.elapsedSeconds) peakBytes=\(evidence.peakPhysicalFootprintBytes) spans=\(diarization.spans.count) speakers=\(Set(diarization.spans.map(\.speakerID)).count)")
        } catch {
            _ = try? await gate.releaseModel(diarizationLease) { await diarizer.unload() }
            if let evidence = await diarizer.evidence {
                try? Self.write(
                    evidence,
                    to: speakerDirectory.appendingPathComponent("lifecycle.json")
                )
            }
            try? await gate.endWorkflow(workflow)
            throw error
        }
    }

    func testAlignmentAndDiarizationWorkersAreSequentialAndPreserveContracts() async throws {
        let alignmentFixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/request.json" ]; do sleep 0.01; done
        printf '{"alignment":{"chunks":[{"index":0,"sourceStart":0,"sourceEnd":1,"cues":[{"id":"cue-0001","text":"一。","start":0.1,"end":0.9}],"rawItems":[{"cueID":"cue-0001","text":"一。","start":0.1,"end":0.9}]}],"modelID":"\(HighQualityForcedAlignerRuntime.modelID)","revision":"\(HighQualityForcedAlignerRuntime.revision)","peakMemoryBytes":12,"configuration":{"language":"Japanese","sampleRate":"16000"}}}' > "$directory/response.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let diarizationFixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/request.json" ]; do sleep 0.01; done
        printf '{"diarization":{"spans":[{"speakerID":3,"start":0,"end":1}],"modelID":"\(HighQualitySpeakerKitRuntime.modelID)","revision":"\(HighQualitySpeakerKitRuntime.revision)","peakMemoryBytes":34,"useExclusiveReconciliation":false,"speakerCountPolicy":{"mode":"automatic"},"configuration":{"runtimeRevision":"\(HighQualitySpeakerKitRuntime.runtimeRevision)","precision":"quantized","segmenterVariant":"W8A16","embedderVariant":"W8A16","speakerCount":"automatic","clusterDistanceThreshold":"library-default","overlap":"non-exclusive","attribution":"principal"}}}' > "$directory/response.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            currentMemoryBytes: { 1_000 },
            memoryPressure: pressure
        )
        let aligner = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: alignmentFixture.executable,
            workingDirectory: alignmentFixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        let diarizer = HighQualityAlignmentSpeakerWorkerClient(
            stage: .diarization,
            executableURL: diarizationFixture.executable,
            workingDirectory: diarizationFixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let alignmentLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "fixture-aligner",
            declaredPeakBytes: 4_000
        )
        try await aligner.prepare(progress: { _, _ in })
        try await gate.markLoaded(alignmentLease)

        do {
            _ = try await gate.acquireModel(
                workflow: workflow,
                modelID: "fixture-speakerkit",
                declaredPeakBytes: 4_000
            )
            XCTFail("A diarization worker must not overlap the alignment worker.")
        } catch let error as HeavyweightModelGateError {
            guard case .modelAlreadyActive = error else {
                return XCTFail("Expected modelAlreadyActive, got \(error).")
            }
        }

        let turn = HighQualityTranslationTurn(
            id: "cue-0001",
            japanese: "一。",
            precedingJapanese: [],
            followingJapanese: [],
            speakerLabel: nil,
            sourceStart: 0,
            sourceEnd: 1
        )
        let alignment = try await aligner.align(samples: [0.25], turns: [turn])
        XCTAssertEqual(alignment.chunks.first?.cues.first?.start, 0.1)
        XCTAssertEqual(alignment.configuration?["language"], "Japanese")
        XCTAssertEqual(
            try Data(contentsOf: alignmentFixture.directory.appendingPathComponent("audio.f32"))
                .count,
            MemoryLayout<Float>.size
        )
        _ = try await gate.releaseModel(alignmentLease) { await aligner.unload() }
        let alignmentPID = await aligner.processIdentifier
        XCTAssertNil(alignmentPID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: alignmentFixture.directory.appendingPathComponent("audio.f32").path
        ))

        let diarizationLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "fixture-speakerkit",
            declaredPeakBytes: 4_000
        )
        try await diarizer.prepare(progress: { _, _ in })
        try await gate.markLoaded(diarizationLease)
        let diarization = try await diarizer.diarize(
            samples: [0.25],
            useExclusiveReconciliation: false,
            speakerCountPolicy: .automatic
        )
        XCTAssertEqual(diarization.spans, [.init(speakerID: 3, start: 0, end: 1)])
        XCTAssertEqual(diarization.speakerCountPolicy, .automatic)
        XCTAssertEqual(diarization.configuration?["precision"], "quantized")
        XCTAssertEqual(diarization.configuration?["overlap"], "non-exclusive")
        let rawRequest = try String(
            contentsOf: diarizationFixture.directory.appendingPathComponent("request.json"),
            encoding: .utf8
        )
        XCTAssertTrue(rawRequest.contains(#""useExclusiveReconciliation":false"#))
        XCTAssertTrue(rawRequest.contains(#""mode":"automatic""#))
        _ = try await gate.releaseModel(diarizationLease) { await diarizer.unload() }
        try await gate.endWorkflow(workflow)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: diarizationFixture.directory.appendingPathComponent("audio.f32").path
        ))

        let alignmentEvidence = await aligner.evidence
        let diarizationEvidence = await diarizer.evidence
        XCTAssertEqual(alignmentEvidence?.exitStatus, 0)
        XCTAssertEqual(diarizationEvidence?.exitStatus, 0)
        XCTAssertTrue(alignmentEvidence?.command.contains("--high-quality-alignment-worker") == true)
        XCTAssertTrue(diarizationEvidence?.command.contains("--high-quality-diarization-worker") == true)
    }

    func testMalformedWorkerEvidenceFailsClosed() async throws {
        let fixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/request.json" ]; do sleep 0.01; done
        printf '{malformed' > "$directory/response.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let worker = HighQualityAlignmentSpeakerWorkerClient(
            stage: .diarization,
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })

        do {
            _ = try await worker.diarize(
                samples: [0],
                useExclusiveReconciliation: false,
                speakerCountPolicy: .automatic
            )
            XCTFail("Malformed evidence must not cross the worker boundary.")
        } catch let error as HighQualityAlignmentSpeakerWorkerError {
            guard case .protocolFailure(let stage, _) = error else {
                return XCTFail("Expected protocolFailure, got \(error).")
            }
            XCTAssertEqual(stage, "SpeakerKit")
        }
        await worker.unload()
        let evidence = await worker.evidence
        XCTAssertNotNil(evidence)
    }

    func testWellFormedMismatchedProvenanceFailsClosed() async throws {
        let fixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/request.json" ]; do sleep 0.01; done
        printf '{"alignment":{"chunks":[],"modelID":"wrong/model","revision":"wrong-revision","peakMemoryBytes":0,"configuration":{"language":"Japanese","sampleRate":"16000"}}}' > "$directory/response.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let worker = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })

        do {
            _ = try await worker.align(samples: [0], turns: [])
            XCTFail("Mismatched model provenance must not cross the worker boundary.")
        } catch let error as HighQualityAlignmentSpeakerWorkerError {
            guard case .protocolFailure(let stage, let message) = error else {
                return XCTFail("Expected protocolFailure, got \(error).")
            }
            XCTAssertEqual(stage, "Forced alignment")
            XCTAssertTrue(message.contains("pinned worker"))
        }
        await worker.unload()
    }

    func testCriticalPressureTerminatesAuxiliaryWorkerRecoverably() async throws {
        let fixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        trap 'exit 75' TERM
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while :; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let worker = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        pressure.record(.critical)
        try await waitUntil { await worker.evidence != nil }

        do {
            _ = try await worker.align(samples: [0], turns: [])
            XCTFail("Critical pressure must make the worker unavailable.")
        } catch let error as HighQualityAlignmentSpeakerWorkerError {
            guard case .criticalMemoryPressure(let stage) = error else {
                return XCTFail("Expected criticalMemoryPressure, got \(error).")
            }
            XCTAssertEqual(stage, "Forced alignment")
            XCTAssertTrue(error.localizedDescription.contains("retry"))
        }
        let evidence = await worker.evidence
        XCTAssertTrue(evidence?.pressureTransitions.contains { $0.level == .critical } == true)
        await worker.unload()
    }

    func testCancellingPendingAlignmentAllowsCleanWorkerExit() async throws {
        let fixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let worker = HighQualityAlignmentSpeakerWorkerClient(
            stage: .alignment,
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        let alignment = Task { try await worker.align(samples: [0], turns: []) }
        try await Task.sleep(for: .milliseconds(10))
        alignment.cancel()

        do {
            _ = try await alignment.value
            XCTFail("Cancellation must stop waiting for worker evidence.")
        } catch is CancellationError {}
        await worker.unload()

        let pid = await worker.processIdentifier
        let evidence = await worker.evidence
        XCTAssertNil(pid)
        XCTAssertEqual(evidence?.exitStatus, 0)
    }

    func testChildCrashIsClassifiedAndRecorded() async throws {
        let fixture = try AuxiliaryWorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.json"
        while [ ! -f "$directory/request.json" ]; do sleep 0.01; done
        exit 42
        """)
        let worker = HighQualityAlignmentSpeakerWorkerClient(
            stage: .diarization,
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })

        do {
            _ = try await worker.diarize(
                samples: [0],
                useExclusiveReconciliation: false,
                speakerCountPolicy: .automatic
            )
            XCTFail("A crashed SpeakerKit worker must fail its request.")
        } catch let error as HighQualityAlignmentSpeakerWorkerError {
            guard case .protocolFailure(let stage, let message) = error else {
                return XCTFail("Expected protocolFailure, got \(error).")
            }
            XCTAssertEqual(stage, "SpeakerKit")
            XCTAssertTrue(message.contains("exited before replying"))
        }
        let evidence = await worker.evidence
        XCTAssertEqual(evidence?.exitStatus, 42)
        XCTAssertFalse(evidence?.forcedTermination == true)
        await worker.unload()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("audio.f32").path
        ))
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
        let succeeded = await predicate()
        XCTAssertTrue(succeeded)
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct AuxiliaryWorkerFixture {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("worker.sh")
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
    }
}
