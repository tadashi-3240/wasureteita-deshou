import CoreLocation
import Foundation
import Combine
import UIKit

/// 店舗付近の滞在判定（目安 50〜100m・約1分）。領域監視＋必要時のみ限定的な位置更新。
enum DwellConfig {
    /// 50〜100m の目安中央寄り
    static let radiusMeters: CLLocationDistance = 75
    static let requiredSeconds: TimeInterval = 60
    static let identifierPrefix = "dwell."
    /// 内側判定の余裕（GPS 誤差）
    static let insideSlackFactor: CLLocationDistance = 1.5
}

/// 予定の円形ジオフェンス監視。接近通知＋滞在による自動解除。
@MainActor
final class LocationMonitor: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastErrorMessage: String?
    /// 現在システムに渡している監視領域の件数
    @Published private(set) var monitoredRegionCount: Int = 0
    /// 店舗付近に滞在計測中の件数（デバッグ／設定表示用）
    @Published private(set) var dwellTrackingCount: Int = 0

    private let manager = CLLocationManager()
    private let notifier = ReminderNotifier()
    private var reminderLookup: [String: Reminder] = [:]
    /// 同じ接近領域にいるあいだの連打を防ぐ（退出でクリア）。投稿前に同期的にセット。
    private var notifiedWhileInside: Set<String> = []
    /// 滞在領域に入った時刻（reminder UUID 文字列）
    private var dwellEnteredAt: [String: Date] = [:]
    private var isUpdatingForDwell = false

    /// 約1分滞在で自動解除するときのコールバック（ReminderStore が履歴へ）
    var onDwellAutoClear: ((UUID) -> Void)?

    private enum PersistKeys {
        static let dwellEnteredAt = "location.dwellEnteredAt.v1"
        static let notifiedWhileInside = "location.notifiedWhileInside.v1"
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        // 常時 GPS は使わない。滞在計測中のみ限定的に更新する。
        manager.allowsBackgroundLocationUpdates = false
        loadDwellEnteredAt()
        loadNotifiedWhileInside()
        refreshMonitoredCount()
        dwellTrackingCount = dwellEnteredAt.count
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = manager.authorizationStatus
        refreshMonitoredCount()
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// 保存済み予定と監視を同期する（接近領域＋滞在領域）。末尾で一括 requestState。
    func sync(reminders: [Reminder]) {
        reminderLookup = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id.uuidString, $0) })

        let wanted = Set(reminders.flatMap { reminder -> [String] in
            let key = reminder.id.uuidString
            return [key, Self.dwellIdentifier(for: key)]
        })

        for region in manager.monitoredRegions {
            guard let circular = region as? CLCircularRegion else { continue }
            if !wanted.contains(circular.identifier) {
                manager.stopMonitoring(for: circular)
                let reminderKey = Self.reminderKey(fromRegionId: circular.identifier)
                clearNotifiedWhileInside(reminderKey)
                clearDwellTracking(reminderKey: reminderKey)
            }
        }

        // もう無い予定の滞在計測を落とす
        for key in Array(dwellEnteredAt.keys) where reminderLookup[key] == nil {
            clearDwellTracking(reminderKey: key)
        }

        for reminder in reminders {
            startOrUpdate(reminder: reminder)
        }
        refreshMonitoredCount()
        evaluateDwell(at: manager.location)
        // 領域ごとの requestState はここに寄せる（起動時の二重問い合わせを避ける）
        requestStateForAllMonitoredRegions()
    }

    func stopMonitoring(id: UUID) {
        let key = id.uuidString
        reminderLookup.removeValue(forKey: key)
        clearNotifiedWhileInside(key)
        clearDwellTracking(reminderKey: key)
        for region in manager.monitoredRegions {
            let regionKey = Self.reminderKey(fromRegionId: region.identifier)
            if regionKey == key {
                manager.stopMonitoring(for: region)
            }
        }
        refreshMonitoredCount()
        stopDwellLocationUpdatesIfNeeded()
    }

    /// フォアグラウンド復帰時など、監視中の全領域の内外を再問い合わせする。
    /// `sync` 末尾からも呼ばれる。呼び出し側で sync と重ねないこと。
    func requestStateForAllMonitoredRegions() {
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
        refreshMonitoredCount()
        evaluateDwell(at: manager.location)
    }

    private func refreshMonitoredCount() {
        monitoredRegionCount = manager.monitoredRegions.count
    }

    private func startOrUpdate(reminder: Reminder) {
        let key = reminder.id.uuidString
        reminderLookup[key] = reminder

        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            lastErrorMessage = "位置情報の許可が必要です。"
            return
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            lastErrorMessage = "この端末では領域監視を利用できません。"
            return
        }

        let center = CLLocationCoordinate2D(latitude: reminder.latitude, longitude: reminder.longitude)

        // 接近通知用（設定距離）
        let approachRadius = CLLocationDistance(max(100, AppNotifySettings.clamp(reminder.notifyDistanceMeters)))
        startCircularRegion(
            center: center,
            radius: approachRadius,
            identifier: key
        )

        // 滞在判定用（店舗付近 約 75m）
        startCircularRegion(
            center: center,
            radius: DwellConfig.radiusMeters,
            identifier: Self.dwellIdentifier(for: key)
        )
    }

    private func startCircularRegion(
        center: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        identifier: String
    ) {
        let region = CLCircularRegion(center: center, radius: radius, identifier: identifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true

        for existing in manager.monitoredRegions where existing.identifier == identifier {
            manager.stopMonitoring(for: existing)
        }

        manager.startMonitoring(for: region)
        // requestState は sync 末尾の一括呼び出しに任せる
    }

    private func handleApproachEnter(identifier: String) {
        guard let reminder = reminderLookup[identifier] else { return }
        // 投稿前に同期的に「送信中／送信済み」を立て、requestState / didEnter の多重呼び出しを遮断する
        guard !notifiedWhileInside.contains(identifier) else { return }
        notifiedWhileInside.insert(identifier)
        persistNotifiedWhileInside()

        notifier.postApproachNotification(for: reminder) { [weak self] success, errorMessage in
            guard let self else { return }
            if !success {
                // 失敗時のみ解除して再試行可
                self.clearNotifiedWhileInside(identifier)
                self.lastErrorMessage = errorMessage ?? "通知の送信に失敗しました。"
                return
            }
            // 前面は AppDelegate.willPresent が読み上げる（二重読み上げ防止）。
            // 非アクティブ／BG 起床時のみここで試す（成功は保証しない — ApproachSpeechSynthesizer コメント参照）。
            if UIApplication.shared.applicationState != .active {
                ApproachSpeechSynthesizer.shared.speakApproachIfEnabled(task: reminder.task)
            }
        }
    }

    private func handleDwellEnter(reminderKey: String) {
        guard reminderLookup[reminderKey] != nil else { return }
        if dwellEnteredAt[reminderKey] == nil {
            dwellEnteredAt[reminderKey] = Date()
            persistDwellEnteredAt()
            dwellTrackingCount = dwellEnteredAt.count
        }
        startDwellLocationUpdatesIfNeeded()
        evaluateDwell(at: manager.location)
    }

    private func handleDwellExit(reminderKey: String) {
        clearDwellTracking(reminderKey: reminderKey)
        stopDwellLocationUpdatesIfNeeded()
    }

    private func clearDwellTracking(reminderKey: String) {
        guard dwellEnteredAt.removeValue(forKey: reminderKey) != nil else { return }
        persistDwellEnteredAt()
        dwellTrackingCount = dwellEnteredAt.count
    }

    private func clearNotifiedWhileInside(_ key: String) {
        guard notifiedWhileInside.remove(key) != nil else { return }
        persistNotifiedWhileInside()
    }

    private func evaluateDwell(at location: CLLocation?) {
        let now = Date()
        var toClear: [String] = []

        for (reminderKey, enteredAt) in dwellEnteredAt {
            guard let reminder = reminderLookup[reminderKey] else {
                toClear.append(reminderKey)
                continue
            }

            if let location {
                let center = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
                let limit = DwellConfig.radiusMeters * DwellConfig.insideSlackFactor
                if location.distance(from: center) > limit {
                    // 退出イベント待ち。計測は維持（一時的な GPS 飛びを許容）
                    continue
                }
            }

            if now.timeIntervalSince(enteredAt) >= DwellConfig.requiredSeconds {
                toClear.append(reminderKey)
            }
        }

        for key in toClear {
            finishDwellAutoClear(reminderKey: key)
        }
    }

    private func finishDwellAutoClear(reminderKey: String) {
        guard let uuid = UUID(uuidString: reminderKey) else { return }
        guard reminderLookup[reminderKey] != nil else {
            clearDwellTracking(reminderKey: reminderKey)
            stopDwellLocationUpdatesIfNeeded()
            return
        }
        clearDwellTracking(reminderKey: reminderKey)
        clearNotifiedWhileInside(reminderKey)
        stopDwellLocationUpdatesIfNeeded()
        onDwellAutoClear?(uuid)
    }

    private func startDwellLocationUpdatesIfNeeded() {
        guard !dwellEnteredAt.isEmpty else { return }
        guard !isUpdatingForDwell else { return }
        isUpdatingForDwell = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        // Always 許可時のみ BG 更新。When In Use でも FG なら更新される。
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()
    }

    private func stopDwellLocationUpdatesIfNeeded() {
        guard dwellEnteredAt.isEmpty else { return }
        guard isUpdatingForDwell else { return }
        isUpdatingForDwell = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func persistDwellEnteredAt() {
        let encoded = dwellEnteredAt.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(encoded, forKey: PersistKeys.dwellEnteredAt)
    }

    private func loadDwellEnteredAt() {
        guard let raw = UserDefaults.standard.dictionary(forKey: PersistKeys.dwellEnteredAt) as? [String: Double] else {
            dwellEnteredAt = [:]
            return
        }
        dwellEnteredAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
        if !dwellEnteredAt.isEmpty {
            startDwellLocationUpdatesIfNeeded()
        }
    }

    private func persistNotifiedWhileInside() {
        UserDefaults.standard.set(Array(notifiedWhileInside), forKey: PersistKeys.notifiedWhileInside)
    }

    private func loadNotifiedWhileInside() {
        if let raw = UserDefaults.standard.array(forKey: PersistKeys.notifiedWhileInside) as? [String] {
            notifiedWhileInside = Set(raw)
        } else {
            notifiedWhileInside = []
        }
    }

    static func dwellIdentifier(for reminderKey: String) -> String {
        DwellConfig.identifierPrefix + reminderKey
    }

    static func isDwellIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(DwellConfig.identifierPrefix)
    }

    static func reminderKey(fromRegionId identifier: String) -> String {
        if isDwellIdentifier(identifier) {
            return String(identifier.dropFirst(DwellConfig.identifierPrefix.count))
        }
        return identifier
    }
}

