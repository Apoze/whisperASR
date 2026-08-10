import Foundation

enum HighQualityConversationContextPolicy: String, Codable, Sendable {
    case none
    case previousAcceptedV1 = "previous-accepted-v1"

    static let productDefault = Self.previousAcceptedV1

    var version: String { rawValue }
    var maximumDepth: Int { self == .none ? 0 : 2 }
    var maximumEncodedHistoryBytes: Int { self == .none ? 0 : 512 }
    var largePauseSeconds: TimeInterval { self == .none ? .infinity : 8 }
}

enum HighQualityConversationContextResetReason: String, Codable, Sendable {
    case jobStart = "job-start"
    case largePause = "large-pause"
    case chapter
    case sceneBoundary = "scene-boundary"
}

struct HighQualityAcceptedTranslationPair: Codable, Equatable, Sendable {
    let cueID: String
    let japanese: String
    let english: String
}

struct HighQualityConversationContextEvidence: Codable, Equatable, Sendable {
    let policyVersion: String
    let acceptedHistory: [HighQualityAcceptedTranslationPair]
    let resetReason: HighQualityConversationContextResetReason?
    let currentTarget: String
    let encodedHistoryBytes: Int
}

struct HighQualityConversationContextState {
    let policy: HighQualityConversationContextPolicy
    let explicitResetReasons: [String: HighQualityConversationContextResetReason]
    private var accepted: [HighQualityAcceptedTranslationPair] = []
    private var previousTurn: HighQualityTranslationTurn?

    init(
        policy: HighQualityConversationContextPolicy,
        explicitResetReasons: [String: HighQualityConversationContextResetReason]
    ) {
        self.policy = policy
        self.explicitResetReasons = explicitResetReasons
    }

    mutating func context(for turn: HighQualityTranslationTurn) -> HighQualityConversationContextEvidence? {
        guard policy != .none else { return nil }
        let resetReason = resetReason(for: turn)
        if resetReason != nil { accepted.removeAll(keepingCapacity: true) }
        var history = Array(accepted.suffix(policy.maximumDepth))
        while encodedBytes(history) > policy.maximumEncodedHistoryBytes {
            history.removeFirst()
        }
        previousTurn = turn
        return .init(
            policyVersion: policy.version,
            acceptedHistory: history,
            resetReason: resetReason,
            currentTarget: turn.japanese,
            encodedHistoryBytes: encodedBytes(history)
        )
    }

    mutating func accept(_ turn: HighQualityTranslationTurn, english: String) {
        accepted.append(.init(cueID: turn.id, japanese: turn.japanese, english: english))
    }

    private func resetReason(
        for turn: HighQualityTranslationTurn
    ) -> HighQualityConversationContextResetReason? {
        if previousTurn == nil { return .jobStart }
        if let explicit = explicitResetReasons[turn.id] { return explicit }
        guard let previousEnd = previousTurn?.sourceEnd,
              let currentStart = turn.sourceStart,
              currentStart - previousEnd >= policy.largePauseSeconds else { return nil }
        return .largePause
    }

    private func encodedBytes(_ history: [HighQualityAcceptedTranslationPair]) -> Int {
        history.reduce(0) { $0 + $1.japanese.utf8.count + $1.english.utf8.count }
    }
}
