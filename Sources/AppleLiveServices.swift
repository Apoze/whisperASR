@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech
import SwiftUI
import Translation

enum AppleLiveError: LocalizedError {
    case unsupportedLanguage(String)
    case speechAssetsUnavailable
    case speechFormatUnavailable
    case translationAssetsUnavailable
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language):
            return "Apple Speech does not support \(language)."
        case .speechAssetsUnavailable:
            return "Apple Speech resources are not installed."
        case .speechFormatUnavailable:
            return "Apple Speech could not select an audio format."
        case .translationAssetsUnavailable:
            return "Apple Translation resources are not installed."
        case .emptyTranslation:
            return "Apple Translation returned an empty result."
        }
    }
}

struct LiveSourceUpdate: Equatable, Sendable {
    let segment: TranscriptionSegment
    let isFinal: Bool
    let finalizedThroughSample: Int
    private let attributedText: AttributedString?

    init(
        segment: TranscriptionSegment,
        isFinal: Bool,
        finalizedThroughSample: Int,
        attributedText: AttributedString? = nil
    ) {
        self.segment = segment
        self.isFinal = isFinal
        self.finalizedThroughSample = finalizedThroughSample
        self.attributedText = attributedText
    }

    /// Returns only words whose native Apple timestamps extend past a stable
    /// subtitle boundary. Synthetic test updates without attributes stay strict.
    func clipped(afterSample sample: Int) -> LiveSourceUpdate? {
        let end = segment.end ?? segment.start
        let cutoff = Double(sample) / 16_000
        guard end > cutoff else { return nil }
        guard segment.start < cutoff else { return self }
        guard #available(macOS 26.0, *) else { return nil }
        guard let attributedText,
              let range = attributedText.rangeOfAudioTimeRangeAttributes(
                intersecting: CMTimeRange(
                    start: CMTime(value: Int64(sample), timescale: 16_000),
                    end: CMTime(seconds: end, preferredTimescale: 16_000)
                )
              ) else { return nil }
        let clippedText = AttributedString(attributedText[range])
        let text = String(clippedText.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LiveSourceUpdate(
            segment: TranscriptionSegment(start: cutoff, end: end, text: text),
            isFinal: isFinal,
            finalizedThroughSample: finalizedThroughSample,
            attributedText: clippedText
        )
    }
}

@available(macOS 26.0, *)
actor AppleSpeechService {
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<CMTime?, Error>?
    private var resultTask: Task<Void, Error>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var nextAnalyzerInputTime: CMTime?

    static func supportedSourceLocales(
        requireHighFidelity: Bool
    ) async -> [SpeechLocaleChoice] {
        guard #available(macOS 26.4, *) else { return [] }
        let lowLanguages = await LanguageAvailability(preferredStrategy: .lowLatency)
            .supportedLanguages
        let highLanguages = await LanguageAvailability(preferredStrategy: .highFidelity)
            .supportedLanguages
        let lowCodes = Set(lowLanguages.compactMap { $0.languageCode?.identifier })
        let highCodes = Set(highLanguages.compactMap { $0.languageCode?.identifier })
        let translatableCodes = (requireHighFidelity
            ? lowCodes.intersection(highCodes)
            : lowCodes
        ).subtracting(["en"])

        var seen = Set<String>()
        return await SpeechTranscriber.supportedLocales
            .filter { locale in
                guard let code = locale.language.languageCode?.identifier else { return false }
                return translatableCodes.contains(code) && seen.insert(code).inserted
            }
            .map { locale in
                let identifier = locale.identifier(.bcp47)
                let label = Locale.current.localizedString(forIdentifier: identifier)
                    ?? locale.localizedString(forIdentifier: identifier)
                    ?? identifier
                return SpeechLocaleChoice(id: identifier, label: label.capitalized)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func prepare(
        localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw AppleLiveError.unsupportedLanguage(localeIdentifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            progress(1)
            return
        case .unsupported:
            throw AppleLiveError.speechAssetsUnavailable
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw AppleLiveError.speechAssetsUnavailable
            }
            let progressTask = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
            progress(1)
        @unknown default:
            throw AppleLiveError.speechAssetsUnavailable
        }
    }

    func start(
        localeIdentifier: String,
        onUpdate: @escaping @MainActor @Sendable (LiveSourceUpdate) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        await cancel()
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw AppleLiveError.unsupportedLanguage(localeIdentifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .lingering
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: Self.inputFormat
        ) else {
            throw AppleLiveError.speechFormatUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)

        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        guard let continuation else { throw AppleLiveError.speechFormatUnavailable }

        self.analyzer = analyzer
        analyzerFormat = format
        converter = Self.formatsMatch(Self.inputFormat, format)
            ? nil : AVAudioConverter(from: Self.inputFormat, to: format)
        inputContinuation = continuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = max(0, CMTimeGetSeconds(result.range.start))
                    let duration = max(0, CMTimeGetSeconds(result.range.duration))
                    let finalized = max(0, CMTimeGetSeconds(result.resultsFinalizationTime))
                    await onUpdate(LiveSourceUpdate(
                        segment: TranscriptionSegment(
                            start: start,
                            end: start + duration,
                            text: text
                        ),
                        isFinal: result.isFinal,
                        finalizedThroughSample: Int((finalized * 16_000).rounded()),
                        attributedText: result.text
                    ))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await onFailure(error)
                throw error
            }
        }
        analysisTask = Task { try await analyzer.analyzeSequence(stream) }
    }

