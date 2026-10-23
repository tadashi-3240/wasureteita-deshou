import CoreLocation
import SwiftUI

/// 内容確認 → 決定 → 場所の決め方（店舗検索／自宅／地図）→ 候補／地図 → 予定保存。
struct SimpleUtteranceConfirmView: View {
    let rawText: String
    let knownPlaceNames: [String]
    var onBack: () -> Void

    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var draftStore: DraftUtteranceStore
    @EnvironmentObject private var notifySettings: AppNotifySettings
    @EnvironmentObject private var locationMonitor: LocationMonitor
    @EnvironmentObject private var homeStore: HomePlaceStore
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore

    @StateObject private var locationProvider = UserLocationProvider()

    @State private var placeText: String
    @State private var taskText: String
    @State private var suggestsHome: Bool
    @State private var phase: Phase = .review
    @State private var candidates: [PlaceCandidate] = []
    @State private var selected: PlaceCandidate?
    @State private var errorMessage: String?
    @State private var showPermissionSheet = false
    @State private var pendingSaveAfterPermission = false
    @State private var isResolvingHome = false
    @State private var homeHintMessage: String?
    @State private var didRefineParse = false

    private let search = PlaceSearchService()
    private static let buildTag = "build: stage5-nickname-2"

    private enum Phase: Equatable {
        case review
        case placeMethod
        case searching
        case candidates
        case map
        case confirm
        case saved
    }

    init(rawText: String, knownPlaceNames: [String] = [], onBack: @escaping () -> Void) {
        self.rawText = rawText
        self.knownPlaceNames = knownPlaceNames
        self.onBack = onBack
        let parsed = UtteranceParser.parse(rawText, knownPlaceNames: knownPlaceNames)
        _placeText = State(initialValue: parsed.placePhrase)
        _taskText = State(initialValue: parsed.taskPhrase)
        _suggestsHome = State(initialValue: parsed.suggestsHome)
    }

