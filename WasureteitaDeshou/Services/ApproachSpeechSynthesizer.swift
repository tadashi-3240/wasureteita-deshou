import AVFoundation
import UIKit

/// 接近時の用事文を `AVSpeechSynthesizer` で読み上げる。
///
/// iOS 制約（正直に）:
/// - **フォアグラウンド**: アプリ前面なら日本語 TTS は動作する（設定 ON 時）。
/// - **バックグラウンド／ロック画面**: 領域監視で短く起きても、システムが音声出力を抑えることが多く、
///   自由文の読み上げは **保証できない**。無理押しの `UIBackgroundModes=audio` 迂回はしない。
/// - BG／ロックでは **通知音＋文字** が基本。読み上げは前面での補助。
/// - 使える声は iOS／端末依存（ダウンロード済み音声のみ）。クラウド TTS は使わない。
@MainActor
final class ApproachSpeechSynthesizer: NSObject {
    static let shared = ApproachSpeechSynthesizer()

    private let synthesizer = AVSpeechSynthesizer()
    private var didConfigureSession = false

    /// 「忘れていたでしょう？○○予定ですよ！」形式。
    static func approachUtterance(task: String) -> String {
        "忘れていたでしょう？\(task)予定ですよ！"
    }

    /// 端末に入っている日本語（`ja` / `ja-JP`）の声。無いものはここに出ない。
    /// 声カタログの参照のみでインスタンス状態を触らないため `nonisolated`（`SpeechVoiceStyle.availableStyles` など MainActor 外から呼べる）。
    nonisolated static func japaneseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let lang = voice.language.lowercased()
            return lang == "ja" || lang.hasPrefix("ja-") || lang.hasPrefix("ja_")
        }
    }

    /// 接近イベント用。設定が OFF なら何もしない。
    func speakApproachIfEnabled(task: String) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        speak(Self.approachUtterance(task: task))
    }

    /// 通知の title+body から読み上げ（`willPresent` 用）。設定 OFF なら何もしない。
    func speakNotificationIfEnabled(title: String, body: String) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        let text = "\(title)\(body)"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speak(text)
    }

    /// 設定画面のテスト。設定の ON/OFF に関わらず一度読む（動作確認用）。
    func speakTest() {
        speak(Self.approachUtterance(task: "テスト"))
    }

    private func speak(_ text: String) {
        prepareAudioSessionIfNeeded()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let style = AppNotifySettings.speechVoiceStyleStored
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(for: style)
        utterance.rate = style.speechRate
        utterance.pitchMultiplier = style.pitchMultiplier
        synthesizer.speak(utterance)
    }

    /// スタイルに合う日本語声を選ぶ。端末に無い候補はスキップし、最後は `ja-JP` 既定へ。
    static func resolveVoice(for style: SpeechVoiceStyle) -> AVSpeechSynthesisVoice? {
        let available = japaneseVoices()
        let fallback = AVSpeechSynthesisVoice(language: "ja-JP")

        switch style {
        case .brightYoung:
            if let match = firstMatch(in: available, matching: Self.brightYoungPreferMatchers) {
                return match
            }
            if let female = available.first(where: { $0.gender == .female }) {
                return female
            }
            return fallback ?? available.first
        case .standard:
            return fallback ?? available.first
        case .lower:
            if let match = firstMatch(in: available, matching: Self.lowerPreferMatchers) {
                return match
            }
            if let male = available.first(where: { $0.gender == .male }) {
                return male
            }
            return fallback ?? available.first
        }
    }

    /// いま選ばれる声の短い表示名（設定の注記用）。無いときは空。
    static func resolvedVoiceDisplayName(for style: SpeechVoiceStyle) -> String {
        guard let voice = resolveVoice(for: style) else { return "" }
        let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? voice.identifier : name
    }

    // MARK: - Voice matching (若い女性寄り → 無ければ次へ)

    /// 優先順: Siri 女性 → O-ren → Hattori → Kyoko enhanced → Kyoko。端末に無いものはスキップ。
    private static let brightYoungPreferMatchers: [(AVSpeechSynthesisVoice) -> Bool] = [
        { v in
            let id = v.identifier.lowercased()
            let name = v.name.lowercased()
            let hasSiri = id.contains("siri") || name.contains("siri")
            let femaleHint = v.gender == .female
                || id.contains("female")
                || name.contains("female")
            return hasSiri && femaleHint
        },
        { v in
            let blob = "\(v.identifier) \(v.name)".lowercased()
            return blob.contains("o-ren") || blob.contains("oren")
        },
        { v in
            let blob = "\(v.identifier) \(v.name)".lowercased()
            return blob.contains("hattori")
        },
        { v in
            let blob = "\(v.identifier) \(v.name)".lowercased()
            let isKyoko = blob.contains("kyoko")
            let enhanced = blob.contains("enhanced") || blob.contains("premium") || blob.contains("quality")
            return isKyoko && enhanced
        },
        { v in
            let blob = "\(v.identifier) \(v.name)".lowercased()
            return blob.contains("kyoko")
        },
    ]

    private static let lowerPreferMatchers: [(AVSpeechSynthesisVoice) -> Bool] = [
        { v in
            let blob = "\(v.identifier) \(v.name)".lowercased()
            return blob.contains("hattori")
        },
        { v in
            let id = v.identifier.lowercased()
            let name = v.name.lowercased()
            let hasSiri = id.contains("siri") || name.contains("siri")
            let maleHint = v.gender == .male
                || id.contains("male")
                || name.contains("male")
            return hasSiri && maleHint
        },
    ]

    private static func firstMatch(
        in voices: [AVSpeechSynthesisVoice],
        matching matchers: [(AVSpeechSynthesisVoice) -> Bool]
    ) -> AVSpeechSynthesisVoice? {
        for matcher in matchers {
            if let found = voices.first(where: matcher) {
                return found
            }
        }
        return nil
    }

    /// 最小限のセッション設定。BG 保証のためではない。
    private func prepareAudioSessionIfNeeded() {
        guard !didConfigureSession else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // spokenAudio + duckOthers: 前面での読み上げ向け。BG 継続用の audio モードは付けない。
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            didConfigureSession = true
        } catch {
            // セッション失敗でも speak は試す（端末状態次第）
            didConfigureSession = false
        }
    }
}

