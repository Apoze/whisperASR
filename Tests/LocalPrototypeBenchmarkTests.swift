import Foundation
import XCTest
@testable import WhisperASRApp

final class LocalPrototypeBenchmarkTests: XCTestCase {
    private struct CandidateOutput: Codable {
        let passageID: Int
        let engine: String
        let source: String?
        let english: String
        let elapsedMilliseconds: Double
        let residentBytes: UInt64
    }

    private struct BlindOutput: Codable {
        let passageID: Int
        let candidate: String
        let english: String
    }

    /// Run explicitly with:
    /// Scripts/run_local_benchmark.sh .build/benchmarks/canonical-firefox-16k-mono.wav
    ///
    /// It intentionally downloads/loads large models and is therefore skipped
    /// during normal unit tests.
    @MainActor
    func testCanonicalQualityBenchmarkWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISPERASR_BENCHMARK_WAV"] else {
            throw XCTSkip("Set WHISPERASR_BENCHMARK_WAV to run the local model comparison.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple high-fidelity translation requires macOS 26.4 or later.")
        }

        let url = URL(fileURLWithPath: path)
        let samples = try await AudioLoader.loadSamples(url: url)
        let passages = CanonicalBenchmarkCorpus.passages(totalSamples: samples.count)
        XCTAssertFalse(passages.isEmpty)
        XCTAssertTrue(passages.allSatisfy {
            (12...25).contains(Double($0.endSample - $0.startSample) / 16_000)
        })

        let modelManager = LocalEnglishModelManager()
        let whisper = TranscriptionService()
        let translation = AppleTranslationService()
        try await translation.configure(sourceLocale: "ja", mode: .highFidelityOnly)

        let originalSelection = ModelManager.shared.selectedFileName
        defer { ModelManager.shared.selectedFileName = originalSelection }
        var outputs: [CandidateOutput] = []

        for engine in LocalEnglishEngine.allCases {
            if engine == .whisperTurboApple {
                guard let turbo = ModelCatalog.model(id: "large-v3-turbo"),
                      ModelManager.shared.isDownloaded(turbo) else {
                    XCTFail("Whisper Large v3 Turbo must be downloaded before the opt-in benchmark.")
                    return
                }
                ModelManager.shared.selectedFileName = turbo.fileName
                try await whisper.preloadModel(requireEnglishTranslation: false)
            } else {
                await whisper.unloadModel()
            }
            try await modelManager.prepare(engine)
            let resident: UInt64
            if case .ready(let bytes) = modelManager.phase(for: engine) {
                resident = bytes
            } else {
                XCTFail("\(engine.label) was not ready")
                return
            }

            for passage in passages {
                let audio = Array(samples[passage.startSample..<passage.endSample])
                let started = DispatchTime.now().uptimeNanoseconds
                let source: String?
                let english: String
                switch engine {
                case .whisperTurboApple:
                    let result = try await whisper.transcribeChunk(
                        samples: audio,
                        language: "ja",
                        translate: false
                    )
                    source = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    english = try await translation.translate(source!, highFidelity: true)
                case .qwenApple:
                    source = try await modelManager.transcribeQwen(
                        audio: audio,
                        language: "Japanese"
                    )
                    english = try await translation.translate(source!, highFidelity: true)
                }
                guard !EnglishSubtitleValidator.containsSourceScript(english) else {
                    XCTFail("\(engine.label) returned source script for passage \(passage.id)")
                    return
                }
                outputs.append(CandidateOutput(
                    passageID: passage.id,
                    engine: engine.rawValue,
                    source: source,
                    english: english,
                    elapsedMilliseconds: Double(
                        DispatchTime.now().uptimeNanoseconds - started
                    ) / 1_000_000,
                    residentBytes: resident
                ))
            }
        }

        await modelManager.shutdown()
        whisper.shutdown()
        try writeReports(outputs, nextTo: url)
    }

    /// Replays the canonical PCM at wall-clock speed through the exact Apple
    /// preview service. This catches timestamp discontinuities that an offline
    /// file transcription cannot expose.
    @MainActor
    func testApplePreviewStreamingWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "WHISPERASR_PREVIEW_BENCHMARK_WAV"
        ] else {
            throw XCTSkip("Set WHISPERASR_PREVIEW_BENCHMARK_WAV to test Apple streaming previews.")
        }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple streaming previews require macOS 26.4 or later.")
        }

        let samples = try await AudioLoader.loadSamples(url: URL(fileURLWithPath: path))
        let service = AppleSpeechService()
        try await service.prepare(localeIdentifier: "ja-JP") { _ in }

        var updates: [LiveSourceUpdate] = []
        var updateTimes: [Double] = []
        var failure: Error?
        let started = DispatchTime.now().uptimeNanoseconds
        try await service.start(
            localeIdentifier: "ja-JP",
            onUpdate: {
                updates.append($0)
                updateTimes.append(Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000_000)
            },
            onFailure: { failure = $0 }
        )
        defer { Task { await service.cancel() } }

        let frame = 1_600
        let forceEvery = 24_000
        let feeder = Task { @MainActor in
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + frame)
                try await service.send(
                    samples: Array(samples[offset..<end]),
                    startSample: offset
                )
                offset = end
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        var target = forceEvery
        while target < samples.count {
            try await Task.sleep(for: .milliseconds(1_500))
            try await service.finalizeAvailableAudio()
            target += forceEvery
        }
        try await feeder.value
        try await service.finalizeAvailableAudio()
        try await Task.sleep(for: .milliseconds(500))
        await service.cancel()

        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(updates.count, 3)
        XCTAssertTrue(updates.allSatisfy {
            ($0.segment.end ?? $0.segment.start) >= $0.segment.start
        })
        if let overlapping = updates.first(where: {
            ($0.segment.end ?? $0.segment.start) - $0.segment.start > 0.2
        }) {
            let cutoff = Int((
                (overlapping.segment.start + (overlapping.segment.end ?? overlapping.segment.start))
                    / 2 * 16_000
            ).rounded())
            var planner = LocalPreviewPlanner()
            planner.suspend(through: cutoff)
            planner.resume(through: cutoff)
            planner.submit(overlapping)
            XCTAssertGreaterThanOrEqual(
                planner.takeLatest()?.update.segment.start ?? 0,
                Double(cutoff) / 16_000
            )
        } else {
            XCTFail("Apple Speech returned no timestamped result spanning the test boundary.")
        }
        print("[PreviewBenchmark] updates=\(updates.count) seconds=\(updateTimes)")
        for index in updates.indices where index == 0
            || updates[index].isFinal
            || updateTimes[index] - updateTimes[index - 1] > 0.2 {
            let update = updates[index]
            print(
                "[PreviewBenchmark] t=\(updateTimes[index]) "
                + "range=\(update.segment.start)-\(update.segment.end ?? update.segment.start) "
                + "final=\(update.isFinal) text=\(update.segment.text)"
            )
        }
        let timeline = updates.indices.map { index in
            let update = updates[index]
            return "\(updateTimes[index])\t\(update.segment.start)\t"
                + "\(update.segment.end ?? update.segment.start)\t"
                + "\(update.isFinal)\t\(update.segment.text)"
        }.joined(separator: "\n")
        try timeline.write(
            to: URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent("apple-preview-timeline.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeReports(_ outputs: [CandidateOutput], nextTo wav: URL) throws {
        let root = wav.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outputs).write(
            to: root.appendingPathComponent("quality-full.json"),
            options: .atomic
        )

        let names = ["A", "B"]
        var blind: [BlindOutput] = []
        var key: [String: String] = [:]
        for passageID in Set(outputs.map(\.passageID)).sorted() {
            let candidates = outputs.filter { $0.passageID == passageID }
            for (index, output) in candidates.enumerated() {
                let label = names[(index + passageID) % names.count]
                blind.append(BlindOutput(
                    passageID: passageID,
                    candidate: label,
                    english: output.english
                ))
                key["\(passageID)-\(label)"] = output.engine
            }
        }
        blind.sort { ($0.passageID, $0.candidate) < ($1.passageID, $1.candidate) }
        try encoder.encode(blind).write(
            to: root.appendingPathComponent("quality-blind.json"),
            options: .atomic
        )
        try encoder.encode(key).write(
            to: root.appendingPathComponent("quality-key.json"),
            options: .atomic
        )
    }
}
