import Foundation

/// 日本語の短い用事文から場所と用事を分ける。厳密な NLP ではない。
///
/// 例（knownPlaceNames: ["金古のセブン", "高崎のイオン", "会社"]）:
/// - 「金古のセブンで牛乳を買う」→ 場所: 金古のセブン / 用事: 牛乳を買う
/// - 「高崎のイオンに寄って買い物」→ 場所: 高崎のイオン / 用事: 買い物
/// - 「会社に着いたらメール確認」→ 場所: 会社 / 用事: メール確認
/// - 「帰ったら洗濯をする」→ 場所: 自宅 / 用事: 洗濯をする（suggestsHome）
/// - 「セブン 牛乳買う」（呼び名一致）→ 場所: 金古のセブン or セブン / 用事: 牛乳買う
enum UtteranceParser {
    /// - Parameters:
    ///   - text: 入力文
    ///   - knownPlaceNames: `SavedPlace.displayName` など、既知の場所の呼び名（長い名前を優先）
    static func parse(_ text: String, knownPlaceNames: [String] = []) -> ParsedUtterance {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let home = parseHomeUtterance(trimmed) {
            return home
        }

        // SavedPlace の呼び名（文頭・文中、長い名前優先）
        if let known = splitByKnownNames(in: trimmed, names: knownPlaceNames) {
            return known
        }

        // 「〜に寄って〜」「〜に着いたら〜」「〜へ行って〜」など
        for connector in Self.placeTaskConnectors {
            if let split = split(by: connector, in: trimmed), !split.place.isEmpty {
                let task = split.task.isEmpty ? "用事あり" : split.task
                return ParsedUtterance(rawText: trimmed, placePhrase: split.place, taskPhrase: task)
            }
        }

        // 「セブンで〜」など接続詞「で」（タスク側が空でないとき）
        if let split = split(by: "で", in: trimmed), !split.place.isEmpty, !split.task.isEmpty {
            return ParsedUtterance(rawText: trimmed, placePhrase: split.place, taskPhrase: split.task)
        }

        if let brandSplit = splitByKnownBrand(in: trimmed) {
            return brandSplit
        }

        // 場所が取れない → 地図指定用に用事だけ残す
        return ParsedUtterance(
            rawText: trimmed,
            placePhrase: "",
            taskPhrase: trimmed.isEmpty ? "用事あり" : trimmed
        )
    }

    /// 場所と用事のあいだに入る言い回し（長いもの優先で走査）
    private static let placeTaskConnectors = [
        "まで行ってから",
        "に着いたら",
        "へ着いたら",
        "に寄って",
        "へ寄って",
        "に寄ったら",
        "へ寄ったら",
        "まで行って",
        "へ行って",
        "に行って"
    ]

    /// 既知名の直後に続く粒子・接続（長いもの優先）
    private static let trailingConnectors = [
        "に寄って",
        "へ寄って",
        "に着いたら",
        "へ着いたら",
        "まで行ってから",
        "まで行って",
        "へ行って",
        "に行って",
        "に寄ったら",
        "へ寄ったら",
        "で",
        "に",
        "へ",
        "を",
        "、",
        " "
    ]

