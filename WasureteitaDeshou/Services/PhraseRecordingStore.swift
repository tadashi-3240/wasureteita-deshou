import AVFoundation
import Combine

/// 「忘れていたでしょう」フレーズの端末内録音（m4a）。クラウド同期なし。
@MainActor
final class PhraseRecordingStore: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let shared = PhraseRecordingStore()

    nonisolated static let fileName = "approach-intro-phrase.m4a"

    /// 録音ファイルの URL（Documents）。
    nonisolated static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent(Self.fileName)
    }

    nonisolated static var hasRecordingOnDisk: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    @Published private(set) var hasRecording: Bool = false
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPlayingPreview: Bool = false
    @Published private(set) var micAuthorization: AVAudioApplication.recordPermission = .undetermined
    @Published var statusMessage: String?

    private var recorder: AVAudioRecorder?
    private var previewPlayer: AVAudioPlayer?

    override init() {
        super.init()
        refreshHasRecording()
        refreshMicAuthorization()
    }

    func refreshHasRecording() {
        hasRecording = Self.hasRecordingOnDisk
    }

    func refreshMicAuthorization() {
        micAuthorization = AVAudioApplication.shared.recordPermission
    }

    /// マイク許可を求める。既に決定済みならその結果。
    func requestMicrophonePermission() async -> Bool {
        refreshMicAuthorization()
        switch micAuthorization {
        case .granted:
            return true
        case .denied:
            statusMessage = "マイクが拒否されています。iPhone設定→忘れていたでしょう→マイク、でオンにしてください。"
            return false
        case .undetermined:
            break
        @unknown default:
            break
        }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        refreshMicAuthorization()
        if !granted {
            statusMessage = "マイクが拒否されています。iPhone設定→忘れていたでしょう→マイク、でオンにしてください。"
        }
        return granted
    }

    /// 録音開始。既存があれば上書き（差し替え）。
    func startRecording() async {
        stopPreview()
        ApproachSpeechSynthesizer.shared.stopAllAudio()

        guard await requestMicrophonePermission() else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: [])
        } catch {
            statusMessage = "マイクの準備に失敗しました。"
            return
        }

        let url = Self.fileURL
        // 差し替え時は古いファイルを消してから録る。
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = false
            guard rec.prepareToRecord(), rec.record() else {
                statusMessage = "録音を開始できませんでした。"
                return
            }
            recorder = rec
            isRecording = true
            statusMessage = "録音中…「忘れていたでしょう？」と言ってください。止めるボタンで保存します。"
        } catch {
            statusMessage = "録音の開始に失敗しました。"
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording, let recorder else {
            isRecording = false
            return
        }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        refreshHasRecording()
        if hasRecording {
            statusMessage = "録音を保存しました。接近時にこの声で「忘れていたでしょう」を再生します。"
        } else {
            statusMessage = "録音ファイルがありません。"
        }
        // 接近再生用に playback へ戻す（失敗しても次の speak で張り直す）。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func playPreview() {
        guard hasRecording || Self.hasRecordingOnDisk else {
            statusMessage = "録音がありません。"
            return
        }
        stopPreview()
        ApproachSpeechSynthesizer.shared.stopAllAudio()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(contentsOf: Self.fileURL)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                statusMessage = "再生できませんでした。"
                return
            }
            previewPlayer = player
            isPlayingPreview = true
            statusMessage = "録音を再生しています。"
        } catch {
            statusMessage = "再生に失敗しました。"
            isPlayingPreview = false
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
    }

    func deleteRecording() {
        stopPreview()
        if isRecording {
            recorder?.stop()
            recorder = nil
            isRecording = false
        }
        try? FileManager.default.removeItem(at: Self.fileURL)
        refreshHasRecording()
        statusMessage = "録音を削除しました。接近時は端末の読み上げ声を使います。"
    }

    // MARK: - Delegates

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            self.recorder = nil
            self.refreshHasRecording()
            if !flag {
                try? FileManager.default.removeItem(at: Self.fileURL)
                self.refreshHasRecording()
                self.statusMessage = "録音に失敗しました。"
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.previewPlayer === player {
                self.previewPlayer = nil
                self.isPlayingPreview = false
            }
        }
    }
}
