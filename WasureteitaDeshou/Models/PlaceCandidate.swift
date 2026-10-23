import CoreLocation
import Foundation
import MapKit

/// MapKit 検索結果の1件。
struct PlaceCandidate: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: String = UUID().uuidString, name: String, address: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    init(mapItem: MKMapItem) {
        let loc = mapItem.placemark.coordinate
        let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "名前なしの場所"
        let address = [
            mapItem.placemark.administrativeArea,
            mapItem.placemark.locality,
            mapItem.placemark.thoroughfare,
            mapItem.placemark.subThoroughfare
        ]
        .compactMap { $0 }
        .joined(separator: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = "\(name)|\(loc.latitude)|\(loc.longitude)"
        self.name = name
        self.address = address.isEmpty ? (mapItem.placemark.title ?? "") : address
        self.latitude = loc.latitude
        self.longitude = loc.longitude
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
