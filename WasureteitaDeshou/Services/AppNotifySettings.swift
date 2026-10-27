import Foundation
import Combine

/// 通知距離の全体デフォルト（新規予定に適用）。予定ごとの上書きも Reminder に持つ。
/// 接近時の音声読み上げ ON/OFF・声の種類もここ（既定は ON／自然な若い女性声）。
@MainActor
final class AppNotifySettings: ObservableObject {
    private enum Keys {
        static let defaultDistance = "settings.defaultNotifyDistanceMeters"
        static let speechEnabled = "settings.approachSpeechEnabled"
        /// speech-9 以降。旧キーに残った無効 raw は読まず既定へ戻す。
        static let speechVoiceStyle = "settings.approachSpeechVoiceStyle.v9"
        static let speechVoiceStyleLegacy = "settings.approachSpeechVoiceStyle"
    }

    /// 純粋な定数・関数。Sendable モデルからも安全に呼べるよう MainActor から外す。
    nonisolated static let allowedDistances = [300, 500, 1000]

    /// AppDelegate など MainActor 外からも読める既定（キー未設定＝ON）。
    nonisolated static var isSpeechEnabledStored: Bool {
        if UserDefaults.standard.object(forKey: Keys.speechEnabled) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Keys.speechEnabled)
    }

    /// 声の種類（未設定＝自然な若い女性声）。
    /// v9 キー優先。旧キーの有効値は一度だけ引き継ぎ、無効／未知 raw は捨てて既定へ。
    nonisolated static var speechVoiceStyleStored: SpeechVoiceStyle {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Keys.speechVoiceStyle),
           let style = SpeechVoiceStyle(rawValue: raw) {
            return style
        }
        if let legacy = defaults.string(forKey: Keys.speechVoiceStyleLegacy),
           let style = SpeechVoiceStyle(rawValue: legacy) {
            defaults.set(style.rawValue, forKey: Keys.speechVoiceStyle)
            defaults.removeObject(forKey: Keys.speechVoiceStyleLegacy)
            return style
        }
        // 旧キーにゴミが残っていても既定へ（無効 raw を掃除）
        if defaults.object(forKey: Keys.speechVoiceStyleLegacy) != nil {
            defaults.removeObject(forKey: Keys.speechVoiceStyleLegacy)
        }
        return .brightYoung
    }

    @Published var defaultNotifyDistanceMeters: Int {
        didSet {
            let clamped = Self.clamp(defaultNotifyDistanceMeters)
            if clamped != defaultNotifyDistanceMeters {
                defaultNotifyDistanceMeters = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.defaultDistance)
        }
    }

    /// 接近通知時に用事文を読み上げる（既定 ON）。BG は進入直後に試行（100% 保証はしない）。
    @Published var speechEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speechEnabled, forKey: Keys.speechEnabled)
        }
    }

    /// 読み上げの声の種類（UserDefaults 永続化）。
    @Published var speechVoiceStyle: SpeechVoiceStyle {
        didSet {
            UserDefaults.standard.set(speechVoiceStyle.rawValue, forKey: Keys.speechVoiceStyle)
            // 旧キーが残っていると別経路で読まれる心配はないが、混乱防止で掃除。
            UserDefaults.standard.removeObject(forKey: Keys.speechVoiceStyleLegacy)
        }
    }

    init() {
        let stored = UserDefaults.standard.integer(forKey: Keys.defaultDistance)
        defaultNotifyDistanceMeters = stored == 0 ? 1000 : Self.clamp(stored)
        speechEnabled = Self.isSpeechEnabledStored
        speechVoiceStyle = Self.speechVoiceStyleStored
    }

    /// 既定の「自然な若い女性声」へ戻し、即テスト再生できるよう UserDefaults も同期。
    func reselectDefaultSpeechVoice() {
        speechVoiceStyle = .brightYoung
        UserDefaults.standard.set(SpeechVoiceStyle.brightYoung.rawValue, forKey: Keys.speechVoiceStyle)
        UserDefaults.standard.removeObject(forKey: Keys.speechVoiceStyleLegacy)
    }

    nonisolated static func clamp(_ meters: Int) -> Int {
        if allowedDistances.contains(meters) { return meters }
        return 1000
    }
}
