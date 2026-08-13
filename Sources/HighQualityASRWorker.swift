import AudioCommon
import CryptoKit
import Darwin
import FluidAudio
import Foundation
import MLX

struct HighQualityASRWorkerEvidence: Codable, Equatable, Sendable {
    let backend: HighQualityASRBackend
    let model: HighQualityModelEvidence
    let lifecycle: HighQualityWorkerEvidence
}

enum HighQualityASRWorkerError: LocalizedError, Equatable, Sendable {
    case criticalMemoryPressure
    case backendFailure(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .criticalMemoryPressure:
            "Japanese ASR stopped because macOS memory pressure became critical. Close other applications and retry; this failure is recoverable."
        case .backendFailure(let message):
            "Japanese ASR failed: \(message)"
        case .protocolFailure(let message):
            "Japanese ASR worker failed: \(message)"
        }
    }
}

private struct HighQualityASRWorkerRequest: Codable {
    let audioFile: String
    let sampleCount: Int
    let anchored: Bool
}

private struct HighQualityASRWorkerResponse: Codable {
    let ready: Bool?
    let model: HighQualityModelEvidence?
    let exchange: HighQualityASRExchange?
    let error: String?
    let criticalMemoryPressure: Bool?
}

actor HighQualityASRWorkerClient {
    private let backend: HighQualityASRBackend
    private let worker: HighQualityWorkerProcess
    private var sequence = 0
    private var preparedModel: HighQualityModelEvidence?

    init(
        backend: HighQualityASRBackend,
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]),
        workingDirectory: URL? = nil,
        pressure: MacMemoryPressureMonitor = .shared,
        pollInterval: Duration = .milliseconds(100),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.backend = backend
        let directory = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "WhisperASR-ASR-\(backend.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        worker = HighQualityWorkerProcess(
            executableURL: executableURL,
            arguments: [
                HighQualityASRWorkerCommand.argument,
                backend.rawValue,
                directory.path,
            ],
            workingDirectory: directory,
            pressure: pressure,
            pollInterval: pollInterval,
            shutdownTimeout: shutdownTimeout
        )
    }

    var processIdentifier: Int32? { get async { await worker.processIdentifier } }

    var evidence: HighQualityASRWorkerEvidence? {
        get async {
            guard let lifecycle = await worker.evidence else { return nil }
            return .init(
                backend: backend,
                model: preparedModel ?? backend.model,
                lifecycle: lifecycle
            )
        }
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if await worker.processIdentifier != nil { return }
        let pid: Int32
        do {
            pid = try await worker.launch()
        } catch {
            throw Self.mapped(error)
        }
        progress(0, "\(backend.displayName) worker \(pid) starting…")
        do {
            let response: HighQualityASRWorkerResponse = try await worker.waitForJSON(
                at: worker.workingDirectory.appendingPathComponent("ready.json")
            )
            if response.criticalMemoryPressure == true {
                await worker.stop(critical: true)
                throw HighQualityASRWorkerError.criticalMemoryPressure
            }
            if let model = response.model,
               model.backend == backend,
               model.modelID == backend.model.modelID,
               model.revision == backend.model.revision,
               model.weightSHA256?.isEmpty == false {
                preparedModel = model
            }
            if let error = response.error {
                throw HighQualityASRWorkerError.backendFailure(error)
            }
            guard response.ready == true, preparedModel != nil else {
                throw HighQualityASRWorkerError.protocolFailure("invalid ready response")
            }
            progress(1, "\(backend.displayName) worker \(pid) ready")
        } catch {
            let critical = await worker.isCritical
            await worker.stop(critical: critical)
            throw critical ? HighQualityASRWorkerError.criticalMemoryPressure : Self.mapped(error)
        }
    }

    func transcribe(
        _ samples: [Float],
        anchored: Bool
    ) async throws -> HighQualityASRExchange {
        guard !(await worker.isCritical) else {
            throw HighQualityASRWorkerError.criticalMemoryPressure
        }
        guard await worker.processIdentifier != nil else {
            throw HighQualityASRWorkerError.protocolFailure("process is not running")
        }
        sequence += 1
        let audioFile = "audio-\(sequence).f32"
        let audioURL = worker.workingDirectory.appendingPathComponent(audioFile)
        let requestURL = worker.workingDirectory.appendingPathComponent("request-\(sequence).json")
        let responseURL = worker.workingDirectory.appendingPathComponent("response-\(sequence).json")
        let audioData = samples.withUnsafeBytes { Data($0) }
        try audioData.write(to: audioURL, options: .atomic)
        try JSONEncoder().encode(HighQualityASRWorkerRequest(
            audioFile: audioFile,
            sampleCount: samples.count,
            anchored: anchored
        )).write(to: requestURL, options: .atomic)

        let response: HighQualityASRWorkerResponse
        do {
            response = try await worker.waitForJSON(at: responseURL)
        } catch {
            if await worker.isCritical {
                throw HighQualityASRWorkerError.criticalMemoryPressure
            }
            throw Self.mapped(error)
        }
        let critical = await worker.isCritical
        if response.criticalMemoryPressure == true || critical {
            await worker.stop(critical: true)
            throw HighQualityASRWorkerError.criticalMemoryPressure
        }
        if let error = response.error {
            throw HighQualityASRWorkerError.backendFailure(error)
        }
        guard let exchange = response.exchange,
              Self.isValid(exchange, sampleCount: samples.count, anchored: anchored) else {
            throw HighQualityASRWorkerError.protocolFailure("invalid transcription response")
        }
        return exchange
    }

    func unload() async {
        let critical = await worker.isCritical
        await worker.stop(critical: critical)
    }

    private static func isValid(
        _ exchange: HighQualityASRExchange,
        sampleCount: Int,
        anchored: Bool
    ) -> Bool {
        guard anchored else { return exchange.chunks.isEmpty }
        let duration = Double(sampleCount) / 16_000
        guard exchange.rawTranscript == exchange.chunks.map(\.transcript).joined(separator: "\n")
        else { return false }
        return exchange.chunks.enumerated().allSatisfy { offset, chunk in
            chunk.index == offset
                && chunk.sourceStart >= 0
                && chunk.sourceEnd >= chunk.sourceStart
                && chunk.sourceEnd <= duration
                && !chunk.transcript.isEmpty
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? HighQualityASRWorkerError { return error }
        if let error = error as? HighQualityWorkerProcessError {
            switch error {
            case .criticalMemoryPressure:
                return HighQualityASRWorkerError.criticalMemoryPressure
            case .protocolFailure(let message):
                return HighQualityASRWorkerError.protocolFailure(message)
            }
        }
        return HighQualityASRWorkerError.protocolFailure(error.localizedDescription)
    }
}

