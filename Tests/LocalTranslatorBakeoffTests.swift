import CryptoKit
import Foundation
import HuggingFace
import XCTest
@testable import WhisperASRApp

final class LocalTranslatorBakeoffTests: XCTestCase {
    func testRealCandidateOnFrozenCorpusWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_RUN_TRANSLATOR_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_local_translator_bakeoff.sh for the real local comparison.")
        }
        guard let rawCandidate = environment["WHISPERASR_TRANSLATOR_CANDIDATE"],
              let candidate = LocalMLXTranslator.Candidate(rawValue: rawCandidate),
              let corpusID = environment["WHISPERASR_TRANSLATOR_CORPUS"],
              ["qudu2fx3ncc", "md62mmdz0m"].contains(corpusID),
              let outputPath = environment["WHISPERASR_TRANSLATOR_OUTPUT"] else {
            throw XCTSkip("Candidate, corpus and output path are required.")
        }
        if corpusID == "md62mmdz0m" {
            guard environment["WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT"] == "1" else {
                throw XCTSkip("The final holdout requires explicit authorization.")
            }
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent(
            "docs/japanese-live/corpora/\(corpusID)/manifest.json"
        )
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(
            JapaneseBenchmarkSupport.Manifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.annotations.status, .complete)
        XCTAssertFalse(manifest.annotations.reviewedBy.isEmpty)

        let source = HighQualitySourceProvenance(
            path: manifestURL.path,
            fileName: corpusID,
            byteCount: UInt64(manifestData.count),
            modifiedAt: nil,
            sourceURL: nil,
            youtube: .init(
                sourceURL: corpusID == "qudu2fx3ncc"
                    ? "https://www.youtube.com/watch?v=QUdu2fx3NCc"
                    : "https://www.youtube.com/watch?v=_mD62MMDz0M",
                title: corpusID,
                channel: "frozen-reference",
                description: manifest.source.description,
                ytDLPVersion: "reference-only",
                diagnostics: ""
            )
        )
        let turns = manifest.annotations.turns.enumerated().map { index, turn in
            HighQualityTranslationTurn(
                id: String(format: "cue-%04d", turn.id),
                japanese: turn.japanese,
                precedingJapanese: index == 0
                    ? [] : [manifest.annotations.turns[index - 1].japanese],
                followingJapanese: index + 1 == manifest.annotations.turns.count
                    ? [] : [manifest.annotations.turns[index + 1].japanese],
                speakerLabel: turn.speaker,
                sourceStart: Double(turn.startSample) / Double(manifest.fixture.sampleRate),
                sourceEnd: Double(turn.endSample) / Double(manifest.fixture.sampleRate)
            )
        }
        let glossary = HighQualityGlossarySelector.select(source: source, turns: turns)
        let batch = HighQualityTranslationBatch(
            source: source,
            turns: turns,
            glossary: glossary.promptTerms
        )
        var artifact = LocalTranslatorBakeoffArtifact(
            schemaVersion: 1,
            candidate: candidate.rawValue,
            modelID: candidate.modelID,
            revision: candidate.revision,
            weightSHA256: candidate.weightSHA256,
            cachedWeightBlobSHA256: [],
            runtimeVersion: LocalMLXTranslator.runtimeVersion,
            corpusID: corpusID,
            corpusRole: corpusID == "qudu2fx3ncc" ? "development" : "untouched-final-holdout",
            manifestSHA256: Self.sha256(manifestData),
            frozenInputSHA256: Self.sha256(try Self.encoded(batch)),
            implementationSHA256: try Self.implementationHashes(root: root),
            contextBudgetTokens: LocalMLXTranslator.inputTokenLimit,
            generation: .init(maxTokens: 256, temperature: 0, thinking: false),
            glossary: glossary,
            reserveBytes: HeavyweightModelGate.systemReserveBytes,
            baselineMemoryBytes: 0,
            releasedMemoryBytes: nil,
            preparationDurationSeconds: 0,
            translationDurationSeconds: 0,
            totalDurationSeconds: 0,
            peakMemoryBytes: 0,
            gates: [:],
            request: batch,
            promptsAndOutputs: [],
            response: nil,
            metricsInput: manifest.annotations.turns.map {
                .init(
                    id: String(format: "cue-%04d", $0.id),
                    source: $0.japanese,
                    reference: $0.english ?? "",
                    hypothesis: ""
                )
            },
            failureDiagnostics: [],
            startedAt: Date(),
            finishedAt: nil
        )
        let outputURL = URL(fileURLWithPath: outputPath)
        let started = ContinuousClock.now
        let runtime = LocalMLXTranslator(candidate: candidate)
        let gate = HeavyweightModelGate.shared
        var workflow: HeavyweightWorkflowLease?
        var model: HeavyweightModelLease?

        do {
            workflow = try await gate.beginWorkflow(.offline(UUID()))
            model = try await gate.acquireModel(
                workflow: workflow!,
                modelID: candidate.modelID,
                declaredPeakBytes: candidate.declaredPeakMemoryBytes
            )
            artifact.baselineMemoryBytes = model!.baselineMemoryBytes
            artifact.gates["eightGBReserve"] = model!.reserveBytes >= 8 * 1_024 * 1_024 * 1_024

            do {
                _ = try await gate.acquireModel(
                    workflow: workflow!,
                    modelID: candidate == .translateGemma12B
                        ? LocalMLXTranslator.Candidate.qwen3_14B.modelID
                        : LocalMLXTranslator.Candidate.translateGemma12B.modelID,
                    declaredPeakBytes: 1
                )
                artifact.gates["exclusiveResidentModel"] = false
            } catch HeavyweightModelGateError.modelAlreadyActive {
                artifact.gates["exclusiveResidentModel"] = true
            }

            let preparationStarted = ContinuousClock.now
            try await runtime.prepare(progress: { _, _ in })
            artifact.preparationDurationSeconds = Self.seconds(since: preparationStarted)
            artifact.cachedWeightBlobSHA256 = try Self.cachedWeightHashes(candidate)
            artifact.gates["weightHashes"] = artifact.cachedWeightBlobSHA256
                == candidate.weightSHA256
            try await gate.markLoaded(model!)
            artifact.gates["localPreparation"] = true
            artifact.gates["load"] = true

            var cancellation: Task<HighQualityTranslationExchange, Error>? = Task {
                try await runtime.translate(.init(
                    source: batch.source,
                    turns: Array(batch.turns.prefix(4)),
                    glossary: batch.glossary
                ))
            }
            try await Task.sleep(for: .milliseconds(100))
            cancellation?.cancel()
            do {
                _ = try await cancellation?.value
                artifact.gates["cancellation"] = false
            } catch {
                let message = (error as? HighQualityTranslationServiceError)?.message
                    ?? error.localizedDescription
                guard error is CancellationError
                        || message.localizedCaseInsensitiveContains("cancel")
                        || message.localizedCaseInsensitiveContains("annul") else {
                    throw error
                }
                artifact.gates["cancellation"] = true
                artifact.failureDiagnostics.append("expected-cancellation: \(message)")
            }
            cancellation = nil

            let translationStarted = ContinuousClock.now
            let exchange = try await runtime.translate(batch)
            artifact.translationDurationSeconds = Self.seconds(since: translationStarted)
            artifact.peakMemoryBytes = exchange.peakMemoryBytes
            artifact.promptsAndOutputs = exchange.batches
            artifact.response = exchange.response
            artifact.gates["nonEmptyOutput"] = exchange.batches.count == turns.count
                && exchange.batches.allSatisfy { !$0.sanitizedOutput.isEmpty }
            artifact.gates["evidence"] = exchange.revision == candidate.revision
                && exchange.runtimeVersion == LocalMLXTranslator.runtimeVersion
                && exchange.batches.allSatisfy {
                    !$0.sanitizedPrompt.isEmpty
                        && $0.nativePrompt?.isEmpty == false
                        && $0.nativeOutput?.isEmpty == false
                        && $0.inputTokens <= LocalMLXTranslator.inputTokenLimit
            }
            let turnByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
            artifact.gates["modelFrozenContext"] = exchange.batches.allSatisfy {
                guard $0.cueIDs.count == 1,
                      let cueID = $0.cueIDs.first,
                      let turn = turnByID[cueID],
                      let prompt = $0.nativePrompt else { return false }
                return prompt.contains("<<<CURRENT:\(cueID)>>>")
                    && (turn.speakerLabel.map { prompt.contains($0) } ?? true)
                    && turn.precedingJapanese.allSatisfy(prompt.contains)
                    && turn.followingJapanese.allSatisfy(prompt.contains)
            }

            let response = try JSONDecoder().decode(TranslationEnvelope.self, from: Data(
                exchange.response.utf8
            ))
            let expectedIDs = turns.map(\.id)
            let observedIDs = response.translations.map(\.id)
            artifact.gates["cueIntegrity"] = observedIDs == expectedIDs
                && Set(observedIDs).count == observedIDs.count
            let outputByID = Dictionary(uniqueKeysWithValues: response.translations.map {
                ($0.id, $0.text)
            })
            artifact.metricsInput = artifact.metricsInput.map {
                .init(
                    id: $0.id,
                    source: $0.source,
                    reference: $0.reference,
                    hypothesis: outputByID[$0.id] ?? ""
                )
            }

            artifact.releasedMemoryBytes = try await gate.releaseModel(
                model!,
                unload: { await runtime.unload() }
            )
            model = nil
            artifact.gates["unload"] = true
            artifact.gates["memoryRelease"] = true
            try await gate.endWorkflow(workflow!)
            workflow = nil
            artifact.totalDurationSeconds = Self.seconds(since: started)
            artifact.finishedAt = Date()
            XCTAssertTrue(artifact.gates.values.allSatisfy { $0 })
            try Self.write(artifact, to: outputURL)
        } catch {
            if let translationError = error as? HighQualityTranslationServiceError {
                artifact.promptsAndOutputs = translationError.batches
                artifact.response = translationError.response
                artifact.peakMemoryBytes = translationError.peakMemoryBytes
            }
            artifact.failureDiagnostics.append("failure: \(error.localizedDescription)")
            if let model {
                do {
                    artifact.releasedMemoryBytes = try await gate.releaseModel(
                        model,
                        unload: { await runtime.unload() }
                    )
                } catch {
                    artifact.failureDiagnostics.append("cleanup: \(error.localizedDescription)")
                }
            } else {
                await runtime.unload()
            }
            if let workflow { try? await gate.endWorkflow(workflow) }
            artifact.totalDurationSeconds = Self.seconds(since: started)
            artifact.finishedAt = Date()
            try Self.write(artifact, to: outputURL)
            throw error
        }
    }

    static func cachedWeightHashes(
        _ candidate: LocalMLXTranslator.Candidate
    ) throws -> [String] {
        let pieces = candidate.modelID.split(separator: "/", maxSplits: 1).map(String.init)
        let snapshot = try HubCache.default.snapshotPath(
            repo: .init(namespace: pieces[0], name: pieces[1]),
            kind: .model,
            commitHash: candidate.revision
        )
        return try candidate.weightFileNames.map {
            let resolved = snapshot.appendingPathComponent($0).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try sha256File(resolved)
        }
    }

    private static func implementationHashes(root: URL) throws -> [String: String] {
        let paths = [
            "Sources/HighQualityJob.swift",
            "Sources/LocalMLXTranslator.swift",
            "Tests/LocalTranslatorBakeoffTests.swift",
            "Scripts/run_local_translator_bakeoff.sh",
            "Scripts/report_local_translator_bakeoff.py",
        ]
        return try Dictionary(uniqueKeysWithValues: paths.map {
            ($0, try sha256File(root.appendingPathComponent($0)))
        })
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func write(
        _ artifact: LocalTranslatorBakeoffArtifact,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: url, options: .atomic)
    }
}

