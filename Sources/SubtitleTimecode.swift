import Foundation

enum SubtitleTimecode {
    static func srt(_ seconds: TimeInterval) -> String { format(seconds, separator: ",") }
    static func webVTT(_ seconds: TimeInterval) -> String { format(seconds, separator: ".") }

    private static func format(_ seconds: TimeInterval, separator: Character) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d%@%03d",
            total / 3_600_000,
            (total % 3_600_000) / 60_000,
            (total % 60_000) / 1000,
            String(separator),
            total % 1000
        )
    }
}
