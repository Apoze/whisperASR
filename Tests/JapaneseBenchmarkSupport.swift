import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

struct JapaneseCERScore: Equatable {
    let editDistance: Int
    let substitutionCount: Int
    let deletionCount: Int
    let insertionCount: Int
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
        let annotationStripped = text
            .replacingOccurrences(
                of: #"[［\[].*?[］\]]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "（笑）", with: "")
            .replacingOccurrences(of: "(笑)", with: "")
        let compatibilityNormalized = annotationStripped.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "ja_JP"))
        var result = ""
        for scalar in compatibilityNormalized.unicodeScalars where !ignored.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return Array(result)
    }

    static func score(_ pairs: [(reference: String, hypothesis: String)]) -> JapaneseCERScore {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var referenceCount = 0
        var hypothesisCount = 0
        var omissions = 0
        for pair in pairs {
            let reference = normalized(pair.reference)
            let hypothesis = normalized(pair.hypothesis)
            let alignment = alignment(reference, hypothesis)
            substitutions += alignment.substitutions
            deletions += alignment.deletions
            insertions += alignment.insertions
            referenceCount += reference.count
            hypothesisCount += hypothesis.count
            if !reference.isEmpty, hypothesis.isEmpty { omissions += 1 }
        }
        return JapaneseCERScore(
            editDistance: substitutions + deletions + insertions,
            substitutionCount: substitutions,
            deletionCount: deletions,
            insertionCount: insertions,
            referenceCharacterCount: referenceCount,
            hypothesisCharacterCount: hypothesisCount,
            omissionCount: omissions
        )
    }

    private static func alignment(
        _ reference: [Character],
        _ hypothesis: [Character]
    ) -> (substitutions: Int, deletions: Int, insertions: Int) {
        var matrix = Array(
            repeating: Array(repeating: 0, count: hypothesis.count + 1),
            count: reference.count + 1
        )
        for index in 0...reference.count { matrix[index][0] = index }
        for index in 0...hypothesis.count { matrix[0][index] = index }
        for referenceIndex in reference.indices {
            for hypothesisIndex in hypothesis.indices {
                matrix[referenceIndex + 1][hypothesisIndex + 1] = min(
                    matrix[referenceIndex][hypothesisIndex + 1] + 1,
                    matrix[referenceIndex + 1][hypothesisIndex] + 1,
                    matrix[referenceIndex][hypothesisIndex]
                        + (reference[referenceIndex] == hypothesis[hypothesisIndex] ? 0 : 1)
                )
            }
        }

        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var referenceIndex = reference.count
        var hypothesisIndex = hypothesis.count
        while referenceIndex > 0 || hypothesisIndex > 0 {
            if referenceIndex > 0, hypothesisIndex > 0,
               matrix[referenceIndex][hypothesisIndex]
                    == matrix[referenceIndex - 1][hypothesisIndex - 1]
                        + (reference[referenceIndex - 1] == hypothesis[hypothesisIndex - 1] ? 0 : 1) {
                if reference[referenceIndex - 1] != hypothesis[hypothesisIndex - 1] {
                    substitutions += 1
                }
                referenceIndex -= 1
                hypothesisIndex -= 1
            } else if referenceIndex > 0,
                      matrix[referenceIndex][hypothesisIndex]
                        == matrix[referenceIndex - 1][hypothesisIndex] + 1 {
                deletions += 1
                referenceIndex -= 1
            } else {
                insertions += 1
                hypothesisIndex -= 1
            }
        }
        return (substitutions, deletions, insertions)
    }
}

enum JapaneseBenchmarkSupport {
    struct Manifest: Codable {
        enum Purpose: String, Codable {
            case development
            case holdoutDialogue = "holdout-dialogue"
            case holdoutPodcast = "holdout-podcast"
            case holdoutSpeakerChanges = "holdout-speaker-changes"
        }

        struct Source: Codable {
            struct Reference: Codable {
                let label: String
                let locator: String
                let sha256: String?
            }

            let description: String
            let references: [Reference]
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
            enum Status: String, Codable {
                case complete
                case pendingHumanReview = "pending-human-review"
                case incomplete
            }

            let status: Status
            let reviewedBy: [String]
            let reviewNote: String
            let pendingJapanese: [String]?
            let turns: [Turn]
            let voiceChanges: [VoiceChange]
            let negativeRanges: [NegativeRange]?
        }

        struct NegativeRange: Codable {
            let range: [Int]
            let reason: String?
        }

