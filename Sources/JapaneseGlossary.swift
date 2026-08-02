import CryptoKit
import Foundation

struct JapaneseContextTerm: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var canonical: String
    var reading: String
    var aliases: [String]

    init(
        id: String = UUID().uuidString,
        canonical: String = "",
        reading: String = "",
        aliases: [String] = []
    ) {
        self.id = id
        self.canonical = canonical
        self.reading = reading
        self.aliases = aliases
    }

    fileprivate var normalized: Self {
        Self(
            id: id,
            canonical: normalizedJapaneseContextText(canonical),
            reading: normalizedJapaneseContextText(reading),
            aliases: aliases.map(normalizedJapaneseContextText).filter { !$0.isEmpty }
        )
    }
}

struct JapaneseContextProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var terms: [JapaneseContextTerm]
}

struct JapaneseContextLibrary: Codable, Equatable, Sendable {
    static let profilesKey = "japaneseContextProfiles"
    static let selectionKey = "japaneseContextSelection"
    static let schemaVersionKey = "japaneseContextProfilesSchemaVersion"
    static let schemaVersion = 1
    static let offSelection = "off"
    static let generalID = "general"
    static let vspoID = "vspo"

    var profiles: [JapaneseContextProfile]

    var generalProfile: JapaneseContextProfile? {
        profiles.first { $0.id == Self.generalID }
    }

    func activeGlossary(selection: String) -> JapaneseGlossary {
        guard selection != Self.offSelection, let generalProfile else { return .empty }
        let selected = selection == Self.generalID
            ? nil : profiles.first { $0.id == selection && $0.id != Self.generalID }
        // The explicitly selected topic wins alias conflicts, then General fills gaps.
        let activeProfiles = [selected, generalProfile].compactMap { $0 }
        var canonicals = Set<String>()
        let terms = activeProfiles.flatMap(\.terms)
            .map(\.normalized)
            .filter { !$0.canonical.isEmpty && canonicals.insert($0.canonical).inserted }
        return JapaneseGlossary(terms: terms)
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        if let json = defaults.string(forKey: profilesKey),
           let data = json.data(using: .utf8),
           let library = try? JSONDecoder().decode(Self.self, from: data),
           library.generalProfile != nil {
            return library
        }

        var library = defaultLibrary
        let legacyRules = defaults.string(forKey: JapaneseGlossary.rulesKey) ?? ""
        if !legacyRules.isEmpty,
           let generalIndex = library.profiles.firstIndex(where: { $0.id == generalID }) {
            for (offset, rule) in legacyRules.split(whereSeparator: \.isNewline).enumerated() {
                let parts = rule.split(separator: "=", maxSplits: 1).map {
                    normalizedJapaneseContextText(String($0))
                }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
                if let termIndex = library.profiles[generalIndex].terms.firstIndex(where: {
                    $0.canonical == parts[1]
                }) {
                    if !library.profiles[generalIndex].terms[termIndex].aliases.contains(parts[0]) {
                        library.profiles[generalIndex].terms[termIndex].aliases.append(parts[0])
                    }
                } else {
                    library.profiles[generalIndex].terms.append(JapaneseContextTerm(
                        id: "legacy-\(offset)",
                        canonical: parts[1],
                        aliases: [parts[0]]
                    ))
                }
            }
        }

        library.store(in: defaults)
        if defaults.string(forKey: selectionKey) == nil {
            let legacyEnabled = defaults.object(forKey: JapaneseGlossary.enabledKey)
                .map { _ in defaults.bool(forKey: JapaneseGlossary.enabledKey) }
            defaults.set(legacyEnabled == false ? offSelection : generalID, forKey: selectionKey)
        }
        defaults.set(schemaVersion, forKey: schemaVersionKey)
        return library
    }

