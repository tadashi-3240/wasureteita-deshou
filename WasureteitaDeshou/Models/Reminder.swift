import Foundation

/// 端末内に保存する予定。notifyDistanceMeters で近づき通知の目安距離を持つ。
struct Reminder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var placeName: String
    var address: String
    var task: String
    var latitude: Double
    var longitude: Double
    var rawUtterance: String
    var createdAt: Date
    /// 近づき通知の目安距離（300 / 500 / 1000）。保証はしない。
    var notifyDistanceMeters: Int

    init(
        id: UUID = UUID(),
        placeName: String,
        address: String,
        task: String,
        latitude: Double,
        longitude: Double,
        rawUtterance: String,
        createdAt: Date = Date(),
        notifyDistanceMeters: Int = 1000
    ) {
        self.id = id
        self.placeName = placeName
        self.address = address
        self.task = task
        self.latitude = latitude
        self.longitude = longitude
        self.rawUtterance = rawUtterance
        self.createdAt = createdAt
        self.notifyDistanceMeters = notifyDistanceMeters
    }
}
