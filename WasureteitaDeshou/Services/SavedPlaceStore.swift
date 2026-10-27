import Foundation
import Combine

/// 内容確認の「決定」で場所欄を SavedPlace に当てた結果。
enum SavedPlaceDecideResolve: Equatable {
    case none
    case unique(SavedPlace)
    case multiple([SavedPlace])
}

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

    /// 決定時: 完全一致 → 正規化一致 → 地名＋店名 → 明確な部分一致 → トークン一致。一意なら座標確定。
    func resolveForDecide(query: String) -> SavedPlaceDecideResolve {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .none }

        let exact = places
            .filter { $0.displayName.localizedCaseInsensitiveCompare(q) == .orderedSame }
            .sorted { $0.updatedAt > $1.updatedAt }
        if exact.count == 1 { return .unique(exact[0]) }
        if exact.count > 1 { return .multiple(exact) }

        // 「金古のセブン」↔「金古のセブンイレブン」などブランド正規化後の一意一致
        let qNorm = SavedPlace.normalizeForMatch(q)
        let normalizedExact = places
            .filter {
                SavedPlace.normalizeForMatch($0.displayName)
                    .localizedCaseInsensitiveCompare(qNorm) == .orderedSame
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        if normalizedExact.count == 1 { return .unique(normalizedExact[0]) }
        if normalizedExact.count > 1 { return .multiple(normalizedExact) }

        // 「金古のセブン」「高崎のイオン」: 地名と店名の両方が当たるものだけ（セブン複数店舗の誤爆を抑える）
        if SavedPlace.areaBrandParts(in: q) != nil {
            let structured = places
                .filter { $0.matchesAreaBrand(for: q) }
                .sorted { $0.updatedAt > $1.updatedAt }
            if structured.count == 1 { return .unique(structured[0]) }
            if structured.count > 1 { return .multiple(structured) }
        }

        let clear = places
            .filter { $0.isClearPartialMatch(for: q) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if clear.count == 1 { return .unique(clear[0]) }
        if clear.count > 1 { return .multiple(clear) }

        let fuzzy = matches(query: q)
        if fuzzy.count == 1 { return .unique(fuzzy[0]) }
        if fuzzy.count > 1 { return .multiple(fuzzy) }
        return .none
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

        var next = places
        if !forceNewAlias,
           let index = next.firstIndex(where: {
               $0.distanceMeters(to: latitude, longitude: longitude) <= Self.proximityMeters
           }) {
            next[index].displayName = name
            next[index].address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            next[index].latitude = latitude
            next[index].longitude = longitude
            next[index].updatedAt = Date()
            places = next
            persist()
            return places[index]
        }

        let place = SavedPlace(
            displayName: name,
            address: address,
            latitude: latitude,
            longitude: longitude
        )
        next.insert(place, at: 0)
        places = next
        persist()
        return place
    }

    func updateDisplayName(id: UUID, displayName: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var next = places
        next[index].displayName = name
        next[index].updatedAt = Date()
        places = next
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
