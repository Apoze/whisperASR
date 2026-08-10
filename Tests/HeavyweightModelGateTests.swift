import XCTest
@testable import WhisperASRApp

final class HeavyweightModelGateTests: XCTestCase {
    func testSecondModelIsRejectedUntilSequentialHandoffCompletes() async throws {
        let memory = MemoryReading(1_000)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            releaseTimeout: .milliseconds(50),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { await memory.value }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let first = try await gate.acquireModel(
            workflow: workflow,
            modelID: "asr",
            declaredPeakBytes: 8_000
        )
        try await gate.markLoaded(first)

        do {
            _ = try await gate.acquireModel(
                workflow: workflow,
                modelID: "translator",
                declaredPeakBytes: 8_000
            )
            XCTFail("A second heavyweight model must be rejected.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(error, .modelAlreadyActive(requested: "translator", active: "asr"))
        }

        await memory.set(1_050)
        _ = try await gate.releaseModel(first, unload: {})
        let second = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        try await gate.markLoaded(second)
        _ = try await gate.releaseModel(second, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testFailedLoadAndCancellationStillUnloadAndReleaseLease() async throws {
        for failure in [TestFailure.failedLoad, .cancelled] {
            let memory = MemoryReading(1_000)
            let unloads = Counter()
            let gate = HeavyweightModelGate(
                totalMemoryBytes: 24_000,
                reserveBytes: 8_000,
                releaseToleranceBytes: 100,
                releaseTimeout: .milliseconds(50),
                releasePollInterval: .milliseconds(1),
                currentMemoryBytes: { await memory.value }
            )
            let workflow = try await gate.beginWorkflow(.offline(UUID()))
            let lease = try await gate.acquireModel(
                workflow: workflow,
                modelID: "asr",
                declaredPeakBytes: 8_000
            )

            do {
                throw failure
            } catch {
                _ = try await gate.releaseModel(lease) { await unloads.increment() }
            }

            let unloadCount = await unloads.value
            XCTAssertEqual(unloadCount, 1)
            let next = try await gate.acquireModel(
                workflow: workflow,
                modelID: "translator",
                declaredPeakBytes: 8_000
            )
            _ = try await gate.releaseModel(next, unload: {})
            try await gate.endWorkflow(workflow)
        }
    }

    func testCapacityAndMemoryReleaseChecksFailClosed() async throws {
        let memory = MemoryReading(1_000)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            releaseTimeout: .milliseconds(10),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { await memory.value }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))

        do {
            _ = try await gate.acquireModel(
                workflow: workflow,
                modelID: "too-large",
                declaredPeakBytes: 16_001
            )
            XCTFail("The 8 GB system reserve must be protected.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .insufficientCapacity(
                    modelID: "too-large",
                    declaredPeakBytes: 16_001,
                    reserveBytes: 8_000,
                    totalMemoryBytes: 24_000
                )
            )
        }

        do {
            _ = try await gate.acquireModel(
                workflow: workflow,
                modelID: "baseline-plus-model-too-large",
                declaredPeakBytes: 15_001
            )
            XCTFail("Current memory plus the model peak must preserve the reserve.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .insufficientCapacity(
                    modelID: "baseline-plus-model-too-large",
                    declaredPeakBytes: 15_001,
                    reserveBytes: 8_000,
                    totalMemoryBytes: 24_000
                )
            )
        }

        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "asr",
            declaredPeakBytes: 8_000
        )
        await memory.set(1_101)
        do {
            _ = try await gate.releaseModel(lease, unload: {})
            XCTFail("A model must remain blocked when memory was not released.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .memoryNotReleased(modelID: "asr", currentBytes: 1_101, maximumBytes: 1_100)
            )
            XCTAssertTrue(error.localizedDescription.contains("quit and reopen WhisperASR"))
        }

        do {
            _ = try await gate.acquireModel(
                workflow: workflow,
                modelID: "translator",
                declaredPeakBytes: 8_000
            )
            XCTFail("The failed release must keep the gate closed.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(error, .modelAlreadyActive(requested: "translator", active: "asr"))
        }
    }

    func testRuntimeWatchdogCancelsWhenFootprintBreaksTheReserve() async throws {
        let footprint = MemoryReading(1_000)
        let available = MemoryReading(20_000)
        let cancelled = Counter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            releaseTimeout: .milliseconds(50),
            releasePollInterval: .milliseconds(1),
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await footprint.value },
            currentAvailableMemoryBytes: { await available.value }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )

        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                do {
                    while true { try await Task.sleep(for: .milliseconds(1)) }
                } catch {
                    await cancelled.increment()
                    throw error
                }
            }
        }
        await footprint.set(16_001)
        do {
            _ = try await operation.value
            XCTFail("The operation must stop before consuming the 8 GB reserve.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .runtimeReserveViolated(
                    modelID: "translator",
                    currentBytes: 16_001,
                    maximumBytes: 16_000,
                    availableBytes: 20_000,
                    reserveBytes: 8_000
                )
            )
        }
        let cancellationCount = await cancelled.value
        XCTAssertEqual(cancellationCount, 1)

        await footprint.set(1_000)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testRuntimeWatchdogCancelsWhenSystemAvailableFallsBelowReserve() async throws {
        let footprint = MemoryReading(1_000)
        let available = MemoryReading(20_000)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await footprint.value },
            currentAvailableMemoryBytes: { await available.value }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "asr",
            declaredPeakBytes: 8_000
        )
        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                while true { try await Task.sleep(for: .milliseconds(1)) }
            }
        }
        await available.set(7_999)

        do {
            _ = try await operation.value
            XCTFail("The operation must stop when system availability breaks the reserve.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .runtimeReserveViolated(
                    modelID: "asr",
                    currentBytes: 1_000,
                    maximumBytes: 16_000,
                    availableBytes: 7_999,
                    reserveBytes: 8_000
                )
            )
        }

        await available.set(20_000)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testLiveAndOfflineWorkflowsAreMutuallyExclusive() async throws {
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            currentMemoryBytes: { 1_000 }
        )
        let live = try await gate.beginWorkflow(.live)
        do {
            _ = try await gate.beginWorkflow(.offline(UUID()))
            XCTFail("An offline job must fail while Live Japanese Captions owns the gate.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .workflowAlreadyActive(
                    requested: "High-quality job",
                    active: "Live Japanese Captions"
                )
            )
        }
        try await gate.endWorkflow(live)

        let offline = try await gate.beginWorkflow(.offline(UUID()))
        do {
            _ = try await gate.beginWorkflow(.live)
            XCTFail("Live model loading must fail while an offline job owns the gate.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .workflowAlreadyActive(
                    requested: "Live Japanese Captions",
                    active: "High-quality job"
                )
            )
        }
        try await gate.endWorkflow(offline)
    }

    func testLiveOwnerHoldsGateUntilItsModelIsActuallyUnloaded() async throws {
        let unloads = Counter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            currentMemoryBytes: { 1_000 }
        )
        let owner = HeavyweightLiveModelOwner(gate: gate)
        try await owner.prepare(
            modelID: "live:whisper.cpp",
            declaredPeakBytes: 8_000,
            load: {},
            unload: { await unloads.increment() }
        )

        do {
            _ = try await gate.beginWorkflow(.offline(UUID()))
            XCTFail("Offline work must remain blocked while the live model is resident.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .workflowAlreadyActive(
                    requested: "High-quality job",
                    active: "Live Japanese Captions"
                )
            )
        }

        try await owner.unload { await unloads.increment() }
        let unloadCount = await unloads.value
        XCTAssertEqual(unloadCount, 1)
        let offline = try await gate.beginWorkflow(.offline(UUID()))
        try await gate.endWorkflow(offline)
    }
}

private enum TestFailure: Error {
    case failedLoad
    case cancelled
}

private actor MemoryReading {
    private(set) var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func set(_ value: UInt64) { self.value = value }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
