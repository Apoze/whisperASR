import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

enum JapaneseBenchmarkCSV {
    enum ParseError: Error, LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let message): message
            }
        }
    }

    static func records(
        data: Data,
        expectedHeader: [String]
    ) throws -> [[String: String]] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParseError.malformed("CSV is not valid UTF-8.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try rows(text)
        guard let header = rows.first, header == expectedHeader else {
            throw ParseError.malformed("Unexpected CSV header: \(rows.first ?? []).")
        }
        return try rows.dropFirst().enumerated().compactMap { index, row in
            if row.count == 1, row[0].isEmpty { return nil }
            guard row.count == header.count else {
                throw ParseError.malformed(
                    "CSV row \(index + 2) has \(row.count) fields; expected \(header.count)."
                )
            }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }

    static func sampleIndex(timecode: String, sampleRate: Int = 16_000) throws -> Int {
        let clock = timecode.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3,
              clock[0].count == 2,
              clock[1].count == 2 else {
            throw ParseError.malformed("Invalid timecode: \(timecode).")
        }
        let seconds = clock[2].split(separator: ".", omittingEmptySubsequences: false)
        guard seconds.count == 2,
              seconds[0].count == 2,
              seconds[1].count == 3,
              let hours = Int(clock[0]),
              let minutes = Int(clock[1]),
              let wholeSeconds = Int(seconds[0]),
              let milliseconds = Int(seconds[1]),
              (0..<60).contains(minutes),
              (0..<60).contains(wholeSeconds),
              (0..<1_000).contains(milliseconds),
              sampleRate.isMultiple(of: 1_000) else {
            throw ParseError.malformed("Invalid timecode: \(timecode).")
        }
        let totalMilliseconds = (((hours * 60) + minutes) * 60 + wholeSeconds) * 1_000
            + milliseconds
        return totalMilliseconds * sampleRate / 1_000
    }

    private static func rows(_ text: String) throws -> [[String]] {
        let characters = Array(text)
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var afterQuote = false
        var index = 0

        func finishField() {
            row.append(field)
            field = ""
            afterQuote = false
        }

        func finishRow() {
            finishField()
            result.append(row)
            row = []
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        afterQuote = true
                    }
                } else {
                    field.append(character)
                }
            } else if afterQuote {
                switch character {
                case ",": finishField()
                case "\n", "\r\n": finishRow()
                case "\r":
                    finishRow()
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default:
                    throw ParseError.malformed(
                        "Unexpected character '\(character)' after a quoted field at offset \(index)."
                    )
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty else {
                        throw ParseError.malformed("Quote inside an unquoted field.")
                    }
                    inQuotes = true
                case ",": finishField()
                case "\n", "\r\n": finishRow()
                case "\r":
                    finishRow()
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default: field.append(character)
                }
            }
            index += 1
        }

        guard !inQuotes else {
            throw ParseError.malformed("Unterminated quoted field.")
        }
        if afterQuote || !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return result
    }
}

struct JapaneseCERScore: Equatable {
    let editDistance: Int
    let referenceCharacterCount: Int
    let hypothesisCharacterCount: Int
    let omissionCount: Int

    var rate: Double? {
        referenceCharacterCount > 0
            ? Double(editDistance) / Double(referenceCharacterCount)
            : nil
    }
}

