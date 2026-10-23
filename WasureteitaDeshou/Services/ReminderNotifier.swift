import Foundation
import UserNotifications

/// ローカル通知（専用音ピロリローン）。読み上げは `ApproachSpeechSynthesizer`（前面向け）。
@MainActor
final class ReminderNotifier {
    static let soundFileName = "piroriron.caf"
    static let categoryId = "approach.reminder"

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 接近通知。識別子は予定ごとに安定（`approach-{uuid}`）。`completion` は add 成功時のみ true。
    func postApproachNotification(
        for reminder: Reminder,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let reminderId = reminder.id.uuidString
        let identifier = "approach-\(reminderId)"
        let content = makeContent(
            title: "忘れていたでしょう？",
            body: "\(reminder.task)予定ですよ！",
            reminderId: reminderId
        )
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        add(request, completion: completion)
    }

    /// 設定画面の動作確認用。
    func postTestNotification(completion: ((Bool, String?) -> Void)? = nil) {
        let content = makeContent(
            title: "忘れていたでしょう？（テスト）",
            body: "通知の許可と音の確認です。",
            reminderId: "test"
        )
        let request = UNNotificationRequest(
            identifier: "test-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        add(request, completion: completion ?? { _, _ in })
    }

    private func makeContent(title: String, body: String, reminderId: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound()
        content.categoryIdentifier = Self.categoryId
        content.userInfo = ["reminderId": reminderId]
        return content
    }

    /// バンドルにカスタム音があればそれ、無ければ `.default`。
    private func notificationSound() -> UNNotificationSound {
        let name = (Self.soundFileName as NSString).deletingPathExtension
        let ext = (Self.soundFileName as NSString).pathExtension
        if Bundle.main.url(forResource: name, withExtension: ext) != nil {
            return UNNotificationSound(named: UNNotificationSoundName(Self.soundFileName))
        }
        return .default
    }

    private func add(
        _ request: UNNotificationRequest,
        completion: @escaping (Bool, String?) -> Void
    ) {
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(true, nil)
                }
            }
        }
    }
}
