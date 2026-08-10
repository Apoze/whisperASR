import Darwin
import Foundation

struct HighQualityTranslationWorkerMemorySample: Codable, Equatable, Sendable {
    let at: Date
    let availableMemoryBytes: UInt64
}

struct HighQualityTranslationWorkerEvidence: Codable, Equatable, Sendable {
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
    let availableMemorySamples: [HighQualityTranslationWorkerMemorySample]
    let swapUsedBeforeBytes: UInt64?
    let swapUsedAfterBytes: UInt64?
    let rawLogPath: String
    let rawLog: String
}

enum HighQualityTranslationWorkerError: LocalizedError, Equatable, Sendable {
    case criticalMemoryPressure
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .criticalMemoryPressure:
            "TranslateGemma stopped because macOS memory pressure became critical. Close other applications and retry; this failure is recoverable."
        case .protocolFailure(let message):
            "TranslateGemma worker failed: \(message)"
        }
    }
}

private struct HighQualityTranslationWorkerResponse: Codable {
    let ready: Bool?
    let exchange: HighQualityTranslationExchange?
    let error: HighQualityTranslationServiceError?
    let criticalMemoryPressure: Bool?

    static let ready = Self(
        ready: true,
        exchange: nil,
        error: nil,
        criticalMemoryPressure: nil
    )
}