enum JapaneseCER {
    static func normalized(_ text: String) -> [Character] {
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.controlCharacters)
        let compatibilityNormalized = text.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "ja_JP"))
        var result = ""
        for scalar in compatibilityNormalized.unicodeScalars where !ignored.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return Array(result)
    }

    static func score(_ pairs: [(reference: String, hypothesis: String)]) -> JapaneseCERScore {
        var distance = 0
        var referenceCount = 0
        var hypothesisCount = 0
        var omissions = 0
        for pair in pairs {
            let reference = normalized(pair.reference)
            let hypothesis = normalized(pair.hypothesis)
            referenceCount += reference.count
            hypothesisCount += hypothesis.count
            distance += editDistance(reference, hypothesis)
            if !reference.isEmpty, hypothesis.isEmpty { omissions += 1 }
        }
        return JapaneseCERScore(
            editDistance: distance,
            referenceCharacterCount: referenceCount,
            hypothesisCharacterCount: hypothesisCount,
            omissionCount: omissions
        )
    }

    private static func editDistance(_ reference: [Character], _ hypothesis: [Character]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        guard !hypothesis.isEmpty else { return reference.count }
        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceCharacter) in reference.enumerated() {
            var current = Array(repeating: 0, count: hypothesis.count + 1)
            current[0] = referenceIndex + 1
            for (hypothesisIndex, hypothesisCharacter) in hypothesis.enumerated() {
                current[hypothesisIndex + 1] = min(
                    previous[hypothesisIndex + 1] + 1,
                    current[hypothesisIndex] + 1,
                    previous[hypothesisIndex] + (referenceCharacter == hypothesisCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[hypothesis.count]
    }
}

private typealias JapaneseBenchmarkManifest = JapaneseBenchmarkSupport.Manifest

private enum JapaneseBakeoffEngine: String, Codable, CaseIterable {
    case whisperTurbo = "whisper-large-v3-turbo"
    case voxtralContinuous = "voxtral-continuous"
    case qwenASR = "qwen3-asr-1.7b-mlx-8bit"
    case cohereQ8 = "cohere-transcribe-03-2026-mlx-8bit"
}

private struct JapaneseBakeoffTurnReport: Codable {
    let turnID: Int
    let confidence: JapaneseBenchmarkManifest.Turn.Confidence
    let speaker: String
    let startSample: Int
    let endSample: Int
    let referenceJapanese: String
    let hypothesisJapanese: String
    let asrMilliseconds: Double
    let appleEnglish: String?
    let appleHighFidelityMilliseconds: Double?
    let validEnglish: Bool?
    let residentBytes: UInt64
    let asrError: String?
    let translationError: String?
}

private struct JapaneseBakeoffCERReport: Codable, Equatable {
    let turnCount: Int
    let editDistance: Int
    let referenceCharacterCount: Int
    let hypothesisCharacterCount: Int
    let omissionCount: Int
    let rate: Double?
}

private struct JapaneseBakeoffEngineReport: Codable {
    let engine: JapaneseBakeoffEngine
    let status: String
    let setupError: String?
    let primaryHighConfidenceCER: JapaneseBakeoffCERReport
    let diagnosticMediumConfidenceCER: JapaneseBakeoffCERReport
    let criticalDiagnostics: JapaneseBakeoffCriticalDiagnostics
    let asrP50Milliseconds: Double?
    let asrP95Milliseconds: Double?
    let asrWorstMilliseconds: Double?
    let appleHighFidelityP50Milliseconds: Double?
    let appleHighFidelityP95Milliseconds: Double?
    let appleHighFidelityWorstMilliseconds: Double?
    let maximumResidentBytes: UInt64
    let turns: [JapaneseBakeoffTurnReport]
}

private struct JapaneseBakeoffCriticalDiagnostics: Codable {
    let questionTurnCER: JapaneseBakeoffCERReport
    let referenceNegationMarkerCount: Int
    let missingNegationMarkerCount: Int
    let referenceNumberTokenCount: Int
    let missingNumberTokenCount: Int
    let properNameScoringStatus: String
    let note: String
}

private struct JapaneseBakeoffFullReport: Codable {
    let schemaVersion: Int
    let corpusID: String
    let corpusSHA256: String
    let generatedAt: String
    let scope: String
    let selectedTurnIDs: [Int]
    let boundaryMode: String
    let productionBoundaryStatus: String
    let productionBoundaryNote: String
    let appleHighFidelityEnabled: Bool
    let voxtralConfiguration: VoxtralContinuousConfiguration
    let engines: [JapaneseBakeoffEngineReport]
}

private struct JapaneseBakeoffBlindCandidate: Codable {
    let alias: String
    let japanese: String
    let english: String?
}

private struct JapaneseBakeoffBlindItem: Codable {
    let turnID: Int
    let confidence: JapaneseBenchmarkManifest.Turn.Confidence
    let referenceJapanese: String
    let candidates: [JapaneseBakeoffBlindCandidate]
}

private struct JapaneseBakeoffBlindReport: Codable {
    let schemaVersion: Int
    let corpusID: String
    let scope: String
    let note: String
    let items: [JapaneseBakeoffBlindItem]
}

private typealias JapaneseBakeoffTranslation = @Sendable (String) async throws -> String

final class JapaneseModelBakeoffTests: XCTestCase {
    private static let turnsHeader = [
        "tour", "debut_switch", "fin", "locuteur", "description_locuteur",
        "japonais", "confiance", "note",
    ]
    private static let detailedHeader = [
        "index", "debut", "fin", "locuteur", "description_locuteur",
        "changement_de_locuteur", "japonais", "confiance", "note",
    ]

    func testCSVTimecodeAndCERPrimitives() throws {
        let data = Data("\u{FEFF}id,text,note\r\n1,\"a,b\",\"say \"\"hi\"\"\"\r\n".utf8)
        let records = try JapaneseBenchmarkCSV.records(
            data: data,
            expectedHeader: ["id", "text", "note"]
        )
        XCTAssertEqual(records, [["id": "1", "text": "a,b", "note": "say \"hi\""]])
        XCTAssertEqual(
            try JapaneseBenchmarkCSV.sampleIndex(timecode: "00:04:32.100"),
            4_353_600
        )

        XCTAssertEqual(String(JapaneseCER.normalized(" ＡＢＣ、１２３。 みな ")), "abc123みな")
        let score = JapaneseCER.score([
            (reference: "日本語", hypothesis: "日本後"),
            (reference: "はい", hypothesis: ""),
        ])
        XCTAssertEqual(score.editDistance, 3)
        XCTAssertEqual(score.referenceCharacterCount, 5)
        XCTAssertEqual(score.omissionCount, 1)
        XCTAssertEqual(score.rate, 0.6)
    }

    func testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns() {
        let reports = [
            JapaneseBakeoffTurnReport(
                turnID: 1,
                confidence: .high,
                speaker: "A",
                startSample: 0,
                endSample: 16_000,
                referenceJapanese: "日本語",
                hypothesisJapanese: "日本後",
                asrMilliseconds: 10,
                appleEnglish: nil,
                appleHighFidelityMilliseconds: nil,
                validEnglish: nil,
                residentBytes: 1,
                asrError: nil,
                translationError: nil
            ),
            JapaneseBakeoffTurnReport(
                turnID: 2,
                confidence: .medium,
                speaker: "B",
                startSample: 16_000,
                endSample: 32_000,
                referenceJapanese: "はい",
                hypothesisJapanese: "",
                asrMilliseconds: 20,
                appleEnglish: nil,
                appleHighFidelityMilliseconds: nil,
                validEnglish: nil,
                residentBytes: 2,
                asrError: nil,
                translationError: nil
            ),
        ]

        let high = cerReport(reports, confidence: .high)
        let medium = cerReport(reports, confidence: .medium)
        XCTAssertEqual(high.turnCount, 1)
        XCTAssertEqual(high.editDistance, 1)
        XCTAssertEqual(high.omissionCount, 0)
        XCTAssertEqual(medium.turnCount, 1)
        XCTAssertEqual(medium.editDistance, 2)
        XCTAssertEqual(medium.omissionCount, 1)

        let artifacts = blindArtifacts(
            corpusID: "fixture",
            scope: "unit",
            reports: JapaneseBakeoffEngine.allCases.map { engine in
                JapaneseBakeoffEngineReport(
                    engine: engine,
                    status: "complete",
                    setupError: nil,
                    primaryHighConfidenceCER: high,
                    diagnosticMediumConfidenceCER: medium,
                    criticalDiagnostics: criticalDiagnostics(reports),
                    asrP50Milliseconds: 10,
                    asrP95Milliseconds: 20,
                    asrWorstMilliseconds: 20,
                    appleHighFidelityP50Milliseconds: nil,
                    appleHighFidelityP95Milliseconds: nil,
                    appleHighFidelityWorstMilliseconds: nil,
                    maximumResidentBytes: 2,
                    turns: reports
                )
            }
        )
        XCTAssertEqual(artifacts.report.items.count, 2)
        XCTAssertEqual(Set(artifacts.report.items[0].candidates.map(\.alias)), Set(["A", "B", "C", "D"]))
        XCTAssertEqual(artifacts.key.count, 8)
    }

    /// Run with `Scripts/run_japanese_bakeoff.sh [smoke|full]`.
    ///
    /// Every engine receives the exact same annotated human turn ranges. The
    /// production clause planner is deliberately not approximated here: its
    /// long-lived state lives in AppState and is measured by the existing live
    /// replay benchmarks instead.
    @MainActor
    func testJapaneseASRBakeoffWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_JAPANESE_BAKEOFF"] == "1" else {
            throw XCTSkip("Run Scripts/run_japanese_bakeoff.sh to compare local Japanese ASR models.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let corpusURL = URL(
            fileURLWithPath: environment["WHISPERASR_JAPANESE_BAKEOFF_CORPUS"]
                ?? root.appendingPathComponent(
                    ".build/benchmarks/corpora/easy-japanese-1"
                ).path
        ).standardizedFileURL
        let manifestURL = corpusURL.appendingPathComponent("manifest.json")
        let manifest = try JapaneseBenchmarkSupport.loadManifest(at: manifestURL)
        let wavURL = corpusURL.appendingPathComponent("audio-16k-mono.wav")
        XCTAssertEqual(try sha256(wavURL), manifest.fixture.sha256)
        let samples = try await AudioLoader.loadSamples(url: wavURL)
        XCTAssertEqual(samples.count, manifest.fixture.sampleCount)
        XCTAssertEqual(manifest.fixture.sampleRate, 16_000)

        let scope = environment["WHISPERASR_JAPANESE_BAKEOFF_SCOPE"] ?? "full"
        let selectedIDs = selectedTurnIDs(environment: environment, scope: scope)
        let selectedTurns = manifest.annotations.turns.filter { selectedIDs.contains($0.id) }
        XCTAssertEqual(selectedTurns.count, selectedIDs.count)
        XCTAssertTrue(selectedTurns.allSatisfy { $0.endSample <= samples.count })

        let translation = try await optionalAppleTranslation(environment: environment)
        let modelManager = LocalEnglishModelManager()
        let whisper = TranscriptionService()
        let voxtralConfiguration = requestedVoxtralConfiguration(environment: environment)
        await modelManager.selectContinuousVoxtralConfiguration(voxtralConfiguration)
        let requestedEngines = selectedEngines(environment: environment)

        var engineReports: [JapaneseBakeoffEngineReport] = []
        for engine in requestedEngines {
            print("[JapaneseBakeoff] preparing \(engine.rawValue)")
            let report = await runEngine(
                engine,
                turns: selectedTurns,
                samples: samples,
                modelManager: modelManager,
                whisper: whisper,
                translation: translation
            )
            engineReports.append(report)
            print(
                "[JapaneseBakeoff] \(engine.rawValue) "
                    + "high-CER=\(format(report.primaryHighConfidenceCER.rate)) "
                    + "medium-CER=\(format(report.diagnosticMediumConfidenceCER.rate)) "
                    + "status=\(report.status)"
            )
        }
        await modelManager.shutdown()
        await whisper.unloadModel()

        let report = JapaneseBakeoffFullReport(
            schemaVersion: 1,
            corpusID: manifest.corpusID,
            corpusSHA256: manifest.fixture.sha256,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            scope: scope,
            selectedTurnIDs: selectedTurns.map(\.id),
            boundaryMode: "human-reference-turns",
            productionBoundaryStatus: "not-reproduced",
            productionBoundaryNote: "Production boundaries depend on AppState's continuous VoxtralClausePlanner, VAD, preview scheduler and optional diarization state. Recreating them turn-by-turn here would be a false simulation; use the existing real-time replay reports for that pass.",
            appleHighFidelityEnabled: translation != nil,
            voxtralConfiguration: voxtralConfiguration,
            engines: engineReports
        )
        let artifacts = blindArtifacts(
            corpusID: manifest.corpusID,
            scope: scope,
            reports: engineReports
        )
        try writeBakeoffArtifacts(
            report: report,
            blind: artifacts.report,
            key: artifacts.key,
            scope: scope,
            root: root
        )

        let failures = engineReports.flatMap { engine -> [String] in
            var result: [String] = []
            if engine.status != "complete" {
                result.append("\(engine.engine.rawValue): \(engine.setupError ?? engine.status)")
            }
            result += engine.turns.compactMap { turn in
                turn.asrError.map { "\(engine.engine.rawValue) turn \(turn.turnID): \($0)" }
            }
            return result
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPrepareEasyJapaneseCorpusWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WHISPERASR_PREPARE_JAPANESE_CORPUS"] == "1",
              let videoPath = environment["WHISPERASR_JAPANESE_CORPUS_VIDEO"],
              let archivePath = environment["WHISPERASR_JAPANESE_CORPUS_TRANSCRIPT_ARCHIVE"],
              let outputPath = environment["WHISPERASR_JAPANESE_CORPUS_OUTPUT"] else {
            throw XCTSkip("Run Scripts/prepare_japanese_bakeoff.sh to prepare the local corpus.")
        }

        let videoURL = URL(fileURLWithPath: videoPath).standardizedFileURL
        let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let turnsURL = outputURL.appendingPathComponent("turns.csv")
        let detailedURL = outputURL.appendingPathComponent("detailed.csv")
        let speakersURL = outputURL.appendingPathComponent("speakers.srt")
        let wavURL = outputURL.appendingPathComponent("audio-16k-mono.wav")

        let videoSHA = try sha256(videoURL)
        let archiveSHA = try sha256(archiveURL)
        XCTAssertEqual(
            videoSHA,
            "6b6fee800edaf8fe5ffea029f673b37e04b648cd24aaa779c1c53dc9446b2667"
        )
        XCTAssertEqual(
            archiveSHA,
            "1da9a9d3d2d41455eef067cee3a57d8c0ea7aca9c0a33291347e492a1ae238c1"
        )

        let turnsData = try Data(contentsOf: turnsURL)
        let detailedData = try Data(contentsOf: detailedURL)
        let speakersData = try Data(contentsOf: speakersURL)
        XCTAssertEqual(
            digest(turnsData),
            "d9a81899c6bb0e424161f732f53761cabcac41d14fed144e885cec2a0835e25d"
        )
        XCTAssertEqual(
            digest(detailedData),
            "c67ae24564eed86e750de000122677404ba7641ad8f4f2400b238e644f3f7fd4"
        )
        XCTAssertEqual(
            digest(speakersData),
            "d87a98fdbbf99151b8ad2533f27abf53d9001bdc6506a718328ba11f89313dbf"
        )

        let turnRecords = try JapaneseBenchmarkCSV.records(
            data: turnsData,
            expectedHeader: Self.turnsHeader
        )
        let turns = try turnRecords.enumerated().map { index, record in
            try referenceTurn(record, expectedID: index + 1)
        }
        guard zip(turns, turns.dropFirst()).allSatisfy({ previous, next in
            next.startSample >= previous.endSample
        }) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Reference turns overlap or are out of order."
            )
        }
        let detailedRecords = try JapaneseBenchmarkCSV.records(
            data: detailedData,
            expectedHeader: Self.detailedHeader
        )
        try validateDetailedRecords(detailedRecords)

        let speakers = try XCTUnwrap(String(data: speakersData, encoding: .utf8))
        XCTAssertEqual(speakers.components(separatedBy: " --> ").count - 1, 102)

        let samples = try await AudioLoader.loadSamples(url: videoURL)
        XCTAssertGreaterThan(samples.count, 4_353_600)
        XCTAssertTrue(turns.allSatisfy { $0.endSample <= samples.count })

        let wavData = PCM16WAV.data(samples: samples)
        try wavData.write(to: wavURL, options: .atomic)

        let highCount = turns.filter { $0.confidence == .high }.count
        let mediumCount = turns.filter { $0.confidence == .medium }.count
        let speakerCount = Set(turns.map(\.speaker)).count
        let speakerChanges = zip(turns, turns.dropFirst()).filter { $0.speaker != $1.speaker }.count
        let annotatedSamples = turns.reduce(0) { $0 + $1.endSample - $1.startSample }
        XCTAssertEqual(turns.count, 59)
        XCTAssertEqual(highCount, 46)
        XCTAssertEqual(mediumCount, 13)
        XCTAssertEqual(speakerCount, 15)
        XCTAssertEqual(speakerChanges, 57)
        XCTAssertEqual(annotatedSamples, 4_111_760)

        let manifest = JapaneseBenchmarkManifest(
            schemaVersion: 1,
            corpusID: "easy-japanese-1",
            source: .init(
                videoPath: videoURL.path,
                videoSHA256: videoSHA,
                transcriptArchivePath: archiveURL.path,
                transcriptArchiveSHA256: archiveSHA,
                turnsCSVSHA256: digest(turnsData),
                detailedCSVSHA256: digest(detailedData),
                speakersSRTSHA256: digest(speakersData)
            ),
            fixture: .init(
                path: ".build/benchmarks/corpora/easy-japanese-1/audio-16k-mono.wav",
                sha256: digest(wavData),
                sampleRate: 16_000,
                channelCount: 1,
                sampleFormat: "pcm_s16le",
                sampleCount: samples.count
            ),
            annotations: .init(
                turnCount: turns.count,
                detailedFragmentCount: detailedRecords.count,
                speakerCount: speakerCount,
                speakerChangeCount: speakerChanges,
                highConfidenceTurnCount: highCount,
                mediumConfidenceTurnCount: mediumCount,
                annotatedSampleCount: annotatedSamples,
                turns: turns
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: outputURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func selectedTurnIDs(
        environment: [String: String],
        scope: String
    ) -> Set<Int> {
        if let raw = environment["WHISPERASR_JAPANESE_BAKEOFF_TURN_IDS"] {
            return Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        return scope == "smoke" ? Set([3, 4, 6, 7]) : Set(1...59)
    }

    private func requestedVoxtralConfiguration(
        environment: [String: String]
    ) -> VoxtralContinuousConfiguration {
        let model = environment["WHISPERASR_VOXTRAL_HELPER_VARIANT"]
            .flatMap(VoxtralModelVariant.init(rawValue:)) ?? .q4
        let delay = environment["WHISPERASR_VOXTRAL_HELPER_DELAY_MS"]
            .flatMap(Int.init)
            .flatMap(VoxtralTranscriptionDelay.init(rawValue:)) ?? .milliseconds960
        return VoxtralContinuousConfiguration(model: model, delay: delay)
    }

    private func selectedEngines(
        environment: [String: String]
    ) -> [JapaneseBakeoffEngine] {
        guard let raw = environment["WHISPERASR_JAPANESE_BAKEOFF_ENGINES"] else {
            return JapaneseBakeoffEngine.allCases
        }
        return raw.split(separator: ",").compactMap {
            JapaneseBakeoffEngine(rawValue: String($0))
        }
    }

    @MainActor
    private func optionalAppleTranslation(
        environment: [String: String]
    ) async throws -> JapaneseBakeoffTranslation? {
        guard environment["WHISPERASR_JAPANESE_BAKEOFF_APPLE"] == "1" else { return nil }
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Apple high-fidelity comparison requires macOS 26.4 or later.")
        }
        let service = AppleTranslationService()
        try await service.configure(sourceLocale: "ja", mode: .highFidelityOnly)
        return { text in
            try await service.translate(text, highFidelity: true)
        }
    }

    @MainActor
    private func runEngine(
        _ engine: JapaneseBakeoffEngine,
        turns: [JapaneseBenchmarkManifest.Turn],
        samples: [Float],
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService,
        translation: JapaneseBakeoffTranslation?
    ) async -> JapaneseBakeoffEngineReport {
        var turnReports: [JapaneseBakeoffTurnReport] = []
        var setupError: String?

        do {
            await modelManager.unload()
            await whisper.unloadModel()
            switch engine {
            case .whisperTurbo:
                guard let turbo = ModelCatalog.model(id: "large-v3-turbo"),
                      ModelManager.shared.isDownloaded(turbo) else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Whisper Large v3 Turbo is not downloaded."]
                    )
                }
                try await whisper.preloadModel(
                    modelPath: ModelCatalog.path(for: turbo).path,
                    requireEnglishTranslation: false
                )
            case .voxtralContinuous:
                try await modelManager.prepare(.voxtralApple)
            case .qwenASR:
                try await modelManager.prepare(.qwenApple)
            case .cohereQ8:
                try await modelManager.prepare(.cohereApple)
            }
        } catch {
            setupError = error.localizedDescription
        }

        if setupError == nil {
            for (index, turn) in turns.enumerated() {
                let audio = Array(samples[turn.startSample..<turn.endSample])
                let asrStarted = DispatchTime.now().uptimeNanoseconds
                var hypothesis = ""
                var asrError: String?
                do {
                    hypothesis = try await transcribe(
                        engine,
                        audio: audio,
                        absoluteStartSample: turn.startSample,
                        modelManager: modelManager,
                        whisper: whisper
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    asrError = error.localizedDescription
                }
                let asrFinished = DispatchTime.now().uptimeNanoseconds

                var english: String?
                var translationMilliseconds: Double?
                var validEnglish: Bool?
                var translationError: String?
                if let translation, asrError == nil, !hypothesis.isEmpty {
                    let translationStarted = DispatchTime.now().uptimeNanoseconds
                    do {
                        let candidate = try await translation(hypothesis)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let valid = !candidate.isEmpty
                            && !EnglishSubtitleValidator.containsSourceScript(candidate)
                        english = candidate
                        validEnglish = valid
                        if !valid {
                            translationError = "Apple highFidelity returned empty or source-script text."
                        }
                    } catch {
                        translationError = error.localizedDescription
                        validEnglish = false
                    }
                    translationMilliseconds = Double(
                        DispatchTime.now().uptimeNanoseconds - translationStarted
                    ) / 1_000_000
                }

                let helperBytes = engine == .voxtralContinuous
                    ? await modelManager.continuousVoxtralProgress().helperRSSBytes ?? 0
                    : 0
                turnReports.append(JapaneseBakeoffTurnReport(
                    turnID: turn.id,
                    confidence: turn.confidence,
                    speaker: turn.speaker,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    referenceJapanese: turn.japanese,
                    hypothesisJapanese: hypothesis,
                    asrMilliseconds: Double(asrFinished - asrStarted) / 1_000_000,
                    appleEnglish: english,
                    appleHighFidelityMilliseconds: translationMilliseconds,
                    validEnglish: validEnglish,
                    residentBytes: modelManager.currentMemoryBytes() + helperBytes,
                    asrError: asrError,
                    translationError: translationError
                ))
                print(
                    "[JapaneseBakeoff] \(engine.rawValue) "
                        + "turn=\(turn.id) progress=\(index + 1)/\(turns.count)"
                )
            }
        }

        await whisper.unloadModel()
        await modelManager.unload()
        return engineReport(
            engine: engine,
            setupError: setupError,
            turns: turnReports,
            expectedTurnCount: turns.count,
            translationEnabled: translation != nil
        )
    }

    @MainActor
    private func transcribe(
        _ engine: JapaneseBakeoffEngine,
        audio: [Float],
        absoluteStartSample: Int,
        modelManager: LocalEnglishModelManager,
        whisper: TranscriptionService
    ) async throws -> String {
        switch engine {
        case .whisperTurbo:
            guard let turbo = ModelCatalog.model(id: "large-v3-turbo") else {
                throw NSError(
                    domain: "JapaneseModelBakeoff",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Whisper Turbo is absent from ModelCatalog."]
                )
            }
            return try await whisper.transcribeChunk(
                samples: audio,
                language: "ja",
                translate: false,
                modelPath: ModelCatalog.path(for: turbo).path
            ).text
        case .qwenASR:
            return try await modelManager.transcribeQwen(
                audio: audio,
                language: "Japanese"
            )
        case .cohereQ8:
            return try await modelManager.transcribeCohere(
                audio: audio,
                language: "ja"
            )
        case .voxtralContinuous:
            let events = try await modelManager.startContinuousVoxtral()
            let collector = Task {
                var failures: [String] = []
                for await event in events {
                    if case .failed(let message) = event { failures.append(message) }
                }
                return failures
            }
            let blockSamples = VoxtralHelperManifest.sampleRate
                * VoxtralHelperManifest.transportBlockMilliseconds / 1_000
            do {
                for localStart in stride(from: 0, to: audio.count, by: blockSamples) {
                    let localEnd = min(audio.count, localStart + blockSamples)
                    let absoluteRange = (absoluteStartSample + localStart)..<(absoluteStartSample + localEnd)
                    try await modelManager.feedContinuousVoxtral(
                        samples: Array(audio[localStart..<localEnd]),
                        range: absoluteRange
                    )
                }
                let transcript = try await modelManager.finishContinuousVoxtral()
                let failures = await collector.value
                guard failures.isEmpty else {
                    throw NSError(
                        domain: "JapaneseModelBakeoff",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
                    )
                }
                return transcript
            } catch {
                await modelManager.cancelContinuousVoxtral()
                collector.cancel()
                _ = await collector.result
                throw error
            }
        }
    }

    private func engineReport(
        engine: JapaneseBakeoffEngine,
        setupError: String?,
        turns: [JapaneseBakeoffTurnReport],
        expectedTurnCount: Int,
        translationEnabled: Bool
    ) -> JapaneseBakeoffEngineReport {
        let asrFailures = turns.filter { $0.asrError != nil }.count
        let translationFailures = translationEnabled
            ? turns.filter { !$0.hypothesisJapanese.isEmpty && $0.validEnglish != true }.count
            : 0
        let status: String
        if setupError != nil {
            status = "unavailable"
        } else if turns.count != expectedTurnCount || asrFailures > 0 || translationFailures > 0 {
            status = "partial"
        } else {
            status = "complete"
        }
        let asr = turns.filter { $0.asrError == nil }.map(\.asrMilliseconds)
        let translations = turns.compactMap(\.appleHighFidelityMilliseconds)
        return JapaneseBakeoffEngineReport(
            engine: engine,
            status: status,
            setupError: setupError,
            primaryHighConfidenceCER: cerReport(turns, confidence: .high),
            diagnosticMediumConfidenceCER: cerReport(turns, confidence: .medium),
            criticalDiagnostics: criticalDiagnostics(turns),
            asrP50Milliseconds: percentile(asr, fraction: 0.50),
            asrP95Milliseconds: percentile(asr, fraction: 0.95),
            asrWorstMilliseconds: asr.max(),
            appleHighFidelityP50Milliseconds: percentile(translations, fraction: 0.50),
            appleHighFidelityP95Milliseconds: percentile(translations, fraction: 0.95),
            appleHighFidelityWorstMilliseconds: translations.max(),
            maximumResidentBytes: turns.map(\.residentBytes).max() ?? 0,
            turns: turns
        )
    }

    private func cerReport(
        _ turns: [JapaneseBakeoffTurnReport],
        confidence: JapaneseBenchmarkManifest.Turn.Confidence
    ) -> JapaneseBakeoffCERReport {
        let selected = turns.filter { $0.confidence == confidence }
        let score = JapaneseCER.score(selected.map {
            (reference: $0.referenceJapanese, hypothesis: $0.hypothesisJapanese)
        })
        return JapaneseBakeoffCERReport(
            turnCount: selected.count,
            editDistance: score.editDistance,
            referenceCharacterCount: score.referenceCharacterCount,
            hypothesisCharacterCount: score.hypothesisCharacterCount,
            omissionCount: score.omissionCount,
            rate: score.rate
        )
    }

    private func criticalDiagnostics(
        _ turns: [JapaneseBakeoffTurnReport]
    ) -> JapaneseBakeoffCriticalDiagnostics {
        let primary = turns.filter { $0.confidence == .high }
        let questions = primary.filter { turn in
            let text = turn.referenceJapanese.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.contains("？") || text.contains("?")
        }
        let negationMarkers = [
            "じゃなかった", "ではなかった", "ませんでした", "なかった",
            "じゃない", "ではない", "ません", "ない",
        ]
        var referenceNegations = 0
        var missingNegations = 0
        var referenceNumbers = 0
        var missingNumbers = 0
        for turn in primary {
            let hypothesis = turn.hypothesisJapanese.precomposedStringWithCompatibilityMapping
            let reference = turn.referenceJapanese.precomposedStringWithCompatibilityMapping
            let markers = negationMarkers.filter { reference.contains($0) }
            referenceNegations += markers.count
            missingNegations += markers.filter { !hypothesis.contains($0) }.count
            let numbers = numberTokens(in: reference)
            referenceNumbers += numbers.count
            missingNumbers += numbers.filter { !hypothesis.contains($0) }.count
        }
        return JapaneseBakeoffCriticalDiagnostics(
            questionTurnCER: cerReport(questions, confidence: .high),
            referenceNegationMarkerCount: referenceNegations,
            missingNegationMarkerCount: missingNegations,
            referenceNumberTokenCount: referenceNumbers,
            missingNumberTokenCount: missingNumbers,
            properNameScoringStatus: "not-automatically-scored: the supplied corpus has no proper-name span annotations",
            note: "Question CER uses high-confidence turns containing ?/？. Negations and numbers use conservative exact NFC marker matching and remain diagnostic, not the primary score."
        )
    }

    private func numberTokens(in text: String) -> [String] {
        let numberCharacters = Set("0123456789０１２３４５６７８９一二三四五六七八九十百千万億兆")
        var result: [String] = []
        var current = ""
        for character in text {
            if numberCharacters.contains(character) {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(ceil(Double(sorted.count) * fraction)) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func blindArtifacts(
        corpusID: String,
        scope: String,
        reports: [JapaneseBakeoffEngineReport]
    ) -> (report: JapaneseBakeoffBlindReport, key: [String: String]) {
        let engines = JapaneseBakeoffEngine.allCases
        let reportsByEngine = Dictionary(uniqueKeysWithValues: reports.map { ($0.engine, $0) })
        let turnIDs = Set(reports.flatMap { $0.turns.map(\.turnID) }).sorted()
        var key: [String: String] = [:]
        let items = turnIDs.compactMap { turnID -> JapaneseBakeoffBlindItem? in
            let available = reports.compactMap { report in
                report.turns.first { $0.turnID == turnID }
            }
            guard let reference = available.first else { return nil }
            let candidates = engines.indices.compactMap { aliasIndex -> JapaneseBakeoffBlindCandidate? in
                let engine = engines[(aliasIndex + turnID) % engines.count]
                guard let turn = reportsByEngine[engine]?.turns.first(where: {
                    $0.turnID == turnID
                }) else { return nil }
                let alias = String(UnicodeScalar(65 + aliasIndex)!)
                key["\(turnID):\(alias)"] = engine.rawValue
                return JapaneseBakeoffBlindCandidate(
                    alias: alias,
                    japanese: turn.hypothesisJapanese,
                    english: turn.appleEnglish
                )
            }
            return JapaneseBakeoffBlindItem(
                turnID: turnID,
                confidence: reference.confidence,
                referenceJapanese: reference.referenceJapanese,
                candidates: candidates
            )
        }
        return (
            JapaneseBakeoffBlindReport(
                schemaVersion: 1,
                corpusID: corpusID,
                scope: scope,
                note: "Aliases are rotated independently for each turn. English is present only when WHISPERASR_JAPANESE_BAKEOFF_APPLE=1.",
                items: items
            ),
            key
        )
    }

    private func writeBakeoffArtifacts(
        report: JapaneseBakeoffFullReport,
        blind: JapaneseBakeoffBlindReport,
        key: [String: String],
        scope: String,
        root: URL
    ) throws {
        let output = root.appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let safeScope = scope.replacingOccurrences(of: "/", with: "-")
        let stem = "easy-japanese-1-asr-bakeoff-\(safeScope)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifacts: [(String, Data)] = [
            ("\(stem)-full.json", try encoder.encode(report)),
            ("\(stem)-blind.json", try encoder.encode(blind)),
            ("\(stem)-key.json", try encoder.encode(key)),
        ]
        for (name, data) in artifacts {
            let url = output.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            print("[JapaneseBakeoff] wrote \(url.path)")
        }
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "n/a"
    }

    private func referenceTurn(
        _ record: [String: String],
        expectedID: Int
    ) throws -> JapaneseBenchmarkManifest.Turn {
        let id = try integer(record["tour"], field: "tour")
        guard id == expectedID else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Expected turn \(expectedID), found \(id)."
            )
        }
        let start = try JapaneseBenchmarkCSV.sampleIndex(
            timecode: try required(record["debut_switch"], field: "debut_switch")
        )
        let end = try JapaneseBenchmarkCSV.sampleIndex(
            timecode: try required(record["fin"], field: "fin")
        )
        guard end > start else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Turn \(id) has an invalid range.")
        }
        let confidence = try confidence(record["confiance"])
        let note = record["note"].flatMap { $0.isEmpty ? nil : $0 }
        return JapaneseBenchmarkManifest.Turn(
            id: id,
            speaker: try required(record["locuteur"], field: "locuteur"),
            speakerDescription: try required(
                record["description_locuteur"],
                field: "description_locuteur"
            ),
            startSample: start,
            endSample: end,
            japanese: try required(record["japonais"], field: "japonais"),
            confidence: confidence,
            note: note
        )
    }

    private func validateDetailedRecords(_ records: [[String: String]]) throws {
        guard records.count == 102 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Expected 102 detailed fragments, found \(records.count)."
            )
        }
        var high = 0
        var medium = 0
        var previousEnd = 0
        for (index, record) in records.enumerated() {
            let id = try integer(record["index"], field: "index")
            guard id == index + 1 else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Expected detailed fragment \(index + 1), found \(id)."
                )
            }
            let start = try JapaneseBenchmarkCSV.sampleIndex(
                timecode: try required(record["debut"], field: "debut")
            )
            let end = try JapaneseBenchmarkCSV.sampleIndex(
                timecode: try required(record["fin"], field: "fin")
            )
            guard start >= previousEnd,
                  end > start,
                  ["OUI", "NON"].contains(try required(
                    record["changement_de_locuteur"],
                    field: "changement_de_locuteur"
                  )) else {
                throw JapaneseBenchmarkCSV.ParseError.malformed(
                    "Detailed fragment \(id) has invalid timing or speaker-change state."
                )
            }
            _ = try required(record["locuteur"], field: "locuteur")
            _ = try required(record["japonais"], field: "japonais")
            switch try confidence(record["confiance"]) {
            case .high: high += 1
            case .medium: medium += 1
            }
            previousEnd = end
        }
        guard high == 89, medium == 13 else {
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Unexpected detailed confidence counts: high=\(high), medium=\(medium)."
            )
        }
    }

    private func confidence(
        _ value: String?
    ) throws -> JapaneseBenchmarkManifest.Turn.Confidence {
        switch value {
        case "élevée": .high
        case "moyenne": .medium
        default:
            throw JapaneseBenchmarkCSV.ParseError.malformed(
                "Unexpected confidence: \(value ?? "nil")."
            )
        }
    }

    private func integer(_ value: String?, field: String) throws -> Int {
        guard let value, let result = Int(value) else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Invalid integer in \(field).")
        }
        return result
    }

    private func required(_ value: String?, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw JapaneseBenchmarkCSV.ParseError.malformed("Missing \(field).")
        }
        return value
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
