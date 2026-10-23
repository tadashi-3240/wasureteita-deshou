import UIKit
import UserNotifications

/// 起動時に通知センターのデリゲートを張り、フォアグラウンドでもバナーを出す。
/// 前面表示時（`willPresent`）に用事文の読み上げも試す（設定 ON 時）。
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
        // バックグラウンド／ロック画面では willPresent は呼ばれない（通知音＋文字が基本）。
        let content = notification.request.content
        Task { @MainActor in
            ApproachSpeechSynthesizer.shared.speakNotificationIfEnabled(
                title: content.title,
                body: content.body
            )
        }
        completionHandler([.banner, .sound, .list])
    }
}