    /// 「自宅で〜」「家に着いたら〜」「帰ったら〜」など。
    private static func parseHomeUtterance(_ text: String) -> ParsedUtterance? {
        let homePlaceLabels = ["自宅", "うち", "家"]

        // 「自宅で洗濯をする」
        if let split = split(by: "で", in: text),
           homePlaceLabels.contains(where: { split.place == $0 }),
           !split.task.isEmpty {
            return ParsedUtterance(
                rawText: text,
                placePhrase: "自宅",
                taskPhrase: split.task,
                suggestsHome: true
            )
        }

        // 長い接頭辞を先に
        let homePrefixes: [(prefix: String, strip: String)] = [
            ("自宅に着いたら", "自宅に着いたら"),
            ("うちに着いたら", "うちに着いたら"),
            ("家に着いたら", "家に着いたら"),
            ("家へ着いたら", "家へ着いたら"),
            ("家に帰ったら", "家に帰ったら"),
            ("うちに帰ったら", "うちに帰ったら"),
            ("帰ってきたら", "帰ってきたら"),
            ("帰宅したら", "帰宅したら"),
            ("帰ったら", "帰ったら"),
            ("自宅で", "自宅で"),
            ("うちで", "うちで"),
            ("家で", "家で"),
            ("自宅に", "自宅に"),
            ("うちに", "うちに"),
            ("家に", "家に")
        ]

        for item in homePrefixes {
            guard text.hasPrefix(item.prefix) else { continue }
            var task = String(text.dropFirst(item.strip.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for connector in ["で", "に", "へ", "を", "、"] {
                if task.hasPrefix(connector) {
                    task = String(task.dropFirst(connector.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if task.isEmpty { task = "用事あり" }
            return ParsedUtterance(
                rawText: text,
                placePhrase: "自宅",
                taskPhrase: task,
                suggestsHome: true
            )
        }

        // 文中の自宅ラベル（「今日は自宅で洗濯」など）。「家」単独は誤爆しやすいので除外。
        if let midHome = splitByKnownNames(in: text, names: ["自宅", "うち"], forcePlacePhrase: "自宅") {
            return ParsedUtterance(
                rawText: text,
                placePhrase: "自宅",
                taskPhrase: midHome.taskPhrase,
                suggestsHome: true
            )
        }

        // 「洗濯をする（自宅）」のような末尾表記は手動選択に任せ、ここでは拾わない
        if text.contains("自宅") || text.contains("家に着い") || text.contains("帰ったら") {
            // 部分一致だがプレフィックスにならなかった → 用事は全文、場所は自宅候補
            if text.contains("帰ったら") || text.contains("家に着い") || text.contains("帰宅") {
                var task = text
                for phrase in ["帰ったら", "家に着いたら", "うちに着いたら", "帰宅したら", "帰ってきたら"] {
                    if let range = task.range(of: phrase) {
                        task = String(task[range.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                if task.isEmpty { task = "用事あり" }
                return ParsedUtterance(
                    rawText: text,
                    placePhrase: "自宅",
                    taskPhrase: task,
                    suggestsHome: true
                )
            }
        }

        return nil
    }

    private static func split(by separator: String, in text: String) -> (place: String, task: String)? {
        guard let range = text.range(of: separator) else { return nil }
        let place = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let task = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (place, task)
    }

    /// SavedPlace 呼び名や自宅ラベルなど、既知の場所語で place / task を分割。
    /// 文頭一致を優先し、なければ文中の最初の一致。長い名前優先。
    private static func splitByKnownNames(
        in text: String,
        names: [String],
        forcePlacePhrase: String? = nil
    ) -> ParsedUtterance? {
        let sorted = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }

        guard !sorted.isEmpty else { return nil }

        // 1) 文頭一致
        for name in sorted {
            if text.hasPrefix(name) {
                return makeKnownSplit(
                    text: text,
                    name: name,
                    nameRange: text.startIndex..<text.index(text.startIndex, offsetBy: name.count),
                    forcePlacePhrase: forcePlacePhrase
                )
            }
        }

        // 2) 文中一致（最初に現れる最長名）。直後が場所コネクタ／空白か、直前が「〜の」のときだけ採用。
        var best: (name: String, range: Range<String.Index>)?
        for name in sorted {
            guard let range = text.range(of: name) else { continue }
            guard isPlausibleMidPlaceMatch(text: text, nameRange: range) else { continue }
            if let current = best {
                if range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound && name.count > current.name.count) {
                    best = (name, range)
                }
            } else {
                best = (name, range)
            }
        }

        guard let best else { return nil }
        return makeKnownSplit(
            text: text,
            name: best.name,
            nameRange: best.range,
            forcePlacePhrase: forcePlacePhrase
        )
    }

    /// 文中の場所語として妥当か（用事側の名詞に SavedPlace 名が含まれる誤爆を抑える）
    private static func isPlausibleMidPlaceMatch(text: String, nameRange: Range<String.Index>) -> Bool {
        let before = String(text[..<nameRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let afterRaw = String(text[nameRange.upperBound...])
        if before.hasSuffix("の") || before.isEmpty { return true }
        if afterRaw.isEmpty { return true }
        let afterTrimmed = afterRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if afterTrimmed.isEmpty { return true }
        for prefix in Self.trailingConnectors where prefix != "を" {
            if afterRaw.hasPrefix(prefix) || afterTrimmed.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    private static func makeKnownSplit(
        text: String,
        name: String,
        nameRange: Range<String.Index>,
        forcePlacePhrase: String?
    ) -> ParsedUtterance {
        let before = String(text[..<nameRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var after = String(text[nameRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        after = stripLeadingConnectors(after)

        let place: String
        if let forcePlacePhrase {
            place = forcePlacePhrase
        } else if before.isEmpty {
            place = name
        } else if before.hasSuffix("の") {
            // 「金古の」+ 呼び名／ブランド
            place = before + name
        } else {
            place = name
        }

        var task = after
        if task.isEmpty { task = "用事あり" }

        return ParsedUtterance(rawText: text, placePhrase: place, taskPhrase: task)
    }

    private static func stripLeadingConnectors(_ text: String) -> String {
        var task = text
        for prefix in Self.trailingConnectors {
            if task.hasPrefix(prefix) {
                task = String(task.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return task
    }

    /// 「セブンイレブンで…」のように接続詞なしでも店舗名が含まれる場合
    private static func splitByKnownBrand(in text: String) -> ParsedUtterance? {
        let brands = [
            "セブンイレブン", "セブン−イレブン", "セブン-イレブン", "セブン",
            "ファミリーマート", "ファミマ",
            "ローソン",
            "ミニストップ",
            "デイリーヤマザキ",
            "イオン", "マックスバリュ",
            "コストコ",
            "ドラッグストア", "薬局"
        ]
        // 長いブランド名を優先（「セブンイレブン」が「セブン」より先）
        return splitByKnownNames(in: text, names: brands)
    }
}
