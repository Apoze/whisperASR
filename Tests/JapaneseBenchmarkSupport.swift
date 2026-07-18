import Foundation
import XCTest

enum JapaneseBenchmarkSupport {
    struct Manifest: Codable {
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

    enum ValidationError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case invalidCorpusID
        case invalidFixture
        case inconsistentCounts
        case invalidTurn(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "Unsupported Japanese corpus schema v\(version)."
            case .invalidCorpusID:
                "Corpus ID is empty."
            case .invalidFixture:
                "Fixture must be mono Float/PCM at 16 kHz with a positive sample count and SHA-256."
            case .inconsistentCounts:
                "Annotation summary does not match its turns."
            case let .invalidTurn(id):
                "Turn \(id) has invalid text, speaker, confidence or sample bounds."
            }
        }
    }

    static func loadManifest(at url: URL) throws -> Manifest {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try validate(manifest)
        return manifest
    }

    static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard !manifest.corpusID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidCorpusID
        }
        let fixture = manifest.fixture
        guard fixture.sampleRate == 16_000,
              fixture.channelCount == 1,
              fixture.sampleCount > 0,
              fixture.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidFixture
        }
        let annotations = manifest.annotations
        let turns = annotations.turns
        guard annotations.turnCount == turns.count,
              annotations.highConfidenceTurnCount == turns.filter({ $0.confidence == .high }).count,
              annotations.mediumConfidenceTurnCount == turns.filter({ $0.confidence == .medium }).count,
              annotations.speakerCount == Set(turns.map(\.speaker)).count,
              annotations.speakerChangeCount == zip(turns, turns.dropFirst())
                .filter({ $0.speaker != $1.speaker }).count,
              Set(turns.map(\.id)).count == turns.count else {
            throw ValidationError.inconsistentCounts
        }
        var previousStart = 0
        for turn in turns {
            guard turn.id > 0,
                  !turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !turn.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.startSample >= previousStart,
                  turn.endSample > turn.startSample,
                  turn.endSample <= fixture.sampleCount else {
                throw ValidationError.invalidTurn(turn.id)
            }
            previousStart = turn.startSample
        }
    }

    static func blindOrder<Element>(
        _ values: [Element],
        seed: String,
        itemID: Int,
        identity: (Element) -> String
    ) -> [Element] {
        values.sorted { lhs, rhs in
            let leftIdentity = identity(lhs)
            let rightIdentity = identity(rhs)
            let left = stableHash("\(seed)|\(itemID)|\(leftIdentity)")
            let right = stableHash("\(seed)|\(itemID)|\(rightIdentity)")
            return left == right ? leftIdentity < rightIdentity : left < right
        }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

final class JapaneseBenchmarkSupportTests: XCTestCase {
    func testV1ValidatesCorpusAndBlindOrderIsReproducible() throws {
        let valid = Data(#"""
        {
          "schemaVersion": 1,
          "corpusID": "fixture",
          "source": {
            "videoPath": "/local/video.mp4",
            "videoSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "transcriptArchivePath": "/local/transcript.zip",
            "transcriptArchiveSHA256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "turnsCSVSHA256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "detailedCSVSHA256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "speakersSRTSHA256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
          },
          "fixture": {
            "path": ".build/benchmarks/corpora/fixture/audio.wav",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sampleRate": 16000,
            "channelCount": 1,
            "sampleFormat": "pcm_f32le",
            "sampleCount": 100
          },
          "annotations": {
            "turnCount": 1,
            "detailedFragmentCount": 1,
            "speakerCount": 1,
            "speakerChangeCount": 0,
            "highConfidenceTurnCount": 1,
            "mediumConfidenceTurnCount": 0,
            "annotatedSampleCount": 100,
            "turns": [{
              "id": 1,
              "speaker": "A",
              "speakerDescription": "voice A",
              "startSample": 0,
              "endSample": 100,
              "japanese": "はい",
              "confidence": "high"
            }]
          }
        }
        """#.utf8)
        XCTAssertNoThrow(try JapaneseBenchmarkSupport.decode(valid))

        let values = ["alpha", "beta", "gamma"]
        let first = JapaneseBenchmarkSupport.blindOrder(
            values, seed: "fixture", itemID: 1, identity: { $0 }
        )
        XCTAssertEqual(
            first,
            JapaneseBenchmarkSupport.blindOrder(
                values, seed: "fixture", itemID: 1, identity: { $0 }
            )
        )
        XCTAssertEqual(Set(first), Set(values))
    }
}
