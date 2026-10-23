import CoreLocation
import Foundation

/// 端末内に保存する自宅。通知は既存 Reminder と同じく placeName などで扱う。
struct HomePlace: Codable, Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// 任意。逆ジオや地図指定で埋める。
    var address: String

    init(
        name: String = "自宅",
        latitude: Double,
        longitude: Double,
        address: String = ""
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "自宅"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = latitude
        self.longitude = longitude
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func asPlaceCandidate() -> PlaceCandidate {
        PlaceCandidate(
            id: "home|\(latitude)|\(longitude)",
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude
        )
    }
}