actor HighQualityTranslationWorkerClient {
    private let executableURL: URL
    private let workingDirectory: URL
    private let pressure: MacMemoryPressureMonitor
    private let pollInterval: Duration
    private let shutdownTimeout: Duration
    private var process: Process?
    private var logHandle: FileHandle?
    private var monitorTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pressureLevel = MacMemoryPressureLevel.normal
    private var sequence = 0
    private var peakPhysicalFootprintBytes: UInt64 = 0
    private var memorySamples: [HighQualityTranslationWorkerMemorySample] = []
    private var swapUsedBeforeBytes: UInt64?
    private var forcedTermination = false
    private var criticalPressure = false
    private var stopping = false
    private(set) var evidence: HighQualityTranslationWorkerEvidence?

    init(
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]),
        workingDirectory: URL? = nil,
        pressure: MacMemoryPressureMonitor = .shared,
        pollInterval: Duration = .milliseconds(100),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "WhisperASR-TranslateGemma-\(UUID().uuidString)",
                isDirectory: true
            )
        self.pressure = pressure
        self.pollInterval = pollInterval
        self.shutdownTimeout = shutdownTimeout
    }

    var processIdentifier: Int32? {
        guard process?.isRunning == true else { return nil }
        return process?.processIdentifier
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if process?.isRunning == true { return }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let logURL = workingDirectory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let child = Process()
        child.executableURL = executableURL
        child.arguments = [HighQualityTranslationWorkerCommand.argument, workingDirectory.path]
        child.standardOutput = log
        child.standardError = log
        try await waitForLaunchPressure()
        startedAt = Date()
        pressureLevel = .normal
        swapUsedBeforeBytes = Self.swapUsedBytes()
        logHandle = log
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            try? log.close()
            logHandle = nil
            throw HighQualityTranslationWorkerError.protocolFailure(error.localizedDescription)
        }
        progress(0, "TranslateGemma worker \(child.processIdentifier) starting…")
        sample(child.processIdentifier)
        monitorTask = Task { await monitor(child.processIdentifier) }
        do {
            let response: HighQualityTranslationWorkerResponse = try await waitForJSON(
                at: workingDirectory.appendingPathComponent("ready.json")
            )
            if response.criticalMemoryPressure == true {
                criticalPressure = true
                throw HighQualityTranslationWorkerError.criticalMemoryPressure
            }
            if let error = response.error { throw error }
            guard response.ready == true else {
                throw HighQualityTranslationWorkerError.protocolFailure("invalid ready response")
            }
            progress(1, "TranslateGemma worker \(child.processIdentifier) ready")
        } catch {
            if pressure.level == .critical { criticalPressure = true }
            await stop(critical: criticalPressure)
            throw criticalPressure
                ? HighQualityTranslationWorkerError.criticalMemoryPressure
                : error
        }
    }

    func translate(
        _ batch: HighQualityTranslationBatch
    ) async throws -> HighQualityTranslationExchange {
        guard !criticalPressure else {
            throw HighQualityTranslationWorkerError.criticalMemoryPressure
        }
        guard process?.isRunning == true else {
            throw HighQualityTranslationWorkerError.protocolFailure("process is not running")
        }
        sequence += 1
        let requestURL = workingDirectory.appendingPathComponent("request-\(sequence).json")
        let responseURL = workingDirectory.appendingPathComponent("response-\(sequence).json")
        try JSONEncoder().encode(batch).write(to: requestURL, options: .atomic)
        let response: HighQualityTranslationWorkerResponse
        do {
            response = try await waitForJSON(at: responseURL)
        } catch {
            if pressure.level == .critical { criticalPressure = true }
            if criticalPressure {
                throw HighQualityTranslationWorkerError.criticalMemoryPressure
            }
            throw error
        }
        if response.criticalMemoryPressure == true || pressure.level == .critical {
            criticalPressure = true
            await stop(critical: true)
            if let error = response.error {
                throw HighQualityTranslationServiceError(
                    model: error.model,
                    attempts: error.attempts,
                    response: error.response,
                    revision: error.revision,
                    runtimeVersion: error.runtimeVersion,
                    batches: error.batches,
                    peakMemoryBytes: error.peakMemoryBytes,
                    message: HighQualityTranslationWorkerError.criticalMemoryPressure
                        .localizedDescription
                )
            }
            throw HighQualityTranslationWorkerError.criticalMemoryPressure
        }
        if let error = response.error { throw error }
        guard let exchange = response.exchange else {
            throw HighQualityTranslationWorkerError.protocolFailure("missing translation response")
        }
        return exchange
    }

    func unload() async {
        await stop(critical: criticalPressure)
    }

    private func monitor(_ pid: Int32) async {
        while process?.processIdentifier == pid, process?.isRunning == true, !stopping {
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
                    criticalPressure = true
                    await stop(critical: true)
                    return
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
        if process?.processIdentifier == pid, process?.isRunning == false, !stopping {
            finish(process: process!, forced: forcedTermination)
        }
    }

    private func stop(critical: Bool) async {
        guard let child = process else { return }
        guard !stopping else {
            while process != nil { try? await Task.sleep(for: pollInterval) }
            return
        }
        stopping = true
        if child.isRunning {
            if critical {
                _ = kill(child.processIdentifier, SIGTERM)
            } else {
                try? Data().write(
                    to: workingDirectory.appendingPathComponent("shutdown"),
                    options: .atomic
                )
            }
            await waitForExit(child, timeout: shutdownTimeout)
        }
        if child.isRunning, !critical {
            _ = kill(child.processIdentifier, SIGTERM)
            await waitForExit(child, timeout: shutdownTimeout)
        }
        if child.isRunning {
            forcedTermination = true
            _ = kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
        finish(process: child, forced: forcedTermination)
    }

    private func waitForExit(_ child: Process, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while child.isRunning, clock.now < deadline {
            sample(child.processIdentifier)
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func waitForJSON<Value: Decodable>(at url: URL) async throws -> Value {
        while true {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
            }
            if process?.isRunning != true {
                if let child = process { finish(process: child, forced: forcedTermination) }
                if criticalPressure {
                    throw HighQualityTranslationWorkerError.criticalMemoryPressure
                }
                throw HighQualityTranslationWorkerError.protocolFailure("process exited before replying")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func waitForLaunchPressure() async throws {
        while pressure.level == .warning {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
        }
        guard pressure.level != .critical else {
            criticalPressure = true
            throw HighQualityTranslationWorkerError.criticalMemoryPressure
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
            command: [executableURL.path, HighQualityTranslationWorkerCommand.argument, workingDirectory.path],
            processIdentifier: child.processIdentifier,
            startedAt: beganAt,
            exitedAt: finishedAt,
            elapsedSeconds: finishedAt.timeIntervalSince(beganAt),
            exitStatus: child.terminationStatus,
            terminationReason: child.terminationReason == .exit
                ? "exit"
                : "uncaught-signal",
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

enum HighQualityTranslationWorkerCommand {
    static let argument = "--high-quality-translation-worker"

    static func run(directory: URL) async -> Int32 {
        let translator = LocalMLXTranslator()
        let parentPID = getppid()
        let pressure = MacMemoryPressureMonitor.shared
        signal(SIGTERM, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        let task = Task {
            try await translator.prepare(progress: { _, _ in })
            try write(.ready, to: directory.appendingPathComponent("ready.json"))
            var sequence = 1
            while !Task.isCancelled {
                if FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("shutdown").path
                ) { break }
                let requestURL = directory.appendingPathComponent("request-\(sequence).json")
                guard FileManager.default.fileExists(atPath: requestURL.path) else {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let batch = try JSONDecoder().decode(
                    HighQualityTranslationBatch.self,
                    from: Data(contentsOf: requestURL)
                )
                let responseURL = directory.appendingPathComponent("response-\(sequence).json")
                do {
                    let exchange = try await translator.translate(batch)
                    try write(
                        .init(
                            ready: nil,
                            exchange: exchange,
                            error: nil,
                            criticalMemoryPressure: nil
                        ),
                        to: responseURL
                    )
                } catch let error as HighQualityTranslationServiceError {
                    try write(.init(
                        ready: nil,
                        exchange: nil,
                        error: error,
                        criticalMemoryPressure: pressure.level == .critical
                    ), to: responseURL)
                }
                sequence += 1
            }
        }

        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        termination.setEventHandler { task.cancel() }
        termination.resume()
        let warning = DispatchSource.makeSignalSource(signal: SIGUSR1)
        warning.setEventHandler { Task { await translator.handleMemoryWarning() } }
        warning.resume()
        let safety = Task {
            var previous = MacMemoryPressureLevel.normal
            while !Task.isCancelled {
                if getppid() != parentPID || pressure.level == .critical {
                    task.cancel()
                    return
                }
                if pressure.level == .warning, previous != .warning {
                    await translator.handleMemoryWarning()
                }
                previous = pressure.level
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let status: Int32
        do {
            try await task.value
            status = 0
        } catch {
            let response = HighQualityTranslationWorkerResponse(
                ready: nil,
                exchange: nil,
                error: error as? HighQualityTranslationServiceError ?? .init(
                    model: LocalMLXTranslator.modelID,
                    attempts: [],
                    response: nil,
                    revision: LocalMLXTranslator.revision,
                    runtimeVersion: LocalMLXTranslator.runtimeVersion,
                    message: error.localizedDescription
                ),
                criticalMemoryPressure: pressure.level == .critical
            )
            try? write(response, to: directory.appendingPathComponent("ready.json"))
            status = error is CancellationError ? 75 : 1
        }
        safety.cancel()
        termination.cancel()
        warning.cancel()
        await translator.unload()
        return status
    }

    private static func write(
        _ response: HighQualityTranslationWorkerResponse,
        to url: URL
    ) throws {
        try JSONEncoder().encode(response).write(to: url, options: .atomic)
    }
}
