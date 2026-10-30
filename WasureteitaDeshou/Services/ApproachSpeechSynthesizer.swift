import AVFoundation
import UIKit

/// 接近時の用事文を読み上げる。
///
/// - 設定に「忘れていたでしょう」の録音があればそれを再生し、用事部分は TTS。
/// - 録音が無ければ全文を `AVSpeechSynthesizer` で読む。
///
/// iOS 制約（正直に）:
/// - **フォアグラウンド**: アプリ前面なら日本語 TTS／録音再生は動作する（設定 ON 時）。
/// - **バックグラウンド（画面オフ／ホーム退避）**: 領域進入で短く起きているあいだに
///   通知投稿→遅延→録音／`AVSpeech` を開始する。`UIBackgroundModes=audio` は **接近読み上げのためだけ**
///   （常時再生アプリではない）。進入直後の短い発話は通ることが多いが、OS の節電・Focus・消音等で
///   無音になることがあり **100% 保証はしない**。
/// - **ロック画面**: 進入検知で起きて発話を開始できた場合はスピーカーから聞こえることがある。
///   ロックのまま発話が始まらない／途中で切れる端末・状態もある。その場合は **通知音＋文字** が基本で、
///   通知タップで前面復帰後に確実に読む。
/// - 使える声は iOS／端末依存（ダウンロード済み音声のみ）。クラウド TTS は使わない。
@MainActor
final class ApproachSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = ApproachSpeechSynthesizer()

    /// 通知音（ピロリローン）が鳴り止んでから約1.75秒空けて読む（旧 3.5s の半分）。
    /// `piroriron.caf` 実長は afinfo で 0.69s（30429 frames @ 44100 Hz）→ 0.69 + 1.75 = 2.44。
    /// 前面・BG とも同じ遅延（BG は `beginBackgroundTask` で枠を延ばす）。speech-11 の値を維持。
    nonisolated static let notificationSoundClearance: TimeInterval = 2.44

    /// 固定フレーズ（録音対象）。
    nonisolated static let phraseIntro = "忘れていたでしょう？"

    private let synthesizer = AVSpeechSynthesizer()
    private var phrasePlayer: AVAudioPlayer?
    private var pendingAfterPhraseTTS: String?
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
        "\(phraseIntro)\(taskSuffix(task: task))"
    }

    /// 用事部分のみ（録音のあとに TTS）。
    static func taskSuffix(task: String) -> String {
        "\(task)予定ですよ！"
    }

    /// 設定／接近の再生を止める（録音開始・プレビューと干渉しないように）。
    func stopAllAudio() {
        pendingSpeakTask?.cancel()
        pendingSpeakTask = nil
        pendingAfterPhraseTTS = nil
        phrasePlayer?.stop()
        phrasePlayer = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        endSpeakBackgroundTask()
    }

    /// 端末に入っている日本語（`ja` / `ja-JP`）の声。無いものはここに出ない。
    /// 声カタログの参照のみでインスタンス状態を触らないため `nonisolated`（`SpeechVoiceStyle.availableStyles` など MainActor 外から呼べる）。
    nonisolated static func japaneseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let lang = voice.language.lowercased()
            return lang == "ja" || lang.hasPrefix("ja-") || lang.hasPrefix("ja_")
        }
    }

    /// デバッグ用: 端末の ja 声を identifier / name / quality / gender で列挙。
    nonisolated static func japaneseVoiceCatalogDebugLines() -> [String] {
        japaneseVoices()
            .sorted { $0.identifier < $1.identifier }
            .map { voice in
                let q: String
                switch voice.quality {
                case .premium: q = "premium"
                case .enhanced: q = "enhanced"
                default: q = "default"
                }
                let g: String
                switch voice.gender {
                case .female: g = "female"
                case .male: g = "male"
                default: g = "unspecified"
                }
                return "\(voice.identifier) | \(voice.name) | \(q) | \(g)"
            }
    }

    /// 接近イベント用。設定が OFF なら何もしない。
    /// - Parameter delay: 通知音との衝突回避用。通知直後は `notificationSoundClearance` を渡す（前面／BG 共通）。
    func speakApproachIfEnabled(task: String, delay: TimeInterval = 0) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        scheduleApproach(
            coalesceKey: Self.approachUtterance(task: task),
            taskSuffix: Self.taskSuffix(task: task),
            after: delay,
            bypassCoalesce: false,
            voiceStylePrefix: nil
        )
    }

    /// 通知の title+body から読み上げ（`willPresent` / 通知タップ用）。設定 OFF なら何もしない。
    /// 接近通知は title＝フレーズ・body＝用事。録音があればフレーズは録音、用事は TTS。
    func speakNotificationIfEnabled(
        title: String,
        body: String,
        delay: TimeInterval = ApproachSpeechSynthesizer.notificationSoundClearance
    ) {
        guard AppNotifySettings.isSpeechEnabledStored else { return }
        let text = "\(title)\(body)"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isApproachPhraseTitle = title.hasPrefix("忘れていたでしょう")
        if isApproachPhraseTitle, !trimmedBody.isEmpty {
            scheduleApproach(
                coalesceKey: text,
                taskSuffix: trimmedBody,
                after: delay,
                bypassCoalesce: false,
                voiceStylePrefix: nil
            )
        } else {
            scheduleSpeak(text, after: delay, bypassCoalesce: false)
        }
    }

    /// 設定画面のテスト。設定の ON/OFF に関わらず一度読む（動作確認用）。遅延なし。
    /// 毎回 **新規 utterance**・coalesce **完全 bypass**。録音があればそれを再生してから用事を TTS。
    /// 端末に別声が足りないときは（録音無しのとき）冒頭でプリセット名を読む。
    func speakTest() {
        pendingSpeakTask?.cancel()
        phrasePlayer?.stop()
        phrasePlayer = nil
        pendingAfterPhraseTTS = nil
        // coalesce を完全に無効化（前回と同文でも必ず再生）。
        lastSpokenText = nil
        lastSpokenStyleRaw = nil
        lastSpokenAt = nil

        let style = AppNotifySettings.speechVoiceStyleStored
        let suffix = Self.taskSuffix(task: "テスト")
        var voicePrefix: String?
        if !PhraseRecordingStore.hasRecordingOnDisk, Self.distinctJapaneseVoiceCount() < 3 {
            // 差を耳で明示（同じ voice identifier に寄る端末向け）。録音時は冒頭が自分の声なので付けない。
            voicePrefix = "\(style.displayName)。"
        }
        scheduleApproach(
            coalesceKey: (voicePrefix ?? "") + Self.approachUtterance(task: "テスト"),
            taskSuffix: suffix,
            after: 0,
            bypassCoalesce: true,
            voiceStylePrefix: voicePrefix
        )
    }

    /// 録音があれば再生→用事 TTS。無ければ全文 TTS（prefix があれば先頭に付与）。
    private func scheduleApproach(
        coalesceKey: String,
        taskSuffix: String,
        after delay: TimeInterval,
        bypassCoalesce: Bool,
        voiceStylePrefix: String?
    ) {
        pendingSpeakTask?.cancel()
        phrasePlayer?.stop()
        phrasePlayer = nil
        pendingAfterPhraseTTS = nil
        beginSpeakBackgroundTask()
        pendingSpeakTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                endSpeakBackgroundTaskIfIdle()
                return
            }
            if !markCoalesce(coalesceKey, bypass: bypassCoalesce) {
                endSpeakBackgroundTaskIfIdle()
                return
            }
            PhraseRecordingStore.shared.stopPreview()
            if PhraseRecordingStore.hasRecordingOnDisk {
                playPhraseThenSpeak(taskSuffix: taskSuffix)
            } else {
                let full = (voiceStylePrefix ?? "") + Self.phraseIntro + taskSuffix
                speakTTSNow(full)
            }
        }
    }

    private func scheduleSpeak(_ text: String, after delay: TimeInterval, bypassCoalesce: Bool) {
        pendingSpeakTask?.cancel()
        phrasePlayer?.stop()
        phrasePlayer = nil
        pendingAfterPhraseTTS = nil
        beginSpeakBackgroundTask()
        pendingSpeakTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                endSpeakBackgroundTaskIfIdle()
                return
            }
            if !markCoalesce(text, bypass: bypassCoalesce) {
                endSpeakBackgroundTaskIfIdle()
                return
            }
            speakTTSNow(text)
        }
    }

    /// - Returns: false なら coalesce でスキップ。
    private func markCoalesce(_ text: String, bypass: Bool) -> Bool {
        let style = AppNotifySettings.speechVoiceStyleStored
        let now = Date()
        if !bypass,
           let last = lastSpokenText,
           last == text,
           lastSpokenStyleRaw == style.rawValue,
           let at = lastSpokenAt,
           now.timeIntervalSince(at) < coalesceInterval {
            return false
        }
        lastSpokenText = text
        lastSpokenStyleRaw = style.rawValue
        lastSpokenAt = now
        return true
    }

    private func playPhraseThenSpeak(taskSuffix: String) {
        let url = PhraseRecordingStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            speakTTSNow(Self.phraseIntro + taskSuffix)
            return
        }
        prepareAudioSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            pendingAfterPhraseTTS = taskSuffix
            phrasePlayer = player
            guard player.play() else {
                pendingAfterPhraseTTS = nil
                phrasePlayer = nil
                speakTTSNow(Self.phraseIntro + taskSuffix)
                return
            }
        } catch {
            pendingAfterPhraseTTS = nil
            speakTTSNow(Self.phraseIntro + taskSuffix)
        }
    }

    private func speakTTSNow(_ text: String) {
        prepareAudioSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let style = AppNotifySettings.speechVoiceStyleStored
        // 毎回新規 utterance（再利用しない）。
        let utterance = AVSpeechUtterance(string: text)
        let assignment = Self.voiceAssignment(for: style)
        utterance.voice = assignment.voice
        utterance.rate = style.speechRate(collapsed: assignment.presetsCollapsed)
        utterance.pitchMultiplier = style.pitchMultiplier(collapsed: assignment.presetsCollapsed)
        synthesizer.speak(utterance)
        // 発話終了／キャンセルで BG タスクを閉じる（delegate）。
    }

    // MARK: - Distinct voice assignment（プリセットごとに別 identifier）

    struct VoiceAssignment {
        let voice: AVSpeechSynthesisVoice?
        /// 端末の ja 声が足りず、3プリセットが 3 未満の identifier に寄っている。
        let presetsCollapsed: Bool
    }

    /// 3プリセット分の声を **可能な限り異なる identifier** で確定する。
    /// 同じ `bestNatural` への収束はしない。足りないときだけ同じ声＋極端な pitch/rate。
    nonisolated static func resolveAllPresetVoices() -> [SpeechVoiceStyle: AVSpeechSynthesisVoice] {
        let available = japaneseVoices()
        let fallback = AVSpeechSynthesisVoice(language: "ja-JP")
        guard !available.isEmpty else {
            var map: [SpeechVoiceStyle: AVSpeechSynthesisVoice] = [:]
            if let fallback {
                for style in SpeechVoiceStyle.allCases { map[style] = fallback }
            }
            return map
        }

        var used = Set<String>()
        var map: [SpeechVoiceStyle: AVSpeechSynthesisVoice] = [:]

        let bright = pickExclusive(
            in: available,
            excluding: &used,
            ranked: Self.brightYoungRanked(available)
        ) ?? available[0]
        used.insert(bright.identifier)
        map[.brightYoung] = bright

        let standard = pickExclusive(
            in: available,
            excluding: &used,
            ranked: Self.standardRanked(available)
        ) ?? available.first { !used.contains($0.identifier) } ?? bright
        used.insert(standard.identifier)
        map[.standard] = standard

        let lower = pickExclusive(
            in: available,
            excluding: &used,
            ranked: Self.lowerRanked(available)
        ) ?? available.first { !used.contains($0.identifier) } ?? standard
        map[.lower] = lower

        return map
    }

    nonisolated static func voiceAssignment(for style: SpeechVoiceStyle) -> VoiceAssignment {
        let map = resolveAllPresetVoices()
        let ids = Set(map.values.map(\.identifier))
        return VoiceAssignment(voice: map[style], presetsCollapsed: ids.count < 3)
    }

    /// スタイルに合う日本語声（`resolveAllPresetVoices` 経由で排他割当）。
    static func resolveVoice(for style: SpeechVoiceStyle) -> AVSpeechSynthesisVoice? {
        voiceAssignment(for: style).voice
    }

    nonisolated static func distinctJapaneseVoiceCount() -> Int {
        Set(japaneseVoices().map(\.identifier)).count
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
        let collapsed = voiceAssignment(for: style).presetsCollapsed
        let pitchNote = String(format: "pitch %.2f", style.pitchMultiplier(collapsed: collapsed))
        if qualityHint.isEmpty { return "\(base) · \(pitchNote)" }
        return "\(base)（\(qualityHint)）· \(pitchNote)"
    }

    /// 設定デバッグ用: identifier と name をそのまま出す。
    static func resolvedVoiceDebugLabel(for style: SpeechVoiceStyle) -> String {
        guard let voice = resolveVoice(for: style) else { return "(none)" }
        let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let namePart = name.isEmpty ? "—" : name
        return "\(voice.identifier)\nname: \(namePart)"
    }

    /// 2スタイルが同じ声 ID に潰れているか（設定の警告用）。
    static func stylesCollapseToSameVoice(_ a: SpeechVoiceStyle, _ b: SpeechVoiceStyle) -> Bool {
        guard let va = resolveVoice(for: a), let vb = resolveVoice(for: b) else { return false }
        return va.identifier == vb.identifier
    }

    /// 3プリセットがすべて別 identifier か。
    static func allPresetsHaveDistinctVoices() -> Bool {
        let map = resolveAllPresetVoices()
        let ids = Set(map.values.map(\.identifier))
        return ids.count >= 3
    }

    // MARK: - Ranked candidates（排他割当の優先順位）

    /// 若い女性: Premium → Enhanced → Siri 女性 → O-ren → Kyoko → その他女性寄り。
    nonisolated private static func brightYoungRanked(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.sorted { naturalFemaleScore($0) > naturalFemaleScore($1) }
            .filter { naturalFemaleScore($0) >= 0 }
    }

    /// 標準: クラシック Kyoko（compact）を優先。無ければ Eloquence の女性寄り名、その他。
    nonisolated private static func standardRanked(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        var ranked: [AVSpeechSynthesisVoice] = []
        if let kyoko = classicKyoko(in: voices) {
            ranked.append(kyoko)
        }
        let eloquenceFemaleHints = ["sandy", "shelley", "flo", "grandma"]
        for hint in eloquenceFemaleHints {
            if let v = voices.first(where: {
                "\($0.identifier) \($0.name)".lowercased().contains(hint)
            }) {
                ranked.append(v)
            }
        }
        ranked.append(contentsOf: voices.filter { isFemaleHint($0) })
        ranked.append(contentsOf: voices)
        return ranked
    }

    /// 低め: Hattori → 男性 → Eloquence 男性寄り → 残り。
    nonisolated private static func lowerRanked(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        var ranked: [AVSpeechSynthesisVoice] = []
        for matcher in lowerPreferMatchers {
            if let v = voices.first(where: matcher) {
                ranked.append(v)
            }
        }
        ranked.append(contentsOf: voices.filter { $0.gender == .male })
        let eloquenceMaleHints = ["hattori", "grandpa", "rocko", "reed", "eddy"]
        for hint in eloquenceMaleHints {
            if let v = voices.first(where: {
                "\($0.identifier) \($0.name)".lowercased().contains(hint)
            }) {
                ranked.append(v)
            }
        }
        ranked.append(contentsOf: voices)
        return ranked
    }

    nonisolated private static func pickExclusive(
        in voices: [AVSpeechSynthesisVoice],
        excluding used: inout Set<String>,
        ranked: [AVSpeechSynthesisVoice]
    ) -> AVSpeechSynthesisVoice? {
        for candidate in ranked {
            if !used.contains(candidate.identifier) {
                return candidate
            }
        }
        return voices.first { !used.contains($0.identifier) }
    }

    /// 自然な日本語の女性声スコア。高いほど若い女性枠向け。非女性寄りは負。
    nonisolated private static func naturalFemaleScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        guard isFemaleHint(voice) else {
            // Eloquence の女性寄り名は gender 未設定でも加点対象外にしないよう下で別扱い
            let blob = "\(voice.identifier) \(voice.name)".lowercased()
            if blob.contains("sandy") || blob.contains("shelley") || blob.contains("flo") {
                return 5
            }
            return -1
        }
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

    /// 標準用: Kyoko の compact／default を優先（Enhanced／Premium の Kyoko は避ける）。
    nonisolated private static func classicKyoko(in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
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

    nonisolated private static func isFemaleHint(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.gender == .female { return true }
        let blob = "\(voice.identifier) \(voice.name)".lowercased()
        if blob.contains("female") { return true }
        // 日本語の代表的な女性声名（gender 未設定の古いエントリ向け）
        if blob.contains("kyoko") || blob.contains("o-ren") || blob.contains("oren") { return true }
        return false
    }

    nonisolated private static let lowerPreferMatchers: [(AVSpeechSynthesisVoice) -> Bool] = [
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
                self?.pendingAfterPhraseTTS = nil
                self?.phrasePlayer?.stop()
                self?.phrasePlayer = nil
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
        guard phrasePlayer == nil || phrasePlayer?.isPlaying != true else { return }
        guard pendingAfterPhraseTTS == nil else { return }
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

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.phrasePlayer === player else { return }
            self.phrasePlayer = nil
            let suffix = self.pendingAfterPhraseTTS
            self.pendingAfterPhraseTTS = nil
            if let suffix, !suffix.isEmpty {
                self.speakTTSNow(suffix)
            } else {
                self.endSpeakBackgroundTaskIfIdle()
            }
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

    /// 通常時の pitch。端末に別声が足りず潰れたときは極端に開く。
    func pitchMultiplier(collapsed: Bool) -> Float {
        if collapsed {
            switch self {
            case .brightYoung: return 1.40
            case .standard: return 1.0
            case .lower: return 0.50
            }
        }
        switch self {
        case .brightYoung: return 1.14
        case .standard: return 1.0
        case .lower: return 0.82
        }
    }

    /// 通常時の rate。潰れたときははっきり差を付ける。
    func speechRate(collapsed: Bool) -> Float {
        let def = AVSpeechUtteranceDefaultSpeechRate
        let maxR = AVSpeechUtteranceMaximumSpeechRate
        let minR = AVSpeechUtteranceMinimumSpeechRate
        if collapsed {
            switch self {
            case .brightYoung: return min(def + 0.12, maxR)
            case .standard: return def
            case .lower: return max(def - 0.15, minR)
            }
        }
        switch self {
        case .brightYoung: return min(def + 0.025, maxR)
        case .standard: return def
        case .lower: return max(def - 0.025, minR)
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