        struct Turn: Codable {
            enum Confidence: String, Codable {
                case high
                case medium
                case low
                case unverified
            }

            struct CriticalTerm: Codable, Equatable {
                enum Category: String, Codable {
                    case negation
                    case number
                    case name
                    case question
                    case shortReply = "short-reply"
                }

                let category: Category
                let japanese: String
                let expectedEnglish: [String]?
            }

            let id: Int
            let speaker: String
            let startSample: Int
            let endSample: Int
            let japanese: String
            let english: String?
            let confidence: Confidence
            let criticalTerms: [CriticalTerm]
            let overlap: Bool?
            let note: String?
        }

        struct VoiceChange: Codable {
            let id: String
            let previousSpeaker: String
            let nextSpeaker: String
            let previousSpeechEndSample: Int?
            let nextSpeechStartSample: Int
            let kind: String?
            let overlapRange: [Int]?
            let acceptableBreakRange: [Int]
            let expectedJapaneseBefore: String?
            let expectedJapaneseAfter: String?
        }

        let schemaVersion: Int
        let corpusID: String
        let purpose: Purpose
        let source: Source
        let fixture: Fixture
        let annotations: Annotations
    }

    enum ValidationError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case conflictingDuplicateKey
        case invalidCorpusID
        case absolutePath(String)
        case pathEscapesWorkspace(String)
        case invalidSourceReference(String)
        case invalidFixture
        case invalidReview
        case duplicateTurnID
        case invalidTurn(Int)
        case invalidCriticalTerm(Int)
        case invalidVoiceChange(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "Unsupported Japanese corpus schema v\(version)."
            case .conflictingDuplicateKey:
                "The Japanese corpus JSON contains a conflicting duplicate key."
            case .invalidCorpusID:
                "Corpus ID is empty."
            case let .absolutePath(path):
                "Schema v2 local paths must be repo-relative: \(path)"
            case let .pathEscapesWorkspace(path):
                "Corpus fixture escapes the workspace: \(path)"
            case let .invalidSourceReference(locator):
                "Corpus source reference is not repo-relative, HTTPS or a pinned SHA-256 URN: \(locator)"
            case .invalidFixture:
                "Fixture must be mono PCM at 16 kHz with a positive sample count and SHA-256."
            case .invalidReview:
                "Annotations require a review note; complete corpora also need named reviewers and verified purpose-specific evidence."
            case .duplicateTurnID:
                "Turn IDs are not unique."
            case let .invalidTurn(id):
                "Turn \(id) has invalid text, speaker or sample bounds."
            case let .invalidCriticalTerm(id):
                "Turn \(id) has an invalid critical term."
            case let .invalidVoiceChange(id):
                "Voice change \(id) has an invalid break range or speaker pair."
            }
        }
    }

    static func loadManifest(at url: URL) throws -> Manifest {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Manifest {
        var keyScanner = JSONKeyScanner(data: data)
        do {
            try keyScanner.validate()
        } catch JSONKeyScanner.ScanError.duplicateKey {
            throw ValidationError.conflictingDuplicateKey
        } catch {
            // JSONDecoder below remains authoritative for syntax errors.
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: data)
        try validate(manifest)
        return manifest
    }

    static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 2 else {
            throw ValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.corpusID.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
            options: .regularExpression
        ) != nil else {
            throw ValidationError.invalidCorpusID
        }
        let localLocators = [manifest.fixture.path]
            + manifest.source.references.compactMap { reference -> String? in
                let locator = reference.locator
                guard let scheme = URL(string: locator)?.scheme else { return locator }
                return scheme == "file" ? locator : nil
            }
        if let absolute = localLocators.first(where: {
            NSString(string: $0).isAbsolutePath || $0.hasPrefix("file:")
        }) {
            throw ValidationError.absolutePath(absolute)
        }
        if let escaping = localLocators.first(where: {
            NSString(string: $0).pathComponents.contains("..")
        }) {
            throw ValidationError.pathEscapesWorkspace(escaping)
        }
        let fixture = manifest.fixture
        guard !manifest.source.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fixture.sampleRate == 16_000,
              fixture.channelCount == 1,
              fixture.sampleFormat == "pcm_s16le",
              fixture.sampleCount > 0,
              isSHA256(fixture.sha256),
              manifest.source.references.allSatisfy({ reference in
                  !reference.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !reference.locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && reference.sha256.map(isSHA256) != false
              }) else {
            throw ValidationError.invalidFixture
        }
        for reference in manifest.source.references {
            guard let scheme = URL(string: reference.locator)?.scheme else { continue }
            switch scheme {
            case "https": break
            case "urn":
                guard let sha256 = reference.sha256,
                      reference.locator == "urn:sha256:\(sha256)" else {
                    throw ValidationError.invalidSourceReference(reference.locator)
                }
            default:
                throw ValidationError.invalidSourceReference(reference.locator)
            }
        }

        let annotations = manifest.annotations
        guard !annotations.reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidReview
        }
        guard annotations.pendingJapanese?.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) != false else {
            throw ValidationError.invalidReview
        }
        if annotations.status == .complete {
            let hasRequiredAnnotations = manifest.purpose == .holdoutSpeakerChanges
                ? !annotations.voiceChanges.isEmpty
                : !annotations.turns.isEmpty
            guard !annotations.reviewedBy.isEmpty,
                  annotations.reviewedBy.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }),
                  hasRequiredAnnotations,
                  annotations.pendingJapanese?.isEmpty != false,
                  annotations.turns.allSatisfy({ $0.confidence != .unverified }) else {
                throw ValidationError.invalidReview
            }
        }
        guard Set(annotations.turns.map(\.id)).count == annotations.turns.count else {
            throw ValidationError.duplicateTurnID
        }
        var previousStart = 0
        for turn in annotations.turns {
            guard turn.id > 0,
                  !turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !turn.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.startSample >= previousStart,
                  turn.endSample > turn.startSample,
                  turn.endSample <= fixture.sampleCount else {
                throw ValidationError.invalidTurn(turn.id)
            }
            guard turn.criticalTerms.allSatisfy({ term in
                !term.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && turn.japanese.contains(term.japanese)
                    && (term.expectedEnglish?.allSatisfy({ !$0.isEmpty }) ?? true)
            }) else {
                throw ValidationError.invalidCriticalTerm(turn.id)
            }
            previousStart = turn.startSample
        }
        guard Set(annotations.voiceChanges.map(\.id)).count
                == annotations.voiceChanges.count else {
            throw ValidationError.invalidVoiceChange("duplicate")
        }
        for change in annotations.voiceChanges {
            guard change.acceptableBreakRange.count == 2,
                  !change.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.nextSpeechStartSample >= 0,
                  change.nextSpeechStartSample <= fixture.sampleCount,
                  change.previousSpeechEndSample.map({
                      $0 >= 0 && $0 <= fixture.sampleCount
                  }) != false,
                  change.overlapRange.map({ range in
                      range.count == 2
                          && range[0] >= 0
                          && range[1] >= range[0]
                          && range[1] <= fixture.sampleCount
                  }) != false,
                  change.acceptableBreakRange[0] >= 0,
                  change.acceptableBreakRange[1] >= change.acceptableBreakRange[0],
                  change.acceptableBreakRange[1] <= fixture.sampleCount,
                  !change.previousSpeaker.isEmpty,
                  !change.nextSpeaker.isEmpty,
                  change.previousSpeaker != change.nextSpeaker else {
                throw ValidationError.invalidVoiceChange(change.id)
            }
        }
        for negativeRange in annotations.negativeRanges ?? [] {
            guard negativeRange.range.count == 2,
                  negativeRange.range[0] >= 0,
                  negativeRange.range[1] >= negativeRange.range[0],
                  negativeRange.range[1] <= fixture.sampleCount else {
                throw ValidationError.invalidVoiceChange("negative-range")
            }
        }
    }

    static func fixtureURL(for manifest: Manifest, workspaceRoot: URL) throws -> URL {
        let root = workspaceRoot.standardizedFileURL
        let result = root.appendingPathComponent(manifest.fixture.path).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard result.path.hasPrefix(rootPrefix) else {
            throw ValidationError.pathEscapesWorkspace(manifest.fixture.path)
        }
        return result
    }

    static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Files use their byte digest. Model directories use one stable digest
    /// over relative paths and bytes so every runtime can attest its tree.
    static func artifactSHA256(at url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue { return try sha256(at: url) }

        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { throw CocoaError(.fileReadUnknown) }
        let files = enumerator.compactMap { $0 as? URL }.filter { file in
            (try? file.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.path.dropFirst(url.path.count + 1).utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private struct JSONKeyScanner {
        enum ScanError: Error {
            case malformed
            case duplicateKey
        }

        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) {
            bytes = Array(data)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                index = 3
            }
        }

        mutating func validate() throws {
            try value()
            skipWhitespace()
            guard index == bytes.count else { throw ScanError.malformed }
        }

        private mutating func value() throws {
            skipWhitespace()
            guard let byte = current else { throw ScanError.malformed }
            switch byte {
            case 0x7B: try object() // {
            case 0x5B: try array() // [
            case 0x22: _ = try string() // "
            default: try scalar()
            }
        }

        private mutating func object() throws {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw ScanError.duplicateKey }
                skipWhitespace()
                guard consume(0x3A) else { throw ScanError.malformed }
                try value()
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw ScanError.malformed }
            }
        }

        private mutating func array() throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try value()
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw ScanError.malformed }
            }
        }

        private mutating func string() throws -> String {
            let start = index
            guard consume(0x22) else { throw ScanError.malformed }
            while let byte = current {
                index += 1
                if byte == 0x5C {
                    guard current != nil else { throw ScanError.malformed }
                    index += 1
                } else if byte == 0x22 {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start..<index])
                    )
                }
            }
            throw ScanError.malformed
        }

        private mutating func scalar() throws {
            let start = index
            while let byte = current,
                  ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(byte) {
                index += 1
            }
            guard index > start else { throw ScanError.malformed }
        }

        private mutating func skipWhitespace() {
            while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
                index += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1
            return true
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }
    }
}

