import Foundation
import XCTest
@testable import WhisperASRApp

final class TranscriptionPersistenceStoreTests: XCTestCase {
    func testTranscriptionSaveAtRoundTripsAndCreatesDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("nested/item.json")
        let item = TranscriptionItem(fileURL: root.appendingPathComponent("audio.m4a"))
        item.segments = [TranscriptionSegment(start: 0, end: 1, text: "日本語")]
        item.fullText = "日本語"
        item.status = .completed

        try TranscriptionStore.save(item, at: destination)

        let restored = try TranscriptionStore.decodedItem(
            from: Data(contentsOf: destination)
        )
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.fullText, "日本語")
        XCTAssertEqual(restored.status, .completed)
    }

    func testTranscriptionSaveAtPropagatesDirectoryFailure() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        let item = TranscriptionItem(fileURL: root.appendingPathComponent("audio.m4a"))

        XCTAssertThrowsError(
            try TranscriptionStore.save(
                item,
                at: blockingFile.appendingPathComponent("item.json")
            )
        )
    }

    func testRecoveryStoreRejectsOlderGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveRecoveryStore(fileURL: root.appendingPathComponent("recovery.json"))
        let session = UUID()
        await store.beginSession(session)

        let newest = try await store.save(Data("new".utf8), sessionID: session, generation: 2)
        let stale = try await store.save(Data("old".utf8), sessionID: session, generation: 1)
        let stored = try await store.data()

        XCTAssertEqual(newest, .saved)
        XCTAssertEqual(stale, .staleGeneration)
        XCTAssertEqual(stored, Data("new".utf8))
    }

    func testRemovedRecoverySessionRejectsDelayedSave() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveRecoveryStore(fileURL: root.appendingPathComponent("recovery.json"))
        let session = UUID()
        await store.beginSession(session)
        _ = try await store.save(Data("saved".utf8), sessionID: session, generation: 1)

        let removed = try await store.remove(sessionID: session)
        let delayed = try await store.save(
            Data("late".utf8),
            sessionID: session,
            generation: 2
        )
        let exists = await store.exists()
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(delayed, .inactiveSession)
        XCTAssertFalse(exists)
    }

    func testNewSessionCannotBeDeletedOrOverwrittenByOldSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveRecoveryStore(fileURL: root.appendingPathComponent("recovery.json"))
        let first = UUID()
        let second = UUID()
        await store.beginSession(first)
        _ = try await store.save(Data("first".utf8), sessionID: first, generation: 1)
        await store.beginSession(second)
        _ = try await store.save(Data("second".utf8), sessionID: second, generation: 1)

        let staleRemoval = try await store.remove(sessionID: first)
        let staleSave = try await store.save(
            Data("late".utf8),
            sessionID: first,
            generation: 2
        )
        let stored = try await store.data()
        XCTAssertEqual(staleRemoval, .inactiveSession)
        XCTAssertEqual(staleSave, .inactiveSession)
        XCTAssertEqual(stored, Data("second".utf8))
    }

    func testRecoveryStorePropagatesWriteFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        let store = LiveRecoveryStore(
            fileURL: blockingFile.appendingPathComponent("recovery.json")
        )
        let session = UUID()
        await store.beginSession(session)

        do {
            _ = try await store.save(Data("snapshot".utf8), sessionID: session, generation: 1)
            XCTFail("The write should fail.")
        } catch {
            let stored = try await store.data()
            XCTAssertNil(stored)
            try FileManager.default.removeItem(at: blockingFile)
            let retry = try await store.save(
                Data("snapshot".utf8),
                sessionID: session,
                generation: 1
            )
            XCTAssertEqual(retry, .saved)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperASR-PersistenceTests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
