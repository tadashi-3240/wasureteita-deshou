import SwiftUI

/// 登録済み予定の一覧（簡易編集・削除・手動完了・通知距離）。手動完了は履歴へ。
struct ScheduleListView: View {
    @EnvironmentObject private var reminderStore: ReminderStore
    @State private var editing: Reminder?

    var body: some View {
        NavigationStack {
            Group {
                if reminderStore.reminders.isEmpty {
                    ContentUnavailableView {
                        Label("予定はまだありません", systemImage: "list.bullet")
                    } description: {
                        Text("「登録」タブで文章を入力し、場所を決めるとここに表示されます。")
                            .font(.system(size: 18))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        ForEach(reminderStore.reminders) { reminder in
                            Button {
                                editing = reminder
                            } label: {
                                ReminderRow(reminder: reminder)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    reminderStore.delete(id: reminder.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    reminderStore.complete(id: reminder.id)
                                } label: {
                                    Label("完了", systemImage: "checkmark")
                                }
                                .tint(Color("BrandAccent"))
                            }
                        }
                        .onDelete(perform: reminderStore.delete(at:))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("予定一覧")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $editing) { reminder in
                ReminderEditView(reminder: reminder) { updated in
                    reminderStore.update(updated)
                } onComplete: {
                    reminderStore.complete(id: reminder.id)
                } onDelete: {
                    reminderStore.delete(id: reminder.id)
                }
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reminder.task)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
            Text(reminder.placeName)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            if !reminder.address.isEmpty {
                Text(reminder.address)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            Text("通知 約\(reminder.notifyDistanceMeters) m ・ \(reminder.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReminderEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var placeName: String
    @State private var task: String
    @State private var notifyDistance: Int
    let original: Reminder
    let onSave: (Reminder) -> Void
    let onComplete: () -> Void
    let onDelete: () -> Void

    init(
        reminder: Reminder,
        onSave: @escaping (Reminder) -> Void,
        onComplete: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        original = reminder
        _placeName = State(initialValue: reminder.placeName)
        _task = State(initialValue: reminder.task)
        _notifyDistance = State(initialValue: AppNotifySettings.clamp(reminder.notifyDistanceMeters))
        self.onSave = onSave
        self.onComplete = onComplete
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("用事") {
                    TextField("用事", text: $task)
                        .font(.system(size: 20))
                }
                Section("場所名") {
                    TextField("場所名", text: $placeName)
                        .font(.system(size: 20))
                }
                Section {
                    Picker("通知距離", selection: $notifyDistance) {
                        Text("300 m").tag(300)
                        Text("500 m").tag(500)
                        Text("1000 m").tag(1000)
                    }
                    .font(.system(size: 18))
                    Text("GPS の都合で実際の通知位置は前後します。正確な距離は保証しません。")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("近づいたら通知")
                }
                Section {
                    Button("完了して履歴へ") {
                        onComplete()
                        dismiss()
                    }
                    .font(.system(size: 18))
                    Button("削除（履歴に残さない）", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                    .font(.system(size: 18))
                }
            }
            .navigationTitle("予定を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = original
                        updated.placeName = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.notifyDistanceMeters = notifyDistance
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    let monitor = LocationMonitor()
    return ScheduleListView()
        .environmentObject(ReminderStore(locationMonitor: monitor))
}
