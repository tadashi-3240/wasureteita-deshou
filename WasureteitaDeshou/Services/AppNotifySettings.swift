import Foundation
import Combine

/// 通知距離の全体デフォルト（新規予定に適用）。予定ごとの上書きも Reminder に持つ。
/// 接近時の音声読み上げ ON/OFF・声の種類もここ（既定は ON／明るい若い声）。
@MainActor
final class AppNotifySettings: ObservableObject {
    private enum Keys {
        static let defaultDistance = "settings.defaultNotifyDistanceMeters"
        static let speechEnabled = "settings.approachSpeechEnabled"
        static let speechVoiceStyle = "settings.approachSpeechVoiceStyle"
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

    /// 声の種類（未設定＝明るい若い声）。
    nonisolated static var speechVoiceStyleStored: SpeechVoiceStyle {
        guard let raw = UserDefaults.standard.string(forKey: Keys.speechVoiceStyle),
              let style = SpeechVoiceStyle(rawValue: raw) else {
            return .brightYoung
        }
        return style
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

    /// 接近通知時に用事文を読み上げる（既定 ON）。BG／ロックでは保証しない。
    @Published var speechEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speechEnabled, forKey: Keys.speechEnabled)
        }
    }

    /// 読み上げの声の種類（UserDefaults 永続化）。
    @Published var speechVoiceStyle: SpeechVoiceStyle {
        didSet {
            UserDefaults.standard.set(speechVoiceStyle.rawValue, forKey: Keys.speechVoiceStyle)
        }
    }

    init() {
        let stored = UserDefaults.standard.integer(forKey: Keys.defaultDistance)
        defaultNotifyDistanceMeters = stored == 0 ? 1000 : Self.clamp(stored)
        speechEnabled = Self.isSpeechEnabledStored
        speechVoiceStyle = Self.speechVoiceStyleStored
    }

    nonisolated static func clamp(_ meters: Int) -> Int {
        if allowedDistances.contains(meters) { return meters }
        return 1000
    }
}
