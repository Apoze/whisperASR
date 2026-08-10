import Darwin
import Foundation
import MLX

enum HighQualityAlignmentSpeakerWorkerStage: String, Sendable {
    case alignment
    case diarization

    var argument: String { "--high-quality-\(rawValue)-worker" }
    var name: String { self == .alignment ? "Forced alignment" : "SpeakerKit" }
}

enum HighQualityAlignmentSpeakerWorkerError: LocalizedError, Equatable, Sendable {
    case criticalMemoryPressure(stage: String)
    case protocolFailure(stage: String, message: String)

    var errorDescription: String? {
        switch self {
        case .criticalMemoryPressure(let stage):
            "\(stage) stopped because macOS memory pressure became critical. Close other applications and retry; this failure is recoverable."
        case .protocolFailure(let stage, let message):
            "\(stage) worker failed: \(message)"
        }
    }
}

private struct HighQualityAlignmentSpeakerWorkerRequest: Codable {
    let audioFileName: String
    let sampleCount: Int
    let turns: [HighQualityTranslationTurn]?
    let useExclusiveReconciliation: Bool?
    let speakerCountPolicy: HighQualitySpeakerCountPolicy?
}

private struct HighQualityAlignmentSpeakerWorkerResponse: Codable {
    let ready: Bool?
    let alignment: HighQualityAlignmentExchange?
    let diarization: HighQualityDiarizationExchange?
    let errorMessage: String?
    let criticalMemoryPressure: Bool?

    static let ready = Self(
        ready: true,
        alignment: nil,
        diarization: nil,
        errorMessage: nil,
        criticalMemoryPressure: nil
    )
}

