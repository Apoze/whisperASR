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

private struct JapaneseBenchmarkManifest: Codable {
    struct Source: Codable {
        let videoPath: String
        let videoSHA256: String
        let transcriptArchivePath: String
        let transcriptArchiveSHA256: String
        let turnsCSVSHA256: String
        let detailedCSVSHA256: String
        let speakersSRTSHA256: String
    }

    struct Fixture: Codable {
        let path: String
        let sha256: String
        let sampleRate: Int
        let channelCount: Int
        let sampleFormat: String
        let sampleCount: Int
    }

    struct Annotations: Codable {
        let turnCount: Int
        let detailedFragmentCount: Int
        let speakerCount: Int
        let speakerChangeCount: Int
        let highConfidenceTurnCount: Int
        let mediumConfidenceTurnCount: Int
        let annotatedSampleCount: Int
        let turns: [Turn]
    }

    struct Turn: Codable {
        enum Confidence: String, Codable {
            case high
            case medium
        }

        let id: Int
        let speaker: String
        let speakerDescription: String
        let startSample: Int
        let endSample: Int
        let japanese: String
        let confidence: Confidence
        let note: String?
    }

    let schemaVersion: Int
    let corpusID: String
    let source: Source
    let fixture: Fixture
    let annotations: Annotations
}

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
