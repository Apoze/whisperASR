import AVFoundation
import Foundation
import XCTest
@testable import WhisperASRApp

private enum StereoBenchmarkChannel: String, CaseIterable, Codable {
    case currentMono = "current-mono"
    case channel0 = "channel-0"
    case channel1 = "channel-1"
    case averageMix = "average-mix"
}

private struct StereoBenchmarkAudio {
    let currentMono: [Float]
    let left: [Float]
    let right: [Float]

    func samples(for channel: StereoBenchmarkChannel) -> [Float] {
        switch channel {
        case .currentMono: currentMono
        case .channel0: left
        case .channel1: right
        case .averageMix: zip(left, right).map { ($0 + $1) * 0.5 }
        }
    }
}

private enum StereoBenchmarkLoader {
    static func load(url: URL) async throws -> StereoBenchmarkAudio {
        async let currentMono = AudioLoader.loadSamples(url: url)
        let stereo = try await loadStereo(url: url)
        let mono = try await currentMono
        guard !mono.isEmpty,
              mono.count == stereo.left.count,
              mono.count == stereo.right.count else {
            throw NSError(
                domain: "StereoChannelBakeoff",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Mono and stereo decodes are not sample-aligned: \(mono.count), \(stereo.left.count), \(stereo.right.count)."]
            )
        }
        let average = zip(stereo.left, stereo.right).map { ($0 + $1) * 0.5 }
        guard zeroLagCorrelation(mono, average) >= 0.99 else {
            throw NSError(
                domain: "StereoChannelBakeoff",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "The current mono decode is not aligned with the stereo decode."]
            )
        }
        return StereoBenchmarkAudio(
            currentMono: mono,
            left: stereo.left,
            right: stereo.right
        )
    }

    private static func zeroLagCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count, 160_000)
        guard count > 0 else { return 0 }
        var dot = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0
        for index in 0..<count {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsEnergy += left * left
            rhsEnergy += right * right
        }
        guard lhsEnergy > 0, rhsEnergy > 0 else { return 0 }
        return dot / sqrt(lhsEnergy * rhsEnergy)
    }

    private static func loadStereo(url: URL) async throws -> (left: [Float], right: [Float]) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "StereoChannelBakeoff",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found in the video."]
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "StereoChannelBakeoff",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "AVFoundation rejected stereo PCM output."]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "StereoChannelBakeoff",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "AVFoundation could not start stereo decoding."]
            )
        }

        var left: [Float] = []
        var right: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw NSError(
                    domain: "StereoChannelBakeoff",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "A decoded audio buffer had no PCM data."]
                )
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            var data = Data(count: byteCount)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw NSError(
                    domain: "StereoChannelBakeoff",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Could not copy decoded stereo PCM (\(status))."]
                )
            }
            try data.withUnsafeBytes { bytes in
                let values = bytes.bindMemory(to: Float.self)
                guard values.count.isMultiple(of: 2) else {
                    throw NSError(
                        domain: "StereoChannelBakeoff",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Decoded stereo PCM did not contain complete frames."]
                    )
                }
                for index in stride(from: 0, to: values.count - 1, by: 2) {
                    left.append(values[index])
                    right.append(values[index + 1])
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "StereoChannelBakeoff",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Stereo decoding stopped early."]
            )
        }
        return (left, right)
    }
}

private struct StereoBenchmarkTurn {
    let id: Int
    let startSample: Int
    let endSample: Int
    let japanese: String
    let highConfidence: Bool
}

private struct StereoBenchmarkReport: Codable {
    struct Variant: Codable {
        struct Turn: Codable {
            let id: Int
            let reference: String
            let hypothesis: String
            let error: String?
        }

        let channel: StereoBenchmarkChannel
        let highConfidenceCER: Double?
        let highConfidenceEditDistance: Int
        let highConfidenceReferenceCharacters: Int
        let omissions: Int
        let turns: [Turn]
    }

    let schemaVersion: Int
    let videoPath: String
    let scope: String
    let model: String
    let delayMilliseconds: Int
    let channelLayout: String
    let difficultRangesSeconds: [[Double]]
    let selectedTurnIDs: [Int]
    let variants: [Variant]
}

final class StereoChannelBakeoffTests: XCTestCase {
    private static let ranges: [Range<Int>] = [
        552_000..<760_000,       // 34.5–47.5 s
        1_480_000..<1_688_000,   // 92.5–105.5 s
        2_971_200..<3_328_000,   // 185.7–208.0 s
        4_272_000..<4_353_600,   // 267.0–272.1 s
    ]

    func testStereoVariantMath() {
        let audio = StereoBenchmarkAudio(
            currentMono: [0.25, -0.25],
            left: [1, -1],
            right: [-0.5, 0.5]
        )
        XCTAssertEqual(audio.samples(for: .channel0), [1, -1])
        XCTAssertEqual(audio.samples(for: .channel1), [-0.5, 0.5])
        XCTAssertEqual(audio.samples(for: .averageMix), [0.25, -0.25])
        XCTAssertEqual(audio.samples(for: .currentMono), [0.25, -0.25])
    }