actor HighQualityAlignmentSpeakerWorkerClient {
    private let stage: HighQualityAlignmentSpeakerWorkerStage
    private let worker: HighQualityWorkerProcess

    init(
        stage: HighQualityAlignmentSpeakerWorkerStage,
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]),
        workingDirectory: URL? = nil,
        pressure: MacMemoryPressureMonitor = .shared,
        pollInterval: Duration = .milliseconds(100),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.stage = stage
        let directory = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "WhisperASR-\(stage.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        worker = HighQualityWorkerProcess(
            executableURL: executableURL,
            arguments: [stage.argument, directory.path],
            workingDirectory: directory,
            pressure: pressure,
            pollInterval: pollInterval,
            shutdownTimeout: shutdownTimeout
        )
    }

    var processIdentifier: Int32? { get async { await worker.processIdentifier } }
    var evidence: HighQualityWorkerEvidence? { get async { await worker.evidence } }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        do {
            let pid = try await worker.launch()
            progress(0, "\(stage.name) worker \(pid) starting…")
            let response: HighQualityAlignmentSpeakerWorkerResponse = try await worker.waitForJSON(
                at: worker.workingDirectory.appendingPathComponent("ready.json")
            )
            try await validate(response)
            guard response.ready == true else {
                throw error("invalid ready response")
            }
            progress(1, "\(stage.name) worker \(pid) ready")
        } catch is CancellationError {
            await worker.stop()
            throw CancellationError()
        } catch {
            await worker.stop(critical: await worker.isCritical)
            throw mapped(error)
        }
    }

    func align(
        samples: [Float],
        turns: [HighQualityTranslationTurn]
    ) async throws -> HighQualityAlignmentExchange {
        guard stage == .alignment else { throw error("wrong worker stage") }
        let response = try await request(
            samples: samples,
            turns: turns,
            useExclusiveReconciliation: nil,
            speakerCountPolicy: nil
        )
        guard let exchange = response.alignment else {
            throw error("missing alignment response")
        }
        try validateAlignment(exchange)
        return exchange
    }

    func diarize(
        samples: [Float],
        useExclusiveReconciliation: Bool,
        speakerCountPolicy: HighQualitySpeakerCountPolicy
    ) async throws -> HighQualityDiarizationExchange {
        guard stage == .diarization else { throw error("wrong worker stage") }
        let response = try await request(
            samples: samples,
            turns: nil,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerCountPolicy: speakerCountPolicy
        )
        guard let exchange = response.diarization else {
            throw error("missing diarization response")
        }
        try validateDiarization(
            exchange,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerCountPolicy: speakerCountPolicy
        )
        return exchange
    }

    func unload() async {
        await worker.stop(critical: await worker.isCritical)
        try? FileManager.default.removeItem(
            at: worker.workingDirectory.appendingPathComponent("audio.f32")
        )
    }

    private func request(
        samples: [Float],
        turns: [HighQualityTranslationTurn]?,
        useExclusiveReconciliation: Bool?,
        speakerCountPolicy: HighQualitySpeakerCountPolicy?
    ) async throws -> HighQualityAlignmentSpeakerWorkerResponse {
        if await worker.isCritical {
            throw HighQualityAlignmentSpeakerWorkerError.criticalMemoryPressure(
                stage: stage.name
            )
        }
        guard await worker.processIdentifier != nil else {
            throw error("process is not running")
        }
        let audioURL = worker.workingDirectory.appendingPathComponent("audio.f32")
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try audio.write(to: audioURL, options: .atomic)
        let request = HighQualityAlignmentSpeakerWorkerRequest(
            audioFileName: audioURL.lastPathComponent,
            sampleCount: samples.count,
            turns: turns,
            useExclusiveReconciliation: useExclusiveReconciliation,
            speakerCountPolicy: speakerCountPolicy
        )
        try JSONEncoder().encode(request).write(
            to: worker.workingDirectory.appendingPathComponent("request.json"),
            options: .atomic
        )
        do {
            let response: HighQualityAlignmentSpeakerWorkerResponse = try await worker.waitForJSON(
                at: worker.workingDirectory.appendingPathComponent("response.json")
            )
            try await validate(response)
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapped(error)
        }
    }

    private func validate(_ response: HighQualityAlignmentSpeakerWorkerResponse) async throws {
        let isCritical = await worker.isCritical
        if response.criticalMemoryPressure == true || isCritical {
            throw HighQualityAlignmentSpeakerWorkerError.criticalMemoryPressure(
                stage: stage.name
            )
        }
        if let message = response.errorMessage { throw error(message) }
    }

    private func validateAlignment(_ exchange: HighQualityAlignmentExchange) throws {
        guard exchange.modelID == HighQualityForcedAlignerRuntime.modelID,
              exchange.revision == HighQualityForcedAlignerRuntime.revision,
              exchange.configuration?["language"] == "Japanese",
              exchange.configuration?["sampleRate"] == "16000" else {
            throw error("alignment provenance does not match the pinned worker")
        }
    }

    private func validateDiarization(
        _ exchange: HighQualityDiarizationExchange,
        useExclusiveReconciliation: Bool,
        speakerCountPolicy: HighQualitySpeakerCountPolicy
    ) throws {
        let expectedConfiguration = [
            "runtimeRevision": HighQualitySpeakerKitRuntime.runtimeRevision,
            "precision": "quantized",
            "segmenterVariant": "W8A16",
            "embedderVariant": "W8A16",
            "speakerCount": speakerCountPolicy.expectedCount.map(String.init) ?? "automatic",
            "clusterDistanceThreshold": "library-default",
            "overlap": useExclusiveReconciliation ? "exclusive" : "non-exclusive",
            "attribution": "principal",
        ]
        guard exchange.modelID == HighQualitySpeakerKitRuntime.modelID,
              exchange.revision == HighQualitySpeakerKitRuntime.revision,
              exchange.useExclusiveReconciliation == useExclusiveReconciliation,
              exchange.speakerCountPolicy == speakerCountPolicy,
              expectedConfiguration.allSatisfy({ exchange.configuration?[$0.key] == $0.value })
        else {
            throw error("SpeakerKit provenance does not match the requested Standard settings")
        }
    }

    private func mapped(_ failure: Error) -> Error {
        guard let processError = failure as? HighQualityWorkerProcessError else {
            if failure is HighQualityAlignmentSpeakerWorkerError { return failure }
            return error(failure.localizedDescription)
        }
        switch processError {
        case .criticalMemoryPressure:
            return HighQualityAlignmentSpeakerWorkerError.criticalMemoryPressure(
                stage: stage.name
            )
        case .protocolFailure(let message):
            return error(message)
        }
    }

    private func error(_ message: String) -> HighQualityAlignmentSpeakerWorkerError {
        .protocolFailure(stage: stage.name, message: message)
    }
}

enum HighQualityAlignmentSpeakerWorkerCommand {
    static func stage(for argument: String) -> HighQualityAlignmentSpeakerWorkerStage? {
        [.alignment, .diarization].first { $0.argument == argument }
    }

