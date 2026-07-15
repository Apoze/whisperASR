import Darwin
import Foundation
import HuggingFace
import MLX
import MLXAudioSTT
import XCTest
@testable import WhisperASRApp

private actor QwenDirectSmokeRuntime {
    private static let modelID = "voiceping-ai/qwen3-asr-ja-en-speech-translation"
    private static let revision = "1251c2a9066981cc303df075b18bd3bbde1d25d6"
    private var model: MLXAudioSTT.Qwen3ASRModel?

    func prepare() async throws {
        let directory = try await HubClient.default.downloadSnapshot(
            of: Repo.ID(rawValue: Self.modelID)!,
            revision: Self.revision,
            matching: ["*.safetensors", "*.json", "*.txt"]
        )
        let loaded = try await MLXAudioSTT.Qwen3ASRModel.fromModelDirectory(directory)
        _ = loaded.generate(
            audio: MLXArray([Float](repeating: 0, count: 16_000)),
            generationParameters: STTGenerateParameters(
                maxTokens: 16,
                temperature: 0,
                language: "English"
            )
        )
        model = loaded
        Memory.clearCache()
    }

    func transcribe(_ audio: [Float]) throws -> String {
        guard let model, !audio.isEmpty else { throw LocalPrototypeError.invalidResponse }
        let output = model.generate(
            audio: MLXArray(audio),
            generationParameters: STTGenerateParameters(
                maxTokens: 448,
                temperature: 0,
                language: "English"
            )
        )
        Memory.clearCache()
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }
}

final class JapaneseDirectModelSmokeTests: XCTestCase {
    private struct Fixture {
        let turn: Int
        let range: Range<Int>
        let requiredEnglishFragments: [String]
    }

    private struct Sample: Codable {
        let turn: Int
        let startSample: Int
        let endSample: Int
        let english: String
        let milliseconds: Double
        let residentBytes: UInt64
    }

    private struct Report: Codable {
        let model: String
        let revision: String
        let corpus: String
        let samples: [Sample]
        let maximumResidentBytes: UInt64
    }

    private let fixtures = [
        Fixture(turn: 7, range: 832_832..<904_912, requiredEnglishFragments: ["rice"]),
        Fixture(turn: 34, range: 2_874_880..<2_942_144, requiredEnglishFragments: ["countr"]),
        Fixture(turn: 46, range: 3_328_128..<3_427_424, requiredEnglishFragments: ["haik", "anime"]),
    ]

    @MainActor
    func testQwenJapaneseEnglishDirectWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_QWEN_JA_EN_SMOKE"] == "1" else {
            throw XCTSkip("Set WHISPERASR_QWEN_JA_EN_SMOKE=1 to run the pinned Qwen JA→EN smoke test.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let audioURL = root.appendingPathComponent(
            ".build/benchmarks/corpora/easy-japanese-1/audio-16k-mono.wav"
        )
        let audio = try await AudioLoader.loadSamples(url: audioURL)
        XCTAssertTrue(fixtures.allSatisfy { $0.range.upperBound <= audio.count })
        XCTAssertTrue(fixtures.allSatisfy { $0.range.count < 10 * 16_000 })

        let runtime = QwenDirectSmokeRuntime()
        try await runtime.prepare()

        var samples: [Sample] = []
        for fixture in fixtures {
            let started = DispatchTime.now().uptimeNanoseconds
            let output = try await runtime.transcribe(Array(audio[fixture.range]))
            let english = try EnglishSubtitleValidator.requireEnglish(output)
            let lowered = english.lowercased()
            XCTAssertTrue(
                fixture.requiredEnglishFragments.contains(where: lowered.contains),
                "Turn \(fixture.turn) lost every required name/topic: \(english)"
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            samples.append(Sample(
                turn: fixture.turn,
                startSample: fixture.range.lowerBound,
                endSample: fixture.range.upperBound,
                english: english,
                milliseconds: elapsed,
                residentBytes: currentPhysicalFootprint()
            ))
        }

        let maximumResidentBytes = samples.map(\.residentBytes).max() ?? 0
        XCTAssertLessThan(maximumResidentBytes, 10 * 1_024 * 1_024 * 1_024)
        let sorted = samples.map(\.milliseconds).sorted()
        let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        XCTAssertLessThanOrEqual(p95, 2_500)

        let report = Report(
            model: "voiceping-ai/qwen3-asr-ja-en-speech-translation",
            revision: "1251c2a9066981cc303df075b18bd3bbde1d25d6",
            corpus: "easy-japanese-1",
            samples: samples,
            maximumResidentBytes: maximumResidentBytes
        )
        let reportURL = root.appendingPathComponent(
            ".build/benchmarks/qwen-ja-en-direct-smoke.json"
        )
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        await runtime.unload()
    }

    func testWhisperLargeV3DirectWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_WHISPER_LARGE_V3_DIRECT_SMOKE"] == "1" else {
            throw XCTSkip("Set WHISPERASR_WHISPER_LARGE_V3_DIRECT_SMOKE=1 to run Whisper Large v3 direct.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let audio = try await AudioLoader.loadSamples(url: root.appendingPathComponent(
            ".build/benchmarks/corpora/easy-japanese-1/audio-16k-mono.wav"
        ))
        let model = try XCTUnwrap(ModelCatalog.model(id: "large-v3"))
        let modelPath = ModelCatalog.path(for: model).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath))

        let service = TranscriptionService()
        try await service.preloadModel(
            modelPath: modelPath,
            requireEnglishTranslation: true
        )
        var samples: [Sample] = []
        for fixture in fixtures {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await service.transcribeChunk(
                samples: Array(audio[fixture.range]),
                language: "ja",
                translate: true,
                modelPath: modelPath
            )
            let english = try EnglishSubtitleValidator.requireEnglish(result.text)
            let lowered = english.lowercased()
            XCTAssertTrue(
                fixture.requiredEnglishFragments.contains(where: lowered.contains),
                "Turn \(fixture.turn) lost every required name/topic: \(english)"
            )
            samples.append(Sample(
                turn: fixture.turn,
                startSample: fixture.range.lowerBound,
                endSample: fixture.range.upperBound,
                english: english,
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                residentBytes: currentPhysicalFootprint()
            ))
        }

        let maximumResidentBytes = samples.map(\.residentBytes).max() ?? 0
        XCTAssertLessThan(maximumResidentBytes, 10 * 1_024 * 1_024 * 1_024)
        let report = Report(
            model: "ggerganov/whisper.cpp/ggml-large-v3.bin",
            revision: "c521a4b02f422512d734391fdf08bb08c0862f68",
            corpus: "easy-japanese-1",
            samples: samples,
            maximumResidentBytes: maximumResidentBytes
        )
        let output = root.appendingPathComponent(
            ".build/benchmarks/whisper-large-v3-direct-smoke.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        await service.unloadModel()
    }

    private func currentPhysicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
