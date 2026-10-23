import Foundation
import Combine

/// 自宅の端末内永続化（UserDefaults）。クラウド同期なし。
@MainActor
final class HomePlaceStore: ObservableObject {
    private enum Keys {
        static let home = "homePlace.v1"
    }

    @Published private(set) var home: HomePlace?

    var isConfigured: Bool { home != nil }

    init() {
        home = Self.load()
    }

    func save(_ place: HomePlace) {
        home = place
        if let data = try? JSONEncoder().encode(place) {
            UserDefaults.standard.set(data, forKey: Keys.home)
        }
    }

    func clear() {
        home = nil
        UserDefaults.standard.removeObject(forKey: Keys.home)
    }

    private static func load() -> HomePlace? {
        guard let data = UserDefaults.standard.data(forKey: Keys.home) else { return nil }
        return try? JSONDecoder().decode(HomePlace.self, from: data)
    }
}
