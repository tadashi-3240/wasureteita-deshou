import Foundation
import Combine

/// 登録タブで入力・確定した文章を端末内に保持する（ログイン不要）。
@MainActor
final class DraftUtteranceStore: ObservableObject {
    private enum Keys {
        static let draftText = "draft.utteranceText"
        static let confirmedText = "draft.confirmedText"
    }

    /// テキスト欄の編集中内容
    @Published var draftText: String {
        didSet {
            UserDefaults.standard.set(draftText, forKey: Keys.draftText)
        }
    }

    /// 「次へ」で確定した文章（解析前の原文）
    @Published private(set) var confirmedText: String {
        didSet {
            UserDefaults.standard.set(confirmedText, forKey: Keys.confirmedText)
        }
    }

    init() {
        draftText = UserDefaults.standard.string(forKey: Keys.draftText) ?? ""
        confirmedText = UserDefaults.standard.string(forKey: Keys.confirmedText) ?? ""
    }

    func confirmDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confirmedText = trimmed
    }

    func clearConfirmed() {
        confirmedText = ""
    }

    func clearAll() {
        draftText = ""
        confirmedText = ""
    }
}