    func send(samples: [Float], startSample: Int) throws {
        guard !samples.isEmpty, let format = analyzerFormat else { return }
        let input = Self.makeBuffer(samples: samples, format: Self.inputFormat)
        let output: AVAudioPCMBuffer
        if let converter {
            let ratio = format.sampleRate / Self.inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 16
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else { throw AppleLiveError.speechFormatUnavailable }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            output = converted
        } else {
            output = input
        }
        let requestedStart = CMTime(value: Int64(startSample), timescale: 16_000)
        let bufferStart = nextAnalyzerInputTime ?? requestedStart
        inputContinuation?.yield(AnalyzerInput(
            buffer: output,
            bufferStartTime: bufferStart
        ))
        nextAnalyzerInputTime = CMTimeAdd(
            bufferStart,
            CMTime(
                value: Int64(output.frameLength),
                timescale: CMTimeScale(format.sampleRate.rounded())
            )
        )
    }

    /// Commit only audio already consumed by the analyzer. A concrete future
    /// timestamp can synchronously wait for more input and block the producer.
    func finalizeAvailableAudio() async throws {
        guard let analyzer else { return }
        try await analyzer.finalize(through: nil)
    }

    func finish() async throws {
        inputContinuation?.finish()
        let lastTime = try await analysisTask?.value
        if let analyzer, let lastTime {
            try await analyzer.finalizeAndFinish(through: lastTime)
        } else if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        try await resultTask?.value
        clear()
    }

    func cancel() async {
        inputContinuation?.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        clear()
    }

    private func clear() {
        analyzer = nil
        inputContinuation = nil
        analysisTask = nil
        resultTask = nil
        analyzerFormat = nil
        converter = nil
        nextAnalyzerInputTime = nil
    }

    private static func makeBuffer(
        samples: [Float],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

}

@available(macOS 26.4, *)
actor AppleTranslationService {
    private var lowLatency: TranslationSession?
    private var highFidelity: TranslationSession?

    static func supportedSourceLocales() async -> [SpeechLocaleChoice] {
        let target = Locale.Language(identifier: "en")
        let availability = LanguageAvailability(preferredStrategy: .highFidelity)
        let languages = await availability.supportedLanguages
        var seen = Set<String>()
        return languages.compactMap { language -> SpeechLocaleChoice? in
            guard language != target,
                  let code = language.languageCode?.identifier,
                  seen.insert(code).inserted else { return nil }
            let identifier = code
            let label = Locale.current.localizedString(forIdentifier: identifier)
                ?? Locale.current.localizedString(forLanguageCode: code)
                ?? identifier
            return SpeechLocaleChoice(id: identifier, label: label.capitalized)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func configure(sourceLocale: String, mode: AppleTranslationMode) async throws {
        let source = Locale.Language(identifier: sourceLocale)
        let target = Locale.Language(identifier: "en")
        if mode != .highFidelityOnly {
            let low = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
            guard await low.isReady else {
                throw AppleLiveError.translationAssetsUnavailable
            }
            lowLatency = low
        } else {
            lowLatency = nil
        }
        if mode.finalUsesHighFidelity {
            let high = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .highFidelity
            )
            guard await high.isReady else {
                throw AppleLiveError.translationAssetsUnavailable
            }
            highFidelity = high
        } else {
            highFidelity = nil
        }
    }

    func translate(_ text: String, highFidelity useHighFidelity: Bool) async throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw AppleLiveError.emptyTranslation }
        guard let session = useHighFidelity ? highFidelity : lowLatency else {
            throw AppleLiveError.translationAssetsUnavailable
        }
        let translated = try await session.translate(source).targetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw AppleLiveError.emptyTranslation }
        return translated
    }

    func cancel() {
        lowLatency?.cancel()
        highFidelity?.cancel()
        lowLatency = nil
        highFidelity = nil
    }
}

@available(macOS 26.4, *)
struct AppleTranslationPreparationView: View {
    let sourceLocale: String
    let mode: AppleTranslationMode
    let report: @MainActor (_ highFidelity: Bool, _ ready: Bool, _ error: String?) -> Void

    @State private var lowReady = false

    var body: some View {
        Group {
            if mode == .highFidelityOnly {
                TranslationPreparationTask(
                    sourceLocale: sourceLocale,
                    strategy: .highFidelity
                ) { ready, error in
                    report(true, ready, error)
                }
            } else {
                TranslationPreparationTask(
                    sourceLocale: sourceLocale,
                    strategy: .lowLatency
                ) { ready, error in
                    lowReady = ready
                    report(false, ready, error)
                }
                if mode == .adaptive && lowReady {
                    TranslationPreparationTask(
                        sourceLocale: sourceLocale,
                        strategy: .highFidelity
                    ) { ready, error in
                        report(true, ready, error)
                    }
                }
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

@available(macOS 26.4, *)
private struct TranslationPreparationTask: View {
    let sourceLocale: String
    let strategy: TranslationSession.Strategy
    let completion: @MainActor (_ ready: Bool, _ error: String?) -> Void

    var body: some View {
        Color.clear
            .translationTask(
                source: Locale.Language(identifier: sourceLocale),
                target: Locale.Language(identifier: "en"),
                preferredStrategy: strategy
            ) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { completion(true, nil) }
                } catch {
                    await MainActor.run { completion(false, error.localizedDescription) }
                }
            }
    }
}
