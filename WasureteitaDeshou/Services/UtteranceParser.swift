import Foundation

/// 日本語の短い用事文から場所と用事を分ける。厳密な NLP ではない。
enum UtteranceParser {
    static func parse(_ text: String) -> ParsedUtterance {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let home = parseHomeUtterance(trimmed) {
            return home
        }

        if let split = split(by: "で", in: trimmed), !split.place.isEmpty, !split.task.isEmpty {
            return ParsedUtterance(rawText: trimmed, placePhrase: split.place, taskPhrase: split.task)
        }

        // 「〜に寄って〜」「〜へ行って〜」など
        for connector in ["に寄って", "へ行って", "に行って", "まで行って"] {
            if let split = split(by: connector, in: trimmed), !split.place.isEmpty {
                let task = split.task.isEmpty ? "用事あり" : split.task
                return ParsedUtterance(rawText: trimmed, placePhrase: split.place, taskPhrase: task)
            }
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
            "薬局", "ドラッグストア"
        ]

        for brand in brands {
            guard let range = text.range(of: brand) else { continue }
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let afterBrand = String(text[range.upperBound...])
            let place: String
            if before.isEmpty {
                place = brand
            } else if before.hasSuffix("の") {
                place = before + brand
            } else {
                place = (before + brand).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var task = afterBrand
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["で", "に", "へ", "を"] {
                if task.hasPrefix(prefix) {
                    task = String(task.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if task.isEmpty { task = "用事あり" }
            return ParsedUtterance(rawText: text, placePhrase: place, taskPhrase: task)
        }
        return nil
    }
}
