import Foundation

enum HighQualityDeliverable: String, Codable, CaseIterable, Hashable, Sendable {
    case japaneseTranscript = "japanese-transcript"
}

enum HighQualityASRBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwenJA = "qwen-ja"
    case parakeetJA = "parakeet-ja"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .qwenJA: "Qwen JA"
        case .parakeetJA: "Parakeet JA"
        }
    }

    var model: HighQualityModelEvidence {
        switch self {
        case .qwenJA:
            .init(
                backend: self,
                modelID: LocalPrototypeModelID.qwen,
                revision: LocalPrototypeModelID.qwenRevision
            )
        case .parakeetJA:
            .init(
                backend: self,
                modelID: LocalPrototypeModelID.parakeet,
                revision: LocalPrototypeModelID.parakeetRevision
            )
        }
    }
}

enum HighQualityJobDependency: String, Codable, Sendable {
    case sourceAcquisition = "source-acquisition"
    case sourceNormalization = "source-normalization"
    case japaneseASR = "japanese-asr"
    case export
}

enum HighQualityJobStage: String, Codable, Sendable {
    case validating
    case acquiringSource = "acquiring-source"
    case normalizingSource = "normalizing-source"
    case preparingASR = "preparing-asr"
    case transcribing
    case exporting
    case completed
    case cancelled
    case failed
}

enum HighQualityJobFailureStage: String, Codable, Sendable {
    case acquisition
    case source
    case application
    case modelPreparation = "model-preparation"
    case asr
    case export
    case cancelled
}

struct HighQualityJobProgress: Equatable, Sendable {
    let stage: HighQualityJobStage
    let fraction: Double
    let message: String
}

struct HighQualityJobRequest: Sendable {
    let id: UUID
    let sourceURL: URL
    let deliverables: Set<HighQualityDeliverable>
    let backend: HighQualityASRBackend
    let speakerLabels: Bool
    let outputRoot: URL

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        deliverables: Set<HighQualityDeliverable>,
        backend: HighQualityASRBackend = .qwenJA,
        speakerLabels: Bool = false,
        outputRoot: URL = AppStoragePaths.highQualityJobs
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.deliverables = deliverables
        self.backend = backend
        self.speakerLabels = speakerLabels
        self.outputRoot = outputRoot
    }
}

struct HighQualityJobFailure: Codable, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
}

struct HighQualitySourceProvenance: Codable, Equatable, Sendable {
    let path: String
    let fileName: String
    let byteCount: UInt64?
    let modifiedAt: Date?
    let sourceURL: String?
    let youtube: HighQualityYouTubeEvidence?
}

struct HighQualityYouTubeEvidence: Codable, Equatable, Sendable {
    let sourceURL: String
    let title: String
    let channel: String
    let description: String
    let ytDLPVersion: String
    let diagnostics: String
}

struct HighQualityYouTubeAcquisition: Sendable {
    let audioURL: URL
    let evidence: HighQualityYouTubeEvidence
}

struct HighQualityModelEvidence: Codable, Equatable, Sendable {
    let backend: HighQualityASRBackend
    let modelID: String
    let revision: String
}

struct HighQualityModelEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case loadStarted = "load-started"
        case loadCompleted = "load-completed"
        case unloadCompleted = "unload-completed"
    }

    let kind: Kind
    let backend: HighQualityASRBackend
    let at: Date
}

struct HighQualityGeneratedFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case deliverable
        case evidence
        case manifest
    }

    let path: String
    let kind: Kind
}

struct HighQualityJobManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
    }

    let schemaVersion: Int
    let jobID: UUID
    var status: Status
    var source: HighQualitySourceProvenance
    let deliverables: [HighQualityDeliverable]
    let selectedBackend: HighQualityASRBackend
    let speakerLabels: Bool
    let dependencies: [HighQualityJobDependency]
    let model: HighQualityModelEvidence
    let startedAt: Date
    var finishedAt: Date?
    var stageDurations: [HighQualityJobStage: TimeInterval]
    var peakMemoryBytes: UInt64
    var modelEvents: [HighQualityModelEvent]
    var failures: [HighQualityJobFailure]
    var generatedFiles: [HighQualityGeneratedFile]
}

