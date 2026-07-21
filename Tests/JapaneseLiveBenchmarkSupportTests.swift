import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseLiveBenchmarkSupportTests: XCTestCase {
    func testBacklogWatchdogRequiresContinuousMinute() {
        var watchdog = BenchmarkBacklogWatchdog()
        let start: UInt64 = 1_000_000_000
        XCTAssertFalse(watchdog.observe(milliseconds: 30_001, at: start))
        XCTAssertFalse(watchdog.observe(
            milliseconds: 30_001,
            at: start + BenchmarkBacklogWatchdog.graceNanoseconds - 1
        ))
        XCTAssertTrue(watchdog.observe(
            milliseconds: 30_001,
            at: start + BenchmarkBacklogWatchdog.graceNanoseconds
        ))
        XCTAssertFalse(watchdog.observe(
            milliseconds: 29_999,
            at: start + BenchmarkBacklogWatchdog.graceNanoseconds + 1
        ))
    }

    func testFullWindowCoversFixtureExactly() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = try JapaneseBenchmarkSupport.loadManifest(
            at: root.appendingPathComponent(
                "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
            )
        )
        let window = JapaneseBenchmarkSupport.fullWindow(for: manifest)
        XCTAssertEqual(window.startSample, 0)
        XCTAssertEqual(window.endSample, manifest.fixture.sampleCount)
        XCTAssertEqual(window.sampleCount, manifest.fixture.sampleCount)
    }

    @available(macOS 26.4, *)
    func testFinalTranslatorIsFIFOAndAppendOnly() async {
        let translator = BenchmarkFinalTranslator(
            service: nil,
            unavailableReason: "offline fixture"
        )
        let now = DispatchTime.now().uptimeNanoseconds
        await translator.submit(
            finalID: "first",
            source: "一",
            sourceStartSample: 0,
            sourceEndSample: 1,
            endpointUptimeNanoseconds: now
        )
        await translator.submit(
            finalID: "second",
            source: "二",
            sourceStartSample: 1,
            sourceEndSample: 2,
            endpointUptimeNanoseconds: now
        )
        let result = await translator.finish()
        XCTAssertTrue(result.appendOnly)
        XCTAssertEqual(result.events.map(\.finalID), ["first", "second"])
        XCTAssertEqual(result.events.map(\.error), ["offline fixture", "offline fixture"])
    }

    @available(macOS 26.4, *)
    func testFinalTranslatorRejectsDuplicateIdentity() async {
        let translator = BenchmarkFinalTranslator(service: nil)
        let now = DispatchTime.now().uptimeNanoseconds
        for source in ["一", "二"] {
            await translator.submit(
                finalID: "duplicate",
                source: source,
                sourceStartSample: 0,
                sourceEndSample: 1,
                endpointUptimeNanoseconds: now
            )
        }
        let result = await translator.finish()
        XCTAssertFalse(result.appendOnly)
        XCTAssertEqual(result.events.count, 1)
    }
}