final class JapaneseBenchmarkSupportTests: XCTestCase {
    private static let versionedCorpusIDs = [
        "easy-japanese-1",
        "kikusasaizu-l1-1",
        "okkei-shun-1541-1711",
        "interview-speakers-0245-0325",
        "qudu2fx3ncc",
        "md62mmdz0m",
    ]

    func testV2ValidatesReviewPathsAndReproducibleBlindOrder() throws {
        let valid = Data(#"""
        {
          "schemaVersion": 2,
          "corpusID": "fixture",
          "purpose": "development",
          "source": {
            "description": "fixture",
            "references": [{
              "label": "source",
              "locator": "source.wav",
              "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }]
          },
          "fixture": {
            "path": ".build/benchmarks/japanese-live/fixture/audio.wav",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sampleRate": 16000,
            "channelCount": 1,
            "sampleFormat": "pcm_s16le",
            "sampleCount": 100
          },
          "annotations": {
            "status": "complete",
            "reviewedBy": ["human-reviewer"],
            "reviewNote": "Japanese and timing checked against the waveform.",
            "turns": [{
              "id": 1,
              "speaker": "A",
              "startSample": 0,
              "endSample": 100,
              "japanese": "はい",
              "english": "Yes",
              "confidence": "high",
              "criticalTerms": [{
                "category": "short-reply",
                "japanese": "はい",
                "expectedEnglish": ["yes"]
              }],
              "note": null
            }],
            "voiceChanges": []
          }
        }
        """#.utf8)
        let manifest = try JapaneseBenchmarkSupport.decode(valid)
        XCTAssertEqual(
            try JapaneseBenchmarkSupport.fixtureURL(
                for: manifest,
                workspaceRoot: URL(fileURLWithPath: "/workspace")
            ).path,
            "/workspace/.build/benchmarks/japanese-live/fixture/audio.wav"
        )

        let absolute = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(
                of: ".build/benchmarks/japanese-live/fixture/audio.wav",
                with: "/tmp/audio.wav"
            ).utf8)
        XCTAssertThrowsError(try JapaneseBenchmarkSupport.decode(absolute))

        let unsupportedSource = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "source.wav", with: "ftp://example.com/source.wav")
            .utf8)
        XCTAssertThrowsError(try JapaneseBenchmarkSupport.decode(unsupportedSource))

        let duplicate = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(
                of: #""status": "complete""#,
                with: #""status": "complete", "status": "incomplete""#
            ).utf8)
        XCTAssertThrowsError(try JapaneseBenchmarkSupport.decode(duplicate)) { error in
            XCTAssertEqual(
                error as? JapaneseBenchmarkSupport.ValidationError,
                .conflictingDuplicateKey
            )
        }
        var duplicateWithBOM = Data([0xEF, 0xBB, 0xBF])
        duplicateWithBOM.append(duplicate)
        XCTAssertThrowsError(try JapaneseBenchmarkSupport.decode(duplicateWithBOM))

        let traversal = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: #""corpusID": "fixture""#, with: #""corpusID": "../fixture""#)
            .utf8)
        XCTAssertThrowsError(try JapaneseBenchmarkSupport.decode(traversal))

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

    func testVersionedCorporaRemainBlockedUntilHumanReview() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("docs/japanese-live/corpora")
        let expected: [String: JapaneseBenchmarkSupport.Manifest.Annotations.Status] = [
            "easy-japanese-1": .pendingHumanReview,
            "kikusasaizu-l1-1": .pendingHumanReview,
            "okkei-shun-1541-1711": .incomplete,
            "interview-speakers-0245-0325": .incomplete,
            "qudu2fx3ncc": .pendingHumanReview,
            "md62mmdz0m": .pendingHumanReview,
        ]

        let manifests = try expected.map { corpusID, status in
            let manifest = try JapaneseBenchmarkSupport.loadManifest(
                at: directory.appendingPathComponent("\(corpusID)/manifest.json")
            )
            XCTAssertEqual(manifest.corpusID, corpusID)
            XCTAssertEqual(manifest.annotations.status, status)
            _ = try JapaneseBenchmarkSupport.fixtureURL(for: manifest, workspaceRoot: root)
            return manifest
        }

        XCTAssertFalse(manifests.contains { $0.annotations.status == .complete })
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "easy-japanese-1" })?
                .annotations.turns.count,
            59
        )
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "kikusasaizu-l1-1" })?
                .annotations.turns.count,
            14
        )
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "okkei-shun-1541-1711" })?
                .annotations.turns.count,
            0
        )
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "interview-speakers-0245-0325" })?
                .annotations.turns.count,
            14
        )
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "qudu2fx3ncc" })?
                .annotations.turns.count,
            199
        )
        XCTAssertEqual(
            manifests.first(where: { $0.corpusID == "md62mmdz0m" })?
                .annotations.turns.count,
            271
        )
    }

    func testLocalFixturesMatchVersionedManifestsWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_VERIFY_JAPANESE_CORPORA"] == "1" else {
            throw XCTSkip("Run Scripts/verify_japanese_corpora.sh to verify local WAV fixtures.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("docs/japanese-live/corpora")

        for corpusID in Self.versionedCorpusIDs {
            let manifest = try JapaneseBenchmarkSupport.loadManifest(
                at: directory.appendingPathComponent("\(corpusID)/manifest.json")
            )
            let fixture = try JapaneseBenchmarkSupport.fixtureURL(
                for: manifest,
                workspaceRoot: root
            )
            XCTAssertEqual(
                try JapaneseBenchmarkSupport.sha256(at: fixture),
                manifest.fixture.sha256
            )
            for reference in manifest.source.references {
                guard URL(string: reference.locator)?.scheme == nil,
                      let expectedSHA256 = reference.sha256 else { continue }
                let referenceURL = root.appendingPathComponent(reference.locator)
                XCTAssertEqual(
                    try JapaneseBenchmarkSupport.sha256(at: referenceURL),
                    expectedSHA256
                )
            }
            let samples = try await AudioLoader.loadSamples(url: fixture)
            XCTAssertEqual(samples.count, manifest.fixture.sampleCount)
        }
    }

    func testLongFormCorporaKeepScoringBandsSeparate() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("docs/japanese-live/corpora")
        let expected = [
            "qudu2fx3ncc": (high: 143, medium: 44, low: 12, overlap: 37, negatives: 1),
            "md62mmdz0m": (high: 179, medium: 89, low: 3, overlap: 2, negatives: 2),
        ]

        for (corpusID, counts) in expected {
            let manifest = try JapaneseBenchmarkSupport.loadManifest(
                at: directory.appendingPathComponent("\(corpusID)/manifest.json")
            )
            XCTAssertEqual(
                manifest.annotations.turns.filter { $0.confidence == .high }.count,
                counts.high
            )
            XCTAssertEqual(
                manifest.annotations.turns.filter { $0.confidence == .medium }.count,
                counts.medium
            )
            XCTAssertEqual(
                manifest.annotations.turns.filter { $0.confidence == .low }.count,
                counts.low
            )
            XCTAssertEqual(manifest.annotations.negativeRanges?.count, counts.negatives)
            XCTAssertTrue(manifest.annotations.turns.allSatisfy { $0.overlap != nil })
            XCTAssertEqual(
                manifest.annotations.turns.filter { $0.overlap == true }.count,
                counts.overlap
            )
        }
    }
}
