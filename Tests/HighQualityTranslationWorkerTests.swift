import Darwin
import Foundation
import XCTest
@testable import WhisperASRApp

func highQualityTranslationWorkerExecutableURL() -> URL {
    Bundle(for: HighQualityTranslationWorkerTests.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("WhisperASR")
}

final class HighQualityTranslationWorkerTests: XCTestCase {
    func testOneWorkerServesSequentialTranslations() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        sequence=1
        while [ ! -f "$directory/shutdown" ]; do
          if [ -f "$directory/request-$sequence.json" ]; then
            printf '{"exchange":{"model":"fixture","response":"","attempts":[],"batches":[],"peakMemoryBytes":0}}' > "$directory/response-$sequence.tmp"
            mv "$directory/response-$sequence.tmp" "$directory/response-$sequence.json"
            sequence=$((sequence + 1))
          fi
          sleep 0.01
        done
        """)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        let pid = await worker.processIdentifier
        let request = HighQualityTranslationBatch(source: .init(
            path: "/tmp/test.wav",
            fileName: "test.wav",
            byteCount: nil,
            modifiedAt: nil,
            sourceURL: nil,
            youtube: nil
        ), turns: [], glossary: [])

        let first = try await worker.translate(request)
        let second = try await worker.translate(request)
        XCTAssertEqual(first.model, "fixture")
        XCTAssertEqual(second.model, "fixture")
        let samePID = await worker.processIdentifier
        XCTAssertEqual(samePID, pid)
        await worker.unload()
    }

    func testNormalShutdownWaitsForWorkerExitAndRecordsEvidence() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        exit 0
        """)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )

        try await worker.prepare(progress: { _, _ in })
        let activePID = await worker.processIdentifier
        let pid = try XCTUnwrap(activePID)
        XCTAssertEqual(kill(pid, 0), 0)

        await worker.unload()

        XCTAssertNotEqual(kill(pid, 0), 0)
        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)
        XCTAssertEqual(evidence.processIdentifier, pid)
        XCTAssertEqual(evidence.exitStatus, 0)
        XCTAssertFalse(evidence.forcedTermination)
        XCTAssertGreaterThanOrEqual(evidence.elapsedSeconds, 0)
    }

    func testWarningNotifiesWorkerAndRecordsPressureTransition() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        trap 'touch "$directory/warning-observed"' USR1
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        exit 0
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })

        pressure.record(.warning)
        try await fixture.waitForFile("warning-observed")
        pressure.record(.normal)
        await worker.unload()

        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)
        XCTAssertTrue(evidence.pressureTransitions.contains { $0.level == .warning })
    }

    func testWarningBlocksWorkerLaunchUntilPressureReturnsToNormal() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        touch "$directory/launched"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        pressure.record(.warning)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )

        let preparation = Task { try await worker.prepare(progress: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("launched").path
        ))
        pressure.record(.normal)
        try await preparation.value
        await worker.unload()
    }

    func testCriticalPressureTerminatesWorkerWithRecoverableError() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        trap 'exit 75' TERM
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while :; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        pressure.record(.critical)
        try await waitUntil { await worker.evidence != nil }

        do {
            _ = try await worker.translate(.init(source: .init(
                path: "/tmp/test.wav",
                fileName: "test.wav",
                byteCount: nil,
                modifiedAt: nil,
                sourceURL: nil,
                youtube: nil
            ), turns: [], glossary: []))
            XCTFail("Critical pressure must make the worker unavailable.")
        } catch let error as HighQualityTranslationWorkerError {
            XCTAssertEqual(error, .criticalMemoryPressure)
            XCTAssertTrue(error.localizedDescription.contains("retry"))
        }
        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)
        XCTAssertFalse(evidence.forcedTermination)
        XCTAssertTrue(evidence.pressureTransitions.contains { $0.level == .critical })
    }

    func testCriticalPressureReportedDuringPreparationIsRecoverable() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"criticalMemoryPressure":true,"error":{"model":"fixture","attempts":[],"response":null,"batches":[],"peakMemoryBytes":0,"message":"cancelled"}}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        exit 75
        """)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        do {
            try await worker.prepare(progress: { _, _ in })
            XCTFail("Critical preparation pressure must fail recoverably.")
        } catch let error as HighQualityTranslationWorkerError {
            XCTAssertEqual(error, .criticalMemoryPressure)
            XCTAssertTrue(error.localizedDescription.contains("recoverable"))
        }
        let evidence = await worker.evidence
        XCTAssertEqual(evidence?.exitStatus, 75)
    }

    func testCriticalPressureForcesWorkerAfterBoundedCooperativeShutdown() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        trap '' TERM
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while :; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(20)
        )
        try await worker.prepare(progress: { _, _ in })
        pressure.record(.critical)
        try await waitUntil { await worker.evidence != nil }

        let recordedEvidence = await worker.evidence
        let evidence = try XCTUnwrap(recordedEvidence)
        XCTAssertTrue(evidence.forcedTermination)
        XCTAssertEqual(evidence.terminationReason, "uncaught-signal")
    }

    func testCriticalPressureDuringRequestPreservesPartialEvidenceAndFinalizesOnce() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        response='{"criticalMemoryPressure":true,"error":{"model":"fixture","attempts":[],"response":null,"batches":[{"cueIDs":["cue-1"],"sanitizedPrompt":"日本語","sanitizedOutput":"","inputTokens":1}],"peakMemoryBytes":42,"message":"cancelled"}}'
        trap 'printf "%s" "$response" > "$directory/response-1.tmp"; mv "$directory/response-1.tmp" "$directory/response-1.json"; exit 75' TERM
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while :; do sleep 0.01; done
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            workingDirectory: fixture.directory,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(100)
        )
        try await worker.prepare(progress: { _, _ in })
        let translation = Task { try await worker.translate(Self.emptyRequest) }
        try await Task.sleep(for: .milliseconds(10))
        pressure.record(.critical)

        do {
            _ = try await translation.value
            XCTFail("Critical pressure must fail the pending request.")
        } catch let error as HighQualityTranslationServiceError {
            XCTAssertTrue(error.localizedDescription.contains("recoverable"))
            XCTAssertEqual(error.batches.map(\.cueIDs), [["cue-1"]])
        }
        let recordedFirstEvidence = await worker.evidence
        let firstEvidence = try XCTUnwrap(recordedFirstEvidence)
        await worker.unload()
        let recordedFinalEvidence = await worker.evidence
        XCTAssertEqual(recordedFinalEvidence, firstEvidence)
    }

    func testCancellingPendingRequestAllowsCleanWorkerExit() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        let translation = Task { try await worker.translate(Self.emptyRequest) }
        try await Task.sleep(for: .milliseconds(10))
        translation.cancel()
        do {
            _ = try await translation.value
            XCTFail("Cancellation must leave the request pending only until cleanup.")
        } catch is CancellationError {}
        await worker.unload()
        let evidence = await worker.evidence
        XCTAssertNotNil(evidence)
    }

    func testTranslationFailureCrossesWorkerBoundaryWithPartialEvidence() async throws {
        let fixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/request-1.json" ]; do sleep 0.01; done
        printf '{"error":{"model":"fixture","attempts":[],"response":null,"batches":[{"cueIDs":["cue-1"],"sanitizedPrompt":"日本語","sanitizedOutput":"","inputTokens":1}],"peakMemoryBytes":42,"message":"fixture failure"}}' > "$directory/response-1.tmp"
        mv "$directory/response-1.tmp" "$directory/response-1.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let worker = HighQualityTranslationWorkerClient(
            executableURL: fixture.executable,
            pressure: MacMemoryPressureMonitor(native: false),
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await worker.prepare(progress: { _, _ in })
        do {
            _ = try await worker.translate(Self.emptyRequest)
            XCTFail("The worker failure must cross the IPC boundary.")
        } catch let error as HighQualityTranslationServiceError {
            XCTAssertEqual(error.message, "fixture failure")
            XCTAssertEqual(error.batches.map(\.cueIDs), [["cue-1"]])
        }
        await worker.unload()
    }

    func testCrashDoesNotBlockANewWorkerAdmission() async throws {
        let crashingFixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/request-1.json" ]; do sleep 0.01; done
        exit 42
        """)
        let pressure = MacMemoryPressureMonitor(native: false)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            currentMemoryBytes: { 1_000 },
            memoryPressure: pressure
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let crashedLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        try await gate.markLoaded(crashedLease)
        let crashed = HighQualityTranslationWorkerClient(
            executableURL: crashingFixture.executable,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await crashed.prepare(progress: { _, _ in })
        do {
            _ = try await crashed.translate(Self.emptyRequest)
            XCTFail("A crashed worker must fail its request.")
        } catch let error as HighQualityTranslationWorkerError {
            guard case .protocolFailure = error else {
                return XCTFail("Expected a protocol failure, got \(error).")
            }
        }
        let crashedEvidence = await crashed.evidence
        XCTAssertEqual(crashedEvidence?.exitStatus, 42)
        _ = try await gate.releaseModel(crashedLease) { await crashed.unload() }
        let recoveredLease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )

        let healthyFixture = try WorkerFixture(script: """
        #!/bin/sh
        directory="$2"
        printf '{"ready":true}' > "$directory/ready.tmp"
        mv "$directory/ready.tmp" "$directory/ready.json"
        while [ ! -f "$directory/shutdown" ]; do sleep 0.01; done
        """)
        let recovered = HighQualityTranslationWorkerClient(
            executableURL: healthyFixture.executable,
            pressure: pressure,
            pollInterval: .milliseconds(2),
            shutdownTimeout: .milliseconds(50)
        )
        try await recovered.prepare(progress: { _, _ in })
        _ = try await gate.releaseModel(recoveredLease) { await recovered.unload() }
        try await gate.endWorkflow(workflow)
        let recoveredEvidence = await recovered.evidence
        XCTAssertEqual(recoveredEvidence?.exitStatus, 0)
    }

    private static let emptyRequest = HighQualityTranslationBatch(source: .init(
        path: "/tmp/test.wav",
        fileName: "test.wav",
        byteCount: nil,
        modifiedAt: nil,
        sourceURL: nil,
        youtube: nil
    ), turns: [], glossary: [])

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

private struct WorkerFixture {
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

    func waitForFile(_ name: String) async throws {
        let target = directory.appendingPathComponent(name).path
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: target), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
    }
}
