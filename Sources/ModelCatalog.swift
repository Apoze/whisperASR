import Foundation
import Observation

// MARK: - Model Catalog

/// A whisper GGML model available for in-app download.
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let fileName: String
    let url: URL
    let approxBytes: Int64
    let supportsEnglishTranslation: Bool
    let sha256: String?

    init(
        id: String,
        displayName: String,
        detail: String,
        fileName: String,
        url: URL,
        approxBytes: Int64,
        supportsEnglishTranslation: Bool,
        sha256: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.fileName = fileName
        self.url = url
        self.approxBytes = approxBytes
        self.supportsEnglishTranslation = supportsEnglishTranslation
        self.sha256 = sha256
    }

    var approxSizeText: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// All downloadable models. Breeze-ASR-25 is the default (best for
    /// Mandarin/Taiwanese); the rest are official whisper.cpp conversions.
    static let all: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "breeze-asr-25",
            displayName: "Breeze-ASR-25",
            detail: "Best for Mandarin transcription; does not translate",
            fileName: "ggml-model.bin",
            url: URL(string: "https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/resolve/main/ggml-model.bin")!,
            approxBytes: 3_100_000_000,
            supportsEnglishTranslation: false
        ),
        WhisperModelInfo(
            id: "large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            detail: "Fast, accurate transcription; does not translate",
            fileName: "ggml-large-v3-turbo.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!,
            approxBytes: 1_620_000_000,
            supportsEnglishTranslation: false,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        ),
        WhisperModelInfo(
            id: "large-v3",
            displayName: "Whisper Large v3",
            detail: "Highest-quality direct speech translation to English",
            fileName: "ggml-large-v3.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/c521a4b02f422512d734391fdf08bb08c0862f68/ggml-large-v3.bin")!,
            approxBytes: 3_100_000_000,
            supportsEnglishTranslation: true,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        ),
        WhisperModelInfo(
            id: "medium",
            displayName: "Whisper Medium",
            detail: "Recommended for local translation to English",
            fileName: "ggml-medium.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            approxBytes: 1_530_000_000,
            supportsEnglishTranslation: true
        ),
        WhisperModelInfo(
            id: "small",
            displayName: "Whisper Small",
            detail: "Fast, decent quality",
            fileName: "ggml-small.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            approxBytes: 488_000_000,
            supportsEnglishTranslation: true
        ),
        WhisperModelInfo(
            id: "base",
            displayName: "Whisper Base",
            detail: "Very fast, basic quality",
            fileName: "ggml-base.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            approxBytes: 148_000_000,
            supportsEnglishTranslation: true
        ),
        WhisperModelInfo(
            id: "tiny",
            displayName: "Whisper Tiny",
            detail: "Fastest, lowest quality",
            fileName: "ggml-tiny.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            approxBytes: 78_000_000,
            supportsEnglishTranslation: true
        ),
    ]

    static func model(id: String) -> WhisperModelInfo? {
        all.first { $0.id == id }
    }

    static func model(fileName: String) -> WhisperModelInfo? {
        all.first { $0.fileName == fileName }
    }

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models")
    }

    static func path(for model: WhisperModelInfo) -> URL {
        modelDirectory.appendingPathComponent(model.fileName)
    }

    static var selectedModelSupportsEnglishTranslation: Bool {
        let defaults = UserDefaults.standard
        if let selected = defaults.string(forKey: "selectedModelFile"),
           let model = model(fileName: selected) {
            return model.supportsEnglishTranslation
        }
        let path = defaults.string(forKey: "modelPath")
            ?? modelDirectory.appendingPathComponent("ggml-model.bin").path
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return !name.contains("turbo") && !name.contains("breeze") && name != "ggml-model.bin"
    }
}

/// Resolves the one Whisper model used by the local-English pipeline. L7 may
/// substitute Kotoba only in an explicitly opted-in benchmark process; normal
/// application runs always use the catalog model selected by the pipeline.
struct LocalWhisperModelSelection: Equatable {
    static let benchmarkCandidateEnvironmentKey = "WHISPERASR_L7_WHISPER_CANDIDATE"
    static let kotobaPathEnvironmentKey = "WHISPERASR_KOTOBA_Q5_MODEL"
    static let kotobaModelID = "kotoba-tech/kotoba-whisper-v2.0-ggml"
    static let kotobaRevision = "e3a0cf6a62b95911703cfb97d819292e058f12c3"
    static let kotobaSHA256 = "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"

    let candidate: String
    let modelID: String
    let revision: String?
    let displayName: String
    let fileURL: URL
    let expectedSHA256: String?

    var cacheKey: String {
        "\(candidate)|\(fileURL.path)|\(expectedSHA256 ?? "unpinned")"
    }

