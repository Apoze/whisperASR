import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os
import CoreGraphics
import Darwin

enum RecordingState: Equatable {
    case idle
    case loading
    case ready
    case recording
    case saving
    case permissionDenied
}

struct RecordingStopResult: Equatable, Sendable {
    let archiveURL: URL?
    let finalSampleCount: Int
    let m4aDroppedSampleCount: Int
    let pcmComplete: Bool
}

enum CanonicalPCMResamplerError: LocalizedError {
    case unavailable
    case bufferAllocation
    case conversion(String)
    case didNotReachEndOfStream

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The canonical PCM converter could not be created."
        case .bufferAllocation:
            return "The canonical PCM converter could not allocate an audio buffer."
        case .conversion(let message):
            return "Canonical PCM conversion failed: \(message)"
        case .didNotReachEndOfStream:
            return "The canonical PCM converter did not finish its end-of-stream drain."
        }
    }
}

/// Stateful 48 kHz Float32 mono to 16 kHz Float32 mono conversion. All calls
/// are serialized by AudioRecorder's capture queue so the converter can drain
/// every output buffer, including its delayed tail at the real end of stream.
final class CanonicalPCMResampler {
    static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private let outputFrameCapacity: AVAudioFrameCount
    private var finished = false

    init(outputFrameCapacity: AVAudioFrameCount = 4_096) throws {
        guard let converter = AVAudioConverter(
            from: Self.sourceFormat,
            to: Self.targetFormat
        ) else {
            throw CanonicalPCMResamplerError.unavailable
        }
        self.converter = converter
        self.outputFrameCapacity = max(1, outputFrameCapacity)
    }

    func reset() {
        converter.reset()
        finished = false
    }

    func append(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard !finished else {
            throw CanonicalPCMResamplerError.conversion(
                "audio arrived after end of stream"
            )
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: Self.sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = input.floatChannelData?[0] else {
            throw CanonicalPCMResamplerError.bufferAllocation
        }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: source.count)
        }
        input.frameLength = AVAudioFrameCount(samples.count)