    var body: some View {
        Group {
            switch phase {
            case .review:
                reviewContent
            case .placeMethod, .searching:
                placeMethodContent
            case .candidates:
                PlaceCandidateListView(
                    candidates: candidates,
                    onSelect: { candidate in
                        selected = candidate
                        phase = .confirm
                    },
                    onPickOnMap: {
                        phase = .map
                    }
                )
            case .map:
                MapPlacePickerView(
                    initialCoordinate: locationProvider.coordinate,
                    onConfirm: { candidate in
                        selected = candidate
                        phase = .confirm
                    }
                )
            case .confirm:
                registerConfirmContent
            case .saved:
                savedContent
            }
        }
        .navigationTitle(phaseTitle)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showPermissionSheet) {
            LocationNotifyPermissionView {
                showPermissionSheet = false
                if pendingSaveAfterPermission {
                    pendingSaveAfterPermission = false
                    commitReminder()
                }
            }
            .environmentObject(locationMonitor)
        }
        .onAppear {
            refineParseWithSavedPlacesIfNeeded()
        }
    }

    /// init 時点で EnvironmentObject が無い場合に備え、SavedPlace 呼び名で再分割（手編集前の1回のみ）。
    private func refineParseWithSavedPlacesIfNeeded() {
        guard !didRefineParse, phase == .review else { return }
        didRefineParse = true
        let names = Array(Set(knownPlaceNames + savedPlaceStore.places.map(\.displayName)))
        guard !names.isEmpty else { return }
        let parsed = UtteranceParser.parse(rawText, knownPlaceNames: names)
        placeText = parsed.placePhrase
        taskText = parsed.taskPhrase
        suggestsHome = parsed.suggestsHome
    }

    private var phaseTitle: String {
        switch phase {
        case .review: return "内容の確認"
        case .placeMethod, .searching: return "場所の決め方"
        case .candidates: return "場所の候補"
        case .map: return "地図から指定"
        case .confirm: return "登録の確認"
        case .saved: return "登録完了"
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Self.buildTag)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("内容の確認")
                    .font(.system(size: 28, weight: .bold))

                Text("場所と用事を確認し、「決定」で次に進みます。")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)

                Text("入力した文章")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(rawText)
                    .font(.system(size: 22, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("場所")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("例：金古のセブンイレブン / 自宅", text: $placeText)
                        .font(.system(size: 22))
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("用事")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("例：牛乳を買う / 洗濯をする", text: $taskText)
                        .font(.system(size: 22))
                        .textFieldStyle(.roundedBorder)
                }

                if suggestsHome {
                    Text("「自宅」「帰ったら」などの言い回しです。決定のあと「自宅を使う」が向いています。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                }

                Button(action: confirmContents) {
                    Text("決定")
                        .font(.system(size: 24, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccent"))
                .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 8)

                Text("用事は必須です。場所が空でも、次の画面で自宅や地図から指定できます。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                Button(action: onBack) {
                    Text("戻る")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
        }
    }

    private var placeMethodContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Self.buildTag)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("場所の決め方")
                    .font(.system(size: 28, weight: .bold))

                labeled("場所", placeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "（未入力・次で指定）"
                        : placeText)
                labeled("用事", taskText)

                if suggestsHome {
                    Text("「自宅」「帰ったら」などの言い回しなので、「自宅を使う」が向いています。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                if let homeHintMessage {
                    Text(homeHintMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                }

                if phase == .searching || isResolvingHome {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(phase == .searching ? "お店の候補を探しています…" : "自宅の位置を用意しています…")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else {
                    Button(action: startSearch) {
                        Text("店舗を検索")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandAccent"))
                    .disabled(placeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await useHomePlace() }
                    } label: {
                        Text(homeStore.isConfigured ? "自宅を使う" : "自宅を使う（未設定）")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(suggestsHome ? Color("BrandAccent") : Color.gray)

                    if homeStore.isConfigured, let home = homeStore.home {
                        Text("登録済みの自宅: \(home.name)" + (home.address.isEmpty ? "" : "（\(home.address)）"))
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未設定のときは、いまの位置を自宅にするか、設定タブの「自宅を設定」から地図で指定できます。")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }

                    Button("地図から指定") {
                        phase = .map
                    }
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity)

                    Button {
                        phase = .review
                        errorMessage = nil
                        homeHintMessage = nil
                    } label: {
                        Text("内容をやり直す")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
    }

    private var registerConfirmContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Self.buildTag)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if let selected {
                    labeled("場所", selected.name)
                    if !selected.address.isEmpty {
                        labeled("住所", selected.address)
                    }
                }
                labeled("用事", taskText)
                labeled("通知距離", "\(notifySettings.defaultNotifyDistanceMeters) m（設定で変更可）")

                Text("登録すると、この距離の目安で近づいたときに通知します（正確な距離は保証しません）。")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                Button(action: saveReminder) {
                    Text("予定に登録する")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccent"))
                .disabled(selected == nil)

                Button("場所を選び直す") {
                    selected = nil
                    phase = .placeMethod
                }
                .font(.system(size: 17))
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    private var savedContent: some View {
        VStack(spacing: 24) {
            Text(Self.buildTag)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color("BrandAccent"))
            Text("予定を登録しました")
                .font(.system(size: 26, weight: .bold))
            Text("場所に近づくと「忘れていたでしょう？」と通知します。「予定一覧」から距離の変更・削除ができます。")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("登録に戻る") {
                draftStore.clearAll()
                onBack()
            }
            .font(.system(size: 20, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccent"))

            Spacer()
        }
        .padding(28)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .medium))
        }
    }

    /// 内容確認済み。場所欄が SavedPlace に一意マッチなら確認へ直行。複数なら候補。それ以外は場所の決め方。
    private func confirmContents() {
        errorMessage = nil
        homeHintMessage = nil
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            errorMessage = "用事を入力してください。"
            return
        }
        let place = placeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            switch savedPlaceStore.resolveForDecide(query: place) {
            case .unique(let saved):
                let candidate = saved.asPlaceCandidate()
                selected = candidate
                candidates = [candidate]
                phase = .confirm
                return
            case .multiple(let savedList):
                candidates = savedList.map { $0.asPlaceCandidate() }
                selected = nil
                phase = .candidates
                return
            case .none:
                break
            }
        }
        phase = .placeMethod
    }

    private func startSearch() {
        errorMessage = nil
        homeHintMessage = nil
        let place = placeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        if place.isEmpty {
            phase = .map
            return
        }

        phase = .searching
        locationProvider.requestWhenInUseIfNeeded()
        Task {
            let near = await locationProvider.currentCoordinate()
            let savedSnapshot = savedPlaceStore.places
            do {
                let results = try await search.searchPlaceCandidates(
                    placePhrase: place,
                    near: near,
                    savedPlaces: savedSnapshot
                )
                candidates = results
                applySearchResults(results, placePhrase: place)
            } catch {
                // サービス側でも SavedPlace を返す想定だが、万一の通信エラー時は呼び名だけで続行
                let savedOnly = savedSnapshot
                    .filter { $0.matchesQuery(place) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { $0.asPlaceCandidate() }
                if !savedOnly.isEmpty {
                    candidates = savedOnly
                    applySearchResults(savedOnly, placePhrase: place)
                } else {
                    errorMessage = error.localizedDescription
                    phase = .placeMethod
                }
            }
        }
    }

    /// 2件以上 → 必ず一覧。チェーンは1件でも一覧（勝手に確定しない）。
    /// SavedPlace のみ1件／非チェーンの MapKit 1件 → 確認へ。SavedPlace が空でも MapKit 空なら地図へ。
    private func applySearchResults(_ results: [PlaceCandidate], placePhrase: String) {
        if results.isEmpty {
            phase = .map
            return
        }
        let onlySaved = results.count == 1 && results[0].id.hasPrefix("saved|")
        let isChain = PlaceSearchService.isLikelyChain(placePhrase)
        if results.count == 1 && (onlySaved || !isChain) {
            selected = results[0]
            phase = .confirm
            return
        }
        candidates = results
        phase = .candidates
    }

    private func useHomePlace() async {
        errorMessage = nil
        homeHintMessage = nil
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        if let home = homeStore.home {
            placeText = home.name
            selected = home.asPlaceCandidate()
            phase = .confirm
            return
        }

        // 未設定 → その場でいまの位置を自宅にし、続けて登録確認へ
        isResolvingHome = true
        defer { isResolvingHome = false }

        locationProvider.requestWhenInUseIfNeeded()
        guard let coordinate = await locationProvider.currentCoordinate() else {
            homeHintMessage = "自宅が未設定で、いまの位置も取れませんでした。設定タブの「自宅を設定」から地図で指定するか、位置情報を許可してもう一度「自宅を使う」を押してください。"
            return
        }

        let resolved = await search.reverseGeocode(coordinate: coordinate)
        let home = HomePlace(
            name: "自宅",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: resolved.address
        )
        homeStore.save(home)
        placeText = home.name
        selected = home.asPlaceCandidate()
        homeHintMessage = nil
        phase = .confirm
    }

    private func saveReminder() {
        guard selected != nil else { return }
        locationMonitor.refreshAuthorizationStatus()
        if locationMonitor.authorizationStatus != .authorizedAlways {
            pendingSaveAfterPermission = true
            showPermissionSheet = true
            return
        }
        commitReminder()
    }

    private func commitReminder() {
        guard let selected else { return }
        let reminder = Reminder(
            placeName: selected.name,
            address: selected.address,
            task: taskText.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: selected.latitude,
            longitude: selected.longitude,
            rawUtterance: rawText,
            notifyDistanceMeters: notifySettings.defaultNotifyDistanceMeters
        )
        reminderStore.add(reminder)
        rememberPlaceIfNeeded(selected)
        phase = .saved
    }

    /// 自宅以外を SavedPlace に upsert。自宅は二重保存しない。
    private func rememberPlaceIfNeeded(_ place: PlaceCandidate) {
        if place.id.hasPrefix("home|") { return }
        if let home = homeStore.home {
            let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if homeLoc.distance(from: placeLoc) <= SavedPlaceStore.proximityMeters {
                return
            }
        }
        savedPlaceStore.upsertFromRegistration(
            displayName: place.name,
            address: place.address,
            latitude: place.latitude,
            longitude: place.longitude
        )
    }
}

#Preview {
    let monitor = LocationMonitor()
    return NavigationStack {
        SimpleUtteranceConfirmView(rawText: "帰ったら洗濯をする") {}
    }
    .environmentObject(DraftUtteranceStore())
    .environmentObject(AppNotifySettings())
    .environmentObject(monitor)
    .environmentObject(ReminderStore(locationMonitor: monitor))
    .environmentObject(HomePlaceStore())
    .environmentObject(SavedPlaceStore())
}
