import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

private typealias PromptMessage = [String: any Sendable]

actor LocalMLXTranslator {
    static let modelID = "mlx-community/translategemma-12b-it-4bit"
    static let revision = "f3dcfd54df14672fbcf0731086fb47a797a943ae"
    static let runtimeVersion = "3.31.4"
    static let declaredPeakMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let inputTokenLimit = 2_048

    private var container: ModelContainer?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard container == nil else { return }
        progress(0, "TranslateGemma: preparing download…")
        Memory.peakMemory = 0
        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: Self.modelID, revision: Self.revision),
            progressHandler: {
                progress($0.fractionCompleted * 0.9, "TranslateGemma: downloading…")
            }
        )
        do {
            try Task.checkCancellation()
        } catch {
            Memory.clearCache()
            throw error
        }
        container = loaded
        progress(1, "TranslateGemma ready")
    }

    func translate(_ batch: HighQualityTranslationBatch) async throws -> HighQualityTranslationExchange {
        guard let container else {
            throw HighQualityTranslationServiceError(
                model: Self.modelID,
                attempts: [],
                response: nil,
                message: "TranslateGemma is not loaded."
            )
        }

        let started = Date()
        var translations: [Translation] = []
        var traces: [HighQualityLocalTranslationBatch] = []
        var inFlightTrace: HighQualityLocalTranslationBatch?
        do {
            for turn in batch.turns {
                try Task.checkCancellation()
                var messages = Self.messages(
                    for: turn,
                    glossary: batch.glossary,
                    previous: translations.last
                )
                var tokenCount = try await Self.tokenCount(messages, using: container)
                while tokenCount > Self.inputTokenLimit, messages.count > 1 {
                    messages.removeFirst(2)
                    tokenCount = try await Self.tokenCount(messages, using: container)
                }
                guard tokenCount <= Self.inputTokenLimit else {
                    throw HighQualityTranslationServiceError(
                        model: Self.modelID,
                        attempts: [],
                        response: nil,
                        message: "Cue \(turn.id) exceeds TranslateGemma's 2K input limit."
                    )
                }

                let prompt = try Self.sanitizedPrompt(messages)
                inFlightTrace = .init(
                    cueIDs: [turn.id],
                    sanitizedPrompt: prompt,
                    sanitizedOutput: "",
                    inputTokens: tokenCount
                )
                let input = try await container.prepare(input: UserInput(messages: messages))
                let stream = try await container.generate(
                    input: input,
                    parameters: .init(maxTokens: 512, temperature: 0)
                )
                var output = ""
                for await generation in stream {
                    try Task.checkCancellation()
                    output += generation.chunk ?? ""
                    inFlightTrace = .init(
                        cueIDs: [turn.id],
                        sanitizedPrompt: prompt,
                        sanitizedOutput: output,
                        inputTokens: tokenCount
                    )
                }
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty else {
                    throw HighQualityTranslationServiceError(
                        model: Self.modelID,
                        attempts: [],
                        response: nil,
                        message: "TranslateGemma returned an empty translation for \(turn.id)."
                    )
                }
                translations.append(.init(id: turn.id, source: turn.japanese, text: output))
                traces.append(.init(
                    cueIDs: [turn.id],
                    sanitizedPrompt: prompt,
                    sanitizedOutput: output,
                    inputTokens: tokenCount
                ))
                inFlightTrace = nil
            }

            let response = String(decoding: try JSONEncoder().encode(
                Envelope(translations: translations.map { .init(id: $0.id, text: $0.text) })
            ), as: UTF8.self)
            return .init(
                model: Self.modelID,
                response: response,
                attempts: [.init(
                    number: 1,
                    duration: Date().timeIntervalSince(started),
                    outcome: "success"
                )],
                revision: Self.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory))
            )
        } catch let error as HighQualityTranslationServiceError {
            throw HighQualityTranslationServiceError(
                model: error.model,
                attempts: error.attempts,
                response: error.response,
                revision: Self.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory)),
                message: error.message
            )
        } catch {
            throw HighQualityTranslationServiceError(
                model: Self.modelID,
                attempts: [.init(
                    number: 1,
                    duration: Date().timeIntervalSince(started),
                    outcome: error.localizedDescription
                )],
                response: nil,
                revision: Self.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory)),
                message: error.localizedDescription
            )
        }
    }

    func unload() {
        container = nil
        Memory.clearCache()
    }

    private static func messages(
        for turn: HighQualityTranslationTurn,
        glossary: [HighQualityGlossaryPromptTerm],
        previous: Translation?
    ) -> [PromptMessage] {
        var messages: [PromptMessage] = []
        for term in glossary {
            for japanese in term.japanese {
                for english in [term.english] + term.englishAliases {
                    messages.append(userMessage(japanese))
                    messages.append(["role": "assistant", "content": english])
                }
            }
        }
        if let previous {
            messages.append(userMessage(previous.source))
            messages.append(["role": "assistant", "content": previous.text])
        }
        if let speaker = turn.speakerLabel {
            messages.append(userMessage("話者ラベル: \(speaker)"))
            messages.append(["role": "assistant", "content": "Speaker label: \(speaker)"])
        }
        messages.append(userMessage(turn.japanese))
        return messages
    }

    private static func userMessage(_ text: String) -> PromptMessage {
        let content: [String: any Sendable] = [
            "type": "text",
            "source_lang_code": "ja",
            "target_lang_code": "en",
            "text": text,
        ]
        let items: [[String: any Sendable]] = [content]
        return ["role": "user", "content": items]
    }

    private static func tokenCount(
        _ messages: [PromptMessage],
        using container: ModelContainer
    ) async throws -> Int {
        try await container.perform(values: messages) { context, messages in
            try context.tokenizer.applyChatTemplate(
                messages: messages,
                tools: nil,
                additionalContext: ["add_generation_prompt": true]
            ).count
        }
    }

    private static func sanitizedPrompt(_ messages: [PromptMessage]) throws -> String {
        String(decoding: try JSONSerialization.data(
            withJSONObject: messages,
            options: [.sortedKeys]
        ), as: UTF8.self)
    }

    private struct Translation: Sendable {
        let id: String
        let source: String
        let text: String
    }

    private struct Envelope: Encodable {
        struct Item: Encodable { let id: String; let text: String }
        let translations: [Item]
    }
}
