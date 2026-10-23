import CoreLocation
import Foundation
import MapKit

enum PlaceSearchError: LocalizedError {
    case emptyQuery
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "検索する場所の言葉が空です。"
        case .failed(let message):
            return message
        }
    }
}

/// Apple MapKit による店舗・場所検索。チェーンは候補が複数出やすいようクエリを広げる。
@MainActor
final class PlaceSearchService {
    private let geocoder = CLGeocoder()

    /// コンビニ等。一覧選択を優先したいブランド。
    static let chainBrandKeywords: [String] = [
        "セブンイレブン", "セブン−イレブン", "セブン-イレブン", "7-Eleven", "7‑Eleven",
        "ファミリーマート", "ファミマ",
        "ローソン",
        "ミニストップ",
        "デイリーヤマザキ",
        "セイコーマート",
        "イオン", "マックスバリュ",
        "コストコ"
    ]

    static func isLikelyChain(_ placePhrase: String) -> Bool {
        let p = placePhrase
        return chainBrandKeywords.contains { p.localizedCaseInsensitiveContains($0) }
            || p.contains("セブン")
    }

    /// 場所フレーズから複数クエリで検索し、候補をマージする。
    /// `savedPlaces` の名前部分一致は MapKit より **先頭** に載せる（MapKit が空でも SavedPlace だけで返す）。
    func searchPlaceCandidates(
        placePhrase: String,
        near userLocation: CLLocationCoordinate2D? = nil,
        savedPlaces: [SavedPlace] = []
    ) async throws -> [PlaceCandidate] {
        let base = placePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw PlaceSearchError.emptyQuery }

        let savedCandidates = savedPlaces
            .filter { $0.matchesQuery(base) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { $0.asPlaceCandidate() }

        let queries = queryVariants(for: base)
        var merged: [PlaceCandidate] = []
        for q in queries {
            let batch = try await searchOnce(query: q, near: userLocation, radiusMeters: 80_000)
            merged.append(contentsOf: batch)
        }

        var mapkitResult = deduplicated(merged)

        // チェーンで1件しか取れないときは、ブランド＋地域だけでもう一度広めに取る
        if mapkitResult.count <= 1, let brandQuery = broadenedChainQuery(for: base) {
            let extra = try await searchOnce(query: brandQuery, near: userLocation, radiusMeters: 120_000)
            mapkitResult = deduplicated(mapkitResult + extra)
        }

        return mergeSavedFirst(saved: savedCandidates, mapkit: mapkitResult)
    }

    func search(
        query: String,
        near userLocation: CLLocationCoordinate2D? = nil,
        savedPlaces: [SavedPlace] = []
    ) async throws -> [PlaceCandidate] {
        try await searchPlaceCandidates(placePhrase: query, near: userLocation, savedPlaces: savedPlaces)
    }

    /// SavedPlace を先頭に。MapKit 側で同じ座標近傍は落とす。
    private func mergeSavedFirst(saved: [PlaceCandidate], mapkit: [PlaceCandidate]) -> [PlaceCandidate] {
        guard !saved.isEmpty else { return mapkit }
        var result = saved
        for item in mapkit {
            let nearSaved = saved.contains {
                let a = CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                let b = CLLocation(latitude: item.latitude, longitude: item.longitude)
                return a.distance(from: b) <= SavedPlaceStore.proximityMeters
            }
            if !nearSaved {
                result.append(item)
            }
        }
        return result
    }

    private func searchOnce(
        query: String,
        near userLocation: CLLocationCoordinate2D?,
        radiusMeters: CLLocationDistance
    ) async throws -> [PlaceCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = [.pointOfInterest, .address]
        if let userLocation {
            request.region = MKCoordinateRegion(
                center: userLocation,
                latitudinalMeters: radiusMeters,
                longitudinalMeters: radiusMeters
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.map(PlaceCandidate.init(mapItem:))
        } catch {
            throw PlaceSearchError.failed("場所の検索に失敗しました。通信環境を確認してください。")
        }
    }

    /// 「金古のセブンイレブン」→ 複数の MapKit 向きクエリ
    private func queryVariants(for place: String) -> [String] {
        var variants: [String] = [place]

        let spaced = place
            .replacingOccurrences(of: "の", with: " ")
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if spaced != place { variants.append(spaced) }

        // 地域 + ブランドの語順入れ替え
        if let brand = Self.chainBrandKeywords.first(where: { place.contains($0) })
            ?? (place.contains("セブン") ? "セブンイレブン" : nil) {
            let area = place
                .replacingOccurrences(of: brand, with: "")
                .replacingOccurrences(of: "セブン", with: "")
                .replacingOccurrences(of: "の", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !area.isEmpty {
                variants.append("\(area) \(brand)")
                variants.append("\(brand) \(area)")
                // 町名っぽいとき
                if !area.contains("市") && !area.contains("町") {
                    variants.append("\(area)町 \(brand)")
                    variants.append("\(brand) \(area)町")
                }
            } else {
                variants.append(brand)
            }
        }

        // 重複除去（順序維持）
        var seen = Set<String>()
        return variants.filter { seen.insert($0).inserted }
    }

    private func broadenedChainQuery(for place: String) -> String? {
        guard Self.isLikelyChain(place) else { return nil }
        if let brand = Self.chainBrandKeywords.first(where: { place.contains($0) }) {
            let area = place
                .replacingOccurrences(of: brand, with: "")
                .replacingOccurrences(of: "の", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if area.isEmpty { return brand }
            return "\(area) \(brand)"
        }
        if place.contains("セブン") {
            let area = place.replacingOccurrences(of: "セブン", with: "")
                .replacingOccurrences(of: "イレブン", with: "")
                .replacingOccurrences(of: "の", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return area.isEmpty ? "セブンイレブン" : "\(area) セブンイレブン"
        }
        return nil
    }

    /// 地図で選んだ座標から住所・名前を補完する。
    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> PlaceCandidate {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            let mark = marks.first
            let name = [
                mark?.name,
                mark?.thoroughfare
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? "地図で選んだ場所"

            let address = [
                mark?.administrativeArea,
                mark?.locality,
                mark?.thoroughfare,
                mark?.subThoroughfare
            ]
            .compactMap { $0 }
            .joined(separator: "")

            return PlaceCandidate(
                name: name,
                address: address,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } catch {
            return PlaceCandidate(
                name: "地図で選んだ場所",
                address: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    private func deduplicated(_ items: [PlaceCandidate]) -> [PlaceCandidate] {
        var seen = Set<String>()
        var result: [PlaceCandidate] = []
        for item in items {
            let key = "\(item.name)|\(String(format: "%.4f", item.latitude))|\(String(format: "%.4f", item.longitude))"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }
}