    @MainActor
    func testDifficultPassageStereoBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_STEREO_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_stereo_bakeoff.sh for the local stereo comparison.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let videoURL = URL(fileURLWithPath: environment["WHISPERASR_STEREO_BAKEOFF_VIDEO"]
            ?? "/Users/maz/Downloads/Easy Japanese 1 - Typical Japanese.mp4")
        let corpusURL = URL(fileURLWithPath: environment["WHISPERASR_STEREO_BAKEOFF_CORPUS"]
            ?? root.appendingPathComponent(".build/benchmarks/corpora/easy-japanese-1").path)
        let audio = try await StereoBenchmarkLoader.load(url: videoURL)
        let fullCorpus = environment["WHISPERASR_STEREO_BAKEOFF_FULL"] == "1"
        let allTurns = try loadTurns(corpusURL.appendingPathComponent("turns.csv"))
        let turns = fullCorpus ? allTurns : allTurns.filter { turn in
                let midpoint = turn.startSample + (turn.endSample - turn.startSample) / 2
                return Self.ranges.contains { $0.contains(midpoint) }
            }
        XCTAssertFalse(turns.isEmpty)
        XCTAssertTrue(turns.allSatisfy { $0.endSample <= audio.currentMono.count })

        let manager = LocalEnglishModelManager()
        await manager.selectContinuousVoxtralConfiguration(.default)
        try await manager.prepare(.voxtralApple)
        var variants: [StereoBenchmarkReport.Variant] = []
        for channel in StereoBenchmarkChannel.allCases {
            let samples = audio.samples(for: channel)
            var reports: [StereoBenchmarkReport.Variant.Turn] = []
            for turn in turns {
                let hypothesis = try await transcribe(
                    Array(samples[turn.startSample..<turn.endSample]),
                    absoluteStart: turn.startSample,
                    manager: manager
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                reports.append(.init(
                    id: turn.id,
                    reference: turn.japanese,
                    hypothesis: hypothesis,
                    error: nil
                ))
                print("[StereoBakeoff] \(channel.rawValue) turn \(turn.id)")
            }
            XCTAssertEqual(reports.count, turns.count)
            let highIDs = Set(turns.filter(\.highConfidence).map(\.id))
            let score = JapaneseCER.score(reports.filter { highIDs.contains($0.id) }.map {
                (reference: $0.reference, hypothesis: $0.hypothesis)
            })
            variants.append(.init(
                channel: channel,
                highConfidenceCER: score.rate,
                highConfidenceEditDistance: score.editDistance,
                highConfidenceReferenceCharacters: score.referenceCharacterCount,
                omissions: score.omissionCount,
                turns: reports
            ))
        }
        await manager.shutdown()

        let report = StereoBenchmarkReport(
            schemaVersion: 1,
            videoPath: videoURL.path,
            scope: fullCorpus ? "all-59-human-turns" : "difficult-turns-by-midpoint",
            model: VoxtralContinuousConfiguration.default.model.rawValue,
            delayMilliseconds: VoxtralContinuousConfiguration.default.delay.rawValue,
            channelLayout: "unspecified; channel-0/channel-1 use decoded container order",
            difficultRangesSeconds: Self.ranges.map {
                [Double($0.lowerBound) / 16_000, Double($0.upperBound) / 16_000]
            },
            selectedTurnIDs: turns.map(\.id),
            variants: variants
        )
        let output = root.appendingPathComponent(
            fullCorpus
                ? ".build/benchmarks/easy-japanese-1-stereo-full-bakeoff.json"
                : ".build/benchmarks/easy-japanese-1-stereo-bakeoff.json"
        )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private func loadTurns(_ url: URL) throws -> [StereoBenchmarkTurn] {
        let records = try JapaneseBenchmarkCSV.records(
            data: Data(contentsOf: url),
            expectedHeader: [
                "tour", "debut_switch", "fin", "locuteur",
                "description_locuteur", "japonais", "confiance", "note",
            ]
        )
        return try records.map { record in
            guard let id = record["tour"].flatMap(Int.init),
                  let start = record["debut_switch"],
                  let end = record["fin"],
                  let japanese = record["japonais"],
                  let confidence = record["confiance"] else {
                throw NSError(
                    domain: "StereoChannelBakeoff",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Malformed benchmark turn row."]
                )
            }
            return try StereoBenchmarkTurn(
                id: id,
                startSample: JapaneseBenchmarkCSV.sampleIndex(timecode: start),
                endSample: JapaneseBenchmarkCSV.sampleIndex(timecode: end),
                japanese: japanese,
                highConfidence: confidence == "élevée"
            )
        }
    }

    @MainActor
    private func transcribe(
        _ samples: [Float],
        absoluteStart: Int,
        manager: LocalEnglishModelManager
    ) async throws -> String {
        let events = try await manager.startContinuousVoxtral()
        let collector = Task {
            var failures: [String] = []
            for await event in events {
                if case .failed(let message) = event { failures.append(message) }
            }
            return failures
        }
        do {
            let block = VoxtralHelperManifest.sampleRate
                * VoxtralHelperManifest.transportBlockMilliseconds / 1_000
            for start in stride(from: 0, to: samples.count, by: block) {
                let end = min(samples.count, start + block)
                try await manager.feedContinuousVoxtral(
                    samples: Array(samples[start..<end]),
                    range: (absoluteStart + start)..<(absoluteStart + end)
                )
            }
            let transcript = try await manager.finishContinuousVoxtral()
            let failures = await collector.value
            if !failures.isEmpty {
                throw NSError(
                    domain: "StereoChannelBakeoff",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
                )
            }
            return transcript
        } catch {
            await manager.cancelContinuousVoxtral()
            collector.cancel()
            _ = await collector.result
            throw error
        }
    }
}
