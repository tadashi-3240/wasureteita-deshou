import CoreLocation
import Foundation

/// 検索範囲のヒント用。When In Use のみ（Always / ジオフェンスは第3段階）。
@MainActor
final class UserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUseIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// 短時間で現在地を1回取る。拒否・失敗時は nil。
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        if let coordinate { return coordinate }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let cont = self.continuation {
                    self.continuation = nil
                    cont.resume(returning: self.coordinate)
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.coordinate = locations.last?.coordinate
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: self.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: self.coordinate)
            }
        }
    }
}
