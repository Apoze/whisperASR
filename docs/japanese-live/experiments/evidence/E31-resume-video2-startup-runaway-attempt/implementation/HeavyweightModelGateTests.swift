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

    func testOfflineAdmissionUsesMemoryPressureInsteadOfFixedReserve() async throws {
        let memory = MemoryReading(1_000)
        let available = MemoryReading(7_999)
        let pressure = MacMemoryPressureMonitor(native: false)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            releaseToleranceBytes: 100,
            releaseTimeout: .milliseconds(10),
            releasePollInterval: .milliseconds(1),
            currentMemoryBytes: { await memory.value },
            currentAvailableMemoryBytes: { await available.value },
            memoryPressure: pressure
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        XCTAssertEqual(lease.availableMemoryBytes, 7_999)
        XCTAssertEqual(lease.reserveBytes, 0)
        await memory.set(1_101)
        do {
            _ = try await gate.releaseModel(lease, unload: {})
            XCTFail("A model must remain blocked when memory was not released.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .memoryNotReleased(modelID: "translator", currentBytes: 1_101, maximumBytes: 1_100)
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
            XCTAssertEqual(error, .modelAlreadyActive(requested: "translator", active: "translator"))
        }
    }

    func testWarningBlocksNextOfflineModelUntilPressureReturnsToNormal() async throws {
        let footprint = MemoryReading(1_000)
        let available = MemoryReading(20_000)
        let pressure = MacMemoryPressureMonitor(native: false)
        pressure.record(.warning)
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await footprint.value },
            currentAvailableMemoryBytes: { await available.value },
            memoryPressure: pressure
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let acquired = Counter()
        let acquisition = Task {
            let lease = try await gate.acquireModel(
                workflow: workflow,
                modelID: "translator",
                declaredPeakBytes: 8_000
            )
            await acquired.increment()
            return lease
        }
        try await Task.sleep(for: .milliseconds(10))
        let countWhileWarning = await acquired.value
        XCTAssertEqual(countWhileWarning, 0)

        pressure.record(.normal)
        let lease = try await acquisition.value
        let countAfterNormal = await acquired.value
        XCTAssertEqual(countAfterNormal, 1)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testCriticalPressureCancelsOfflineModelWithRecoverableFailure() async throws {
        let footprint = MemoryReading(1_000)
        let available = MemoryReading(20_000)
        let pressure = MacMemoryPressureMonitor(native: false)
        let cancelled = Counter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(1),
            currentMemoryBytes: { await footprint.value },
            currentAvailableMemoryBytes: { await available.value },
            memoryPressure: pressure
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "asr",
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
        pressure.record(.critical)

        do {
            _ = try await operation.value
            XCTFail("Critical macOS memory pressure must stop the active model.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(
                error,
                .criticalMemoryPressure(modelID: "asr")
            )
            XCTAssertTrue(error.localizedDescription.contains("retry"))
        }
        let cancellationCount = await cancelled.value
        XCTAssertEqual(cancellationCount, 1)

        pressure.record(.normal)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testWarningCleansOnceAndContinuesAfterRecovery() async throws {
        let memory = MemoryReading(1_000)
        let pressure = MacMemoryPressureMonitor(native: false)
        let cleanups = SynchronousCounter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(20),
            currentMemoryBytes: { await memory.value },
            memoryPressure: pressure,
            cleanupMemory: { cleanups.increment() }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                try await Task.sleep(for: .milliseconds(100))
                return "completed"
            }
        }

        pressure.record(.warning)
        try await waitUntil { cleanups.value == 1 }
        await memory.set(900)
        pressure.record(.normal)

        let result = try await operation.value
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(cleanups.value, 1)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testPersistentWarningContinuesAfterOneCleanupWhenFootprintIsStable() async throws {
        let pressure = MacMemoryPressureMonitor(native: false)
        let cleanups = SynchronousCounter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(20),
            currentMemoryBytes: { 1_000 },
            memoryPressure: pressure,
            cleanupMemory: { cleanups.increment() }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        pressure.record(.warning)

        try await operation.value
        XCTAssertEqual(cleanups.value, 1)
        pressure.record(.normal)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testLiveWarningBehaviorRemainsUnchanged() async throws {
        let pressure = MacMemoryPressureMonitor(native: false)
        let cleanups = SynchronousCounter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(20),
            currentMemoryBytes: { 1_000 },
            currentAvailableMemoryBytes: { 20_000 },
            memoryPressure: pressure,
            cleanupMemory: { cleanups.increment() }
        )
        let workflow = try await gate.beginWorkflow(.live)
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "live",
            declaredPeakBytes: 8_000
        )
        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        pressure.record(.warning)

        try await operation.value
        XCTAssertEqual(cleanups.value, 0)
        pressure.record(.normal)
        _ = try await gate.releaseModel(lease, unload: {})
        try await gate.endWorkflow(workflow)
    }

    func testGrowthAfterWarningCleanupStopsTheModel() async throws {
        let memory = MemoryReading(1_000)
        let pressure = MacMemoryPressureMonitor(native: false)
        let cleanups = SynchronousCounter()
        let gate = HeavyweightModelGate(
            totalMemoryBytes: 24_000,
            reserveBytes: 8_000,
            monitorPollInterval: .milliseconds(20),
            currentMemoryBytes: { await memory.value },
            memoryPressure: pressure,
            cleanupMemory: { cleanups.increment() }
        )
        let workflow = try await gate.beginWorkflow(.offline(UUID()))
        let lease = try await gate.acquireModel(
            workflow: workflow,
            modelID: "translator",
            declaredPeakBytes: 8_000
        )
        let operation = Task {
            try await gate.withMemoryGuard(lease) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        pressure.record(.warning)
        try await waitUntil { cleanups.value == 1 }
        await memory.set(1_250)
        pressure.record(.normal)

        do {
            try await operation.value
            XCTFail("Post-cleanup growth must stop the model.")
        } catch let error as HeavyweightModelGateError {
            XCTAssertEqual(error, .memoryPressureDidNotRecover(modelID: "translator"))
        }
        pressure.record(.normal)
        await memory.set(1_000)
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

private final class SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(predicate())
}