extension LocationMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            self.refreshMonitoredCount()
            if manager.authorizationStatus == .authorizedAlways, !self.dwellEnteredAt.isEmpty {
                self.startDwellLocationUpdatesIfNeeded()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            if Self.isDwellIdentifier(region.identifier) {
                self.handleDwellEnter(reminderKey: Self.reminderKey(fromRegionId: region.identifier))
            } else {
                self.handleApproachEnter(identifier: region.identifier)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            if Self.isDwellIdentifier(region.identifier) {
                self.handleDwellExit(reminderKey: Self.reminderKey(fromRegionId: region.identifier))
            } else {
                self.clearNotifiedWhileInside(region.identifier)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        Task { @MainActor in
            if state == .inside {
                if Self.isDwellIdentifier(region.identifier) {
                    self.handleDwellEnter(reminderKey: Self.reminderKey(fromRegionId: region.identifier))
                } else {
                    self.handleApproachEnter(identifier: region.identifier)
                }
            } else if state == .outside {
                if Self.isDwellIdentifier(region.identifier) {
                    self.handleDwellExit(reminderKey: Self.reminderKey(fromRegionId: region.identifier))
                } else {
                    self.clearNotifiedWhileInside(region.identifier)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.evaluateDwell(at: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = "位置の監視を開始できませんでした。"
            self.refreshMonitoredCount()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        Task { @MainActor in
            self.refreshMonitoredCount()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 限定的な位置更新の失敗は滞在計測を止めない（領域 exit でリセット）
    }
}
