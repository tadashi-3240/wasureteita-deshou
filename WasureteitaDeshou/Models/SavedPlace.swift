import CoreLocation
import Foundation

/// 一度登録した場所の呼び名。端末内のみ。自宅（HomePlace）とは別。
struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 呼び名（ニックネーム）。検索の部分一致対象。「金古のセブン」など地名＋店名をそのまま保存。
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

    /// クエリが呼び名に部分一致するか（「製油所」「水江」→「水江の製油所」、「金古のセブン」→同名・別名）。
    func matchesQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !displayName.isEmpty else { return false }

        let nq = Self.normalizeForMatch(q)
        let nd = Self.normalizeForMatch(displayName)
        if nd.localizedCaseInsensitiveContains(nq) { return true }
        if nq.localizedCaseInsensitiveContains(nd) { return true }

        // 「金古のセブン」↔ MapKit名「セブン‐イレブン 金古町店」など: 地名＋店名の両方が呼び名側に出る
        if let parts = Self.areaBrandParts(in: q) {
            let areaOk = nd.localizedCaseInsensitiveContains(parts.area)
                || displayName.localizedCaseInsensitiveContains(parts.area)
            let brandOk = nd.localizedCaseInsensitiveContains(parts.brand)
            if areaOk && brandOk { return true }
        }

        let queryTokens = Self.tokens(in: nq)
        if queryTokens.contains(where: { nd.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let nameTokens = Self.tokens(in: nd)
        return nameTokens.contains { nq.localizedCaseInsensitiveContains($0) }
    }

    /// 決定時の「明確な部分一致」: 正規化後の完全一致、または片方が他方を含む（2文字以上）。
    func isClearPartialMatch(for query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !displayName.isEmpty else { return false }
        let nq = Self.normalizeForMatch(q)
        let nd = Self.normalizeForMatch(displayName)
        if nd.localizedCaseInsensitiveCompare(nq) == .orderedSame { return true }
        guard min(nd.count, nq.count) >= 2 else { return false }
        return nd.localizedCaseInsensitiveContains(nq)
            || nq.localizedCaseInsensitiveContains(nd)
    }

    /// 「金古のセブン」形式で、地名と店名の両方がこの呼び名（または MapKit 風の店名）に当たるか。
    func matchesAreaBrand(for query: String) -> Bool {
        guard let parts = Self.areaBrandParts(in: query) else { return false }
        if let own = Self.areaBrandParts(in: displayName) {
            return own.area.localizedCaseInsensitiveCompare(parts.area) == .orderedSame
                && own.brand.localizedCaseInsensitiveCompare(parts.brand) == .orderedSame
        }
        let nd = Self.normalizeForMatch(displayName)
        let areaOk = nd.localizedCaseInsensitiveContains(parts.area)
            || displayName.localizedCaseInsensitiveContains(parts.area)
        let brandOk = nd.localizedCaseInsensitiveContains(parts.brand)
        return areaOk && brandOk
    }

    /// ブランド別名を短い正規形に寄せる（セブンイレブン→セブン など）。
    static func normalizeForMatch(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 長い別名を先に短い正規形へ
        let replacements: [(String, String)] = [
            ("セブン−イレブン", "セブン"),
            ("セブン-イレブン", "セブン"),
            ("セブンイレブン", "セブン"),
            ("7-Eleven", "セブン"),
            ("7‑Eleven", "セブン"),
            ("ファミリーマート", "ファミマ"),
            ("デイリーヤマザキ", "ヤマザキ")
        ]
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        return s
    }

    /// 「金古のセブン」→ (金古, セブン)。正規化後。「の」が無い／短すぎるときは nil。
    static func areaBrandParts(in text: String) -> (area: String, brand: String)? {
        let normalized = normalizeForMatch(text)
        guard let range = normalized.range(of: "の") else { return nil }
        let area = String(normalized[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = String(normalized[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard area.count >= 2, brand.count >= 2 else { return nil }
        // 「の」が複数あるときは最初の区切り（地名＋残りを店名）
        return (area, brand)
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
