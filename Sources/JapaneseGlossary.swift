import CryptoKit
import Foundation

/// Exact, deterministic corrections applied only to the Japanese copy sent
/// to translation. The original ASR transcript remains untouched.
struct JapaneseGlossary: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let recognized: String
        let canonical: String
    }

    private let entries: [Entry]

    static let enabledKey = "japaneseGlossaryEnabled"
    static let rulesKey = "japaneseGlossaryRules"
    static let empty = Self(entries: [])

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Stable provenance for reports and recovery without exposing user terms.
    var fingerprint: String? {
        guard !entries.isEmpty else { return nil }
        let canonical = entries.map { "\($0.recognized)=\($0.canonical)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(entries: [Entry]) {
        var recognizedTerms = Set<String>()
        self.entries = entries
            .map {
                Entry(
                    recognized: Self.normalizedTransportText($0.recognized),
                    canonical: Self.normalizedTransportText($0.canonical)
                )
            }
            .filter { !$0.recognized.isEmpty && !$0.canonical.isEmpty }
            .filter { recognizedTerms.insert($0.recognized).inserted }
            .sorted {
                if $0.recognized.utf8.count != $1.recognized.utf8.count {
                    return $0.recognized.utf8.count > $1.recognized.utf8.count
                }
                return $0.recognized < $1.recognized
            }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([Entry].self, forKey: .entries))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    init(rules: String) {
        self.init(entries: rules.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { return nil }
            return Entry(recognized: parts[0], canonical: parts[1])
        })
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard defaults.bool(forKey: enabledKey) else { return .empty }
        return Self(rules: defaults.string(forKey: rulesKey) ?? "")
    }

    func applying(to rawText: String) -> String {
        guard !entries.isEmpty else { return rawText }

        let source = Self.normalizedTransportText(rawText)
        var result = ""
        result.reserveCapacity(source.utf8.count)
        var index = source.startIndex

        while index < source.endIndex {
            if let entry = entries.first(where: { source[index...].hasPrefix($0.recognized) }) {
                result.append(entry.canonical)
                index = source.index(index, offsetBy: entry.recognized.count)
            } else {
                result.append(source[index])
                index = source.index(after: index)
            }
        }
        return result
    }

    private static func normalizedTransportText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters)
            .joined()
            .precomposedStringWithCanonicalMapping
    }
}