enum HighQualityASRWeightEvidence {
    static func collect(for backend: HighQualityASRBackend) throws -> [String: String] {
        let directory: URL
        switch backend {
        case .qwenJA:
            directory = try HuggingFaceDownloader.getCacheDirectory(
                for: LocalPrototypeModelID.qwen
            )
        case .parakeetJA:
            directory = AsrModels.defaultCacheDirectory(for: .tdtJa)
        case .whisperKit:
            directory = ModelCatalog.modelDirectory
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(
                    LocalPrototypeModelID.whisperKitVariant,
                    isDirectory: true
                )
        }
        return try hashes(in: directory)
    }

    static func hashes(in directory: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else { return [:] }
        let files = enumerator.compactMap { $0 as? URL }.filter { url in
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                return false
            }
            return url.pathExtension == "safetensors"
                || (url.pathExtension == "bin"
                    && url.deletingLastPathComponent().lastPathComponent == "weights")
        }.sorted { $0.path < $1.path }

        return try Dictionary(uniqueKeysWithValues: files.map { url in
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let relative = resolved.pathComponents.dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            return (relative, try sha256(resolved))
        })
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private actor HighQualityASRWorkerRuntime {
    private let backend: HighQualityASRBackend
    private let qwen = QwenRuntime()
    private let parakeet = ParakeetRuntime()
    private let whisperKit = WhisperKitRuntime()

    init(backend: HighQualityASRBackend) {
        self.backend = backend
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        switch backend {
        case .qwenJA:
            try await qwen.prepare(progress: progress)
        case .parakeetJA:
            try await parakeet.prepare(progress: progress)
        case .whisperKit:
            try await whisperKit.prepare(progress: progress)
        }
    }

    func transcribe(_ samples: [Float], anchored: Bool) async throws -> HighQualityASRExchange {
        let transcribe: @Sendable ([Float]) async throws -> String
        switch backend {
        case .qwenJA:
            transcribe = {
                try await self.qwen.transcribe(
                    audio: $0,
                    language: "Japanese",
                    preserveRawOutput: true,
                    cancellable: true
                )
            }
        case .parakeetJA:
            transcribe = {
                try await self.parakeet.transcribe(
                    audio: $0,
                    preserveRawOutput: true,
                    cancellable: true
                )
            }
        case .whisperKit:
            transcribe = { try await self.whisperKit.transcribe(audio: $0) }
        }
        if anchored {
            return try await HighQualityJob.Services.chunkedASR(samples, transcribe: transcribe)
        }
        return try await .init(rawTranscript: transcribe(samples), chunks: [])
    }

    func unload() async {
        switch backend {
        case .qwenJA:
            await qwen.unload()
        case .parakeetJA:
            await parakeet.unload()
        case .whisperKit:
            await whisperKit.unload()
        }
    }

    func handleMemoryWarning() {
        if backend == .qwenJA { Memory.clearCache() }
    }
}

enum HighQualityASRWorkerCommand {
    static let argument = "--high-quality-asr-worker"

