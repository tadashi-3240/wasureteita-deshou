import AVFoundation
import UIKit

/// 接近時の用事文を `AVSpeechSynthesizer` で読み上げる。
///
/// iOS 制約（正直に）:
/// - **フォアグラウンド**: アプリ前面なら日本語 TTS は動作する（設定 ON 時）。
/// - **バックグラウンド（画面オフ／ホーム退避）**: 領域進入で短く起きているあいだに
///   通知投稿→遅延→`AVSpeech` を開始する。`UIBackgroundModes=audio` は **接近読み上げのためだけ**
///   （常時再生アプリではない）。進入直後の短い発話は通ることが多いが、OS の節電・Focus・消音等で
///   無音になることがあり **100% 保証はしない**。
/// - **ロック画面**: 進入検知で起きて発話を開始できた場合はスピーカーから聞こえることがある。
///   ロックのまま発話が始まらない／途中で切れる端末・状態もある。その場合は **通知音＋文字** が基本で、
///   通知タップで前面復帰後に確実に読む。
/// - 使える声は iOS／端末依存（ダウンロード済み音声のみ）。クラウド TTS は使わない。
@MainActor
final class ApproachSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ApproachSpeechSynthesizer()

    /// 通知音（ピロリローン）が鳴り止んでから約3.5秒空けて読む。
    /// `piroriron.caf` 実長は afinfo で 0.69s（30429 frames @ 44100 Hz）→ 0.69 + 3.5 = 4.19。
    /// 前面・BG とも同じ遅延（BG は `beginBackgroundTask` で枠を延ばす）。
    static let notificationSoundClearance: TimeInterval = 4.19

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSpeakTask: Task<Void, Never>?
    private var lastSpokenText: String?
    private var lastSpokenAt: Date?
    private let coalesceInterval: TimeInterval = 2.0
    private var speakBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        synthesizer.delegate = self
    }

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
    /// - Parameter delay: 通知音との衝突回避用。通知直後は `notificationSoundClearance` を渡す（前面／BG 共通）。
    func speakApproachIfEnabled(task: String, delay: TimeInterval = 0) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        scheduleSpeak(Self.approachUtterance(task: task), after: delay)
    }

    /// 通知の title+body から読み上げ（`willPresent` / 通知タップ用）。設定 OFF なら何もしない。
    func speakNotificationIfEnabled(
        title: String,
        body: String,
        delay: TimeInterval = ApproachSpeechSynthesizer.notificationSoundClearance
    ) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        let text = "\(title)\(body)"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleSpeak(text, after: delay)
    }

    /// 設定画面のテスト。設定の ON/OFF に関わらず一度読む（動作確認用）。遅延なし。
    func speakTest() {
        scheduleSpeak(Self.approachUtterance(task: "テスト"), after: 0)
    }

    private func scheduleSpeak(_ text: String, after delay: TimeInterval) {
        pendingSpeakTask?.cancel()
        // 遅延＋発話中にサスペンドされないよう、進入検知の短い BG 枠を延ばす。
        beginSpeakBackgroundTask()
        pendingSpeakTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                endSpeakBackgroundTaskIfIdle()
                return
            }
            speakNow(text)
        }
    }

    private func speakNow(_ text: String) {
        let now = Date()
        if let last = lastSpokenText,
           last == text,
           let at = lastSpokenAt,
           now.timeIntervalSince(at) < coalesceInterval {
            endSpeakBackgroundTaskIfIdle()
            return
        }
        lastSpokenText = text
        lastSpokenAt = now

        prepareAudioSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let style = AppNotifySettings.speechVoiceStyleStored
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(for: style)
        utterance.rate = style.speechRate
        utterance.pitchMultiplier = style.pitchMultiplier
        synthesizer.speak(utterance)
        // 発話終了／キャンセルで BG タスクを閉じる（delegate）。
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

    /// 毎回 category／active を張り直す。通知音のあとセッションが落ちることがあるため。
    /// `.playback` + `spokenAudio` + `duckOthers`: サイレントスイッチでも鳴らし、他音はダック。
    /// `UIBackgroundModes=audio` と組み合わせ、進入直後の短い発話を BG でも継続できる範囲で有効にする。
    private func prepareAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // セッション失敗でも speak は試す（端末状態次第）
        }
    }

    // MARK: - Background task (接近読み上げの短い延長のみ)

    private func beginSpeakBackgroundTask() {
        endSpeakBackgroundTask()
        speakBackgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "approach.speech") { [weak self] in
            Task { @MainActor in
                self?.pendingSpeakTask?.cancel()
                if let self, self.synthesizer.isSpeaking {
                    self.synthesizer.stopSpeaking(at: .immediate)
                }
                self?.endSpeakBackgroundTask()
            }
        }
    }

    private func endSpeakBackgroundTask() {
        guard speakBackgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(speakBackgroundTaskId)
        speakBackgroundTaskId = .invalid
    }

    private func endSpeakBackgroundTaskIfIdle() {
        guard !synthesizer.isSpeaking else { return }
        endSpeakBackgroundTask()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.endSpeakBackgroundTask()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.endSpeakBackgroundTask()
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