/// 設定の「声の種類」。端末に無い個別声は内部でスキップし、常にフォールバックする。
enum SpeechVoiceStyle: String, CaseIterable, Identifiable, Sendable {
    case brightYoung
    case standard
    case lower

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brightYoung: return "明るい若い声"
        case .standard: return "標準"
        case .lower: return "低め"
        }
    }

    /// やや上げて元気に（やりすぎない）。
    var pitchMultiplier: Float {
        switch self {
        case .brightYoung: return 1.15
        case .standard: return 1.0
        case .lower: return 0.92
        }
    }

    /// default より少し速め／明るめ（若い声のみ）。
    var speechRate: Float {
        switch self {
        case .brightYoung:
            return min(AVSpeechUtteranceDefaultSpeechRate + 0.04, AVSpeechUtteranceMaximumSpeechRate)
        case .standard, .lower:
            return AVSpeechUtteranceDefaultSpeechRate
        }
    }

    /// ピッカーに出す選択肢。将来、端末依存で外す場合はここを絞る。
    static var availableStyles: [SpeechVoiceStyle] {
        // スタイル自体は常に選べる（声の実体は resolve で端末依存フォールバック）。
        // 日本語声が1つも無い端末では全グレーアウト相当として空にする。
        if ApproachSpeechSynthesizer.japaneseVoices().isEmpty,
           AVSpeechSynthesisVoice(language: "ja-JP") == nil {
            return []
        }
        return Array(allCases)
    }
}