    static func run(backend: HighQualityASRBackend, directory: URL) async -> Int32 {
        let runtime = HighQualityASRWorkerRuntime(backend: backend)
        let parentPID = getppid()
        let pressure = MacMemoryPressureMonitor.shared
        signal(SIGTERM, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        let task = Task {
            let existingHashes = (try? HighQualityASRWeightEvidence.collect(for: backend)) ?? [:]
            do {
                try await runtime.prepare(progress: { _, _ in })
                let hashes = try HighQualityASRWeightEvidence.collect(for: backend)
                guard !hashes.isEmpty else {
                    throw HighQualityASRWorkerError.protocolFailure(
                        "no model weight hashes found"
                    )
                }
                try write(.init(
                    ready: true,
                    model: backend.model.withWeightSHA256(hashes),
                    exchange: nil,
                    error: nil,
                    criticalMemoryPressure: nil
                ), to: directory.appendingPathComponent("ready.json"))
            } catch {
                let failureHashes = pressure.level == .critical || error is CancellationError
                    ? existingHashes
                    : (try? HighQualityASRWeightEvidence.collect(for: backend)) ?? existingHashes
                try? write(.init(
                    ready: nil,
                    model: failureHashes.isEmpty
                        ? nil
                        : backend.model.withWeightSHA256(failureHashes),
                    exchange: nil,
                    error: error.localizedDescription,
                    criticalMemoryPressure: pressure.level == .critical
                ), to: directory.appendingPathComponent("ready.json"))
                throw error
            }

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
                let responseURL = directory.appendingPathComponent("response-\(sequence).json")
                do {
                    let request = try JSONDecoder().decode(
                        HighQualityASRWorkerRequest.self,
                        from: Data(contentsOf: requestURL)
                    )
                    let samples = try samples(for: request, in: directory)
                    let exchange = try await runtime.transcribe(
                        samples,
                        anchored: request.anchored
                    )
                    try write(.init(
                        ready: nil,
                        model: nil,
                        exchange: exchange,
                        error: nil,
                        criticalMemoryPressure: nil
                    ), to: responseURL)
                } catch {
                    try write(.init(
                        ready: nil,
                        model: nil,
                        exchange: nil,
                        error: error.localizedDescription,
                        criticalMemoryPressure: pressure.level == .critical
                    ), to: responseURL)
                }
                sequence += 1
            }
            try Task.checkCancellation()
        }

        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        termination.setEventHandler { task.cancel() }
        termination.resume()
        let warning = DispatchSource.makeSignalSource(signal: SIGUSR1)
        warning.setEventHandler { Task { await runtime.handleMemoryWarning() } }
        warning.resume()
        let safety = Task {
            while !Task.isCancelled {
                if getppid() != parentPID || pressure.level == .critical {
                    task.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let status: Int32
        do {
            try await task.value
            status = 0
        } catch {
            let readyURL = directory.appendingPathComponent("ready.json")
            if !FileManager.default.fileExists(atPath: readyURL.path) {
                try? write(.init(
                    ready: nil,
                    model: nil,
                    exchange: nil,
                    error: error.localizedDescription,
                    criticalMemoryPressure: pressure.level == .critical
                ), to: readyURL)
            }
            status = error is CancellationError ? 75 : 1
        }
        safety.cancel()
        termination.cancel()
        warning.cancel()
        await runtime.unload()
        return status
    }

    private static func samples(
        for request: HighQualityASRWorkerRequest,
        in directory: URL
    ) throws -> [Float] {
        guard request.sampleCount >= 0,
              request.audioFile == URL(fileURLWithPath: request.audioFile).lastPathComponent,
              !request.audioFile.contains("..") else {
            throw HighQualityASRWorkerError.protocolFailure("invalid audio request")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(request.audioFile))
        let byteCount = request.sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !byteCount.overflow, data.count == byteCount.partialValue else {
            throw HighQualityASRWorkerError.protocolFailure("invalid PCM length")
        }
        var samples = [Float](repeating: 0, count: request.sampleCount)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }

    private static func write(
        _ response: HighQualityASRWorkerResponse,
        to url: URL
    ) throws {
        try JSONEncoder().encode(response).write(to: url, options: .atomic)
    }
}
