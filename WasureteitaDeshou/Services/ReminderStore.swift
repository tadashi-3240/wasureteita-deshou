import Foundation
import Combine

/// 予定の端末内永続化（ログイン不要）。追加・更新・削除・完了で位置監視を同期する。
@MainActor
final class ReminderStore: ObservableObject {
    private enum Keys {
        static let reminders = "reminders.v1"
        static let history = "reminderHistory.v1"
    }

    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var history: [ReminderHistoryItem] = []

    private let locationMonitor: LocationMonitor

    init(locationMonitor: LocationMonitor) {
        self.locationMonitor = locationMonitor
        load()
        loadHistory()
        locationMonitor.onDwellAutoClear = { [weak self] id in
            self?.clearToHistory(id: id, reason: .autoDwell)
        }
        locationMonitor.sync(reminders: reminders)
    }

    func add(_ reminder: Reminder) {
        reminders.insert(reminder, at: 0)
        persistAndSync()
    }

    func update(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        persistAndSync()
    }

    /// 履歴に残さず削除（監視解除）。
    func delete(id: UUID) {
        reminders.removeAll { $0.id == id }
        locationMonitor.stopMonitoring(id: id)
        persistAndSync()
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.map { reminders[$0].id }
        reminders.remove(atOffsets: offsets)
        for id in ids {
            locationMonitor.stopMonitoring(id: id)
        }
        persistAndSync()
    }

    /// 手動完了 → 履歴へ保存し監視解除。再通知しない。
    func complete(id: UUID) {
        clearToHistory(id: id, reason: .manual)
    }

    /// 履歴からワンタップ再登録（新しい予定として監視再開）。履歴項目は残す。
    func reregister(from item: ReminderHistoryItem) {
        add(item.asNewReminder())
    }

    func deleteHistory(id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    func resyncMonitoring() {
        locationMonitor.sync(reminders: reminders)
    }

    private func clearToHistory(id: UUID, reason: ReminderClearReason) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        let item = ReminderHistoryItem(from: reminder, reason: reason)
        history.insert(item, at: 0)
        reminders.removeAll { $0.id == id }
        locationMonitor.stopMonitoring(id: id)
        saveHistory()
        persistAndSync()
    }

    private func persistAndSync() {
        save()
        locationMonitor.sync(reminders: reminders)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Keys.reminders) else {
            reminders = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([Reminder].self, from: data)
            reminders = decoded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            reminders = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(reminders)
            UserDefaults.standard.set(data, forKey: Keys.reminders)
        } catch {
            // 端末内保存失敗時はメモリ上の一覧を維持
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Keys.history) else {
            history = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([ReminderHistoryItem].self, from: data)
            history = decoded.sorted { $0.clearedAt > $1.clearedAt }
        } catch {
            history = []
        }
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            UserDefaults.standard.set(data, forKey: Keys.history)
        } catch {
            // 端末内保存失敗時はメモリ上の一覧を維持
        }
    }
}