    static func resolve(
        for engine: LocalEnglishEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> Self {
        let benchmarkCandidate = environment[benchmarkCandidateEnvironmentKey]
        if environment["WHISPERASR_BENCHMARK"] == "1",
           engine == .whisperTurboApple,
           let benchmarkCandidate,
           !benchmarkCandidate.isEmpty,
           benchmarkCandidate != "turbo" {
            guard benchmarkCandidate == "kotoba-q5" else {
                throw LocalWhisperModelSelectionError.unknownCandidate(benchmarkCandidate)
            }
            guard let path = environment[kotobaPathEnvironmentKey], path.hasPrefix("/") else {
                throw LocalWhisperModelSelectionError.missingKotobaPath
            }
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            guard fileExists(fileURL.path) else {
                throw LocalWhisperModelSelectionError.modelNotFound(fileURL.path)
            }
            return Self(
                candidate: benchmarkCandidate,
                modelID: kotobaModelID,
                revision: kotobaRevision,
                displayName: "Kotoba Whisper v2.0 Q5",
                fileURL: fileURL,
                expectedSHA256: kotobaSHA256
            )
        }

        guard let modelID = engine.whisperModelID,
              let model = ModelCatalog.model(id: modelID) else {
            throw LocalWhisperModelSelectionError.engineHasNoWhisperModel(engine.rawValue)
        }
        let fileURL = ModelCatalog.path(for: model).standardizedFileURL
        guard fileExists(fileURL.path) else {
            throw LocalWhisperModelSelectionError.modelNotFound(fileURL.path)
        }
        return Self(
            candidate: model.id == "large-v3-turbo" ? "turbo" : model.id,
            modelID: model.id,
            revision: revision(from: model.url),
            displayName: model.displayName,
            fileURL: fileURL,
            expectedSHA256: model.sha256
        )
    }

    private static func revision(from url: URL) -> String? {
        let components = url.pathComponents
        guard let resolve = components.firstIndex(of: "resolve"),
              components.indices.contains(resolve + 1) else { return nil }
        return components[resolve + 1]
    }
}

enum LocalWhisperModelSelectionError: LocalizedError, Equatable {
    case unknownCandidate(String)
    case missingKotobaPath
    case modelNotFound(String)
    case engineHasNoWhisperModel(String)

    var errorDescription: String? {
        switch self {
        case .unknownCandidate(let candidate):
            return "Unknown L7 Whisper benchmark candidate: \(candidate)."
        case .missingKotobaPath:
            return "WHISPERASR_KOTOBA_Q5_MODEL must contain an absolute Kotoba model path."
        case .modelNotFound(let path):
            return "The required Whisper model was not found at \(path)."
        case .engineHasNoWhisperModel(let engine):
            return "The \(engine) pipeline does not use a Whisper model."
        }
    }
}

// MARK: - Model Manager

/// Tracks which models are on disk, in-flight downloads, and the user's
/// model selection (persisted in UserDefaults as "selectedModelFile").
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var downloadedFileNames: Set<String> = []
    private var downloaders: [String: ModelDownloader] = [:]

    /// File name (in the Models directory) of the model used for transcription.
    /// Empty = automatic (custom path from Settings, else the default model).
    var selectedFileName: String {
        didSet { UserDefaults.standard.set(selectedFileName, forKey: "selectedModelFile") }
    }

    private init() {
        selectedFileName = UserDefaults.standard.string(forKey: "selectedModelFile") ?? ""
        refresh()
        for model in ModelCatalog.all {
            downloaders[model.id] = ModelDownloader(model: model) { [weak self] in
                self?.downloadFinished(model)
            }
        }
    }

    var downloadedModels: [WhisperModelInfo] {
        ModelCatalog.all.filter { downloadedFileNames.contains($0.fileName) }
    }

    var selectedModel: WhisperModelInfo? {
        guard !selectedFileName.isEmpty else { return nil }
        return ModelCatalog.model(fileName: selectedFileName)
    }

    func isDownloaded(_ model: WhisperModelInfo) -> Bool {
        downloadedFileNames.contains(model.fileName)
    }

    func downloader(for model: WhisperModelInfo) -> ModelDownloader {
        downloaders[model.id]!
    }

    /// Re-scan the Models directory.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path)) ?? []
        downloadedFileNames = Set(files)
        // Drop a selection whose file no longer exists (deleted externally)
        if !selectedFileName.isEmpty && !downloadedFileNames.contains(selectedFileName) {
            selectedFileName = ""
        }
    }

    func delete(_ model: WhisperModelInfo) {
        try? FileManager.default.removeItem(at: ModelCatalog.path(for: model))
        refresh()
    }

    /// Called on the main queue when a download completes. The user explicitly
    /// chose this model, so switch transcription to it right away.
    private func downloadFinished(_ model: WhisperModelInfo) {
        refresh()
        selectedFileName = model.fileName
    }
}