struct HighQualityRawEvidence: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let model: HighQualityModelEvidence
    let rawASR: String?
    let sampleRate: Int
    let sampleCount: Int
    let stageDurations: [HighQualityJobStage: TimeInterval]
    let peakMemoryBytes: UInt64
    let modelEvents: [HighQualityModelEvent]
    let failures: [HighQualityJobFailure]
    let generatedFiles: [HighQualityGeneratedFile]
}

struct HighQualityJobResult: Sendable {
    let directory: URL
    let japaneseTranscript: String
    let manifest: HighQualityJobManifest
    let evidence: HighQualityRawEvidence
}

struct HighQualityJobError: LocalizedError, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
    let resultDirectory: URL?

    var errorDescription: String? { message }
}

struct HighQualityJob: Sendable {
    struct Services: Sendable {
        let loadSource: @Sendable (URL) async throws -> [Float]
        let acquireYouTube: @Sendable (URL, URL) async throws -> HighQualityYouTubeAcquisition
        let prepareASR: @Sendable (
            @escaping @Sendable (Double, String) -> Void
        ) async throws -> Void
        let transcribeJapanese: @Sendable ([Float]) async throws -> String
        let unloadASR: @Sendable () async -> Void
        let currentMemoryBytes: @Sendable () async -> UInt64

        init(
            loadSource: @escaping @Sendable (URL) async throws -> [Float],
            acquireYouTube: @escaping @Sendable (
                URL,
                URL
            ) async throws -> HighQualityYouTubeAcquisition = { _, _ in
                throw HighQualityJobError(
                    stage: .acquisition,
                    message: "YouTube acquisition is not configured.",
                    resultDirectory: nil
                )
            },
            prepareASR: @escaping @Sendable (
                @escaping @Sendable (Double, String) -> Void
            ) async throws -> Void,
            transcribeJapanese: @escaping @Sendable ([Float]) async throws -> String,
            unloadASR: @escaping @Sendable () async -> Void,
            currentMemoryBytes: @escaping @Sendable () async -> UInt64 = { 0 }
        ) {
            self.loadSource = loadSource
            self.acquireYouTube = acquireYouTube
            self.prepareASR = prepareASR
            self.transcribeJapanese = transcribeJapanese
            self.unloadASR = unloadASR
            self.currentMemoryBytes = currentMemoryBytes
        }

