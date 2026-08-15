import Foundation
import XCTest
@testable import WhisperASRApp

enum ReadableSubtitleReplaySupport {
    static func replay(
        _ relativePath: String,
        includeSpeakers: Bool = true
    ) throws -> HighQualityReadableSubtitleResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent(
            "docs/japanese-live/experiments/evidence/\(relativePath)"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", path.path]
        process.standardOutput = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(HighQualityRawEvidence.self, from: data)
        let alignment = try XCTUnwrap(raw.alignment)
        let translation = try XCTUnwrap(raw.translation)
        let outputs = Dictionary(uniqueKeysWithValues: translation.integrityVerdicts.map {
            ($0.cueID, $0.generatedOutput)
        })
        let units = try XCTUnwrap(alignment.semanticUnits)
        let fragments = try XCTUnwrap(alignment.semanticFragments)
        XCTAssertEqual(Set(outputs.keys), Set(units.map(\.id)))
        let sourceCues = try units.map { unit in
            HighQualitySubtitleCue(
                id: unit.id,
                start: unit.start,
                end: unit.end,
                text: try XCTUnwrap(outputs[unit.id]),
                speakerLabel: includeSpeakers ? unit.speakerLabel : nil
            )
        }
        return try HighQualityReadableSubtitleReflow.apply(
            to: sourceCues,
            units: units,
            fragments: fragments
        )
    }
}
