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