    static func run(
        stage: HighQualityAlignmentSpeakerWorkerStage,
        directory: URL
    ) async -> Int32 {
        let parentPID = getppid()
        let pressure = MacMemoryPressureMonitor.shared
        signal(SIGTERM, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        let task = Task {
            switch stage {
            case .alignment:
                try await runAlignment(in: directory)
            case .diarization:
                try await runDiarization(in: directory)
            }
        }
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        termination.setEventHandler { task.cancel() }
        termination.resume()
        let warning = DispatchSource.makeSignalSource(signal: SIGUSR1)
        warning.setEventHandler { Memory.clearCache() }
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
            let response = HighQualityAlignmentSpeakerWorkerResponse(
                ready: nil,
                alignment: nil,
                diarization: nil,
                errorMessage: error.localizedDescription,
                criticalMemoryPressure: pressure.level == .critical
            )
            let name = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("request.json").path
            ) ? "response.json" : "ready.json"
            try? write(response, to: directory.appendingPathComponent(name))
            status = error is CancellationError ? 75 : 1
        }
        safety.cancel()
        termination.cancel()
        warning.cancel()
        return status
    }

    private static func runAlignment(in directory: URL) async throws {
        let runtime = HighQualityForcedAlignerRuntime()
        do {
            try await runtime.prepare(progress: { _, _ in })
            try write(.ready, to: directory.appendingPathComponent("ready.json"))
            let request = try await waitForRequest(in: directory)
            guard let turns = request.turns,
                  request.useExclusiveReconciliation == nil,
                  request.speakerCountPolicy == nil else {
                throw HighQualityAlignmentSpeakerWorkerError.protocolFailure(
                    stage: "Forced alignment",
                    message: "invalid request"
                )
            }
            let exchange = try await runtime.align(
                samples: try samples(for: request, in: directory),
                turns: turns
            )
            try write(.init(
                ready: nil,
                alignment: exchange,
                diarization: nil,
                errorMessage: nil,
                criticalMemoryPressure: nil
            ), to: directory.appendingPathComponent("response.json"))
            try await waitForShutdown(in: directory)
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    private static func runDiarization(in directory: URL) async throws {
        let runtime = HighQualitySpeakerKitRuntime()
        do {
            try await runtime.prepare(progress: { _, _ in })
            try write(.ready, to: directory.appendingPathComponent("ready.json"))
            let request = try await waitForRequest(in: directory)
            guard request.turns == nil,
                  let useExclusiveReconciliation = request.useExclusiveReconciliation,
                  let speakerCountPolicy = request.speakerCountPolicy else {
                throw HighQualityAlignmentSpeakerWorkerError.protocolFailure(
                    stage: "SpeakerKit",
                    message: "invalid request"
                )
            }
            let exchange = try await runtime.diarize(
                samples: try samples(for: request, in: directory),
                useExclusiveReconciliation: useExclusiveReconciliation,
                speakerCountPolicy: speakerCountPolicy
            )
            try write(.init(
                ready: nil,
                alignment: nil,
                diarization: exchange,
                errorMessage: nil,
                criticalMemoryPressure: nil
            ), to: directory.appendingPathComponent("response.json"))
            try await waitForShutdown(in: directory)
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    private static func waitForRequest(
        in directory: URL
    ) async throws -> HighQualityAlignmentSpeakerWorkerRequest {
        let url = directory.appendingPathComponent("request.json")
        while !FileManager.default.fileExists(atPath: url.path) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        return try JSONDecoder().decode(
            HighQualityAlignmentSpeakerWorkerRequest.self,
            from: Data(contentsOf: url)
        )
    }

    private static func waitForShutdown(in directory: URL) async throws {
        let path = directory.appendingPathComponent("shutdown").path
        while !FileManager.default.fileExists(atPath: path) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func samples(
        for request: HighQualityAlignmentSpeakerWorkerRequest,
        in directory: URL
    ) throws -> [Float] {
        guard request.sampleCount > 0,
              request.audioFileName == URL(fileURLWithPath: request.audioFileName)
                .lastPathComponent,
              request.sampleCount <= Int.max / MemoryLayout<Float>.size else {
            throw HighQualityAlignmentSpeakerWorkerError.protocolFailure(
                stage: "Heavyweight model",
                message: "invalid audio metadata"
            )
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(
            request.audioFileName
        ))
        guard data.count == request.sampleCount * MemoryLayout<Float>.size else {
            throw HighQualityAlignmentSpeakerWorkerError.protocolFailure(
                stage: "Heavyweight model",
                message: "audio payload size mismatch"
            )
        }
        var result = [Float](repeating: 0, count: request.sampleCount)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }

    private static func write(
        _ response: HighQualityAlignmentSpeakerWorkerResponse,
        to url: URL
    ) throws {
        try JSONEncoder().encode(response).write(to: url, options: .atomic)
    }
}
