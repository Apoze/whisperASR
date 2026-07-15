@preconcurrency import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import os

/// Keeps AVAudioConverter's filter and phase alive across the 100 ms LS-EEND
/// blocks. FluidAudio's convenience conversion creates a new converter per
/// call, which introduces a discontinuity at every block boundary.
final class PersistentDiarizationResampler {
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 8_000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private var ended = false

    init() {
        converter = AVAudioConverter(
            from: Self.inputFormat,
            to: Self.outputFormat
        )!
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }

    func append(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard !ended else { throw PersistentDiarizationResamplerError.alreadyFinished }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: Self.inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let inputChannel = input.floatChannelData?[0] else {
            throw PersistentDiarizationResamplerError.bufferAllocationFailed
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            inputChannel.update(from: source.baseAddress!, count: samples.count)
        }

        let supplied = OSAllocatedUnfairLock(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            let alreadySupplied = supplied.withLock { supplied -> Bool in
                if supplied { return true }
                supplied = true
                return false
            }
            if alreadySupplied {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        var result: [Float] = []
        let capacity = AVAudioFrameCount(max(1_024, samples.count / 2 + 1_024))
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: capacity
            ) else {
                throw PersistentDiarizationResamplerError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            result.append(contentsOf: Self.samples(from: output))
            switch status {
            case .haveData:
                guard output.frameLength > 0 else {
                    throw PersistentDiarizationResamplerError.unexpectedStatus
                }
            case .inputRanDry:
                return result
            case .error:
                throw PersistentDiarizationResamplerError.conversionFailed(conversionError)
            case .endOfStream:
                throw PersistentDiarizationResamplerError.unexpectedStatus
            @unknown default:
                throw PersistentDiarizationResamplerError.unexpectedStatus
            }
        }
    }

    /// Ends the one continuous conversion and returns the filter tail. This is
    /// deliberately called only at the real end of the diarization session.
    func finish() throws -> [Float] {
        guard !ended else { return [] }
        ended = true
        var result: [Float] = []
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            status.pointee = .endOfStream
            return nil
        }
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: 4_096
            ) else {
                throw PersistentDiarizationResamplerError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            guard status != .error else {
                throw PersistentDiarizationResamplerError.conversionFailed(conversionError)
            }
            result.append(contentsOf: Self.samples(from: output))
            switch status {
            case .haveData:
                guard output.frameLength > 0 else {
                    throw PersistentDiarizationResamplerError.unexpectedStatus
                }
            case .endOfStream:
                return result
            case .error:
                throw PersistentDiarizationResamplerError.conversionFailed(conversionError)
            case .inputRanDry:
                throw PersistentDiarizationResamplerError.unexpectedStatus
            @unknown default:
                throw PersistentDiarizationResamplerError.unexpectedStatus
            }
        }
    }

    func reset() {
        converter.reset()
        ended = false
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private enum PersistentDiarizationResamplerError: LocalizedError {
    case alreadyFinished
    case bufferAllocationFailed
    case conversionFailed(Error?)
    case unexpectedStatus

    var errorDescription: String? {
        switch self {
        case .alreadyFinished:
            return "The LS-EEND resampler was already finalized."
        case .bufferAllocationFailed:
            return "The LS-EEND resampler could not allocate an audio buffer."
        case .conversionFailed(let error):
            return "LS-EEND resampling failed: \(error?.localizedDescription ?? "unknown error")"
        case .unexpectedStatus:
            return "The LS-EEND resampler entered an unexpected state."
        }
    }
}

enum LocalDiarizationShadowConfiguration {
    /// Promotion is deliberately compile-time gated. The current LS-EEND and
    /// Sortformer bake-offs miss the required turn-change recall, so even an
    /// old `WHISPERASR_DIARIZATION_ASSIST=1` launch can only collect shadow
    /// metrics and can never change subtitle boundaries.
    static let productionBoundaryAssistPromoted = false

    static var isEnabled: Bool {
        isShadowEnabled || isAssistEnabled
    }

    static var isShadowEnabled: Bool {
        ProcessInfo.processInfo.environment["WHISPERASR_DIARIZATION_SHADOW"] == "1"
    }

    static var isAssistEnabled: Bool {
        ProcessInfo.processInfo.environment["WHISPERASR_DIARIZATION_ASSIST"] == "1"
    }

    static var isAssistRequestedButUnpromoted: Bool {
        isAssistEnabled && !productionBoundaryAssistPromoted
    }

    static var canInfluenceBoundaries: Bool {
        productionBoundaryAssistPromoted && isAssistEnabled
    }
}

struct LocalDiarizationUpdate: Sendable, Equatable {
    let dominantSpeaker: Int?
    let overlappingSpeakers: Set<Int>
    let transition: LocalSpeakerTransition?
    let confidence: Float

    var changeSample: Int? { transition?.changeSample }
}

struct LocalSpeakerTransition: Sendable, Equatable {
    let fromSpeaker: Int
    let toSpeaker: Int
    let changeSample: Int
    let confirmedAtSample: Int
    let confidence: Float
    let wasArmedByOverlap: Bool
}

struct LocalDiarizationShadowStatus: Sendable, Equatable {
    let isReady: Bool
    let failureReason: String?
}

struct LocalDiarizationShadowMetric: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case rawSpeakerChange
        case confirmedSpeakerChange
        case overlapArmed
        case emissionMarker
        case markerCalibrationError
        case speakerBoundaryAccepted
        case speakerBoundaryRejected
        case subtitleBoundary
    }

    let kind: Kind
    let observedThroughSample: Int
    let changeSample: Int?
    let dominantSpeaker: Int?
    let overlappingSpeakers: [Int]
    let confidence: Float
    let boundaryKind: String?
    let markerGeneratedIndex: Int?
    let markerTextStartUTF8: Int?
    let markerUsable: Bool?
    let calibrationErrorSamples: Int?
    let decisionReason: String?
    let endpointDetectedAtSample: Int?
    let stagedAtSample: Int?
    let uptimeNanoseconds: UInt64
}

