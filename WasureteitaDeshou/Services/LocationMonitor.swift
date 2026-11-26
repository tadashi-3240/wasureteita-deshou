import CoreLocation
import Foundation
import Combine

/// 店舗付近の到着判定（目安 50〜100m）。領域進入または同等の距離で即時自動解除。
enum DwellConfig {
    /// 50〜100m の目安中央寄り
    static let radiusMeters: CLLocationDistance = 75
    static let identifierPrefix = "dwell."
    /// 内側判定の余裕（GPS 誤差）
    static let insideSlackFactor: CLLocationDistance = 1.5
}

/// 予定の円形ジオフェンス監視。接近通知＋到着による自動解除。
@MainActor
final class LocationMonitor: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastErrorMessage: String?
    /// 現在システムに渡している監視領域の件数
    @Published private(set) var monitoredRegionCount: Int = 0
    /// 接近圏内で到着距離を監視中の件数（デバッグ／設定表示用）
    @Published private(set) var dwellTrackingCount: Int = 0

    private let manager = CLLocationManager()
    private let notifier = ReminderNotifier()
    private var reminderLookup: [String: Reminder] = [:]
    /// 同じ接近領域にいるあいだの連打を防ぐ（退出でクリア）。投稿前に同期的にセット。
    private var notifiedWhileInside: Set<String> = []
    /// 接近圏内の予定（到着距離チェック用の限定 GPS を動かすキー）
    private var approachInsideKeys: Set<String> = []
    private var isUpdatingForArrival = false

    /// 到着圏進入で自動解除するときのコールバック（ReminderStore が履歴へ）
    var onDwellAutoClear: ((UUID) -> Void)?

    private enum PersistKeys {
        static let notifiedWhileInside = "location.notifiedWhileInside.v1"
        static let approachInsideKeys = "location.approachInsideKeys.v1"
        /// 旧 30s/60s 滞在計測。読み捨てて削除する
        static let legacyDwellEnteredAt = "location.dwellEnteredAt.v1"
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        // 常時 GPS は使わない。接近圏内のみ到着距離チェック用に限定更新する。
        manager.allowsBackgroundLocationUpdates = false
        UserDefaults.standard.removeObject(forKey: PersistKeys.legacyDwellEnteredAt)
        loadNotifiedWhileInside()
        loadApproachInsideKeys()
        refreshMonitoredCount()
        dwellTrackingCount = approachInsideKeys.count
        if !approachInsideKeys.isEmpty {
            startArrivalLocationUpdatesIfNeeded()
        }
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
                markApproachOutside(reminderKey: reminderKey)
            }
        }

        for key in Array(approachInsideKeys) where reminderLookup[key] == nil {
            markApproachOutside(reminderKey: key)
        }

        for reminder in reminders {
            startOrUpdate(reminder: reminder)
        }
        refreshMonitoredCount()
        evaluateArrival(at: manager.location)
        // 領域ごとの requestState はここに寄せる（起動時の二重問い合わせを避ける）
        requestStateForAllMonitoredRegions()
    }

    func stopMonitoring(id: UUID) {
        let key = id.uuidString
        reminderLookup.removeValue(forKey: key)
        clearNotifiedWhileInside(key)
        markApproachOutside(reminderKey: key)
        for region in manager.monitoredRegions {
            let regionKey = Self.reminderKey(fromRegionId: region.identifier)
            if regionKey == key {
                manager.stopMonitoring(for: region)
            }
        }
        refreshMonitoredCount()
        stopArrivalLocationUpdatesIfNeeded()
    }

    /// フォアグラウンド復帰時など、監視中の全領域の内外を再問い合わせする。
    /// `sync` 末尾からも呼ばれる。呼び出し側で sync と重ねないこと。
    func requestStateForAllMonitoredRegions() {
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
        refreshMonitoredCount()
        evaluateArrival(at: manager.location)
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

        // 到着判定用（店舗付近 約 75m）
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
        markApproachInside(reminderKey: identifier)
        // 投稿前に同期的に「送信中／送信済み」を立て、requestState / didEnter の多重呼び出しを遮断する
        guard !notifiedWhileInside.contains(identifier) else {
            evaluateArrival(at: manager.location)
            return
        }
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
            // 前面: willPresent と両方呼ぶ（同一文は synthesizer 側で短時間 coalesce）。
            // BG／非アクティブ: 進入検知の短い実行枠内で通知後に読む（audio BG + beginBackgroundTask）。
            // 通知音との衝突回避のため、前面・BG とも同じ clearance 遅延。
            ApproachSpeechSynthesizer.shared.speakApproachIfEnabled(
                task: reminder.task,
                delay: ApproachSpeechSynthesizer.notificationSoundClearance
            )
        }
        evaluateArrival(at: manager.location)
    }

    private func handleDwellEnter(reminderKey: String) {
        guard reminderLookup[reminderKey] != nil else { return }
        // 到着圏進入で即時解除（滞在待ちなし）
        finishDwellAutoClear(reminderKey: reminderKey)
    }

    private func handleDwellExit(reminderKey: String) {
        // 到着で即解除するため、計測待ちは持たない。退出は no-op。
        _ = reminderKey
    }

    private func markApproachInside(reminderKey: String) {
        guard reminderLookup[reminderKey] != nil else { return }
        if approachInsideKeys.insert(reminderKey).inserted {
            persistApproachInsideKeys()
            dwellTrackingCount = approachInsideKeys.count
        }
        startArrivalLocationUpdatesIfNeeded()
    }

    private func markApproachOutside(reminderKey: String) {
        guard approachInsideKeys.remove(reminderKey) != nil else { return }
        persistApproachInsideKeys()
        dwellTrackingCount = approachInsideKeys.count
        stopArrivalLocationUpdatesIfNeeded()
    }

    private func clearNotifiedWhileInside(_ key: String) {
        guard notifiedWhileInside.remove(key) != nil else { return }
        persistNotifiedWhileInside()
    }

    /// 現在地が到着圏内なら即クリア。接近圏のみでは消さない。
    private func evaluateArrival(at location: CLLocation?) {
        guard let location else { return }
        var toClear: [String] = []

        for (reminderKey, reminder) in reminderLookup {
            let center = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
            let limit = DwellConfig.radiusMeters * DwellConfig.insideSlackFactor
            if location.distance(from: center) <= limit {
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
            clearNotifiedWhileInside(reminderKey)
            markApproachOutside(reminderKey: reminderKey)
            return
        }
        clearNotifiedWhileInside(reminderKey)
        markApproachOutside(reminderKey: reminderKey)
        stopArrivalLocationUpdatesIfNeeded()
        onDwellAutoClear?(uuid)
    }

    private func startArrivalLocationUpdatesIfNeeded() {
        guard !approachInsideKeys.isEmpty else { return }
        guard !isUpdatingForArrival else { return }
        isUpdatingForArrival = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        // 接近圏内の到着距離検知中は静止しても更新を止めない
        manager.pausesLocationUpdatesAutomatically = false
        // Always 許可時のみ BG 更新。When In Use でも FG なら更新される。
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()
    }

    private func stopArrivalLocationUpdatesIfNeeded() {
        guard approachInsideKeys.isEmpty else { return }
        guard isUpdatingForArrival else { return }
        isUpdatingForArrival = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
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

    private func persistApproachInsideKeys() {
        UserDefaults.standard.set(Array(approachInsideKeys), forKey: PersistKeys.approachInsideKeys)
    }

    private func loadApproachInsideKeys() {
        if let raw = UserDefaults.standard.array(forKey: PersistKeys.approachInsideKeys) as? [String] {
            approachInsideKeys = Set(raw)
        } else {
            approachInsideKeys = []
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
            if manager.authorizationStatus == .authorizedAlways, !self.approachInsideKeys.isEmpty {
                self.startArrivalLocationUpdatesIfNeeded()
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
                self.markApproachOutside(reminderKey: region.identifier)
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
                    self.markApproachOutside(reminderKey: region.identifier)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.evaluateArrival(at: locations.last)
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
        // 限定的な位置更新の失敗は到着判定を止めない（接近退出で停止）
    }
}
