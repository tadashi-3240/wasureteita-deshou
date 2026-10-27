import UIKit
import UserNotifications

/// 起動時に通知センターのデリゲートを張り、フォアグラウンドでもバナーを出す。
/// 前面表示時（`willPresent`）と通知タップ後（`didReceive`）に用事文の読み上げを試す（設定 ON 時）。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // フォアグラウンドでの確実な読み上げ経路のひとつ。
        // バナー＋通知音を出しつつ、音が終わってから TTS（短い遅延）。
        // バックグラウンド／ロック画面では willPresent は呼ばれない。
        let content = notification.request.content
        Task { @MainActor in
            ApproachSpeechSynthesizer.shared.speakNotificationIfEnabled(
                title: content.title,
                body: content.body,
                delay: ApproachSpeechSynthesizer.notificationSoundClearance
            )
        }
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // ロック／BG から通知タップで前面に戻ったあと。自由文 TTS が通る範囲。
        let content = response.notification.request.content
        Task { @MainActor in
            ApproachSpeechSynthesizer.shared.speakNotificationIfEnabled(
                title: content.title,
                body: content.body,
                delay: 0.35
            )
        }
        completionHandler()
    }
}
