import Foundation
import XCTest

final class VoxtralConfigurationComparisonTests: XCTestCase {
    private struct SourceReport: Decodable {
        struct Configuration: Decodable {
            let delay: Int
            let model: String
        }

        struct Engine: Decodable {
            struct Turn: Decodable {
                let appleEnglish: String?
                let hypothesisJapanese: String
                let referenceJapanese: String
                let turnID: Int
            }

            let turns: [Turn]
        }

        let engines: [Engine]
        let voxtralConfiguration: Configuration
    }

    private struct BlindReport: Encodable {
        struct Item: Encodable {
            struct Candidate: Encodable {
                let alias: String
                let english: String
                let japanese: String
            }

            let turnID: Int
            let referenceJapanese: String
            let candidates: [Candidate]
        }

        let instructions: String
        let items: [Item]
    }

    private struct KeyReport: Encodable {
        struct Item: Encodable {
            let turnID: Int
            let aliases: [String: String]
        }

        let items: [Item]
    }

    func testAggregateBlindConfigurationComparisonWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_AGGREGATE_BLIND"
        ] == "1" else {
            throw XCTSkip("Run the configuration bakeoff script to aggregate blind results.")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        let names = [
            "easy-japanese-1-asr-bakeoff-q4-960-full-full.json",
            "easy-japanese-1-asr-bakeoff-q6-960-full-full.json",
            "easy-japanese-1-asr-bakeoff-q6-1200-full-full.json",
            "easy-japanese-1-asr-bakeoff-q6-2400-full-full.json",
        ]
        let decoder = JSONDecoder()
        let reports = try names.map {
            try decoder.decode(
                SourceReport.self,
                from: Data(contentsOf: root.appendingPathComponent($0))
            )
        }
        XCTAssertEqual(reports.count, 4)
        let turnIDs = reports[0].engines[0].turns.map(\.turnID)
        XCTAssertTrue(reports.allSatisfy { $0.engines[0].turns.map(\.turnID) == turnIDs })

        var blindItems: [BlindReport.Item] = []
        var keyItems: [KeyReport.Item] = []
        let aliases = ["A", "B", "C", "D"]
        for (turnIndex, turnID) in turnIDs.enumerated() {
            let rotation = turnIndex % reports.count
            var candidates: [BlindReport.Item.Candidate] = []
            var key: [String: String] = [:]
            for aliasIndex in reports.indices {
                let reportIndex = (aliasIndex + rotation) % reports.count
                let report = reports[reportIndex]
                let turn = report.engines[0].turns[turnIndex]
                let alias = aliases[aliasIndex]
                let configuration = "\(report.voxtralConfiguration.model)-\(report.voxtralConfiguration.delay)"
                candidates.append(.init(
                    alias: alias,
                    english: turn.appleEnglish ?? "",
                    japanese: turn.hypothesisJapanese
                ))
                key[alias] = configuration
            }
            blindItems.append(.init(
                turnID: turnID,
                referenceJapanese: reports[0].engines[0].turns[turnIndex].referenceJapanese,
                candidates: candidates
            ))
            keyItems.append(.init(turnID: turnID, aliases: key))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BlindReport(
            instructions: "For each alias, rate fidelity and subtitle naturalness 1-5, flag critical errors, then choose a preference before opening the key.",
            items: blindItems
        )).write(
            to: root.appendingPathComponent("easy-japanese-1-voxtral-configurations-blind.json"),
            options: .atomic
        )
        try encoder.encode(KeyReport(items: keyItems)).write(
            to: root.appendingPathComponent("easy-japanese-1-voxtral-configurations-key.json"),
            options: .atomic
        )
    }
}
