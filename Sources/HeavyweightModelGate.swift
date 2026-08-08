import Darwin
import Foundation
import MLX

enum HeavyweightModelWorkflow: Equatable, Sendable {
    case live
    case offline(UUID)

    var description: String {
        switch self {
        case .live: "Live Japanese Captions"
        case .offline: "High-quality job"
        }
    }
}

struct HeavyweightWorkflowLease: Equatable, Sendable {
    fileprivate let id: UUID
    let workflow: HeavyweightModelWorkflow
}

struct HeavyweightModelLease: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let workflowID: UUID
    let modelID: String
    let baselineMemoryBytes: UInt64
    let declaredPeakBytes: UInt64
    let reserveBytes: UInt64
    let totalMemoryBytes: UInt64
}

enum HeavyweightModelGateError: LocalizedError, Equatable, Sendable {
    case workflowAlreadyActive(requested: String, active: String)
    case modelAlreadyActive(requested: String, active: String)
    case invalidLease
    case insufficientCapacity(
        modelID: String,
        declaredPeakBytes: UInt64,
        reserveBytes: UInt64,
        totalMemoryBytes: UInt64
    )
    case memoryNotReleased(modelID: String, currentBytes: UInt64, maximumBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .workflowAlreadyActive(let requested, let active):
            "Cannot start \(requested) while \(active) owns the heavyweight-model gate."
        case .modelAlreadyActive(let requested, let active):
            "Cannot load \(requested) while \(active) is loading, loaded, or unloading."
        case .invalidLease:
            "The heavyweight-model lease is no longer valid."
        case .insufficientCapacity(let modelID, let peak, let reserve, let total):
            "Cannot load \(modelID): its declared peak (\(peak) bytes) plus the system reserve (\(reserve) bytes) exceeds physical memory (\(total) bytes)."
        case .memoryNotReleased(let modelID, let current, let maximum):
            "Stopped after unloading \(modelID): memory remained at \(current) bytes, above the safe handoff limit of \(maximum) bytes."
        }
    }
}

