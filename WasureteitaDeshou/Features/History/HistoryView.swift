import SwiftUI

/// 解除済み予定の履歴。ワンタップで再登録（監視再開）。
struct HistoryView: View {
    @EnvironmentObject private var reminderStore: ReminderStore

    var body: some View {
        NavigationStack {
            Group {
                if reminderStore.history.isEmpty {
                    ContentUnavailableView {
                        Label("履歴はまだありません", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("店舗付近に約1分滞在して自動解除されたものや、予定一覧で完了したものがここに残ります。")
                            .font(.system(size: 18))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        ForEach(reminderStore.history) { item in
                            HistoryRow(item: item) {
                                reminderStore.reregister(from: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    reminderStore.deleteHistory(id: item.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct HistoryRow: View {
    let item: ReminderHistoryItem
    let onReregister: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.task)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)

            Text(item.placeName)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("登録 \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("解除 \(item.clearedAt.formatted(date: .abbreviated, time: .shortened))・\(reasonLabel)")
            }
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)

            Button(action: onReregister) {
                Text("再登録")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccent"))
            .accessibilityHint("同じ場所と用事で予定を登録し、監視を再開します")
        }
        .padding(.vertical, 8)
    }

    private var reasonLabel: String {
        switch item.clearReason {
        case .autoDwell: return "自動解除"
        case .manual: return "手動完了"
        }
    }
}

#Preview {
    let monitor = LocationMonitor()
    return HistoryView()
        .environmentObject(ReminderStore(locationMonitor: monitor))
}
