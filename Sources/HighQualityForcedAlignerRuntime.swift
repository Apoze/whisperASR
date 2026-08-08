import Foundation
import HuggingFace
import MLX
import MLXAudioSTT

actor HighQualityForcedAlignerRuntime {
    static let modelID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    static let revision = "2f652af86ae0c73fe189b9429225c908ce4bf020"
    static let declaredPeakMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    private static let sampleRate = 16_000

    private var model: Qwen3ForcedAlignerModel?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        progress(0, "Downloading Qwen3 ForcedAligner…")
        guard let repository = Repo.ID(rawValue: Self.modelID) else {
            throw jobError("Invalid forced-alignment model identifier.")
        }
        let directory = try await HubClient.default.downloadSnapshot(
            of: repository,
            revision: Self.revision
        ) { download in
            progress(download.fractionCompleted, "Downloading Qwen3 ForcedAligner…")
        }
        try Task.checkCancellation()
        progress(0.95, "Loading Qwen3 ForcedAligner…")
        Memory.peakMemory = 0
        model = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory)
        progress(1, "Qwen3 ForcedAligner ready")
    }

    func align(
        samples: [Float],
        turns: [HighQualityTranslationTurn]
    ) async throws -> HighQualityAlignmentExchange {
        guard let model else { throw jobError("Forced-alignment model is not loaded.") }

        var chunks: [HighQualityAlignmentChunk] = []
        for (index, group) in Self.groups(turns).enumerated() {
            try Task.checkCancellation()
            let sourceStart = group.first?.sourceStart ?? 0
            let sourceEnd = group.first?.sourceEnd ?? (Double(samples.count) / Double(Self.sampleRate))
            let startSample = max(0, Int((sourceStart * Double(Self.sampleRate)).rounded()))
            let endSample = min(
                samples.count,
                Int((sourceEnd * Double(Self.sampleRate)).rounded())
            )
            guard startSample < endSample else { throw jobError("ASR timing anchor is empty.") }
            let tokenGroups = group.map { Self.alignmentTokens($0.japanese) }
            guard tokenGroups.allSatisfy({ !$0.isEmpty }) else {
                throw jobError("A Japanese cue has no alignable text.")
            }

            let output = model.generate(
                audio: MLXArray(Array(samples[startSample..<endSample])),
                text: tokenGroups.flatMap { $0 }.joined(separator: " "),
                language: "Japanese"
            )
            guard output.items.count == tokenGroups.reduce(0, { $0 + $1.count }) else {
                throw jobError("Qwen3 ForcedAligner returned incomplete character timing.")
            }

            var itemCursor = 0
            var cues: [HighQualityAlignedCue] = []
            var rawItems: [HighQualityAlignmentItem] = []
            for (turn, tokens) in zip(group, tokenGroups) {
                let items = output.items[itemCursor..<(itemCursor + tokens.count)]
                itemCursor += tokens.count
                guard let first = items.first, let last = items.last else {
                    throw jobError("Qwen3 ForcedAligner returned no timing for cue \(turn.id).")
                }
                rawItems += items.map {
                    .init(
                        cueID: turn.id,
                        text: $0.text,
                        start: sourceStart + $0.startTime,
                        end: sourceStart + $0.endTime
                    )
                }
                cues.append(.init(
                    id: turn.id,
                    text: turn.japanese,
                    start: sourceStart + first.startTime,
                    end: sourceStart + last.endTime
                ))
            }
            chunks.append(.init(
                index: index,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                cues: cues,
                rawItems: rawItems
            ))
        }
        return .init(
            chunks: chunks,
            modelID: Self.modelID,
            revision: Self.revision,
            peakMemoryBytes: UInt64(max(0, Memory.peakMemory))
        )
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    private static func groups(
        _ turns: [HighQualityTranslationTurn]
    ) -> [[HighQualityTranslationTurn]] {
        var result: [[HighQualityTranslationTurn]] = []
        var group: [HighQualityTranslationTurn] = []
        for turn in turns {
            if let first = group.first,
               first.sourceStart != turn.sourceStart || first.sourceEnd != turn.sourceEnd {
                result.append(group)
                group = []
            }
            group.append(turn)
        }
        if !group.isEmpty { result.append(group) }
        return result
    }

    private static func alignmentTokens(_ text: String) -> [String] {
        text.filter { $0.isLetter || $0.isNumber || $0 == "'" }.map(String.init)
    }

    private func jobError(_ message: String) -> HighQualityJobError {
        .init(stage: .alignment, message: message, resultDirectory: nil)
    }
}
