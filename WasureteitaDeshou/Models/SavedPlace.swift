import CoreLocation
import Foundation

/// 一度登録した場所の呼び名。端末内のみ。自宅（HomePlace）とは別。
struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 呼び名（ニックネーム）。検索の部分一致対象。
    var displayName: String
    var address: String
    var latitude: Double
    var longitude: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        address: String = "",
        latitude: Double,
        longitude: Double,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = latitude
        self.longitude = longitude
        self.updatedAt = updatedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func asPlaceCandidate() -> PlaceCandidate {
        PlaceCandidate(
            id: "saved|\(id.uuidString)",
            name: displayName,
            address: address.isEmpty ? "保存した場所" : address,
            latitude: latitude,
            longitude: longitude
        )
    }

    /// クエリが呼び名に部分一致するか（「製油所」「水江」→「水江の製油所」）。
    func matchesQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !displayName.isEmpty else { return false }
        if displayName.localizedCaseInsensitiveContains(q) { return true }
        if q.localizedCaseInsensitiveContains(displayName) { return true }
        // クエリ側・呼び名側の両方を「の／空白」でトークン化し、相互に部分一致
        let queryTokens = Self.tokens(in: q)
        if queryTokens.contains(where: { displayName.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let nameTokens = Self.tokens(in: displayName)
        return nameTokens.contains { q.localizedCaseInsensitiveContains($0) }
    }

    /// 決定時の「明確な部分一致」: 完全一致、または片方が他方を含む（2文字以上）。
    func isClearPartialMatch(for query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !displayName.isEmpty else { return false }
        if displayName.localizedCaseInsensitiveCompare(q) == .orderedSame { return true }
        guard min(displayName.count, q.count) >= 2 else { return false }
        return displayName.localizedCaseInsensitiveContains(q)
            || q.localizedCaseInsensitiveContains(displayName)
    }

    private static func tokens(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: "の", with: " ")
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    func distanceMeters(to latitude: Double, longitude: Double) -> CLLocationDistance {
        let a = CLLocation(latitude: self.latitude, longitude: self.longitude)
        let b = CLLocation(latitude: latitude, longitude: longitude)
        return a.distance(from: b)
    }
}
