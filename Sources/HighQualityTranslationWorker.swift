import Darwin
import Foundation

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
    private let worker: HighQualityWorkerProcess
    private var sequence = 0

    init(
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]),
        workingDirectory: URL? = nil,
        pressure: MacMemoryPressureMonitor = .shared,
        pollInterval: Duration = .milliseconds(100),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        let directory = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "WhisperASR-TranslateGemma-\(UUID().uuidString)",
                isDirectory: true
            )
        worker = HighQualityWorkerProcess(
            executableURL: executableURL,
            arguments: [HighQualityTranslationWorkerCommand.argument, directory.path],
            workingDirectory: directory,
            pressure: pressure,
            pollInterval: pollInterval,
            shutdownTimeout: shutdownTimeout
        )
    }

    var processIdentifier: Int32? { get async { await worker.processIdentifier } }

    var evidence: HighQualityTranslationWorkerEvidence? {
        get async { await worker.evidence }
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if await worker.processIdentifier != nil { return }
        let pid: Int32
        do {
            pid = try await worker.launch()
        } catch {
            throw Self.mapped(error)
        }
        progress(0, "TranslateGemma worker \(pid) starting…")
        do {
            let response: HighQualityTranslationWorkerResponse = try await worker.waitForJSON(
                at: worker.workingDirectory.appendingPathComponent("ready.json")
            )
            if response.criticalMemoryPressure == true {
                await worker.stop(critical: true)
                throw HighQualityTranslationWorkerError.criticalMemoryPressure
            }
            if let error = response.error { throw error }
            guard response.ready == true else {
                throw HighQualityTranslationWorkerError.protocolFailure("invalid ready response")
            }
            progress(1, "TranslateGemma worker \(pid) ready")
        } catch {
            let critical = await worker.isCritical
            await worker.stop(critical: critical)
            throw critical ? HighQualityTranslationWorkerError.criticalMemoryPressure : Self.mapped(error)
        }
    }

    func translate(
        _ batch: HighQualityTranslationBatch
    ) async throws -> HighQualityTranslationExchange {
        guard !(await worker.isCritical) else {
            throw HighQualityTranslationWorkerError.criticalMemoryPressure
        }
        guard await worker.processIdentifier != nil else {
            throw HighQualityTranslationWorkerError.protocolFailure("process is not running")
        }
        sequence += 1
        let requestURL = worker.workingDirectory.appendingPathComponent("request-\(sequence).json")
        let responseURL = worker.workingDirectory.appendingPathComponent("response-\(sequence).json")
        try JSONEncoder().encode(batch).write(to: requestURL, options: .atomic)
        let response: HighQualityTranslationWorkerResponse
        do {
            response = try await worker.waitForJSON(at: responseURL)
        } catch {
            if await worker.isCritical {
                throw HighQualityTranslationWorkerError.criticalMemoryPressure
            }
            throw Self.mapped(error)
        }
        let critical = await worker.isCritical
        if response.criticalMemoryPressure == true || critical {
            await worker.stop(critical: true)
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
        let critical = await worker.isCritical
        await worker.stop(critical: critical)
    }

    private static func mapped(_ error: Error) -> Error {
        guard let error = error as? HighQualityWorkerProcessError else { return error }
        switch error {
        case .criticalMemoryPressure:
            return HighQualityTranslationWorkerError.criticalMemoryPressure
        case .protocolFailure(let message):
            return HighQualityTranslationWorkerError.protocolFailure(message)
        }
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