        static func production(for backend: HighQualityASRBackend) -> Self {
            let loadSource: @Sendable (URL) async throws -> [Float] = {
                try await AudioLoader.loadSamples(url: $0)
            }
            let acquireYouTube: @Sendable (
                URL,
                URL
            ) async throws -> HighQualityYouTubeAcquisition = {
                try await YouTubeAcquirer.acquire($0, to: $1)
            }
            switch backend {
            case .qwenJA:
                let runtime = QwenRuntime()
                return Self(
                    loadSource: loadSource,
                    acquireYouTube: acquireYouTube,
                    prepareASR: { try await runtime.prepare(progress: $0) },
                    transcribeJapanese: {
                        try await runtime.transcribe(
                            audio: $0,
                            language: "Japanese",
                            preserveRawOutput: true,
                            cancellable: true
                        )
                    },
                    unloadASR: { await runtime.unload() },
                    currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() }
                )
            case .parakeetJA:
                let runtime = ParakeetRuntime()
                return Self(
                    loadSource: loadSource,
                    acquireYouTube: acquireYouTube,
                    prepareASR: { try await runtime.prepare(progress: $0) },
                    transcribeJapanese: {
                        try await runtime.transcribe(
                            audio: $0,
                            preserveRawOutput: true,
                            cancellable: true
                        )
                    },
                    unloadASR: { await runtime.unload() },
                    currentMemoryBytes: { LocalEnglishModelManager.measuredMemoryBytes() }
                )
            }
        }
    }

    private let servicesForBackend: @Sendable (HighQualityASRBackend) -> Services

    init() {
        servicesForBackend = { Services.production(for: $0) }
    }

    init(services: Services) {
        servicesForBackend = { _ in services }
    }

    init(servicesForBackend: @escaping @Sendable (HighQualityASRBackend) -> Services) {
        self.servicesForBackend = servicesForBackend
    }

    func run(
        _ request: HighQualityJobRequest,
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
    ) async throws -> HighQualityJobResult {
        let services = servicesForBackend(request.backend)
        let isYouTubeSource = !request.sourceURL.isFileURL
        guard !request.deliverables.isEmpty else {
            throw HighQualityJobError(
                stage: .application,
                message: "Select at least one Deliverable before starting.",
                resultDirectory: nil
            )
        }
        guard !request.speakerLabels else {
            throw HighQualityJobError(
                stage: .application,
                message: "Speaker labels are not available for this Japanese transcript job yet.",
                resultDirectory: nil
            )
        }
        if isYouTubeSource {
            try Self.validateYouTubeURL(request.sourceURL)
        }

        let directory = request.outputRoot.appendingPathComponent(
            request.id.uuidString,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw HighQualityJobError(
                stage: .application,
                message: "Could not create the job result directory: \(error.localizedDescription)",
                resultDirectory: nil
            )
        }

        let startedAt = Date()
        var currentStage = HighQualityJobStage.validating
        var stageStartedAt = startedAt
        var sampleCount = 0
        var rawASR: String?
        var transcriptWritten = false
        var acquiredAudioURL: URL?
        var asrLoadStarted = false
        var asrUnloaded = false
        var manifest = HighQualityJobManifest(
            schemaVersion: 1,
            jobID: request.id,
            status: .failed,
            source: Self.provenance(for: request.sourceURL),
            deliverables: request.deliverables.sorted { $0.rawValue < $1.rawValue },
            selectedBackend: request.backend,
            speakerLabels: request.speakerLabels,
            dependencies: isYouTubeSource
                ? [.sourceAcquisition, .sourceNormalization, .japaneseASR, .export]
                : [.sourceNormalization, .japaneseASR, .export],
            model: request.backend.model,
            startedAt: startedAt,
            finishedAt: nil,
            stageDurations: [:],
            peakMemoryBytes: 0,
            modelEvents: [],
            failures: [],
            generatedFiles: []
        )

        func begin(_ stage: HighQualityJobStage, fraction: Double, message: String) {
            let now = Date()
            if currentStage != .validating {
                manifest.stageDurations[currentStage, default: 0] += now.timeIntervalSince(stageStartedAt)
            }
            currentStage = stage
            stageStartedAt = now
            progress(.init(stage: stage, fraction: fraction, message: message))
        }

        do {
            var normalizedSourceURL = request.sourceURL
            if isYouTubeSource {
                begin(.acquiringSource, fraction: 0.02, message: "Acquiring YouTube audio…")
                let acquisitionDirectory = directory.appendingPathComponent(
                    "acquisition",
                    isDirectory: true
                )
                do {
                    let acquisition = try await services.acquireYouTube(
                        request.sourceURL,
                        acquisitionDirectory
                    )
                    normalizedSourceURL = acquisition.audioURL
                    acquiredAudioURL = acquisition.audioURL
                    manifest.source = Self.provenance(
                        for: acquisition.audioURL,
                        youtube: acquisition.evidence
                    )
                    try Task.checkCancellation()
                } catch let error as YouTubeAcquisitionError {
                    manifest.source = Self.provenance(
                        for: request.sourceURL,
                        youtube: .init(
                            sourceURL: request.sourceURL.absoluteString,
                            title: "",
                            channel: "",
                            description: "",
                            ytDLPVersion: error.ytDLPVersion ?? "",
                            diagnostics: error.diagnostics
                        )
                    )
                    if acquiredAudioURL == nil {
                        try? FileManager.default.removeItem(at: acquisitionDirectory)
                    }
                    throw error
                } catch {
                    if acquiredAudioURL == nil {
                        try? FileManager.default.removeItem(at: acquisitionDirectory)
                    }
                    throw error
                }
            }

            begin(.normalizingSource, fraction: 0.05, message: "Normalizing source audio…")
            let samples = try await services.loadSource(normalizedSourceURL)
            sampleCount = samples.count
            try Task.checkCancellation()

            begin(
                .preparingASR,
                fraction: 0.2,
                message: "Preparing \(request.backend.displayName)…"
            )
            asrLoadStarted = true
            manifest.modelEvents.append(.init(
                kind: .loadStarted,
                backend: request.backend,
                at: Date()
            ))
            try await services.prepareASR { fraction, message in
                progress(.init(
                    stage: .preparingASR,
                    fraction: 0.2 + min(max(fraction, 0), 1) * 0.25,
                    message: message
                ))
            }
            manifest.modelEvents.append(.init(
                kind: .loadCompleted,
                backend: request.backend,
                at: Date()
            ))
            try Task.checkCancellation()

            begin(.transcribing, fraction: 0.5, message: "Transcribing Japanese…")
            let rawTranscript = try await services.transcribeJapanese(samples)
            rawASR = rawTranscript
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw LocalPrototypeError.invalidResponse }
            try Task.checkCancellation()

            manifest.peakMemoryBytes = await services.currentMemoryBytes()
            await services.unloadASR()
            asrUnloaded = true
            manifest.modelEvents.append(.init(
                kind: .unloadCompleted,
                backend: request.backend,
                at: Date()
            ))
            begin(.exporting, fraction: 0.9, message: "Writing results…")
            manifest.generatedFiles = Self.generatedFiles(
                includeTranscript: true,
                acquiredAudioURL: acquiredAudioURL
            )
            try (transcript + "\n").write(
                to: directory.appendingPathComponent("japanese-transcript.txt"),
                atomically: true,
                encoding: .utf8
            )
            transcriptWritten = true
            manifest.status = .completed
            var evidence = try Self.writeEvidenceAndManifest(
                rawASR: rawTranscript,
                sampleCount: sampleCount,
                manifest: manifest,
                to: directory
            )
            manifest.stageDurations[.exporting, default: 0] += Date().timeIntervalSince(stageStartedAt)
            manifest.finishedAt = Date()
            evidence = try Self.writeEvidenceAndManifest(
                rawASR: rawTranscript,
                sampleCount: sampleCount,
                manifest: manifest,
                to: directory
            )
            progress(.init(stage: .completed, fraction: 1, message: "Completed"))
            return HighQualityJobResult(
                directory: directory,
                japaneseTranscript: transcript,
                manifest: manifest,
                evidence: evidence
            )
        } catch {
            manifest.peakMemoryBytes = await services.currentMemoryBytes()
            if asrLoadStarted, !asrUnloaded {
                await services.unloadASR()
                manifest.modelEvents.append(.init(
                    kind: .unloadCompleted,
                    backend: request.backend,
                    at: Date()
                ))
            }
            let failureStage: HighQualityJobFailureStage
            let status: HighQualityJobManifest.Status
            if error is CancellationError {
                failureStage = .cancelled
                status = .cancelled
            } else {
                switch currentStage {
                case .acquiringSource: failureStage = .acquisition
                case .normalizingSource: failureStage = .source
                case .preparingASR: failureStage = .modelPreparation
                case .transcribing: failureStage = .asr
                case .exporting: failureStage = .export
                default: failureStage = .application
                }
                status = .failed
            }
            manifest.stageDurations[currentStage, default: 0] += Date().timeIntervalSince(stageStartedAt)
            manifest.status = status
            manifest.finishedAt = Date()
            let failure = HighQualityJobFailure(
                stage: failureStage,
                message: error is CancellationError ? "Job cancelled." : error.localizedDescription
            )
            manifest.failures = [failure]
            manifest.generatedFiles = Self.generatedFiles(
                includeTranscript: transcriptWritten,
                acquiredAudioURL: acquiredAudioURL
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                _ = try Self.writeEvidenceAndManifest(
                    rawASR: rawASR,
                    sampleCount: sampleCount,
                    manifest: manifest,
                    to: directory
                )
            } catch let finalizationError {
                throw HighQualityJobError(
                    stage: failureStage,
                    message: failure.message + " Results could not be finalized: "
                        + finalizationError.localizedDescription,
                    resultDirectory: directory
                )
            }
            progress(.init(
                stage: status == .cancelled ? .cancelled : .failed,
                fraction: 1,
                message: failure.message
            ))
            throw HighQualityJobError(
                stage: failureStage,
                message: failure.message,
                resultDirectory: directory
            )
        }
    }

    private static func provenance(
        for url: URL,
        youtube: HighQualityYouTubeEvidence? = nil
    ) -> HighQualitySourceProvenance {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return HighQualitySourceProvenance(
            path: url.path,
            fileName: url.lastPathComponent,
            byteCount: values?.fileSize.map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            sourceURL: youtube?.sourceURL ?? (url.isFileURL ? nil : url.absoluteString),
            youtube: youtube
        )
    }

    private static func generatedFiles(
        includeTranscript: Bool,
        acquiredAudioURL: URL? = nil
    ) -> [HighQualityGeneratedFile] {
        var files: [HighQualityGeneratedFile] = []
        if includeTranscript {
            files.append(.init(path: "japanese-transcript.txt", kind: .deliverable))
        }
        if let acquiredAudioURL {
            files.append(.init(
                path: "acquisition/\(acquiredAudioURL.lastPathComponent)",
                kind: .evidence
            ))
        }
        files.append(.init(path: "raw-asr.json", kind: .evidence))
        files.append(.init(path: "manifest.json", kind: .manifest))
        return files
    }

    private static func validateYouTubeURL(_ url: URL) throws {
        let host = url.host?.lowercased()
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasPlaylist = url.path == "/playlist" || query.contains { $0.name == "list" }
        let pathParts = url.path.split(separator: "/")
        let isVideoPath: Bool
        if host == "youtu.be" {
            isVideoPath = pathParts.count == 1
        } else {
            isVideoPath = (url.path == "/watch" && query.contains {
                $0.name == "v" && !($0.value ?? "").isEmpty
            }) || (pathParts.count == 2 && ["shorts", "live"].contains(String(pathParts[0])))
        }
        guard url.scheme?.lowercased() == "https",
              youtubeHosts.contains(host ?? ""),
              url.user == nil,
              url.password == nil,
              !hasPlaylist,
              isVideoPath else {
            throw HighQualityJobError(
                stage: .acquisition,
                message: hasPlaylist
                    ? "YouTube playlists are not supported. Paste one public video URL."
                    : "Enter a valid public YouTube video URL.",
                resultDirectory: nil
            )
        }
    }

    private static func evidence(
        rawASR: String?,
        sampleCount: Int,
        manifest: HighQualityJobManifest
    ) -> HighQualityRawEvidence {
        HighQualityRawEvidence(
            source: manifest.source,
            model: manifest.model,
            rawASR: rawASR,
            sampleRate: 16_000,
            sampleCount: sampleCount,
            stageDurations: manifest.stageDurations,
            peakMemoryBytes: manifest.peakMemoryBytes,
            modelEvents: manifest.modelEvents,
            failures: manifest.failures,
            generatedFiles: manifest.generatedFiles
        )
    }

    private static func writeEvidence(
        _ evidence: HighQualityRawEvidence,
        to directory: URL
    ) throws {
        try encoder.encode(evidence).write(
            to: directory.appendingPathComponent("raw-asr.json"),
            options: .atomic
        )
    }

    @discardableResult
    private static func writeEvidenceAndManifest(
        rawASR: String?,
        sampleCount: Int,
        manifest: HighQualityJobManifest,
        to directory: URL
    ) throws -> HighQualityRawEvidence {
        let evidence = evidence(
            rawASR: rawASR,
            sampleCount: sampleCount,
            manifest: manifest
        )
        try writeEvidence(evidence, to: directory)
        try writeManifest(manifest, to: directory)
        return evidence
    }

    private static func writeManifest(
        _ manifest: HighQualityJobManifest,
        to directory: URL
    ) throws {
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
