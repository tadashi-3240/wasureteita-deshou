import Foundation
import Combine

/// 登録済み場所の呼び名。UserDefaults。クラウド同期なし。自宅は含めない。
@MainActor
final class SavedPlaceStore: ObservableObject {
    private enum Keys {
        static let places = "savedPlaces.v1"
    }

    /// 同じ場所とみなす距離（メートル）。近傍なら upsert で名前更新。
    static let proximityMeters: Double = 50

    @Published private(set) var places: [SavedPlace] = []

    init() {
        places = Self.load()
    }

    /// 名前の部分一致。新しい順。
    func matches(query: String) -> [SavedPlace] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return places
            .filter { $0.matchesQuery(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 予定確定時の upsert。近傍なら displayName を更新。別名を別エントリで残す場合は `forceNewAlias`。
    @discardableResult
    func upsertFromRegistration(
        displayName: String,
        address: String,
        latitude: Double,
        longitude: Double,
        forceNewAlias: Bool = false
    ) -> SavedPlace {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // 空名は保存しない（呼び出し側でガード想定）
            return SavedPlace(displayName: "場所", address: address, latitude: latitude, longitude: longitude)
        }

        if !forceNewAlias,
           let index = places.firstIndex(where: {
               $0.distanceMeters(to: latitude, longitude: longitude) <= Self.proximityMeters
           }) {
            places[index].displayName = name
            places[index].address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            places[index].latitude = latitude
            places[index].longitude = longitude
            places[index].updatedAt = Date()
            persist()
            return places[index]
        }

        let place = SavedPlace(
            displayName: name,
            address: address,
            latitude: latitude,
            longitude: longitude
        )
        places.insert(place, at: 0)
        persist()
        return place
    }

    func updateDisplayName(id: UUID, displayName: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        places[index].displayName = name
        places[index].updatedAt = Date()
        persist()
    }

    func delete(id: UUID) {
        places.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: Keys.places)
        }
    }

    private static func load() -> [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: Keys.places) else { return [] }
        return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }
}