    func store(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.profilesKey)
        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
        let selection = defaults.string(forKey: Self.selectionKey) ?? Self.generalID
        if selection != Self.offSelection,
           selection != Self.generalID,
           !profiles.contains(where: { $0.id == selection }) {
            defaults.set(Self.generalID, forKey: Self.selectionKey)
        }
    }

    static let defaultLibrary = Self(profiles: [
        JapaneseContextProfile(
            id: generalID,
            name: "General",
            terms: [
                term("youtube", "YouTube", "ユーチューブ"),
                term("twitch", "Twitch", "ツイッチ"),
                term("discord", "Discord", "ディスコード"),
                term("vtuber", "VTuber", "ブイチューバー"),
                term("esports", "eスポーツ", "イースポーツ"),
                term("steam", "Steam", "スチーム"),
                term("switch", "Nintendo Switch", "ニンテンドースイッチ"),
                term("playstation-5", "PlayStation 5", "プレイステーションファイブ"),
                term("xbox", "Xbox", "エックスボックス"),
                term("twitter", "Twitter", "ツイッター"),
                term("apex-legends", "Apex Legends", "エーペックスレジェンズ"),
                term("valorant", "VALORANT", "ヴァロラント"),
                term("minecraft", "Minecraft", "マインクラフト"),
                term("fortnite", "Fortnite", "フォートナイト"),
                term("street-fighter-6", "Street Fighter 6", "ストリートファイターシックス"),
                term("vcr-gta", "VCR GTA", "ブイシーアールジーティーエー"),
            ]
        ),
        JapaneseContextProfile(
            id: vspoID,
            name: "VSPO",
            terms: [
                term("vspo", "ぶいすぽっ！", "ぶいすぽ"),
                term("kaga-sumire", "花芽すみれ", "かが すみれ"),
                term("kaga-nazuna", "花芽なずな", "かが なずな"),
                term("kogara-toto", "小雀とと", "こがら とと"),
                term("ichinose-uruha", "一ノ瀬うるは", "いちのせ うるは"),
                term("kurumi-noah", "胡桃のあ", "くるみ のあ"),
                term("tosaki-mimi", "兎咲ミミ", "とさき みみ"),
                term("asumi-sena", "空澄セナ", "あすみ せな"),
                term("tachibana-hinano", "橘ひなの", "たちばな ひなの"),
                term("hanabusa-lisa", "英リサ", "はなぶさ りさ"),
                term("kisaragi-ren", "如月れん", "きさらぎ れん"),
                term("kaminari-qpi", "神成きゅぴ", "かみなり きゅぴ"),
                term("yakumo-beni", "八雲べに", "やくも べに"),
                term("aizawa-ema", "藍沢エマ", "あいざわ えま"),
                term("shinomiya-runa", "紫宮るな", "しのみや るな"),
                term("nekota-tsuna", "猫汰つな", "ねこた つな"),
                term("shiranami-ramune", "白波らむね", "しらなみ らむね"),
                term("komori-met", "小森めと", "こもり めと"),
                term("yumeno-akari", "夢野あかり", "ゆめの あかり"),
                term("yano-kuromu", "夜乃くろむ", "やの くろむ"),
                term("tsumugi-kokage", "紡木こかげ", "つむぎ こかげ"),
                term("sendo-yuuhi", "千燈ゆうひ", "せんどう ゆうひ"),
                term("choya-hanabi", "蝶屋はなび", "ちょうや はなび"),
                term(
                    "amayui-moka",
                    "甘結もか",
                    "あまゆい もか",
                    aliases: ["甘いモカ", "甘井もか"]
                ),
                term("ginjo-saine", "銀城サイネ", "ぎんじょう さいね"),
                term("tatsumaki-chise", "龍巻ちせ", "たつまき ちせ"),
                term("aotsuki-remia", "青月レミア", "あおつき れみあ"),
                term("kuroha-arya", "黒刃アリヤ", "くろは ありや"),
                term("jisaki-jira", "地崎ジラ", "じさき じら"),
                term("mikure-narin", "美暮ナリン", "みくれ なりん"),
                term("solari-riko", "ソラリリコ", "そらり りこ"),
                term("suzukami-eris", "涼上エリス", "すずかみ えりす"),
                term("umezono-juno", "梅園ジュノ", "うめぞの じゅの"),
            ]
        ),
    ])

    private static func term(
        _ id: String,
        _ canonical: String,
        _ reading: String,
        aliases: [String] = []
    ) -> JapaneseContextTerm {
        JapaneseContextTerm(
            id: id,
            canonical: canonical,
            reading: reading,
            aliases: aliases
        )
    }
}

/// Immutable session snapshot shared by Apple Speech, translation,
/// benchmark provenance and crash recovery.
struct JapaneseGlossary: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let recognized: String
        let canonical: String
    }

    private let entries: [Entry]
    private let terms: [JapaneseContextTerm]

    // Legacy keys retained only for one-time migration and older backups.
    static let enabledKey = "japaneseGlossaryEnabled"
    static let rulesKey = "japaneseGlossaryRules"
    static let empty = Self(entries: [])

    private enum CodingKeys: String, CodingKey {
        case entries
        case terms
    }

    var isEmpty: Bool { entries.isEmpty && terms.isEmpty }
    var contextualTermCount: Int { terms.count }

    var appleContextualStrings: [String] {
        Array(terms.lazy.map(\.canonical).prefix(100))
    }

    /// Stable provenance for reports and recovery without exposing user terms.
    var fingerprint: String? {
        guard !isEmpty else { return nil }
        let canonical = entries.map { "\($0.recognized)=\($0.canonical)" }
            .joined(separator: "\n")
        let context = terms.map { "\($0.canonical)|\($0.reading)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data((canonical + "\n--context--\n" + context).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(entries: [Entry]) {
        self.entries = Self.validated(entries)
        terms = []
    }

    fileprivate init(terms: [JapaneseContextTerm]) {
        var canonicalTerms = Set<String>()
        self.terms = terms.map(\.normalized).filter {
            !$0.canonical.isEmpty && canonicalTerms.insert($0.canonical).inserted
        }
        self.entries = Self.validated(self.terms.flatMap { term in
            term.aliases.map { Entry(recognized: $0, canonical: term.canonical) }
        })
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = Self.validated(
            try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        )
        terms = (try container.decodeIfPresent(
            [JapaneseContextTerm].self,
            forKey: .terms
        ) ?? []).map(\.normalized).filter { !$0.canonical.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        if !terms.isEmpty {
            try container.encode(terms, forKey: .terms)
        }
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
        let library = JapaneseContextLibrary.stored(in: defaults)
        let selection = defaults.string(forKey: JapaneseContextLibrary.selectionKey)
            ?? JapaneseContextLibrary.generalID
        return library.activeGlossary(selection: selection)
    }

    func applying(to rawText: String) -> String {
        guard !entries.isEmpty else { return rawText }

        let source = normalizedJapaneseTransportText(rawText)
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

    private static func validated(_ entries: [Entry]) -> [Entry] {
        var recognizedTerms = Set<String>()
        return entries
            .map {
                Entry(
                    recognized: normalizedJapaneseContextText($0.recognized),
                    canonical: normalizedJapaneseContextText($0.canonical)
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
}

private func normalizedJapaneseContextText(_ text: String) -> String {
    normalizedJapaneseTransportText(text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedJapaneseTransportText(_ text: String) -> String {
    text.components(separatedBy: .controlCharacters)
        .joined()
        .precomposedStringWithCanonicalMapping
}
