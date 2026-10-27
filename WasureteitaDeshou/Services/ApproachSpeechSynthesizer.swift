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
    private var lastSpokenStyleRaw: String?
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
        scheduleSpeak(Self.approachUtterance(task: task), after: delay, bypassCoalesce: false)
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
        scheduleSpeak(text, after: delay, bypassCoalesce: false)
    }

    /// 設定画面のテスト。設定の ON/OFF に関わらず一度読む（動作確認用）。遅延なし。
    /// プリセット切替直後でも必ず新スタイルで鳴るよう coalesce を bypass。
    func speakTest() {
        scheduleSpeak(Self.approachUtterance(task: "テスト"), after: 0, bypassCoalesce: true)
    }

    private func scheduleSpeak(_ text: String, after delay: TimeInterval, bypassCoalesce: Bool) {
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
            speakNow(text, bypassCoalesce: bypassCoalesce)
        }
    }

    private func speakNow(_ text: String, bypassCoalesce: Bool) {
        let style = AppNotifySettings.speechVoiceStyleStored
        let now = Date()
        if !bypassCoalesce,
           let last = lastSpokenText,
           last == text,
           lastSpokenStyleRaw == style.rawValue,
           let at = lastSpokenAt,
           now.timeIntervalSince(at) < coalesceInterval {
            endSpeakBackgroundTaskIfIdle()
            return
        }
        lastSpokenText = text
        lastSpokenStyleRaw = style.rawValue
        lastSpokenAt = now

        prepareAudioSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(for: style)
        utterance.rate = style.speechRate
        utterance.pitchMultiplier = style.pitchMultiplier
        synthesizer.speak(utterance)
        // 発話終了／キャンセルで BG タスクを閉じる（delegate）。
    }

    /// スタイルに合う日本語声を選ぶ。端末に無い候補はスキップし、最後は `ja-JP` 既定へ。
    /// 3スタイルは可能な限り **別の声**（またははっきり違う pitch）になるよう選ぶ。
    static func resolveVoice(for style: SpeechVoiceStyle) -> AVSpeechSynthesisVoice? {
        let available = japaneseVoices()
        let fallback = AVSpeechSynthesisVoice(language: "ja-JP")

        switch style {
        case .brightYoung:
            // Premium／Enhanced／Siri 系の自然な若い女性。O-ren を Kyoko より優先。
            if let match = bestNaturalJapaneseFemale(in: available) {
                return match
            }
            return fallback ?? available.first
        case .standard:
            // クラシック Kyoko（compact 優先）。brightYoung と同じ Enhanced／Premium に寄せない。
            if let kyoko = classicKyoko(in: available) {
                return kyoko
            }
            // Kyoko が無いとき: brightYoung と違う女性／既定へ。
            let brightId = bestNaturalJapaneseFemale(in: available)?.identifier
            if let otherFemale = available.first(where: {
                isFemaleHint($0) && $0.identifier != brightId
            }) {
                return otherFemale
            }
            return fallback ?? available.first
        case .lower:
            if let match = firstMatch(in: available, matching: Self.lowerPreferMatchers) {
                return match
            }
            if let male = available.first(where: { $0.gender == .male }) {
                return male
            }
            // 男性声が無い端末でも pitch 差で区別できるよう、brightYoung と違う声を優先。
            let brightId = bestNaturalJapaneseFemale(in: available)?.identifier
            if let other = available.first(where: { $0.identifier != brightId }) {
                return other
            }
            return fallback ?? available.first
        }
    }

    /// いま選ばれる声の短い表示名（設定の注記用）。無いときは空。品質ヒント付き。
    static func resolvedVoiceDisplayName(for style: SpeechVoiceStyle) -> String {
        guard let voice = resolveVoice(for: style) else { return "" }
        let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? voice.identifier : name
        let qualityHint: String
        switch voice.quality {
        case .premium: qualityHint = "Premium"
        case .enhanced: qualityHint = "Enhanced"
        default: qualityHint = ""
        }
        let pitchNote = String(format: "pitch %.2f", style.pitchMultiplier)
        if qualityHint.isEmpty { return "\(base) · \(pitchNote)" }
        return "\(base)（\(qualityHint)）· \(pitchNote)"
    }

    /// 2スタイルが同じ声 ID に潰れているか（設定の警告用）。
    static func stylesCollapseToSameVoice(_ a: SpeechVoiceStyle, _ b: SpeechVoiceStyle) -> Bool {
        guard let va = resolveVoice(for: a), let vb = resolveVoice(for: b) else { return false }
        return va.identifier == vb.identifier
    }

    // MARK: - Voice matching（自然な日本語女性: Premium/Enhanced/Siri 優先）

    /// 自然な日本語の女性声をスコアで選ぶ。
    /// 優先: Premium → Enhanced → Siri 女性 → 名前付き女性（O-ren / Kyoko）→ その他女性。
    /// 端末に無い候補は自動スキップ。
    private static func bestNaturalJapaneseFemale(
        in voices: [AVSpeechSynthesisVoice],
        requireEnhancedOrBetter: Bool = false
    ) -> AVSpeechSynthesisVoice? {
        let scored = voices.compactMap { voice -> (AVSpeechSynthesisVoice, Int)? in
            let score = naturalFemaleScore(voice)
            guard score >= 0 else { return nil }
            if requireEnhancedOrBetter {
                switch voice.quality {
                case .premium, .enhanced: break
                default: return nil
                }
            }
            return (voice, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    /// 標準用: Kyoko の compact／default を優先（Enhanced／Premium の Kyoko は避ける）。
    private static func classicKyoko(in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let kyokos = voices.filter { voice in
            let blob = "\(voice.identifier) \(voice.name)".lowercased()
            return blob.contains("kyoko")
        }
        guard !kyokos.isEmpty else { return nil }
        let compact = kyokos.filter { voice in
            switch voice.quality {
            case .premium, .enhanced: return false
            default: return true
            }
        }
        return compact.first ?? kyokos.first
    }

    /// 高いほど自然な若い日本語女性に近い。非女性は負。
    private static func naturalFemaleScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        guard isFemaleHint(voice) else { return -1 }
        let blob = "\(voice.identifier) \(voice.name)".lowercased()
        var score = 10

        switch voice.quality {
        case .premium: score += 80
        case .enhanced: score += 60
        default:
            if blob.contains("premium") { score += 75 }
            else if blob.contains("enhanced") || blob.contains("neural") || blob.contains("quality") {
                score += 55
            }
        }

        let hasSiri = blob.contains("siri")
        if hasSiri { score += 50 }

        if blob.contains("o-ren") || blob.contains("oren") { score += 25 }
        if blob.contains("kyoko") { score += 15 }
        // Hattori は男性寄りのため若い女性枠では加点しない（誤マッチ防止で減点）
        if blob.contains("hattori") { score -= 40 }

        return score
    }

    private static func isFemaleHint(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.gender == .female { return true }
        let blob = "\(voice.identifier) \(voice.name)".lowercased()
        if blob.contains("female") { return true }
        // 日本語の代表的な女性声名（gender 未設定の古いエントリ向け）
        if blob.contains("kyoko") || blob.contains("o-ren") || blob.contains("oren") { return true }
        return false
    }

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
        case .brightYoung: return "自然な若い女性声"
        case .standard: return "標準（Kyoko）"
        case .lower: return "低め（Hattori）"
        }
    }

    /// プリセット差が耳で分かるよう、差をはっきり開ける（同じ声に潰れた端末向けの保険にもなる）。
    var pitchMultiplier: Float {
        switch self {
        case .brightYoung: return 1.14
        case .standard: return 1.0
        case .lower: return 0.82
        }
    }

    /// 若い女性声は少し速め、低めは少しゆっくり。
    var speechRate: Float {
        switch self {
        case .brightYoung:
            return min(AVSpeechUtteranceDefaultSpeechRate + 0.025, AVSpeechUtteranceMaximumSpeechRate)
        case .standard:
            return AVSpeechUtteranceDefaultSpeechRate
        case .lower:
            return max(AVSpeechUtteranceDefaultSpeechRate - 0.025, AVSpeechUtteranceMinimumSpeechRate)
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