private struct TranslationEnvelope: Decodable {
    struct Item: Decodable { let id: String; let text: String }
    let translations: [Item]
}

private struct LocalTranslatorBakeoffArtifact: Codable {
    struct Generation: Codable {
        let maxTokens: Int
        let temperature: Double
        let thinking: Bool
    }

    struct MetricInput: Codable {
        let id: String
        let source: String
        let reference: String
        let hypothesis: String
    }

    let schemaVersion: Int
    let candidate: String
    let modelID: String
    let revision: String
    let weightSHA256: [String]
    var cachedWeightBlobSHA256: [String]
    let runtimeVersion: String
    let corpusID: String
    let corpusRole: String
    let manifestSHA256: String
    let frozenInputSHA256: String
    let implementationSHA256: [String: String]
    let contextBudgetTokens: Int
    let generation: Generation
    let glossary: HighQualityGlossarySelection
    let reserveBytes: UInt64
    var baselineMemoryBytes: UInt64
    var releasedMemoryBytes: UInt64?
    var preparationDurationSeconds: Double
    var translationDurationSeconds: Double
    var totalDurationSeconds: Double
    var peakMemoryBytes: UInt64
    var gates: [String: Bool]
    let request: HighQualityTranslationBatch
    var promptsAndOutputs: [HighQualityLocalTranslationBatch]
    var response: String?
    var metricsInput: [MetricInput]
    var failureDiagnostics: [String]
    let startedAt: Date
    var finishedAt: Date?
}
