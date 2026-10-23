import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var notifySettings: AppNotifySettings
    @EnvironmentObject private var locationMonitor: LocationMonitor
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var homeStore: HomePlaceStore
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore

    @State private var testNotifyMessage: String?
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("build: stage5-speech-3")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("入力は登録タブのテキスト欄で行います。音声を使う場合は、キーボードのマイク（音声入力）を選んでください。アプリ独自の巨大マイク画面はありません。")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } header: {
                    Text("入力について")
                        .font(.system(size: 16, weight: .semibold))
                }

                Section {
                    NavigationLink {
                        HomePlaceSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("自宅を設定")
                                .font(.system(size: 18, weight: .semibold))
                            if let home = homeStore.home {
                                Text(home.address.isEmpty
                                     ? "\(home.name)（位置あり）"
                                     : "\(home.name) — \(home.address)")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未設定。「帰ったら洗濯」などの用事に使います。")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("自宅")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("店舗だけでなく自宅を場所にして、自分用の用事を通知できます。データは端末内のみです。")
                        .font(.system(size: 14))
                }

                Section {
                    NavigationLink {
                        SavedPlacesSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("保存した場所")
                                .font(.system(size: 18, weight: .semibold))
                            if savedPlaceStore.places.isEmpty {
                                Text("予定を登録すると呼び名で覚えて、次回の検索候補に出ます。")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(savedPlaceStore.places.count) 件（タップで呼び名の編集・削除）")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("呼び名")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("自宅とは別です。「水江の製油所」など、一度登録した場所を部分一致で候補の先頭に出します。")
                        .font(.system(size: 14))
                }

                Section {
                    Picker("通知する距離", selection: $notifySettings.defaultNotifyDistanceMeters) {
                        Text("300 m").tag(300)
                        Text("500 m").tag(500)
                        Text("1000 m").tag(1000)
                    }
                    .font(.system(size: 18))

                    Text("新しく登録する予定の初期値です。各予定の編集画面でも変更できます。GPS や電波の都合で、実際に通知される距離は前後することがあり、正確な距離は保証しません。")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } header: {
                    Text("位置通知")
                        .font(.system(size: 16, weight: .semibold))
                }

                Section {
                    LabeledContent("位置情報") {
                        Text(locationStatusLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(locationStatusColor)
                    }

                    LabeledContent("通知") {
                        Text(notificationStatusLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(notificationStatusColor)
                    }

                    LabeledContent("監視中の領域") {
                        Text("\(locationMonitor.monitoredRegionCount) 件")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("滞在計測中") {
                        Text("\(locationMonitor.dwellTrackingCount) 件")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }

                    if locationMonitor.authorizationStatus != .authorizedAlways {
                        Text("バックグラウンドで近づいたことを確実に知らせるには、位置情報を「常に」にしてください。「利用中のみ」だとアプリを閉じているときの進入検知が弱くなります。")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.vertical, 4)
                    }

                    if notificationAuthStatus == .denied {
                        Text("許可されていません。iPhone設定→通知→忘れていたでしょう、でオンにしてください。")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.vertical, 4)
                    }

                    Button("位置情報を「常に」にする") {
                        locationMonitor.requestWhenInUse()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            locationMonitor.requestAlways()
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))

                    Button("通知の許可を求める") {
                        Task {
                            _ = await ReminderNotifier().requestAuthorization()
                            await refreshNotificationAuthStatus()
                            if notificationAuthStatus == .denied {
                                testNotifyMessage = "許可されていません。iPhone設定→通知→忘れていたでしょう、でオンにしてください。"
                            } else if notificationAuthStatus == .authorized || notificationAuthStatus == .provisional {
                                testNotifyMessage = "通知は許可されています。"
                            }
                        }
                    }
                    .font(.system(size: 17))

                    Button("テスト通知を送る") {
                        Task {
                            await sendTestNotification()
                        }
                    }
                    .font(.system(size: 17))

                    Button("圏内を再判定") {
                        // sync 末尾で requestState 一括（二重呼び出ししない）
                        reminderStore.resyncMonitoring()
                        testNotifyMessage = "監視を再同期し、圏内かどうかを問い合わせました。"
                    }
                    .font(.system(size: 17))

                    if let msg = testNotifyMessage {
                        Text(msg)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }

                    if let err = locationMonitor.lastErrorMessage {
                        Text(err)
                            .font(.system(size: 15))
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("権限・動作確認")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("バックグラウンドでも知らせるには、設定アプリでこのアプリの位置情報を「常に」にしてください。iOS の領域監視（ジオフェンス）は、進入・退出の検知に数分かかることがあります。すぐ反応しない場合は「圏内を再判定」を試すか、しばらく待ってください。アプリ前面でもテスト通知のバナーが出ます。")
                        .font(.system(size: 14))
                }

                Section {
                    Text("店舗付近（目安 50〜100m）に約1分滞在すると、予定を自動解除して履歴へ移し、同じ予定は再通知しません。領域の進入・退出と、滞在中だけの限定的な位置更新で判定します。バックグラウンドでは正確な1分を保証できません（アプリが起きていないと計測が遅れることがあります）。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } header: {
                    Text("自動解除（滞在）")
                        .font(.system(size: 16, weight: .semibold))
                }

                Section {
                    Toggle("接近時に読み上げる", isOn: $notifySettings.speechEnabled)
                        .font(.system(size: 18, weight: .semibold))

                    Text("アプリが前面にあるとき、接近通知の表示に合わせて「忘れていたでしょう？○○予定ですよ！」を読み上げます（既定はオン）。バックグラウンドやロック画面では、iOS の制約で読み上げは保証できません。その場合は通知音と文字が基本です。")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    if SpeechVoiceStyle.availableStyles.isEmpty {
                        Text("この端末では日本語の読み上げ声が見つかりません。")
                            .font(.system(size: 15))
                            .foregroundStyle(.orange)
                    } else {
                        Picker("声の種類", selection: $notifySettings.speechVoiceStyle) {
                            ForEach(SpeechVoiceStyle.availableStyles) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .font(.system(size: 18))

                        if !resolvedVoiceLabel.isEmpty {
                            Text("いま使う声: \(resolvedVoiceLabel)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("読み上げテスト") {
                        ApproachSpeechSynthesizer.shared.speakTest()
                        testNotifyMessage = "読み上げを再生しました（設定のオン／オフに関係なくテストします）。"
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .disabled(SpeechVoiceStyle.availableStyles.isEmpty)
                } header: {
                    Text("音声読み上げ")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("クラウド音声合成は使いません。端末の AVSpeechSynthesizer（日本語）のみです。使える声は iOS／端末依存です（未ダウンロードの声は候補から外れ、近い声にフォールバックします）。")
                        .font(.system(size: 14))
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                locationMonitor.refreshAuthorizationStatus()
                Task { await refreshNotificationAuthStatus() }
            }
        }
    }

    private var resolvedVoiceLabel: String {
        ApproachSpeechSynthesizer.resolvedVoiceDisplayName(for: notifySettings.speechVoiceStyle)
    }

    private func refreshNotificationAuthStatus() async {
        notificationAuthStatus = await ReminderNotifier().authorizationStatus()
    }

    private func sendTestNotification() async {
        let notifier = ReminderNotifier()
        var status = await notifier.authorizationStatus()

        if status == .notDetermined {
            _ = await notifier.requestAuthorization()
            status = await notifier.authorizationStatus()
        }

        notificationAuthStatus = status

        switch status {
        case .denied, .notDetermined:
            testNotifyMessage = "許可されていません。iPhone設定→通知→忘れていたでしょう、でオンにしてください。"
            return
        default:
            break
        }

        notifier.postTestNotification { success, errorMessage in
            if success {
                testNotifyMessage = "テスト通知を送りました。バナーが出ない場合は、上の通知ステータスを確認してください。"
            } else {
                testNotifyMessage = errorMessage ?? "テスト通知に失敗しました。"
            }
        }
    }

    private var locationStatusLabel: String {
        switch locationMonitor.authorizationStatus {
        case .authorizedAlways: return "常に許可"
        case .authorizedWhenInUse: return "利用中のみ（常に推奨）"
        case .denied: return "拒否"
        case .restricted: return "制限あり"
        case .notDetermined: return "未設定"
        @unknown default: return "不明"
        }
    }

    private var locationStatusColor: Color {
        switch locationMonitor.authorizationStatus {
        case .authorizedAlways: return .secondary
        case .authorizedWhenInUse: return .orange
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private var notificationStatusLabel: String {
        switch notificationAuthStatus {
        case .authorized: return "許可"
        case .provisional: return "仮許可"
        case .ephemeral: return "一時許可"
        case .denied: return "拒否"
        case .notDetermined: return "未設定"
        @unknown default: return "不明"
        }
    }

    private var notificationStatusColor: Color {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral: return .secondary
        case .denied: return .red
        case .notDetermined: return .orange
        @unknown default: return .secondary
        }
    }
}

#Preview {
    let monitor = LocationMonitor()
    return SettingsView()
        .environmentObject(AppNotifySettings())
        .environmentObject(monitor)
        .environmentObject(ReminderStore(locationMonitor: monitor))
        .environmentObject(HomePlaceStore())
        .environmentObject(SavedPlaceStore())
}
