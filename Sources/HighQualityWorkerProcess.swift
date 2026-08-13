import Darwin
import Foundation

struct HighQualityWorkerMemorySample: Codable, Equatable, Sendable {
    let at: Date
    let availableMemoryBytes: UInt64
}

struct HighQualityWorkerEvidence: Codable, Equatable, Sendable {
    let command: [String]
    let processIdentifier: Int32
    let startedAt: Date
    let exitedAt: Date
    let elapsedSeconds: TimeInterval
    let exitStatus: Int32
    let terminationReason: String
    let forcedTermination: Bool
    let peakPhysicalFootprintBytes: UInt64
    let pressureTransitions: [MacMemoryPressureTransition]
    let availableMemorySamples: [HighQualityWorkerMemorySample]
    let swapUsedBeforeBytes: UInt64?
    let swapUsedAfterBytes: UInt64?
    let rawLogPath: String
    let rawLog: String
}

typealias HighQualityTranslationWorkerMemorySample = HighQualityWorkerMemorySample
typealias HighQualityTranslationWorkerEvidence = HighQualityWorkerEvidence

enum HighQualityWorkerProcessError: Error, Equatable, Sendable {
    case criticalMemoryPressure
    case protocolFailure(String)
}

private final class HighQualityWorkerTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func record() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

