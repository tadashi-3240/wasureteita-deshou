import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            RegistrationInputView()
                .tabItem {
                    Label("登録", systemImage: "square.and.pencil")
                }

            ScheduleListView()
                .tabItem {
                    Label("予定一覧", systemImage: "list.bullet")
                }

            HistoryView()
                .tabItem {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape.fill")
                }
        }
        .tint(Color("BrandAccent"))
    }
}

#Preview {
    let monitor = LocationMonitor()
    return RootTabView()
        .environmentObject(DraftUtteranceStore())
        .environmentObject(AppNotifySettings())
        .environmentObject(monitor)
        .environmentObject(ReminderStore(locationMonitor: monitor))
}
