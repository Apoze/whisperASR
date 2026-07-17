import XCTest
@testable import WhisperASRApp

final class AudioRecorderReliabilityTests: XCTestCase {
    func testCanonicalResamplerPreservesChunkedInputThroughEOS() throws {
        let input = (0..<48_017).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }

        let whole = try CanonicalPCMResampler(outputFrameCapacity: 37)
        var wholeOutput = try whole.append(input)
        wholeOutput += try whole.finish()

        let chunked = try CanonicalPCMResampler(outputFrameCapacity: 19)
        var chunkedOutput: [Float] = []
        var cursor = 0
        let chunkSizes = [1, 47, 480, 997, 2_111, 7_003]
        var chunkIndex = 0
        while cursor < input.count {
            let end = min(
                input.count,
                cursor + chunkSizes[chunkIndex % chunkSizes.count]
            )
            chunkedOutput += try chunked.append(Array(input[cursor..<end]))
            cursor = end
            chunkIndex += 1
        }
        chunkedOutput += try chunked.finish()

        XCTAssertFalse(wholeOutput.isEmpty)
        XCTAssertEqual(
            wholeOutput.count,
            Int((Double(input.count) / 3).rounded())
        )
        XCTAssertEqual(chunkedOutput.count, wholeOutput.count)
        XCTAssertEqual(try chunked.finish(), [])
        for (actual, expected) in zip(chunkedOutput, wholeOutput) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertThrowsError(try chunked.append([0.25]))
        chunked.reset()
        XCTAssertFalse(try chunked.append(input).isEmpty)
        _ = try chunked.finish()
    }

    func testCaptureLifecycleRejectsLateAndPreviousGenerationCallbacks() {
        var lifecycle = AudioRecorder.CaptureLifecycle()
        let firstObject = NSObject()
        let secondObject = NSObject()
        let firstStream = ObjectIdentifier(firstObject)
        let secondStream = ObjectIdentifier(secondObject)

        let firstGeneration = lifecycle.beginSession()
        XCTAssertTrue(lifecycle.activate(
            streamID: firstStream,
            generation: firstGeneration
        ))
        XCTAssertTrue(lifecycle.accepts(streamID: firstStream))

        lifecycle.beginSeal()
        XCTAssertFalse(lifecycle.activate(
            streamID: secondStream,
            generation: firstGeneration
        ))
        lifecycle.seal(finalSampleCount: 123)
        XCTAssertFalse(lifecycle.accepts(streamID: firstStream))
        XCTAssertEqual(lifecycle.sealedFinalSampleCount, 123)

        let secondGeneration = lifecycle.beginSession()
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        XCTAssertFalse(lifecycle.activate(
            streamID: firstStream,
            generation: firstGeneration
        ))
        XCTAssertTrue(lifecycle.activate(
            streamID: secondStream,
            generation: secondGeneration
        ))
        XCTAssertFalse(lifecycle.accepts(streamID: firstStream))
        XCTAssertTrue(lifecycle.accepts(streamID: secondStream))
    }

    func testCaptureLifecycleAllowsOnlyOneRestartAndSealsItsCounters() {
        var lifecycle = AudioRecorder.CaptureLifecycle()
        let generation = lifecycle.beginSession()
        XCTAssertTrue(lifecycle.activate(
            streamID: ObjectIdentifier(NSObject()),
            generation: generation
        ))
        XCTAssertEqual(lifecycle.beginRestart()?.generation, generation)
        XCTAssertNil(lifecycle.beginRestart())
        let token = lifecycle.restartToken
        XCTAssertNotNil(token)
        lifecycle.endRestart(generation: generation, token: token!)
        XCTAssertEqual(lifecycle.beginRestart()?.generation, generation)

        lifecycle.m4aDroppedSampleCount = 32
        lifecycle.pcmComplete = false
        lifecycle.beginSeal()
        lifecycle.seal(finalSampleCount: 456)
        XCTAssertFalse(lifecycle.restartInProgress)
        XCTAssertEqual(lifecycle.m4aDroppedSampleCount, 32)
        XCTAssertFalse(lifecycle.pcmComplete)
    }
}