actor LocalDiarizationShadowJournal {
    private var metrics: [LocalDiarizationShadowMetric] = []
    private var lastObservedDominant: Int?
    private var lastObservedOverlap: Set<Int> = []

    func reset() {
        metrics.removeAll(keepingCapacity: true)
        lastObservedDominant = nil
        lastObservedOverlap.removeAll(keepingCapacity: true)
    }

    func snapshot() -> [LocalDiarizationShadowMetric] { metrics }

    func append(_ updates: [LocalDiarizationUpdate], observedThrough sample: Int) {
        for update in updates {
            if let dominant = update.dominantSpeaker,
               let previous = lastObservedDominant,
               dominant != previous {
                appendMetric(
                    kind: .rawSpeakerChange,
                    observedThrough: sample,
                    changeSample: nil,
                    confidence: update.confidence
                )
            }
            if let dominant = update.dominantSpeaker {
                lastObservedDominant = dominant
            }
            if !update.overlappingSpeakers.isEmpty,
               update.overlappingSpeakers != lastObservedOverlap {
                appendMetric(
                    kind: .overlapArmed,
                    observedThrough: sample,
                    changeSample: nil,
                    confidence: update.confidence
                )
            }
            lastObservedOverlap = update.overlappingSpeakers
            if let transition = update.transition {
                appendMetric(
                    kind: .confirmedSpeakerChange,
                    observedThrough: sample,
                    changeSample: transition.changeSample,
                    confidence: transition.confidence,
                    decisionReason: transition.wasArmedByOverlap
                        ? "confirmedAfterOverlap" : "confirmedExclusive"
                )
            }
        }
    }

    func appendMarker(
        _ marker: VoxtralEmissionMarker,
        calibratedEndSample: Int?
    ) {
        appendMetric(
            kind: .emissionMarker,
            observedThrough: calibratedEndSample ?? marker.proxyEndSample,
            changeSample: marker.proxyEndSample,
            confidence: marker.isUsable ? 1 : 0,
            markerGeneratedIndex: marker.generatedIndex,
            markerTextStartUTF8: marker.groupTextStartUTF8,
            markerUsable: marker.isUsable,
            decisionReason: calibratedEndSample == nil
                ? "uncalibrated" : "calibrated"
        )
    }

    func appendCalibrationError(_ errorSamples: Int, observedThrough sample: Int) {
        appendMetric(
            kind: .markerCalibrationError,
            observedThrough: sample,
            changeSample: nil,
            confidence: 0,
            calibrationErrorSamples: errorSamples
        )
    }

    func appendSpeakerDecision(
        accepted: Bool,
        transition: LocalSpeakerTransition,
        reason: String,
        boundaryKind: String?
    ) {
        appendMetric(
            kind: accepted ? .speakerBoundaryAccepted : .speakerBoundaryRejected,
            observedThrough: transition.confirmedAtSample,
            changeSample: transition.changeSample,
            confidence: transition.confidence,
            boundaryKind: boundaryKind,
            decisionReason: reason
        )
    }

    func appendBoundary(kind: String, detectedAt sample: Int, stagedAt: Int) {
        appendMetric(
            kind: .subtitleBoundary,
            observedThrough: stagedAt,
            changeSample: nil,
            confidence: 0,
            boundaryKind: kind,
            endpointDetectedAtSample: sample,
            stagedAtSample: stagedAt
        )
    }

    func appendAssistDisabled(reason: String, observedThrough sample: Int) {
        appendMetric(
            kind: .speakerBoundaryRejected,
            observedThrough: sample,
            changeSample: nil,
            confidence: 0,
            decisionReason: reason
        )
    }

    /// Metrics intentionally omit track IDs: the product only needs a turn
    /// boundary and must not persist speaker identity.
    private func appendMetric(
        kind: LocalDiarizationShadowMetric.Kind,
        observedThrough: Int,
        changeSample: Int?,
        confidence: Float,
        boundaryKind: String? = nil,
        markerGeneratedIndex: Int? = nil,
        markerTextStartUTF8: Int? = nil,
        markerUsable: Bool? = nil,
        calibrationErrorSamples: Int? = nil,
        decisionReason: String? = nil,
        endpointDetectedAtSample: Int? = nil,
        stagedAtSample: Int? = nil
    ) {
        metrics.append(LocalDiarizationShadowMetric(
            kind: kind,
            observedThroughSample: observedThrough,
            changeSample: changeSample,
            dominantSpeaker: nil,
            overlappingSpeakers: [],
            confidence: confidence,
            boundaryKind: boundaryKind,
            markerGeneratedIndex: markerGeneratedIndex,
            markerTextStartUTF8: markerTextStartUTF8,
            markerUsable: markerUsable,
            calibrationErrorSamples: calibrationErrorSamples,
            decisionReason: decisionReason,
            endpointDetectedAtSample: endpointDetectedAtSample,
            stagedAtSample: stagedAtSample,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
    }

    @discardableResult
    func writeOptInReport() throws -> URL? {
        guard LocalDiarizationShadowConfiguration.isEnabled else { return nil }
        let output: URL
        if let path = ProcessInfo.processInfo.environment["WHISPERASR_DIARIZATION_SHADOW_REPORT"],
           !path.isEmpty {
            output = URL(fileURLWithPath: path)
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    ".build/benchmarks/diarization-shadow-\(UUID().uuidString).json"
                )
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: output, options: .atomic)
        return output
    }
}

enum LocalDiarizationModelManifest {
    struct File: Sendable, Equatable {
        let relativePath: String
        let sha256: String
    }

    static let fluidAudioVersion = "0.15.5"
    static let fluidAudioCommit = "19600a485baa4998812e4654b70d2bab8f2c9949"
    static let repository = "GradientDescent2718/ls-eend-coreml"
    static let revision = "125ed60504885cf1dbadacff8a0cececee04ef17"
    static let modelDirectory = "ls_eend_dih3_100ms.mlmodelc"
    static let remoteDirectory = "optimized/dih3/100ms/\(modelDirectory)"

    static let files: [File] = [
        File(
            relativePath: "analytics/coremldata.bin",
            sha256: "eae41bbb03511ff0e04bb217b278b49e67a9744724c28ac2c3b1ecbb6a719544"
        ),
        File(
            relativePath: "coremldata.bin",
            sha256: "ca07a132288cc2acbaee7e034d18c3a9d66bd5be22617b52e9e812d160268ccf"
        ),
        File(
            relativePath: "metadata.json",
            sha256: "f0f4925a193fd765f54f2c9854b16ce4aaae344669d10c1bd412f498d009af6a"
        ),
        File(
            relativePath: "model.mil",
            sha256: "036a1b0a14ffc42e0ff66a16c955b1a79cbd95409d44c4cc571b29bbec79b86d"
        ),
        File(
            relativePath: "weights/weight.bin",
            sha256: "0bf5dc575c0dcb1856eb21e25f401e9e45c183c663f6b6324404b650fdcdbec2"
        ),
    ]
}

actor LocalDiarizationModelStore {
    private let fileManager: FileManager
    private let cacheRoot: URL

    init(
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WhisperASR/Models/LS-EEND", isDirectory: true)
    }

    func prepare() async throws -> URL {
        let snapshot = cacheRoot.appendingPathComponent(
            LocalDiarizationModelManifest.revision,
            isDirectory: true
        )
        let model = snapshot.appendingPathComponent(
            LocalDiarizationModelManifest.modelDirectory,
            isDirectory: true
        )
        let marker = snapshot.appendingPathComponent(".complete")
        if try cachedSnapshotIsValid(model: model, marker: marker) {
            return model
        }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let staging = cacheRoot.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        let stagingModel = staging.appendingPathComponent(
            LocalDiarizationModelManifest.modelDirectory,
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingModel, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for file in LocalDiarizationModelManifest.files {
            let remotePath = "\(LocalDiarizationModelManifest.remoteDirectory)/\(file.relativePath)"
            guard let url = URL(string:
                "https://huggingface.co/\(LocalDiarizationModelManifest.repository)/resolve/"
                    + "\(LocalDiarizationModelManifest.revision)/\(remotePath)"
            ) else {
                throw URLError(.badURL)
            }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let destination = stagingModel.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: temporary, to: destination)
        }

        try Data(LocalDiarizationModelManifest.revision.utf8).write(
            to: staging.appendingPathComponent(".complete"),
            options: .atomic
        )
        if fileManager.fileExists(atPath: snapshot.path) {
            try fileManager.removeItem(at: snapshot)
        }
        try fileManager.moveItem(at: staging, to: snapshot)
        return model
    }

    func cachedSnapshotIsValid(model: URL, marker: URL) throws -> Bool {
        guard let markerRevision = try? String(contentsOf: marker, encoding: .utf8),
              markerRevision == LocalDiarizationModelManifest.revision else {
            return false
        }
        for file in LocalDiarizationModelManifest.files {
            let url = model.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == file.sha256 else { return false }
        }
        return true
    }
}

struct LocalDiarizationReducer {
    private(set) var lastDominantSpeaker: Int?
    private var sessionBaseSample = 0
    private let sampleRate: Double
    private let speakerActivationThreshold: Float
    private let speakerDeactivationThreshold: Float
    private let newDominantThreshold: Float
    private let dominanceMargin: Float
    private let confirmationFrameCount: Int
    private var activeSpeakers: Set<Int> = []
    private var candidateSpeaker: Int?
    private var candidateStartSample: Int?
    private var candidateLastFrame: Int?
    private var candidateFrameCount = 0
    private var candidateConfidence: Float = 0
    private var overlapArmedSpeakers: Set<Int> = []

    init(
        sessionBaseSample: Int = 0,
        sampleRate: Double = 16_000,
        speakerActivationThreshold: Float = 0.60,
        speakerDeactivationThreshold: Float = 0.40,
        newDominantThreshold: Float = 0.65,
        dominanceMargin: Float = 0.25,
        confirmationFrameCount: Int = 2
    ) {
        self.sessionBaseSample = sessionBaseSample
        self.sampleRate = sampleRate
        self.speakerActivationThreshold = speakerActivationThreshold
        self.speakerDeactivationThreshold = speakerDeactivationThreshold
        self.newDominantThreshold = newDominantThreshold
        self.dominanceMargin = dominanceMargin
        self.confirmationFrameCount = confirmationFrameCount
    }

    mutating func reset(sessionBaseSample: Int) {
        self.sessionBaseSample = sessionBaseSample
        lastDominantSpeaker = nil
        activeSpeakers.removeAll(keepingCapacity: true)
        resetCandidate()
        overlapArmedSpeakers.removeAll(keepingCapacity: true)
    }

    mutating func consume(
        predictions: [Float],
        frameCount: Int,
        startFrame: Int,
        speakerCount: Int,
        frameDurationSeconds: Double
    ) -> [LocalDiarizationUpdate] {
        guard frameCount > 0,
              speakerCount > 0,
              predictions.count >= frameCount * speakerCount else { return [] }

        var updates: [LocalDiarizationUpdate] = []
        updates.reserveCapacity(frameCount)
        let frameDurationSamples = Int(
            (frameDurationSeconds * sampleRate).rounded()
        )
        for frameOffset in 0..<frameCount {
            let base = frameOffset * speakerCount
            let probabilities = Array(predictions[base..<(base + speakerCount)])
            activeSpeakers = Set(activeSpeakers.filter {
                probabilities.indices.contains($0)
                    && probabilities[$0] >= speakerDeactivationThreshold
            })
            activeSpeakers.formUnion(
                probabilities.indices.filter { probabilities[$0] >= speakerActivationThreshold }
            )
            let active = probabilities.indices.filter { activeSpeakers.contains($0) }
            let dominant = active.max { probabilities[$0] < probabilities[$1] }
            let overlappingSpeakers = active.count > 1 ? Set(active) : []
            let frame = startFrame + frameOffset
            let sample = sessionBaseSample + Int(
                (Double(frame) * frameDurationSeconds * sampleRate).rounded()
            )
            var transition: LocalSpeakerTransition?

            if active.count > 1 {
                if let confirmed = lastDominantSpeaker, active.contains(confirmed) {
                    overlapArmedSpeakers.formUnion(active.filter { $0 != confirmed })
                    if let dominant,
                       dominant != confirmed,
                       qualifiesAsTransition(
                           from: confirmed,
                           to: dominant,
                           probabilities: probabilities
                       ) {
                        advanceCandidate(
                            speaker: dominant,
                            sample: sample,
                            frame: frame,
                            confidence: probabilities[dominant]
                        )
                    } else {
                        resetCandidate()
                    }
                } else {
                    resetCandidate()
                }
            } else if let dominant {
                let confidence = probabilities[dominant]
                if let confirmed = lastDominantSpeaker {
                    if dominant == confirmed {
                        resetCandidate()
                        overlapArmedSpeakers.removeAll(keepingCapacity: true)
                    } else if qualifiesAsTransition(
                        from: confirmed,
                        to: dominant,
                        probabilities: probabilities
                    ) {
                        advanceCandidate(
                            speaker: dominant,
                            sample: sample,
                            frame: frame,
                            confidence: confidence
                        )

                        if candidateFrameCount >= confirmationFrameCount,
                           let changeSample = candidateStartSample {
                            transition = LocalSpeakerTransition(
                                fromSpeaker: confirmed,
                                toSpeaker: dominant,
                                changeSample: changeSample,
                                confirmedAtSample: sample + frameDurationSamples,
                                confidence: candidateConfidence,
                                wasArmedByOverlap: overlapArmedSpeakers.contains(dominant)
                            )
                            lastDominantSpeaker = dominant
                            resetCandidate()
                            overlapArmedSpeakers.removeAll(keepingCapacity: true)
                        }
                    } else {
                        resetCandidate()
                    }
                } else if confidence >= newDominantThreshold {
                    lastDominantSpeaker = dominant
                    resetCandidate()
                }
            } else {
                resetCandidate()
            }

            updates.append(LocalDiarizationUpdate(
                dominantSpeaker: dominant,
                overlappingSpeakers: overlappingSpeakers,
                transition: transition,
                confidence: dominant.map { probabilities[$0] } ?? 0
            ))
        }
        return updates
    }

    private func qualifiesAsTransition(
        from oldSpeaker: Int,
        to newSpeaker: Int,
        probabilities: [Float]
    ) -> Bool {
        guard probabilities.indices.contains(oldSpeaker),
              probabilities.indices.contains(newSpeaker) else { return false }
        let oldConfidence = probabilities[oldSpeaker]
        let newConfidence = probabilities[newSpeaker]
        return newConfidence >= newDominantThreshold
            && (oldConfidence <= speakerDeactivationThreshold
                || newConfidence - oldConfidence >= dominanceMargin)
    }

    private mutating func resetCandidate() {
        candidateSpeaker = nil
        candidateStartSample = nil
        candidateLastFrame = nil
        candidateFrameCount = 0
        candidateConfidence = 0
    }

    private mutating func advanceCandidate(
        speaker: Int,
        sample: Int,
        frame: Int,
        confidence: Float
    ) {
        if candidateSpeaker == speaker, candidateLastFrame == frame - 1 {
            candidateFrameCount += 1
            candidateLastFrame = frame
            candidateConfidence = min(candidateConfidence, confidence)
        } else {
            candidateSpeaker = speaker
            candidateStartSample = sample
            candidateLastFrame = frame
            candidateFrameCount = 1
            candidateConfidence = confidence
        }
    }
}

actor LocalDiarizationShadow {
    private let logger = Logger(subsystem: "WhisperASR", category: "LSEENDShadow")
    private let modelStore: LocalDiarizationModelStore
    private var diarizer: LSEENDDiarizer?
    private let resampler = PersistentDiarizationResampler()
    private var reducer = LocalDiarizationReducer()
    private var expectedSample: Int?
    private var failureReason: String?

    init(modelStore: LocalDiarizationModelStore = LocalDiarizationModelStore()) {
        self.modelStore = modelStore
    }

    func prepare() async {
        guard diarizer == nil else { return }
        failureReason = nil
        do {
            let modelURL = try await modelStore.prepare()
            let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
            diarizer = try LSEENDDiarizer(model: model)
            resampler.reset()
            expectedSample = nil
        } catch {
            disable(error)
        }
    }

    func status() -> LocalDiarizationShadowStatus {
        LocalDiarizationShadowStatus(
            isReady: diarizer != nil,
            failureReason: failureReason
        )
    }

    func append(samples: [Float], range: Range<Int>) -> [LocalDiarizationUpdate] {
        guard let diarizer else { return [] }
        guard samples.count == range.count,
              expectedSample == nil || expectedSample == range.lowerBound else {
            disable(LocalDiarizationShadowError.nonContiguousAudio)
            return []
        }
        if expectedSample == nil {
            reducer.reset(sessionBaseSample: range.lowerBound)
        }
        expectedSample = range.upperBound

        do {
            let downsampled = try resampler.append(samples)
            guard !downsampled.isEmpty,
                  let update = try diarizer.process(samples: downsampled, sourceSampleRate: nil) else {
                return []
            }
            return reduce(update, diarizer: diarizer)
        } catch {
            disable(error)
            return []
        }
    }

    func finish() -> [LocalDiarizationUpdate] {
        guard let diarizer else { return [] }
        do {
            var result: [LocalDiarizationUpdate] = []
            let tail = try resampler.finish()
            if !tail.isEmpty,
               let update = try diarizer.process(samples: tail, sourceSampleRate: nil) {
                result.append(contentsOf: reduce(update, diarizer: diarizer))
            }
            if let update = try diarizer.finalizeSession() {
                result.append(contentsOf: reduce(update, diarizer: diarizer))
            }
            return result
        } catch {
            disable(error)
            return []
        }
    }

    func reset() {
        diarizer?.reset()
        resampler.reset()
        reducer.reset(sessionBaseSample: 0)
        expectedSample = nil
        failureReason = nil
    }

    func shutdown() {
        diarizer?.cleanup()
        diarizer = nil
        resampler.reset()
        expectedSample = nil
    }

    private func reduce(
        _ update: DiarizerTimelineUpdate,
        diarizer: LSEENDDiarizer
    ) -> [LocalDiarizationUpdate] {
        let chunk = update.chunkResult
        let speakerCount = diarizer.numSpeakers ?? 0
        let frameDuration = diarizer.modelFrameHz.map { 1 / $0 } ?? 0.1
        return reducer.consume(
            predictions: chunk.finalizedPredictions,
            frameCount: chunk.finalizedFrameCount,
            startFrame: chunk.startFrame,
            speakerCount: speakerCount,
            frameDurationSeconds: frameDuration
        )
    }

    private func disable(_ error: Error) {
        failureReason = error.localizedDescription
        logger.warning("LS-EEND shadow disabled: \(error.localizedDescription, privacy: .public)")
        diarizer?.cleanup()
        diarizer = nil
        resampler.reset()
    }
}

private enum LocalDiarizationShadowError: LocalizedError {
    case nonContiguousAudio

    var errorDescription: String? {
        "LS-EEND shadow received non-contiguous PCM"
    }
}
