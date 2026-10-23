import Foundation

/// 入力文から抜き出した場所フレーズと用事。
struct ParsedUtterance: Equatable, Sendable {
    var rawText: String
    /// 検索に使う場所の言い回し（空なら地図指定へ）
    var placePhrase: String
    var taskPhrase: String
    /// 「帰ったら」「自宅で」など → 登録時に自宅候補を優先する
    var suggestsHome: Bool

    init(
        rawText: String,
        placePhrase: String,
        taskPhrase: String,
        suggestsHome: Bool = false
    ) {
        self.rawText = rawText
        self.placePhrase = placePhrase
        self.taskPhrase = taskPhrase
        self.suggestsHome = suggestsHome
    }

    var hasPlacePhrase: Bool {
        !placePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
