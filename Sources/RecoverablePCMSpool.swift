import Foundation
import os
import Darwin

/// Durable, canonical audio kept independently from the optional M4A archive.
final class RecoverablePCMSpool: @unchecked Sendable {
    static let sampleRate = 16_000
    private static let headerByteCount: UInt64 = 44
    private static let samplesPerSync = sampleRate

    enum Status: String, Codable, Sendable {
        case active
        case partial
        case complete
    }

    struct Progress: Equatable, Sendable {
        let enqueuedThrough: Int
        let writtenThrough: Int
        let durableThrough: Int
    }

    struct Location: Equatable, Sendable {
        let audioURL: URL
        let manifestURL: URL
    }

    struct RecoveryScan: Equatable, Sendable {
        let artifacts: [Artifact]
        let inUseSessionIDs: Set<String>
        let warnings: [String]
    }

    struct Artifact: Equatable, Sendable {
        let sessionID: String
        let audioURL: URL
        let manifestURL: URL
        let sampleCount: Int
        let durableThrough: Int
        let status: Status

        var isComplete: Bool { status == .complete }
        var location: Location { Location(audioURL: audioURL, manifestURL: manifestURL) }
    }

    struct Manifest: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sessionID: String
        let audioFileName: String
        let sampleRate: Int
        let createdAt: Date
        let enqueuedThrough: Int
        let writtenThrough: Int
        let durableThrough: Int
        let status: Status
    }

    enum SpoolError: Error, Equatable, LocalizedError {
        case alreadyExists
        case invalidRange(expectedStart: Int, actual: Range<Int>, sampleCount: Int)
        case closed
        case failed(String)
        case invalidManifest
        case waveTooLarge
        case inUse

        var errorDescription: String? {
            switch self {
            case .alreadyExists:
                "The recovery spool already exists."
            case let .invalidRange(expectedStart, actual, sampleCount):
                "Expected PCM at \(expectedStart), got \(actual) for \(sampleCount) samples."
            case .closed:
                "The recovery spool is already closed."
            case let .failed(message):
                "The recovery spool failed: \(message)"
            case .invalidManifest:
                "The recovery spool manifest is invalid."
            case .waveTooLarge:
                "The recovery WAVE file exceeded the RIFF size limit."
            case .inUse:
                "The recovery spool is still in use by another process."
            }
        }
    }

    let audioURL: URL
    let manifestURL: URL

    private struct State {
        var enqueuedThrough = 0
        var writtenThrough = 0
        var durableThrough = 0
        var closing = false
        var failure: String?
    }

    private let sessionID: String
    private let createdAt: Date
    private let queue = DispatchQueue(label: "com.whisperasr.recoverable-pcm-spool")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handle: FileHandle
    private let queuedWriteCheck: @Sendable () throws -> Void

    convenience init(directoryURL: URL, sessionID: String = UUID().uuidString) throws {
        try self.init(
            audioURL: directoryURL.appendingPathComponent("\(sessionID).canonical-f32.wav"),
            manifestURL: directoryURL.appendingPathComponent("\(sessionID).pcm-spool.json"),
            sessionID: sessionID
        )
    }

    /// The explicit URLs keep integration and failure tests deterministic.
    init(
        audioURL: URL,
        manifestURL: URL,
        sessionID: String = UUID().uuidString,
        createdAt: Date = Date(),
        queuedWriteCheck: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.audioURL = audioURL
        self.manifestURL = manifestURL
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.queuedWriteCheck = queuedWriteCheck

        let fileManager = FileManager.default
        guard audioURL.lastPathComponent == "\(sessionID).canonical-f32.wav",
              manifestURL.lastPathComponent == "\(sessionID).pcm-spool.json" else {
            throw SpoolError.invalidManifest
        }
        guard audioURL.deletingLastPathComponent().standardizedFileURL
                == manifestURL.deletingLastPathComponent().standardizedFileURL else {
            throw SpoolError.invalidManifest
        }
        try fileManager.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: audioURL.path),
              !fileManager.fileExists(atPath: manifestURL.path) else {
            throw SpoolError.alreadyExists
        }
        guard fileManager.createFile(atPath: audioURL.path, contents: Self.waveHeader(dataBytes: 0)) else {
            throw SpoolError.failed("Could not create \(audioURL.lastPathComponent).")
        }

        do {
            handle = try FileHandle(forUpdating: audioURL)
            guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw SpoolError.inUse
            }
            try handle.synchronize()
            try Self.writeManifest(
                Manifest(
                    schemaVersion: Manifest.currentSchemaVersion,
                    sessionID: sessionID,
                    audioFileName: audioURL.lastPathComponent,
                    sampleRate: Self.sampleRate,
                    createdAt: createdAt,
                    enqueuedThrough: 0,
                    writtenThrough: 0,
                    durableThrough: 0,
                    status: .active
                ),
                to: manifestURL
            )
        } catch {
            try? fileManager.removeItem(at: audioURL)
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    var progress: Progress {
        state.withLock {
            Progress(
                enqueuedThrough: $0.enqueuedThrough,
                writtenThrough: $0.writtenThrough,
                durableThrough: $0.durableThrough
            )
        }
    }

    /// Copies a block and queues it without making ScreenCaptureKit wait for
    /// disk I/O. The serial spool queue preserves callback order.
    func enqueue(samples: [Float], range: Range<Int>) throws {
        let immediateError: SpoolError? = state.withLock { current in
            if let failure = current.failure { return .failed(failure) }
            guard !current.closing else { return .closed }
            let expectedStart = current.enqueuedThrough
            guard range.lowerBound == expectedStart,
                  range.count == samples.count else {
                return .invalidRange(
                    expectedStart: expectedStart,
                    actual: range,
                    sampleCount: samples.count
                )
            }
            current.enqueuedThrough = range.upperBound
            queue.async { [self] in
                guard state.withLock({ $0.failure == nil }) else { return }
                do {
                    try queuedWriteCheck()
                    let bytes = Self.floatData(samples)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                    let shouldSync = state.withLock { current -> Bool in
                        current.writtenThrough = range.upperBound
                        return current.writtenThrough - current.durableThrough >= Self.samplesPerSync
                    }
                    if shouldSync {
                        try synchronize(status: .active)
                    }
                } catch {
                    state.withLock { $0.failure = error.localizedDescription }
                }
            }
            return nil
        }
        if let immediateError { throw immediateError }
    }

    func append(samples: [Float], range: Range<Int>) async throws {
        try enqueue(samples: samples, range: range)
        try await waitUntilWritten(through: range.upperBound)
    }

    func waitUntilWritten(through sample: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let failure = state.withLock({ $0.failure }) {
                    continuation.resume(throwing: SpoolError.failed(failure))
                } else if state.withLock({ $0.writtenThrough }) < sample {
                    continuation.resume(throwing: SpoolError.failed(
                        "The spool queue stopped before sample \(sample)."
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func finish(complete: Bool) async throws -> Artifact {
        try await withCheckedThrowingContinuation { continuation in
            let immediateError: SpoolError? = state.withLock { current in
                if let failure = current.failure { return .failed(failure) }
                guard !current.closing else { return .closed }
                current.closing = true
                queue.async { [self] in
                    do {
                        if let failure = state.withLock({ $0.failure }) {
                            throw SpoolError.failed(failure)
                        }
                        let status: Status = complete ? .complete : .partial
                        try synchronize(status: status)
                        try handle.close()
                        let snapshot = state.withLock { $0 }
                        continuation.resume(returning: Artifact(
                            sessionID: sessionID,
                            audioURL: audioURL,
                            manifestURL: manifestURL,
                            sampleCount: snapshot.writtenThrough,
                            durableThrough: snapshot.durableThrough,
                            status: status
                        ))
                    } catch {
                        let message = error.localizedDescription
                        state.withLock { $0.failure = message }
                        continuation.resume(throwing: SpoolError.failed(message))
                    }
                }
                return nil
            }
            if let immediateError {
                continuation.resume(throwing: immediateError)
            }
        }
    }

    /// Repairs an abandoned spool using the file length as the source of truth.
    static func repair(manifestURL: URL) throws -> Artifact? {
        let manifest = try readManifest(at: manifestURL)
        let audioURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(manifest.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        let resourceValues = try audioURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true else {
            throw SpoolError.invalidManifest
        }

        let handle = try FileHandle(forUpdating: audioURL)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw SpoolError.inUse
        }
        defer {
            _ = flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        return try repairLockedAudio(
            handle: handle,
            audioURL: audioURL,
            manifestURL: manifestURL,
            sessionID: manifest.sessionID,
            createdAt: manifest.createdAt
        )
    }

    private static func repairLockedAudio(
        handle: FileHandle,
        audioURL: URL,
        manifestURL: URL,
        sessionID: String,
        createdAt: Date
    ) throws -> Artifact? {
        let size = try handle.seekToEnd()
        guard size >= headerByteCount else { throw SpoolError.invalidManifest }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: Int(headerByteCount)) ?? Data()
        guard isCanonicalWaveHeader(header) else { throw SpoolError.invalidManifest }
        let availableBytes = size > headerByteCount ? size - headerByteCount : 0
        let dataBytes = availableBytes - (availableBytes % UInt64(MemoryLayout<Float>.size))
        guard dataBytes > 0 else { return nil }
        guard dataBytes <= UInt64(UInt32.max - 36) else { throw SpoolError.waveTooLarge }

        try handle.truncate(atOffset: headerByteCount + dataBytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: waveHeader(dataBytes: UInt32(dataBytes)))
        try handle.synchronize()

        let sampleCount = Int(dataBytes) / MemoryLayout<Float>.size
        let repaired = Manifest(
            schemaVersion: Manifest.currentSchemaVersion,
            sessionID: sessionID,
            audioFileName: audioURL.lastPathComponent,
            sampleRate: sampleRate,
            createdAt: createdAt,
            enqueuedThrough: sampleCount,
            writtenThrough: sampleCount,
            durableThrough: sampleCount,
            status: .partial
        )
        try writeManifest(repaired, to: manifestURL)
        return Artifact(
            sessionID: sessionID,
            audioURL: audioURL,
            manifestURL: manifestURL,
            sampleCount: sampleCount,
            durableThrough: sampleCount,
            status: .partial
        )
    }

    static func recoverOrphans(in directoryURL: URL) throws -> [Artifact] {
        try scanOrphans(in: directoryURL).artifacts
    }

    static func scanOrphans(in directoryURL: URL) throws -> RecoveryScan {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return RecoveryScan(artifacts: [], inUseSessionIDs: [], warnings: [])
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let manifests = urls
            .filter { $0.lastPathComponent.hasSuffix(".pcm-spool.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var artifacts: [Artifact] = []
        var inUseSessionIDs: Set<String> = []
        var warnings: [String] = []
        for url in manifests {
            do {
                let manifest = try readManifest(at: url)
                if manifest.status == .complete,
                   let complete = try completeArtifact(manifest: manifest, manifestURL: url) {
                    artifacts.append(complete)
                } else if let repaired = try repair(manifestURL: url) {
                    artifacts.append(repaired)
                } else {
                    try removeLocation(Location(
                        audioURL: url.deletingLastPathComponent()
                            .appendingPathComponent(manifest.audioFileName),
                        manifestURL: url
                    ))
                }
            } catch SpoolError.inUse {
                let suffix = ".pcm-spool.json"
                inUseSessionIDs.insert(String(url.lastPathComponent.dropLast(suffix.count)))
                continue
            } catch {
                do {
                    if let salvaged = try salvageCorruptManifest(at: url) {
                        artifacts.append(salvaged)
                        warnings.append(
                            "Damaged recovery metadata was rebuilt from its canonical audio."
                        )
                        continue
                    }
                } catch SpoolError.inUse {
                    let suffix = ".pcm-spool.json"
                    inUseSessionIDs.insert(
                        String(url.lastPathComponent.dropLast(suffix.count))
                    )
                    continue
                } catch {
                    // Preserve the original scan error in the quarantine report.
                }
                let warning: String
                do {
                    warning = try quarantine(
                        manifestURL: url,
                        reason: error.localizedDescription
                    )
                } catch let quarantineError {
                    warning = "A damaged recovery spool could not be quarantined: \(quarantineError.localizedDescription)"
                }
                warnings.append(warning)
                print("[RecoverablePCMSpool] \(warning)")
            }
        }
        return RecoveryScan(
            artifacts: artifacts,
            inUseSessionIDs: inUseSessionIDs,
            warnings: warnings
        )
    }

    private static func salvageCorruptManifest(at manifestURL: URL) throws -> Artifact? {
        let suffix = ".pcm-spool.json"
        guard manifestURL.lastPathComponent.hasSuffix(suffix) else { return nil }
        let sessionID = String(manifestURL.lastPathComponent.dropLast(suffix.count))
        guard !sessionID.isEmpty else { return nil }
        let audioURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent("\(sessionID).canonical-f32.wav")
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        let values = try audioURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .creationDateKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw SpoolError.invalidManifest
        }
        let handle = try FileHandle(forUpdating: audioURL)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw SpoolError.inUse
        }
        defer {
            _ = flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        return try repairLockedAudio(
            handle: handle,
            audioURL: audioURL,
            manifestURL: manifestURL,
            sessionID: sessionID,
            createdAt: values.creationDate ?? Date()
        )
    }

    static func removeArtifact(
        _ artifact: Artifact,
        retaining retainedURL: URL? = nil
    ) throws {
        try removeLocation(artifact.location, retaining: retainedURL)
    }

    static func removeLocation(
        _ location: Location,
        retaining retainedURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        var removalHandle: FileHandle?
        if fileManager.fileExists(atPath: location.audioURL.path) {
            let handle = try FileHandle(forUpdating: location.audioURL)
            guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                try? handle.close()
                throw SpoolError.inUse
            }
            removalHandle = handle
        }
        defer {
            if let removalHandle {
                _ = flock(removalHandle.fileDescriptor, LOCK_UN)
                try? removalHandle.close()
            }
        }
        if location.audioURL.standardizedFileURL != retainedURL?.standardizedFileURL,
           fileManager.fileExists(atPath: location.audioURL.path) {
            try fileManager.removeItem(at: location.audioURL)
        }
        if fileManager.fileExists(atPath: location.manifestURL.path) {
            try fileManager.removeItem(at: location.manifestURL)
        }
    }

    private static func quarantine(manifestURL: URL, reason: String) throws -> String {
        let fileManager = FileManager.default
        let directory = manifestURL.deletingLastPathComponent()
        let quarantineDirectory = directory.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )
        let suffix = ".pcm-spool.json"
        let sessionName = manifestURL.lastPathComponent.hasSuffix(suffix)
            ? String(manifestURL.lastPathComponent.dropLast(suffix.count))
            : UUID().uuidString
        let quarantineID = "\(sessionName)-\(UUID().uuidString)"
        let quarantinedManifest = quarantineDirectory.appendingPathComponent(
            "\(quarantineID).pcm-spool.invalid"
        )
        try fileManager.moveItem(at: manifestURL, to: quarantinedManifest)

        let audioURL = directory.appendingPathComponent(
            "\(sessionName).canonical-f32.wav"
        )
        if fileManager.fileExists(atPath: audioURL.path) {
            let quarantinedAudio = quarantineDirectory.appendingPathComponent(
                "\(quarantineID).canonical-f32.wav"
            )
            do {
                try fileManager.moveItem(at: audioURL, to: quarantinedAudio)
            } catch {
                return "Recovery metadata was quarantined, but its audio could not be moved: \(error.localizedDescription)"
            }
        }
        return "A damaged recovery spool was quarantined: \(reason)"
    }

    private func synchronize(status: Status) throws {
        let snapshot = state.withLock { $0 }
        let dataBytes = snapshot.writtenThrough * MemoryLayout<Float>.size
        guard dataBytes <= Int(UInt32.max - 36) else { throw SpoolError.waveTooLarge }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.waveHeader(dataBytes: UInt32(dataBytes)))
        try handle.synchronize()
        state.withLock { $0.durableThrough = $0.writtenThrough }
        let durable = state.withLock { $0 }
        try Self.writeManifest(
            Manifest(
                schemaVersion: Manifest.currentSchemaVersion,
                sessionID: sessionID,
                audioFileName: audioURL.lastPathComponent,
                sampleRate: Self.sampleRate,
                createdAt: createdAt,
                enqueuedThrough: durable.enqueuedThrough,
                writtenThrough: durable.writtenThrough,
                durableThrough: durable.durableThrough,
                status: status
            ),
            to: manifestURL
        )
    }

    private static func readManifest(at url: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == Manifest.currentSchemaVersion,
              manifest.sampleRate == sampleRate,
              !manifest.audioFileName.isEmpty,
              manifest.audioFileName != ".",
              manifest.audioFileName != "..",
              !manifest.audioFileName.contains("/"),
              manifest.audioFileName == "\(manifest.sessionID).canonical-f32.wav",
              url.lastPathComponent == "\(manifest.sessionID).pcm-spool.json" else {
            throw SpoolError.invalidManifest
        }
        return manifest
    }

    private static func completeArtifact(
        manifest: Manifest,
        manifestURL: URL
    ) throws -> Artifact? {
        let audioURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(manifest.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        let resourceValues = try audioURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true else {
            throw SpoolError.invalidManifest
        }
        let handle = try FileHandle(forReadingFrom: audioURL)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw SpoolError.inUse
        }
        defer {
            _ = flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        let size = try handle.seekToEnd()
        guard size >= headerByteCount else { return nil }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: Int(headerByteCount)) ?? Data()
        let dataBytes = size - headerByteCount
        let sampleCount = Int(dataBytes) / MemoryLayout<Float>.size
        guard dataBytes <= UInt64(UInt32.max - 36),
              sampleCount > 0,
              dataBytes % UInt64(MemoryLayout<Float>.size) == 0,
              isCanonicalWaveHeader(header),
              littleEndianUInt32(header, at: 40) == UInt32(dataBytes),
              littleEndianUInt32(header, at: 4) == UInt32(36 + dataBytes),
              manifest.enqueuedThrough == sampleCount,
              manifest.writtenThrough == sampleCount,
              manifest.durableThrough == sampleCount else {
            return nil
        }
        return Artifact(
            sessionID: manifest.sessionID,
            audioURL: audioURL,
            manifestURL: manifestURL,
            sampleCount: sampleCount,
            durableThrough: sampleCount,
            status: .complete
        )
    }

    private static func writeManifest(_ manifest: Manifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func isCanonicalWaveHeader(_ data: Data) -> Bool {
        guard data.count >= Int(headerByteCount) else { return false }
        return String(data: data[0..<4], encoding: .ascii) == "RIFF"
            && String(data: data[8..<16], encoding: .ascii) == "WAVEfmt "
            && littleEndianUInt32(data, at: 16) == 16
            && littleEndianUInt16(data, at: 20) == 3
            && littleEndianUInt16(data, at: 22) == 1
            && littleEndianUInt32(data, at: 24) == UInt32(sampleRate)
            && littleEndianUInt32(data, at: 28)
                == UInt32(sampleRate * MemoryLayout<Float>.size)
            && littleEndianUInt16(data, at: 32) == UInt16(MemoryLayout<Float>.size)
            && littleEndianUInt16(data, at: 34) == 32
            && String(data: data[36..<40], encoding: .ascii) == "data"
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func floatData(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func waveHeader(dataBytes: UInt32) -> Data {
        var result = Data()
        result.append(contentsOf: "RIFF".utf8)
        result.appendLittleEndian(36 + dataBytes)
        result.append(contentsOf: "WAVEfmt ".utf8)
        result.appendLittleEndian(UInt32(16))
        result.appendLittleEndian(UInt16(3)) // IEEE Float
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(UInt32(sampleRate))
        result.appendLittleEndian(UInt32(sampleRate * MemoryLayout<Float>.size))
        result.appendLittleEndian(UInt16(MemoryLayout<Float>.size))
        result.appendLittleEndian(UInt16(32))
        result.append(contentsOf: "data".utf8)
        result.appendLittleEndian(dataBytes)
        return result
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