actor HighQualityWorkerProcess {
    private let executableURL: URL
    private let arguments: [String]
    nonisolated let workingDirectory: URL
    private let pressure: MacMemoryPressureMonitor
    private let pollInterval: Duration
    private let shutdownTimeout: Duration
    private var process: Process?
    private var termination: HighQualityWorkerTermination?
    private var logHandle: FileHandle?
    private var monitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pressureLevel = MacMemoryPressureLevel.normal
    private var peakPhysicalFootprintBytes: UInt64 = 0
    private var memorySamples: [HighQualityWorkerMemorySample] = []
    private var swapUsedBeforeBytes: UInt64?
    private var forcedTermination = false
    private var criticalPressure = false
    private var stopping = false
    private(set) var evidence: HighQualityWorkerEvidence?

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        pressure: MacMemoryPressureMonitor,
        pollInterval: Duration,
        shutdownTimeout: Duration
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.pressure = pressure
        self.pollInterval = pollInterval
        self.shutdownTimeout = shutdownTimeout
    }

    var processIdentifier: Int32? {
        guard termination?.isFinished != true else { return nil }
        return process?.processIdentifier
    }

    var isCritical: Bool { criticalPressure || pressure.level == .critical }

    func launch() async throws -> Int32 {
        if let process, termination?.isFinished != true { return process.processIdentifier }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let logURL = workingDirectory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.standardOutput = log
        child.standardError = log
        let termination = HighQualityWorkerTermination()
        child.terminationHandler = { _ in termination.record() }
        try await waitForLaunchPressure()
        startedAt = Date()
        pressureLevel = .normal
        peakPhysicalFootprintBytes = 0
        memorySamples = []
        swapUsedBeforeBytes = Self.swapUsedBytes()
        forcedTermination = false
        criticalPressure = false
        evidence = nil
        logHandle = log
        process = child
        self.termination = termination
        do {
            try child.run()
        } catch {
            process = nil
            self.termination = nil
            try? log.close()
            logHandle = nil
            throw HighQualityWorkerProcessError.protocolFailure(error.localizedDescription)
        }
        sample(child.processIdentifier)
        monitorTask = Task { await monitor(child.processIdentifier) }
        return child.processIdentifier
    }

    func waitForJSON<Value: Decodable>(at url: URL) async throws -> Value {
        let clock = ContinuousClock()
        var invalidData: Data?
        var invalidSince: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                do {
                    return try JSONDecoder().decode(Value.self, from: data)
                } catch {
                    if termination?.isFinished == true || (process == nil && evidence != nil) {
                        if let child = process {
                            finish(process: child, forced: forcedTermination)
                        }
                        if criticalPressure {
                            throw HighQualityWorkerProcessError.criticalMemoryPressure
                        }
                        throw error
                    }
                    if invalidData == data, let invalidSince,
                       invalidSince.duration(to: clock.now) >= .milliseconds(50) {
                        throw error
                    }
                    if invalidData != data {
                        invalidData = data
                        invalidSince = clock.now
                    }
                }
            }
            if termination?.isFinished == true || (process == nil && evidence != nil) {
                if let child = process {
                    finish(process: child, forced: forcedTermination)
                }
                if criticalPressure {
                    throw HighQualityWorkerProcessError.criticalMemoryPressure
                }
                throw HighQualityWorkerProcessError.protocolFailure(
                    "process exited before replying"
                )
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    func stop(critical: Bool = false) async {
        if critical { criticalPressure = true }
        guard let child = process, let termination else { return }
        guard !stopping else {
            await waitForExit(termination, timeout: max(shutdownTimeout, .seconds(1)))
            if termination.isFinished { finish(process: child, forced: forcedTermination) }
            return
        }
        stopping = true
        if !termination.isFinished {
            if criticalPressure {
                _ = kill(child.processIdentifier, SIGTERM)
            } else {
                try? Data().write(
                    to: workingDirectory.appendingPathComponent("shutdown"),
                    options: .atomic
                )
            }
            await waitForExit(termination, timeout: shutdownTimeout)
        }
        if !termination.isFinished, !criticalPressure {
            _ = kill(child.processIdentifier, SIGTERM)
            await waitForExit(termination, timeout: shutdownTimeout)
        }
        if !termination.isFinished {
            forcedTermination = true
            _ = kill(child.processIdentifier, SIGKILL)
            await waitForExit(termination, timeout: max(shutdownTimeout, .seconds(1)))
        }
        guard termination.isFinished else {
            stopping = false
            return
        }
        finish(process: child, forced: forcedTermination)
    }

    private func monitor(_ pid: Int32) async {
        while process?.processIdentifier == pid, termination?.isFinished != true, !stopping {
            sample(pid)
            let level = pressure.level
            if level != pressureLevel {
                pressureLevel = level
                switch level {
                case .normal:
                    break
                case .warning:
                    _ = kill(pid, SIGUSR1)
                case .critical:
                    await stop(critical: true)
                    return
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
        if process?.processIdentifier == pid, !stopping,
           let process, termination?.isFinished == true {
            finish(process: process, forced: forcedTermination)
        }
    }

    private func waitForExit(
        _ termination: HighQualityWorkerTermination,
        timeout: Duration
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !termination.isFinished, clock.now < deadline {
            if let pid = process?.processIdentifier { sample(pid) }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func waitForLaunchPressure() async throws {
        while pressure.level == .warning {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
        }
        guard pressure.level != .critical else {
            criticalPressure = true
            throw HighQualityWorkerProcessError.criticalMemoryPressure
        }
    }

    private func sample(_ pid: Int32) {
        peakPhysicalFootprintBytes = max(
            peakPhysicalFootprintBytes,
            Self.physicalFootprintBytes(pid: pid) ?? 0
        )
        memorySamples.append(.init(
            at: Date(),
            availableMemoryBytes: HeavyweightModelGate.measuredSystemAvailableMemoryBytes()
        ))
    }

    private func finish(process child: Process, forced: Bool) {
        guard process === child else { return }
        let finishedAt = Date()
        let beganAt = startedAt ?? finishedAt
        try? logHandle?.close()
        logHandle = nil
        let logURL = workingDirectory.appendingPathComponent("worker.log")
        let rawLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        evidence = .init(
            command: [executableURL.path] + arguments,
            processIdentifier: child.processIdentifier,
            startedAt: beganAt,
            exitedAt: finishedAt,
            elapsedSeconds: finishedAt.timeIntervalSince(beganAt),
            exitStatus: child.terminationStatus,
            terminationReason: child.terminationReason == .exit ? "exit" : "uncaught-signal",
            forcedTermination: forced,
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            pressureTransitions: pressure.transitions(since: beganAt),
            availableMemorySamples: memorySamples,
            swapUsedBeforeBytes: swapUsedBeforeBytes,
            swapUsedAfterBytes: Self.swapUsedBytes(),
            rawLogPath: logURL.path,
            rawLog: rawLog
        )
        monitorTask?.cancel()
        monitorTask = nil
        process = nil
        termination = nil
        stopping = false
    }

    private nonisolated static func physicalFootprintBytes(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            UnsafeMutableRawPointer(pointer).withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    private nonisolated static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let status = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return status == 0 ? usage.xsu_used : nil
    }
}
