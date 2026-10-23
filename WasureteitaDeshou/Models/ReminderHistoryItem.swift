import Foundation

/// 解除理由。自動滞在解除と手動完了を区別する。
enum ReminderClearReason: String, Codable, Sendable {
    case autoDwell
    case manual
}

/// 解除済み予定の履歴。再登録用に場所・用事を保持する。
struct ReminderHistoryItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var placeName: String
    var address: String
    var task: String
    var latitude: Double
    var longitude: Double
    var rawUtterance: String
    /// もともとの登録日時
    var createdAt: Date
    var clearedAt: Date
    var notifyDistanceMeters: Int
    var clearReason: ReminderClearReason

    init(
        id: UUID = UUID(),
        placeName: String,
        address: String,
        task: String,
        latitude: Double,
        longitude: Double,
        rawUtterance: String,
        createdAt: Date,
        clearedAt: Date = Date(),
        notifyDistanceMeters: Int,
        clearReason: ReminderClearReason
    ) {
        self.id = id
        self.placeName = placeName
        self.address = address
        self.task = task
        self.latitude = latitude
        self.longitude = longitude
        self.rawUtterance = rawUtterance
        self.createdAt = createdAt
        self.clearedAt = clearedAt
        self.notifyDistanceMeters = notifyDistanceMeters
        self.clearReason = clearReason
    }

    init(from reminder: Reminder, clearedAt: Date = Date(), reason: ReminderClearReason) {
        self.init(
            id: UUID(),
            placeName: reminder.placeName,
            address: reminder.address,
            task: reminder.task,
            latitude: reminder.latitude,
            longitude: reminder.longitude,
            rawUtterance: reminder.rawUtterance,
            createdAt: reminder.createdAt,
            clearedAt: clearedAt,
            notifyDistanceMeters: reminder.notifyDistanceMeters,
            clearReason: reason
        )
    }

    /// 履歴から新しい予定として再登録する（新 ID・新登録日時）。
    func asNewReminder() -> Reminder {
        Reminder(
            placeName: placeName,
            address: address,
            task: task,
            latitude: latitude,
            longitude: longitude,
            rawUtterance: rawUtterance.isEmpty ? "\(placeName)で\(task)" : rawUtterance,
            createdAt: Date(),
            notifyDistanceMeters: AppNotifySettings.clamp(notifyDistanceMeters)
        )
    }
}