actor HeavyweightModelGate {
    static let systemReserveBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let shared = HeavyweightModelGate()

    private enum Phase { case loading, loaded, unloading }
    private struct ActiveModel {
        let lease: HeavyweightModelLease
        var phase: Phase
    }

    private let totalMemoryBytes: UInt64
    private let reserveBytes: UInt64
    private let releaseToleranceBytes: UInt64
    private let releaseTimeout: Duration
    private let releasePollInterval: Duration
    private let currentMemoryBytes: @Sendable () async -> UInt64
    private var activeWorkflow: HeavyweightWorkflowLease?
    private var activeModel: ActiveModel?

    init(
        totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        reserveBytes: UInt64 = HeavyweightModelGate.systemReserveBytes,
        releaseToleranceBytes: UInt64 = 512 * 1_024 * 1_024,
        releaseTimeout: Duration = .seconds(5),
        releasePollInterval: Duration = .milliseconds(100),
        currentMemoryBytes: @escaping @Sendable () async -> UInt64 = {
            HeavyweightModelGate.measuredCurrentMemoryBytes()
        }
    ) {
        self.totalMemoryBytes = totalMemoryBytes
        self.reserveBytes = reserveBytes
        self.releaseToleranceBytes = releaseToleranceBytes
        self.releaseTimeout = releaseTimeout
        self.releasePollInterval = releasePollInterval
        self.currentMemoryBytes = currentMemoryBytes
    }

    func beginWorkflow(_ workflow: HeavyweightModelWorkflow) throws -> HeavyweightWorkflowLease {
        if let activeWorkflow {
            throw HeavyweightModelGateError.workflowAlreadyActive(
                requested: workflow.description,
                active: activeWorkflow.workflow.description
            )
        }
        let lease = HeavyweightWorkflowLease(id: UUID(), workflow: workflow)
        activeWorkflow = lease
        return lease
    }

    func endWorkflow(_ lease: HeavyweightWorkflowLease) throws {
        guard activeWorkflow == lease, activeModel == nil else {
            throw HeavyweightModelGateError.invalidLease
        }
        activeWorkflow = nil
    }

    func acquireModel(
        workflow: HeavyweightWorkflowLease,
        modelID: String,
        declaredPeakBytes: UInt64
    ) async throws -> HeavyweightModelLease {
        guard activeWorkflow == workflow else { throw HeavyweightModelGateError.invalidLease }
        if let activeModel {
            throw HeavyweightModelGateError.modelAlreadyActive(
                requested: modelID,
                active: activeModel.lease.modelID
            )
        }
        let baselineMemoryBytes = await currentMemoryBytes()
        guard reserveBytes <= totalMemoryBytes,
              baselineMemoryBytes <= totalMemoryBytes - reserveBytes,
              declaredPeakBytes <= totalMemoryBytes - reserveBytes - baselineMemoryBytes else {
            throw HeavyweightModelGateError.insufficientCapacity(
                modelID: modelID,
                declaredPeakBytes: declaredPeakBytes,
                reserveBytes: reserveBytes,
                totalMemoryBytes: totalMemoryBytes
            )
        }
        let lease = HeavyweightModelLease(
            id: UUID(),
            workflowID: workflow.id,
            modelID: modelID,
            baselineMemoryBytes: baselineMemoryBytes,
            declaredPeakBytes: declaredPeakBytes,
            reserveBytes: reserveBytes,
            totalMemoryBytes: totalMemoryBytes
        )
        activeModel = .init(lease: lease, phase: .loading)
        return lease
    }

    func markLoaded(_ lease: HeavyweightModelLease) throws {
        guard activeModel?.lease == lease else { throw HeavyweightModelGateError.invalidLease }
        activeModel?.phase = .loaded
    }

    func releaseModel(
        _ lease: HeavyweightModelLease,
        unload: @escaping @Sendable () async -> Void
    ) async throws -> UInt64 {
        guard activeModel?.lease == lease else { throw HeavyweightModelGateError.invalidLease }
        activeModel?.phase = .unloading
        await unload()

        let memory = currentMemoryBytes
        let timeout = releaseTimeout
        let interval = releasePollInterval
        let maximum = lease.baselineMemoryBytes.addingReportingOverflow(releaseToleranceBytes)
        let maximumBytes = maximum.overflow ? UInt64.max : maximum.partialValue
        let finalBytes = await Task.detached {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var current = await memory()
            while current > maximumBytes, clock.now < deadline {
                try? await Task.sleep(for: interval)
                current = await memory()
            }
            return current
        }.value
        guard finalBytes <= maximumBytes else {
            throw HeavyweightModelGateError.memoryNotReleased(
                modelID: lease.modelID,
                currentBytes: finalBytes,
                maximumBytes: maximumBytes
            )
        }
        activeModel = nil
        return finalBytes
    }

    nonisolated static func measuredCurrentMemoryBytes() -> UInt64 {
        let mlx = Memory.snapshot()
        let mlxCurrent = UInt64(max(0, mlx.activeMemory + mlx.cacheMemory))
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        return max(footprint, mlxCurrent)
    }
}

actor HeavyweightLiveModelOwner {
    private let gate: HeavyweightModelGate
    private var workflowLease: HeavyweightWorkflowLease?
    private var modelLease: HeavyweightModelLease?
    private var releaseError: HeavyweightModelGateError?

    init(gate: HeavyweightModelGate = .shared) {
        self.gate = gate
    }

    func prepare(
        modelID: String,
        declaredPeakBytes: UInt64,
        load: @escaping @Sendable () async throws -> Void,
        unload: @escaping @Sendable () async -> Void
    ) async throws {
        if let releaseError { throw releaseError }
        if modelLease != nil {
            do {
                try await load()
            } catch let loadError {
                try await self.unload(unload)
                throw loadError
            }
            return
        }

        let workflow = try await gate.beginWorkflow(.live)
        workflowLease = workflow
        let model: HeavyweightModelLease
        do {
            model = try await gate.acquireModel(
                workflow: workflow,
                modelID: modelID,
                declaredPeakBytes: declaredPeakBytes
            )
        } catch {
            try? await gate.endWorkflow(workflow)
            workflowLease = nil
            throw error
        }
        modelLease = model
        do {
            try await load()
            try await gate.markLoaded(model)
        } catch let loadError {
            do {
                _ = try await gate.releaseModel(model, unload: unload)
                modelLease = nil
                try await gate.endWorkflow(workflow)
                workflowLease = nil
            } catch let gateError as HeavyweightModelGateError {
                releaseError = gateError
                throw gateError
            }
            throw loadError
        }
    }

    func unload(_ unload: @escaping @Sendable () async -> Void) async throws {
        guard let modelLease else {
            await unload()
            return
        }
        do {
            _ = try await gate.releaseModel(modelLease, unload: unload)
            self.modelLease = nil
            releaseError = nil
            if let workflowLease {
                try await gate.endWorkflow(workflowLease)
                self.workflowLease = nil
            }
        } catch let error as HeavyweightModelGateError {
            releaseError = error
            throw error
        }
    }
}
