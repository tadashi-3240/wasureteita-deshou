import CoreLocation
import SwiftUI

/// 「次へ」のあと: 内容確認 → 決定 →（必要なら場所の決め方／候補／地図）→ 場所が決まったら即保存 → 完了。
struct PlaceResolveView: View {
    let rawText: String
    let knownPlaceNames: [String]
    var onFinished: (() -> Void)?

    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var draftStore: DraftUtteranceStore
    @EnvironmentObject private var homeStore: HomePlaceStore
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore
    @EnvironmentObject private var notifySettings: AppNotifySettings

    @StateObject private var locationProvider = UserLocationProvider()

    @State private var editablePlace: String
    @State private var editableTask: String
    @State private var phase: Phase = .review
    @State private var candidates: [PlaceCandidate] = []
    @State private var selected: PlaceCandidate?
    @State private var errorMessage: String?
    @State private var didRefineParse = false

    private let search = PlaceSearchService()
    private static let buildTag = "build: stage5-speech-7"

    enum Phase: Equatable {
        case review
        case placeMethod
        case searching
        case candidates
        case map
        case saved
    }

    init(rawText: String, knownPlaceNames: [String] = [], onFinished: (() -> Void)? = nil) {
        self.rawText = rawText
        self.knownPlaceNames = knownPlaceNames
        self.onFinished = onFinished
        let parsed = UtteranceParser.parse(rawText, knownPlaceNames: knownPlaceNames)
        _editablePlace = State(initialValue: parsed.placePhrase)
        _editableTask = State(initialValue: parsed.taskPhrase)
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
                        finishWithPlace(candidate)
                    },
                    onPickOnMap: {
                        phase = .map
                    }
                )
            case .map:
                MapPlacePickerView(
                    initialCoordinate: locationProvider.coordinate,
                    suggestedNickname: editablePlace,
                    requiresNickname: true,
                    onConfirm: { candidate in
                        editablePlace = candidate.name
                        finishWithPlace(candidate)
                    }
                )
            case .saved:
                savedContent
            }
        }
        .navigationTitle(phaseNavigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            guard !didRefineParse, phase == .review else { return }
            didRefineParse = true
            let names = Array(Set(knownPlaceNames + savedPlaceStore.places.map(\.displayName)))
            guard !names.isEmpty else { return }
            let parsed = UtteranceParser.parse(rawText, knownPlaceNames: names)
            editablePlace = parsed.placePhrase
            editableTask = parsed.taskPhrase
        }
    }

    private var phaseNavigationTitle: String {
        switch phase {
        case .review: return "内容の確認"
        case .placeMethod, .searching: return "場所の決め方"
        case .candidates: return "場所の候補"
        case .map: return "地図で場所を登録"
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

                Text("入力した文章")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(rawText)
                    .font(.system(size: 22, weight: .medium))

                VStack(alignment: .leading, spacing: 8) {
                    Text("場所")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("例：金古のセブンイレブン", text: $editablePlace)
                        .font(.system(size: 22))
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("用事")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("例：牛乳を買う", text: $editableTask)
                        .font(.system(size: 22))
                        .textFieldStyle(.roundedBorder)
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
                .disabled(editableTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 8)

                Text("用事は必須です。「決定」で場所が決まればそのまま登録します。距離は設定のデフォルト（予定一覧で変更可）。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
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

                labeled("場所", editablePlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "（未入力・次で指定）"
                        : editablePlace)
                labeled("用事", editableTask)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                }

                if phase == .searching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("場所を検索しています…")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else {
                    let placeEmpty = editablePlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    if placeEmpty {
                        Button {
                            phase = .map
                        } label: {
                            Text("地図で場所を登録")
                                .font(.system(size: 22, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("BrandAccent"))

                        Text("場所の呼び名がわからないときは、地図でピンを置き、呼び名をつけて登録します。")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: startSearch) {
                            Text("場所を検索")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("BrandAccent"))

                        Button {
                            phase = .map
                        } label: {
                            Text("地図で場所を登録")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("BrandAccent"))
                        .padding(.top, 4)

                        Text("検索で見つからないときは、地図でピンと呼び名を登録できます。")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        phase = .review
                        errorMessage = nil
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

    private var savedContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color("BrandAccent"))
            Text("予定を登録しました")
                .font(.system(size: 26, weight: .bold))
            Text("「予定一覧」から確認・編集・削除できます。")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("登録に戻る") {
                draftStore.clearAll()
                onFinished?()
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

    /// 場所欄が SavedPlace に一意マッチなら即保存。複数なら候補。それ以外は場所の決め方。
    private func confirmContents() {
        errorMessage = nil
        let task = editableTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            errorMessage = "用事を入力してください。"
            return
        }
        let place = editablePlace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            switch savedPlaceStore.resolveForDecide(query: place) {
            case .unique(let saved):
                let candidate = saved.asPlaceCandidate()
                candidates = [candidate]
                finishWithPlace(candidate)
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
        let place = editablePlace.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = editableTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        if place.isEmpty {
            phase = .map
            return
        }

        phase = .searching
        // 位置許可は検索開始時のみ（初期描画ではリクエストしない）
        locationProvider.requestWhenInUseIfNeeded()
        Task {
            let near = await locationProvider.currentCoordinate()
            let savedSnapshot = savedPlaceStore.places
            do {
                let results = try await search.search(
                    query: place,
                    near: near,
                    savedPlaces: savedSnapshot
                )
                applySearchResults(results)
            } catch {
                let savedOnly = savedSnapshot
                    .filter { $0.matchesQuery(place) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { $0.asPlaceCandidate() }
                if !savedOnly.isEmpty {
                    applySearchResults(savedOnly)
                } else {
                    errorMessage = error.localizedDescription
                    phase = .placeMethod
                }
            }
        }
    }

    private func applySearchResults(_ results: [PlaceCandidate]) {
        candidates = results
        if results.isEmpty {
            phase = .map
        } else if results.count == 1 {
            finishWithPlace(results[0])
        } else {
            phase = .candidates
        }
    }

    private func finishWithPlace(_ candidate: PlaceCandidate) {
        selected = candidate
        saveReminder()
    }

    private func saveReminder() {
        guard let selected else { return }
        let reminder = Reminder(
            placeName: selected.name,
            address: selected.address,
            task: editableTask.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: selected.latitude,
            longitude: selected.longitude,
            rawUtterance: rawText,
            notifyDistanceMeters: notifySettings.defaultNotifyDistanceMeters
        )
        reminderStore.add(reminder)
        rememberPlaceIfNeeded(selected)
        phase = .saved
    }

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
