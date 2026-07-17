import XCTest
@testable import WhisperASRApp

final class RecoverablePCMSpoolTests: XCTestCase {
    func testWritesFloatWaveAndFinishesAtExactSample() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "exact")

        try await spool.append(samples: [0.25, -0.5], range: 0..<2)
        let artifact = try await spool.finish(complete: true)
        let data = try Data(contentsOf: artifact.audioURL)

        XCTAssertEqual(artifact.sampleCount, 2)
        XCTAssertEqual(artifact.sessionID, "exact")
        XCTAssertEqual(artifact.durableThrough, 2)
        XCTAssertTrue(artifact.isComplete)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(uint16(data, at: 20), 3)
        XCTAssertEqual(uint16(data, at: 22), 1)
        XCTAssertEqual(uint32(data, at: 24), 16_000)
        XCTAssertEqual(uint16(data, at: 34), 32)
        XCTAssertEqual(uint32(data, at: 40), 8)
        XCTAssertEqual(Float(bitPattern: uint32(data, at: 44)), 0.25)
        XCTAssertEqual(Float(bitPattern: uint32(data, at: 48)), -0.5)
    }

    func testRejectsNonContiguousInput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "contiguous")

        do {
            try await spool.append(samples: [1], range: 1..<2)
            XCTFail("Expected a range error")
        } catch let error as RecoverablePCMSpool.SpoolError {
            XCTAssertEqual(
                error,
                .invalidRange(expectedStart: 0, actual: 1..<2, sampleCount: 1)
            )
        }
        try await spool.append(samples: [1], range: 0..<1)
        _ = try await spool.finish(complete: false)
    }

    func testSynchronizesOnlyAfterOneSecondThenAtFinish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "durable")

        try await spool.append(samples: Array(repeating: 0, count: 15_999), range: 0..<15_999)
        XCTAssertEqual(spool.progress.enqueuedThrough, 15_999)
        XCTAssertEqual(spool.progress.writtenThrough, 15_999)
        XCTAssertEqual(spool.progress.durableThrough, 0)

        try await spool.append(samples: [0], range: 15_999..<16_000)
        XCTAssertEqual(spool.progress.durableThrough, 16_000)
        try await spool.append(samples: [0], range: 16_000..<16_001)
        XCTAssertEqual(spool.progress.durableThrough, 16_000)

        let artifact = try await spool.finish(complete: false)
        XCTAssertEqual(artifact.sampleCount, 16_001)
        XCTAssertEqual(artifact.durableThrough, 16_001)
        XCTAssertEqual(artifact.status, .partial)
    }

    func testAsynchronousWriteFailureNeverAdvancesDurabilityOrCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = WriteGate(successfulWrites: 1)
        var spool: RecoverablePCMSpool? = try RecoverablePCMSpool(
            audioURL: fixture.url.appendingPathComponent("disk.canonical-f32.wav"),
            manifestURL: fixture.url.appendingPathComponent("disk.pcm-spool.json"),
            sessionID: "disk",
            queuedWriteCheck: { try gate.check() }
        )
        let first = Array(repeating: Float.zero, count: 16_000)
        try await spool?.append(samples: first, range: 0..<16_000)
        XCTAssertEqual(spool?.progress.durableThrough, 16_000)

        try spool?.enqueue(samples: [1], range: 16_000..<16_001)
        do {
            _ = try await spool?.finish(complete: true)
            XCTFail("Expected the queued write failure to fail Finish")
        } catch {
            // Expected.
        }
        XCTAssertEqual(spool?.progress.writtenThrough, 16_000)
        XCTAssertEqual(spool?.progress.durableThrough, 16_000)

        spool = nil
        let recovered = try RecoverablePCMSpool.scanOrphans(in: fixture.url)
        XCTAssertEqual(recovered.artifacts.map(\.sampleCount), [16_000])
        XCTAssertEqual(recovered.artifacts.map(\.status), [.partial])
    }

    func testRepairRewritesHeaderAndDropsIncompleteFloat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var spool: RecoverablePCMSpool? = try fixture.makeSpool(id: "repair")
        try await spool?.append(samples: [0.25, 0.5], range: 0..<2)
        let artifact = try await spool!.finish(complete: false)
        spool = nil

        let handle = try FileHandle(forUpdating: artifact.audioURL)
        // Corrupt the advisory sizes, not the canonical format identity.
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xAA, 0xBB]))
        try handle.close()

        let repaired = try XCTUnwrap(RecoverablePCMSpool.repair(
            manifestURL: artifact.manifestURL
        ))
        let data = try Data(contentsOf: repaired.audioURL)
        XCTAssertEqual(repaired.sampleCount, 2)
        XCTAssertEqual(repaired.status, .partial)
        XCTAssertEqual(data.count, 52)
        XCTAssertEqual(uint16(data, at: 20), 3)
        XCTAssertEqual(uint32(data, at: 40), 8)
    }

    func testRecoversCompleteAndPartialNonemptyOrphans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var orphan: RecoverablePCMSpool? = try fixture.makeSpool(id: "orphan")
        try await orphan?.append(samples: [0.75], range: 0..<1)
        let orphanManifest = try XCTUnwrap(orphan?.manifestURL)
        orphan = nil

        var empty: RecoverablePCMSpool? = try fixture.makeSpool(id: "empty")
        empty = nil

        let complete = try fixture.makeSpool(id: "complete")
        try await complete.append(samples: [1], range: 0..<1)
        _ = try await complete.finish(complete: true)
        try Data("broken".utf8).write(
            to: fixture.url.appendingPathComponent("broken.pcm-spool.json")
        )

        let recovered = try RecoverablePCMSpool.recoverOrphans(in: fixture.url)
        XCTAssertEqual(recovered.map { $0.manifestURL.resolvingSymlinksInPath() }, [
            fixture.url.appendingPathComponent("complete.pcm-spool.json"),
            orphanManifest,
        ].map { $0.resolvingSymlinksInPath() })
        XCTAssertEqual(recovered.map(\.sampleCount), [1, 1])
        XCTAssertEqual(recovered.map(\.status), [.complete, .partial])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url.appendingPathComponent("empty.canonical-f32.wav").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url.appendingPathComponent("empty.pcm-spool.json").path
        ))
        _ = empty
    }

    func testRecoveryScannerNeverTouchesALiveSpool() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var spool: RecoverablePCMSpool? = try fixture.makeSpool(id: "live")
        try await spool?.append(samples: [0.25], range: 0..<1)
        let before = try Data(contentsOf: fixture.url.appendingPathComponent(
            "live.canonical-f32.wav"
        ))

        let activeScan = try RecoverablePCMSpool.scanOrphans(in: fixture.url)

        XCTAssertTrue(activeScan.artifacts.isEmpty)
        XCTAssertEqual(activeScan.inUseSessionIDs, ["live"])
        XCTAssertEqual(
            try Data(contentsOf: fixture.url.appendingPathComponent(
                "live.canonical-f32.wav"
            )),
            before
        )

        spool = nil
        let crashedScan = try RecoverablePCMSpool.scanOrphans(in: fixture.url)
        XCTAssertEqual(crashedScan.artifacts.map(\.sessionID), ["live"])
    }

    func testRemovalRefusesALiveSpool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var spool: RecoverablePCMSpool? = try fixture.makeSpool(id: "owned")
        let location = RecoverablePCMSpool.Location(
            audioURL: try XCTUnwrap(spool?.audioURL),
            manifestURL: try XCTUnwrap(spool?.manifestURL)
        )

        XCTAssertThrowsError(try RecoverablePCMSpool.removeLocation(location)) { error in
            XCTAssertEqual(error as? RecoverablePCMSpool.SpoolError, .inUse)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.audioURL.path))

        spool = nil
        XCTAssertNoThrow(try RecoverablePCMSpool.removeLocation(location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.manifestURL.path))
    }

    func testCorruptManifestIsQuarantinedAndDoesNotRepeat() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.url.appendingPathComponent("broken.pcm-spool.json")
        let audio = fixture.url.appendingPathComponent("broken.canonical-f32.wav")
        try Data("broken".utf8).write(to: manifest)
        try Data(repeating: 1, count: 64).write(to: audio)

        let first = try RecoverablePCMSpool.scanOrphans(in: fixture.url)
        let second = try RecoverablePCMSpool.scanOrphans(in: fixture.url)

        XCTAssertEqual(first.warnings.count, 1)
        XCTAssertTrue(second.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let quarantine = fixture.url.appendingPathComponent("Quarantine")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count,
            2
        )
    }

    func testCorruptManifestWithCanonicalAudioIsRebuilt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "salvage")
        try await spool.append(samples: [0.25, -0.25], range: 0..<2)
        let artifact = try await spool.finish(complete: false)
        try Data("broken".utf8).write(to: artifact.manifestURL, options: .atomic)

        let scan = try RecoverablePCMSpool.scanOrphans(in: fixture.url)

        XCTAssertEqual(scan.artifacts.map(\.sessionID), ["salvage"])
        XCTAssertEqual(scan.artifacts.map(\.sampleCount), [2])
        XCTAssertEqual(scan.artifacts.map(\.status), [.partial])
        XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertNoThrow(try JSONDecoder().decode(
            RecoverablePCMSpool.Manifest.self,
            from: Data(contentsOf: artifact.manifestURL)
        ))
    }

    func testArchiveExportCopiesCompleteWaveAndKeepsRecoveryArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "archive")
        try await spool.append(samples: [0.25, -0.5], range: 0..<2)
        let artifact = try await spool.finish(complete: true)

        let archive = try AudioRecorder.exportRecoveryWave(
            artifact,
            beside: fixture.url.appendingPathComponent("Recording.m4a")
        )

        XCTAssertEqual(archive.lastPathComponent, "Recording.wav")
        XCTAssertEqual(
            try Data(contentsOf: archive),
            try Data(contentsOf: artifact.audioURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.manifestURL.path))
    }

    func testRequiresAudioAndManifestToShareRecoveryDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try RecoverablePCMSpool(
            audioURL: fixture.url.appendingPathComponent("audio/sample.canonical-f32.wav"),
            manifestURL: fixture.url.appendingPathComponent("manifest/sample.pcm-spool.json"),
            sessionID: "sample"
        )) { error in
            XCTAssertEqual(error as? RecoverablePCMSpool.SpoolError, .invalidManifest)
        }
    }

    func testRepairRejectsAFileWhoseCanonicalFormatIdentityChanged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spool = try fixture.makeSpool(id: "identity")
        try await spool.append(samples: [0.5], range: 0..<1)
        let artifact = try await spool.finish(complete: false)

        let handle = try FileHandle(forUpdating: artifact.audioURL)
        try handle.seek(toOffset: 20)
        try handle.write(contentsOf: Data([1, 0])) // PCM integer, not IEEE Float
        try handle.close()

        XCTAssertThrowsError(try RecoverablePCMSpool.repair(
            manifestURL: artifact.manifestURL
        )) { error in
            XCTAssertEqual(error as? RecoverablePCMSpool.SpoolError, .invalidManifest)
        }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var successfulWrites: Int

    init(successfulWrites: Int) {
        self.successfulWrites = successfulWrites
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard successfulWrites > 0 else { throw TestWriteError.diskFull }
        successfulWrites -= 1
    }
}

private enum TestWriteError: Error {
    case diskFull
}

private struct Fixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoverablePCMSpoolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeSpool(id: String) throws -> RecoverablePCMSpool {
        try RecoverablePCMSpool(
            audioURL: url.appendingPathComponent("\(id).canonical-f32.wav"),
            manifestURL: url.appendingPathComponent("\(id).pcm-spool.json"),
            sessionID: id,
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