        var supplied = false
        return try drain(requireEndOfStream: false) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        return try drain(requireEndOfStream: true) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(
        requireEndOfStream: Bool,
        input: @escaping AVAudioConverterInputBlock
    ) throws -> [Float] {
        var result: [Float] = []
        // A healthy converter completes in a handful of iterations. The bound
        // prevents a framework regression from hanging Finish forever.
        let maximumIterations = requireEndOfStream ? 32 : 4_096
        for _ in 0..<maximumIterations {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.targetFormat,
                frameCapacity: outputFrameCapacity
            ) else {
                throw CanonicalPCMResamplerError.bufferAllocation
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError,
                withInputFrom: input
            )
            if let conversionError {
                throw CanonicalPCMResamplerError.conversion(
                    conversionError.localizedDescription
                )
            }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                ))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if requireEndOfStream { continue }
                return result
            case .endOfStream:
                return result
            case .error:
                throw CanonicalPCMResamplerError.conversion(
                    "AVAudioConverter returned an error without details"
                )
            @unknown default:
                throw CanonicalPCMResamplerError.conversion(
                    "AVAudioConverter returned an unknown status"
                )
            }
        }
        throw CanonicalPCMResamplerError.didNotReachEndOfStream
    }
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var state: RecordingState = .idle
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    var recordingDuration: TimeInterval = 0
    var error: String?
    var meetingEnded = false
    var includeMicrophone = false
    var onMeetingEnded: (() -> Void)?
    var customRecordingName: String?
    var pinWindow = false

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?
    private var outputURL: URL?
    var recordingFileURL: URL? { outputURL }
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var meetingStarted = false

    struct CaptureLifecycle {
        var generation: UInt64 = 0
        var acceptingCallbacks = false
        var activeStreamID: ObjectIdentifier?
        var restartInProgress = false
        var restartToken: UUID?
        var closing = false
        var sealedFinalSampleCount: Int?
        var m4aDroppedSampleCount = 0
        var pcmComplete = true

        mutating func beginSession() -> UInt64 {
            generation &+= 1
            acceptingCallbacks = false
            activeStreamID = nil
            restartInProgress = false
            restartToken = nil
            closing = false
            sealedFinalSampleCount = nil
            m4aDroppedSampleCount = 0
            pcmComplete = true
            return generation
        }

        mutating func activate(streamID: ObjectIdentifier, generation expected: UInt64) -> Bool {
            guard generation == expected, !closing, sealedFinalSampleCount == nil else {
                return false
            }
            acceptingCallbacks = true
            activeStreamID = streamID
            return true
        }

        func accepts(streamID: ObjectIdentifier) -> Bool {
            acceptingCallbacks && activeStreamID == streamID
        }

        mutating func beginRestart() -> (generation: UInt64, token: UUID)? {
            guard acceptingCallbacks, !closing, !restartInProgress else { return nil }
            let token = UUID()
            restartInProgress = true
            restartToken = token
            return (generation, token)
        }

        mutating func endRestart(generation expected: UInt64, token: UUID) {
            guard generation == expected, restartToken == token else { return }
            restartInProgress = false
            restartToken = nil
        }

        mutating func beginSeal() {
            closing = true
        }

        mutating func seal(finalSampleCount: Int) {
            acceptingCallbacks = false
            activeStreamID = nil
            restartInProgress = false
            restartToken = nil
            closing = true
            sealedFinalSampleCount = finalSampleCount
        }
    }

    @ObservationIgnored
    private let captureQueue = DispatchQueue(label: "com.whisperasr.audio-capture")
    @ObservationIgnored
    private var captureLifecycle = OSAllocatedUnfairLock(initialState: CaptureLifecycle())
    @ObservationIgnored
    private var restartTask = OSAllocatedUnfairLock<(
        token: UUID,
        task: Task<Void, Never>
    )?>(initialState: nil)

    // Stream watchdog: detect stalled audio delivery and restart
    private var lastAudioBufferTime = OSAllocatedUnfairLock(initialState: Date())
    private var audioWatchdogTimer: Timer?
    private var recordingApp: SCRunningApplication?
    /// How long without audio before we consider the stream stalled (seconds).
    private static let audioStallThreshold: TimeInterval = 15

    // Microphone mixing
    private var audioEngine: AVAudioEngine?
    private var micSampleBuffer = OSAllocatedUnfairLock(initialState: [Float]())
    private var isMicActive = false
    private static let maxMicBufferSamples = 48000 * 5 // 5 seconds cap

    // Live transcription: accumulated 16kHz mono PCM samples.
    // Buffer + trimOffset are in a single lock so reads/writes are always atomic.
    private struct PCMState {
        var buffer: [Float] = []
        var trimOffset: Int = 0
    }
    private var pcmState = OSAllocatedUnfairLock(initialState: PCMState())

    @ObservationIgnored
    private var pcmResampler = try! CanonicalPCMResampler()
    /// Total number of 16kHz samples accumulated since recording started (absolute count).
    var accumulatedSampleCount: Int {
        pcmState.withLock { $0.trimOffset + $0.buffer.count }
    }

    var sealedFinalSampleCount: Int? {
        captureLifecycle.withLock { $0.sealedFinalSampleCount }
    }

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - Live Transcription PCM Access

    /// Returns a copy of all accumulated 16kHz PCM samples for live transcription.
    func getAccumulatedSamples() -> [Float] {
        pcmState.withLock { Array($0.buffer) }
    }

    /// Returns only the samples from absolute `startIndex` onward — avoids copying the entire
    /// buffer during long recordings (which can be hundreds of MB after 30+ minutes).
    func getSamples(from startIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufIndex = startIndex - state.trimOffset
            guard bufIndex >= 0, bufIndex < state.buffer.count else { return [] }
            return Array(state.buffer[bufIndex...])
        }
    }

    /// Returns the samples in the absolute range `[startIndex, endIndex)` — used to copy only the
    /// audio a chunk needs when its end is held back from the live tail.
    func getSamples(from startIndex: Int, upTo endIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            guard bufStart >= 0, bufEnd > bufStart else { return [] }
            return Array(state.buffer[bufStart..<bufEnd])
        }
    }

    /// Trim committed samples from the front of the PCM buffer to cap memory usage.
    /// `upTo` is an absolute sample index — samples before this index are freed.
    func trimSamples(upTo absoluteIndex: Int) {
        if ProcessInfo.processInfo.environment["WHISPERASR_CAPTURE_CANONICAL"] == "1" {
            return
        }
        pcmState.withLock { state in
            let bufIndex = absoluteIndex - state.trimOffset
            guard bufIndex > 0 else { return }
            let trimCount = min(bufIndex, state.buffer.count)
            state.buffer.removeFirst(trimCount)
            state.trimOffset += trimCount
        }
    }

    /// Compute the RMS energy of a range of samples without copying the buffer.
    /// Used by the transcription loop to skip whisper inference on silence.
    func rmsEnergy(from startIndex: Int, count: Int) -> Float {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            guard bufStart >= 0 else { return 0 }
            let bufEnd = min(bufStart + count, state.buffer.count)
            guard bufEnd > bufStart else { return 0 }
            var sumSquares: Float = 0
            for i in bufStart..<bufEnd {
                let s = state.buffer[i]
                sumSquares += s * s
            }
            return sqrt(sumSquares / Float(bufEnd - bufStart))
        }
    }

    /// Scan the absolute range `[searchFrom, searchTo)` in fixed `frameSamples`-sized frames and
    /// return the absolute sample index at the START of the rightmost silence run of at least
    /// `minSilenceFrames` frames, provided at least one speech frame precedes it. A frame is
    /// "silent" when its RMS is below `silenceThreshold`.
    ///
    /// Used to place live-transcription chunk cuts at natural pauses: cutting here lets the loop
    /// commit the completed utterance and hold back any trailing in-progress speech. Returns nil
    /// when no qualifying trailing silence exists (e.g. continuous speech). Computed under a single
    /// lock so it stays atomic with concurrent appends/trims.
    func lastSilenceCut(searchFrom: Int, searchTo: Int,
                        frameSamples: Int, silenceThreshold: Float, minSilenceFrames: Int) -> Int? {
        pcmState.withLock { state in
            let bufStart = max(0, searchFrom - state.trimOffset)
            let bufEnd = min(searchTo - state.trimOffset, state.buffer.count)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples else { return nil }

            // Per-frame silence flags over the search range.
            let frameCount = (bufEnd - bufStart) / frameSamples
            guard frameCount > 0 else { return nil }
            var isSilent = [Bool](repeating: false, count: frameCount)
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                let e = s + frameSamples
                var sumSquares: Float = 0
                for i in s..<e {
                    let v = state.buffer[i]
                    sumSquares += v * v
                }
                isSilent[f] = sqrt(sumSquares / Float(frameSamples)) < silenceThreshold
            }

            // Walk from the right: find the rightmost run of >= minSilenceFrames silent frames
            // whose start has at least one speech frame before it.
            var run = 0
            var f = frameCount - 1
            while f >= 0 {
                if isSilent[f] {
                    run += 1
                    if run >= minSilenceFrames {
                        let runStartFrame = f               // start of this silence run
                        let hasSpeechBefore = (0..<runStartFrame).contains { !isSilent[$0] }
                        guard hasSpeechBefore else { return nil }
                        return state.trimOffset + bufStart + runStartFrame * frameSamples
                    }
                } else {
                    run = 0
                }
                f -= 1
            }
            return nil
        }
    }

    /// Clears the accumulated PCM sample buffer (called when recording ends).
    private func clearPCMBuffer() {
        pcmState.withLock { state in
            state.buffer.removeAll()
            state.trimOffset = 0
        }
    }

    /// Release live-caption audio only after the final transcription pass has consumed it.
    func discardAccumulatedSamples() {
        clearPCMBuffer()
    }

    // MARK: - App List

    func loadAvailableApps() {
        state = .loading
        error = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications
                    .filter {
                        $0.bundleIdentifier != myBundleID
                            && !$0.applicationName.isEmpty
                            && appsWithWindows.contains($0.bundleIdentifier)
                            && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                    }
                    .sorted { ($0.applicationName) < ($1.applicationName) }

                await MainActor.run {
                    self.availableApps = apps
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code == -3801 || "\(error)".contains("denied") {
                        self.state = .permissionDenied
                    } else {
                        self.error = error.localizedDescription
                        self.state = .permissionDenied
                    }
                }
            }
        }
    }

    // MARK: - Start Recording

    private static let recentAppsKey = "recentRecordingApps"

    /// Bundle IDs of recently recorded apps, most recent first.
    var recentAppBundleIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []
    }

    private func saveRecentApp(bundleID: String) {
        var recent = recentAppBundleIDs
        recent.removeAll { $0 == bundleID }
        recent.insert(bundleID, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        UserDefaults.standard.set(recent, forKey: Self.recentAppsKey)
    }

    func startRecording(app: SCRunningApplication) {
        guard state == .ready else { return }
        saveRecentApp(bundleID: app.bundleIdentifier)
        state = .loading
        error = nil
        let generation = captureLifecycle.withLock { $0.beginSession() }
        captureQueue.sync { pcmResampler.reset() }
        clearPCMBuffer()

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    throw NSError(
                        domain: "AudioRecorder",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No display found."]
                    )
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                // Minimal video config (required but we don't need video)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let fileURL = self.makeOutputURL(appName: app.applicationName)
                self.customRecordingName = nil

                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else {
                    throw NSError(
                        domain: "AudioRecorder",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The M4A writer rejected its audio input."]
                    )
                }
                writer.add(input)
                guard writer.startWriting(), writer.status == .writing else {
                    throw writer.error ?? NSError(
                        domain: "AudioRecorder",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The M4A writer could not start."]
                    )
                }
                writer.startSession(atSourceTime: .zero)

                self.assetWriter = writer
                self.assetWriterInput = input
                self.outputURL = fileURL
                self._hasReceivedSamples.withLock { $0 = false }

                self.recordingApp = app

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: self.captureQueue
                )
                guard self.captureLifecycle.withLock({
                    $0.activate(streamID: ObjectIdentifier(stream), generation: generation)
                }) else {
                    throw CancellationError()
                }
                self.stream = stream
                try await stream.startCapture()
                guard self.captureLifecycle.withLock({
                    $0.generation == generation && $0.accepts(streamID: ObjectIdentifier(stream))
                }) else {
                    try? await stream.stopCapture()
                    throw CancellationError()
                }
                self.recordingAppName = app.applicationName

                if self.includeMicrophone {
                    do {
                        try self.startMicrophoneCapture()
                    } catch {
                        print("[AudioRecorder] failed to start microphone: \(error)")
                        await MainActor.run {
                            self.error = "Microphone unavailable, recording app audio only"
                        }
                    }
                }

                await MainActor.run {
                    self.state = .recording
                    self.recordingDuration = 0
                    self.recordingStartTime = Date()
                    self.timer = Self.commonModeTimer(interval: 1.0) { [weak self] in
                        guard let self, let start = self.recordingStartTime else { return }
                        self.recordingDuration = Date().timeIntervalSince(start)
                    }
                    self.startMeetingMonitor(app: app)
                    self.startAudioWatchdog()
                }
            } catch {
                // Tear down whatever got as far as starting: cancel the writer,
                // delete the stray output file, and drop the half-built stream so
                // the next attempt starts from a clean slate.
                if let stream = self.stream {
                    try? await stream.stopCapture()
                    self.stream = nil
                }
                self.captureLifecycle.withLock { lifecycle in
                    guard lifecycle.generation == generation else { return }
                    lifecycle.acceptingCallbacks = false
                    lifecycle.activeStreamID = nil
                }
                if let writer = self.assetWriter {
                    writer.cancelWriting()
                }
                self.assetWriter = nil
                self.assetWriterInput = nil
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                    self.outputURL = nil
                }
                self.recordingApp = nil
                self.recordingAppName = nil
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                    self.state = .ready
                }
            }
        }
    }

    // MARK: - Stop Recording

    // Compatibility entry points keep this recorder-sealing commit usable by
    // the existing UI. The awaited AppState closure switches to the result
    // variants in the dependent commit.
    func stopRecording() async -> URL? {
        await stopRecordingWithResult().archiveURL
    }

    func stopRecordingWithResult() async -> RecordingStopResult {
        await sealRecording(keepArchive: true)
    }

    func cancelRecording() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.cancelRecordingWithResult()
            await MainActor.run { self.state = .ready }
        }
    }

    func cancelRecordingWithResult() async -> RecordingStopResult {
        await sealRecording(keepArchive: false)
    }

    private func sealRecording(keepArchive: Bool) async -> RecordingStopResult {
        await MainActor.run {
            state = .saving
            timer?.invalidate()
            timer = nil
            stopMeetingMonitor()
            stopAudioWatchdog()
        }

        captureLifecycle.withLock { $0.beginSeal() }
        // A restart first reserves a lifecycle token, then publishes its Task.
        // Finish may land in that tiny interval, so wait until the token is
        // either paired with a task or cleared by the restart itself.
        while captureLifecycle.withLock({ $0.restartInProgress }) {
            let pendingRestart = restartTask.withLock { $0?.task }
            if let pendingRestart {
                pendingRestart.cancel()
                await pendingRestart.value
            } else {
                await Task.yield()
            }
        }

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        // This block runs after every callback already accepted by
        // ScreenCaptureKit. It closes the gate on this same serial queue, so a
        // callback delivered late can no longer slip in behind the barrier.
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.captureLifecycle.withLock { lifecycle in
                    lifecycle.acceptingCallbacks = false
                    lifecycle.activeStreamID = nil
                }
                continuation.resume()
            }
        }

        stopMicrophoneCapture()
        recordingApp = nil

        let pcmSnapshot = await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: (0, false, 0))
                    return
                }
                do {
                    let tail = try self.pcmResampler.finish()
                    if !tail.isEmpty {
                        self.pcmState.withLock { $0.buffer.append(contentsOf: tail) }
                    }
                } catch {
                    print("[AudioRecorder] canonical PCM EOS drain failed: \(error)")
                    self.captureLifecycle.withLock { $0.pcmComplete = false }
                }
                let finalSampleCount = self.accumulatedSampleCount
                let snapshot = self.captureLifecycle.withLock { lifecycle in
                    lifecycle.seal(finalSampleCount: finalSampleCount)
                    return (
                        finalSampleCount,
                        lifecycle.pcmComplete,
                        lifecycle.m4aDroppedSampleCount
                    )
                }
                self.pcmResampler.reset()
                continuation.resume(returning: snapshot)
            }
        }

        let received = _hasReceivedSamples.withLock { $0 }
        print("[AudioRecorder] stopRecording: hasReceivedSamples=\(received), writer=\(assetWriter != nil), input=\(assetWriterInput != nil)")

        var archiveURL: URL?
        if let writer = assetWriter, let input = assetWriterInput {
            if keepArchive {
                input.markAsFinished()
                await writer.finishWriting()

                print("[AudioRecorder] stopRecording: writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")

                if writer.status == .completed, received,
                   pcmSnapshot.2 == 0 {
                    archiveURL = outputURL
                } else if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
            } else {
                writer.cancelWriting()
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }
        } else {
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            print("[AudioRecorder] stopRecording: no writer/input")
        }
        assetWriter = nil
        assetWriterInput = nil
        outputURL = nil

        print("[AudioRecorder] stopRecording: returning url=\(String(describing: archiveURL)), finalSampleCount=\(pcmSnapshot.0)")
        return RecordingStopResult(
            archiveURL: archiveURL,
            finalSampleCount: pcmSnapshot.0,
            m4aDroppedSampleCount: pcmSnapshot.2,
            pcmComplete: pcmSnapshot.1
        )
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Target format matching SCStream output: 48kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

        let needsConversion = hwFormat.sampleRate != 48000 || hwFormat.channelCount != 1
        var converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var samples: [Float]
            if let converter {
                let ratio = 48000.0 / hwFormat.sampleRate
                let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0,
                      let channelData = converted.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
            } else {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            }

            let capturedSamples = samples
            self.micSampleBuffer.withLock { buf in
                buf.append(contentsOf: capturedSamples)
                // Cap buffer size to prevent unbounded growth
                if buf.count > Self.maxMicBufferSamples {
                    buf.removeFirst(buf.count - Self.maxMicBufferSamples)
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        self.isMicActive = true
    }

    private func stopMicrophoneCapture() {
        guard isMicActive else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micSampleBuffer.withLock { $0.removeAll() }
        isMicActive = false
    }

    /// Creates a new CMSampleBuffer with mic audio mixed into the app audio.
    /// Returns nil if mixing is not needed or fails — caller should use the original buffer.
    private func mixedSampleBuffer(from original: CMSampleBuffer) -> CMSampleBuffer? {
        guard isMicActive else { return nil }
        guard let formatDesc = CMSampleBufferGetFormatDescription(original),
              let blockBuffer = CMSampleBufferGetDataBuffer(original) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        // Copy original audio data
        let sampleCount = totalLength / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: sampleCount)
        memcpy(&floats, dataPointer, totalLength)

        // Read matching mic samples and mix
        let micSamples = micSampleBuffer.withLock { buf -> [Float] in
            let count = min(sampleCount, buf.count)
            let result = Array(buf.prefix(count))
            buf.removeFirst(count)
            return result
        }
        for i in 0..<micSamples.count {
            let mixed = floats[i] + micSamples[i]
            floats[i] = max(-1.0, min(1.0, mixed))
        }

        // Create new block buffer with mixed data
        var newBlockBuffer: CMBlockBuffer?
        var res = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &newBlockBuffer
        )
        guard res == kCMBlockBufferNoErr, let newBlockBuffer else { return nil }

        res = floats.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: newBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: totalLength
            )
        }
        guard res == kCMBlockBufferNoErr else { return nil }

        // Create new sample buffer
        let numSamples = CMSampleBufferGetNumSamples(original)
        let pts = CMSampleBufferGetPresentationTimeStamp(original)

        var newSampleBuffer: CMSampleBuffer?
        res = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &newSampleBuffer
        )
        guard res == noErr else { return nil }

        return newSampleBuffer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioRecorder] SCStream stopped with error: \(error)")
        guard captureLifecycle.withLock({ $0.accepts(streamID: ObjectIdentifier(stream)) }) else { return }
        // Attempt to restart the stream automatically
        restartStream()
    }

    // MARK: - Audio Watchdog

    /// A repeating main-run-loop timer scheduled in `.common` modes, so it keeps
    /// firing during modal sessions (e.g. the Zoom meeting-ended NSAlert) — the
    /// default mode pauses there, which froze the duration display and stall
    /// watchdog for as long as the alert stayed open.
    private static func commonModeTimer(interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func startAudioWatchdog() {
        lastAudioBufferTime.withLock { $0 = Date() }
        audioWatchdogTimer = Self.commonModeTimer(interval: 5.0) { [weak self] in
            self?.checkAudioStall()
        }
    }

    private func stopAudioWatchdog() {
        audioWatchdogTimer?.invalidate()
        audioWatchdogTimer = nil
    }

    private func checkAudioStall() {
        guard state == .recording,
              !captureLifecycle.withLock({ $0.restartInProgress }) else { return }
        let lastTime = lastAudioBufferTime.withLock { $0 }
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed > Self.audioStallThreshold {
            print("[AudioRecorder] audio stall detected: no buffers for \(String(format: "%.1f", elapsed))s, restarting stream")
            restartStream()
        }
    }

    private func restartStream() {
        guard state == .recording,
              let restart = captureLifecycle.withLock({
                  $0.beginRestart()
              }) else { return }
        let generation = restart.generation
        let token = restart.token

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.captureLifecycle.withLock {
                    $0.endRestart(generation: generation, token: token)
                }
                self.restartTask.withLock { handle in
                    if handle?.token == token {
                        handle = nil
                    }
                }
            }
            // Stop the old stream
            if let oldStream = self.stream {
                try? await oldStream.stopCapture()
                self.stream = nil
            }

            guard !Task.isCancelled,
                  self.captureLifecycle.withLock({
                      $0.generation == generation && !$0.closing
                  }) else { return }

            // Rebuild a fresh SCStream with the same app
            guard let app = self.recordingApp else {
                return
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled,
                      self.captureLifecycle.withLock({
                          $0.generation == generation && !$0.closing
                      }) else { return }
                guard let display = content.displays.first else {
                    return
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                try newStream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: self.captureQueue
                )
                let newStreamID = ObjectIdentifier(newStream)
                let activated = await withCheckedContinuation { continuation in
                    self.captureQueue.async {
                        continuation.resume(returning: self.captureLifecycle.withLock {
                            $0.activate(streamID: newStreamID, generation: generation)
                        })
                    }
                }
                guard activated, !Task.isCancelled else { return }
                self.stream = newStream
                try await newStream.startCapture()
                guard !Task.isCancelled,
                      self.captureLifecycle.withLock({
                          $0.generation == generation && $0.accepts(streamID: newStreamID)
                      }) else {
                    try? await newStream.stopCapture()
                    return
                }
                self.lastAudioBufferTime.withLock { $0 = Date() }

                print("[AudioRecorder] stream restarted successfully")
            } catch {
                print("[AudioRecorder] stream restart failed: \(error)")
            }
        }
        let isStillCurrent = captureLifecycle.withLock {
            $0.generation == generation && $0.restartToken == token && !$0.closing
        }
        if isStillCurrent {
            restartTask.withLock { $0 = (token, task) }
        } else {
            task.cancel()
        }
    }

    // MARK: - Zoom Meeting Monitor

    private func startMeetingMonitor(app: SCRunningApplication) {
        guard Self.zoomBundleIDs.contains(app.bundleIdentifier) else { return }
        recordingPID = app.processID
        meetingStarted = false
        meetingEnded = false

        meetingMonitorTimer = Self.commonModeTimer(interval: 10.0) { [weak self] in
            self?.checkZoomMeetingWindows()
        }
    }

    private func stopMeetingMonitor() {
        meetingMonitorTimer?.invalidate()
        meetingMonitorTimer = nil
        recordingPID = nil
        meetingStarted = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        // Run the blocking ps check on a background thread to avoid stalling the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Check if Zoom's CptHost subprocess is running — it only exists during an active call.
            let hasMeeting = self.zoomHasActiveCall(parentPID: pid)

            DispatchQueue.main.async {
                if hasMeeting {
                    self.meetingStarted = true
                } else if self.meetingStarted {
                    self.meetingMonitorTimer?.invalidate()
                    self.meetingMonitorTimer = nil
                    self.meetingEnded = true
                    self.onMeetingEnded?()
                }
            }
        }
    }

    /// Returns true if Zoom's CptHost (call/meeting host) subprocess is running under the given parent PID.
    /// Uses Darwin syscalls instead of spawning a /bin/ps subprocess.
    private func zoomHasActiveCall(parentPID: pid_t) -> Bool {
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let byteCount = proc_listchildpids(parentPID, &childPIDs,
            Int32(childPIDs.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return false }
        let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
        for i in 0..<childCount {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(childPIDs[i], &pathBuf, UInt32(MAXPATHLEN)) > 0 {
                if String(cString: pathBuf).contains("CptHost") { return true }
            }
        }
        return false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard captureLifecycle.withLock({ $0.accepts(streamID: ObjectIdentifier(stream)) }) else { return }

        // Track that we're still receiving audio (for stall detection)
        lastAudioBufferTime.withLock { $0 = Date() }

        // Use mixed buffer if mic is active, otherwise use original
        let bufferToWrite = mixedSampleBuffer(from: sampleBuffer) ?? sampleBuffer

        // Accumulate 16kHz PCM samples for live transcription
        do {
            try accumulatePCMSamples(from: bufferToWrite)
        } catch {
            captureLifecycle.withLock { $0.pcmComplete = false }
            print("[AudioRecorder] canonical PCM conversion failed: \(error)")
        }

        guard let input = assetWriterInput else {
            noteM4ADroppedSamples(bufferToWrite.numSamples)
            print("[AudioRecorder] stream callback: no assetWriterInput")
            return
        }
        guard input.isReadyForMoreMediaData else {
            noteM4ADroppedSamples(bufferToWrite.numSamples)
            print("[AudioRecorder] stream callback: input not ready")
            return
        }

        let success = input.append(bufferToWrite)
        if success {
            let wasFirst = _hasReceivedSamples.withLock { val -> Bool in
                let first = !val
                val = true
                return first
            }
            if wasFirst {
                print("[AudioRecorder] first audio sample appended, numSamples=\(bufferToWrite.numSamples)")
            }
        } else {
            noteM4ADroppedSamples(bufferToWrite.numSamples)
            print("[AudioRecorder] stream callback: append failed, writer.status=\(assetWriter?.status.rawValue ?? -1), error=\(String(describing: assetWriter?.error))")
        }
    }

    private func noteM4ADroppedSamples(_ count: Int) {
        captureLifecycle.withLock {
            $0.m4aDroppedSampleCount += max(0, count)
        }
    }

    /// Extracts Float32 samples from a CMSampleBuffer (48kHz) and resamples to 16kHz
    /// via AVAudioConverter (applies anti-alias filter) for whisper.cpp.
    private func accumulatePCMSamples(from sampleBuffer: CMSampleBuffer) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw CanonicalPCMResamplerError.conversion("missing audio data buffer")
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else {
            throw CanonicalPCMResamplerError.conversion("invalid audio data buffer")
        }

        let sampleCount = totalLength / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)
        let source = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))
        let resampled = try pcmResampler.append(source)
        if !resampled.isEmpty {
            pcmState.withLock { state in
                state.buffer.append(contentsOf: resampled)
            }
        }
    }

    // MARK: - Output URL

    private func makeOutputURL(appName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH'h'"
        let timestamp = df.string(from: Date())
        let baseName: String
        if let custom = customRecordingName, !custom.isEmpty {
            let sanitized = custom.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        } else {
            let sanitized = appName.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        }
        var url = recordingsDir.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDir.appendingPathComponent("\(baseName) \(counter).m4a")
            counter += 1
        }
        return url
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
