import CoreLocation
import SwiftUI

/// 「次へ」のあと: 内容確認 → 決定 → 場所の決め方 → MapKit 検索 → 一意／候補／地図。
struct PlaceResolveView: View {
    let rawText: String
    let knownPlaceNames: [String]
    var onFinished: (() -> Void)?

    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var draftStore: DraftUtteranceStore
    @EnvironmentObject private var homeStore: HomePlaceStore
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore

    @StateObject private var locationProvider = UserLocationProvider()

    @State private var editablePlace: String
    @State private var editableTask: String
    @State private var phase: Phase = .review
    @State private var candidates: [PlaceCandidate] = []
    @State private var selected: PlaceCandidate?
    @State private var errorMessage: String?
    @State private var didRefineParse = false

    private let search = PlaceSearchService()
    private static let buildTag = "build: stage5-nickname-2"

    enum Phase: Equatable {
        case review
        case placeMethod
        case searching
        case candidates
        case map
        case confirm
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
                confirmContent
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

                Text("用事は必須です。場所が空でも、次の画面で地図から指定できます。")
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
                    Button(action: startSearch) {
                        Text(editablePlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "地図から場所を指定"
                             : "場所を検索")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandAccent"))

                    if !editablePlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("地図から指定") {
                            phase = .map
                        }
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
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

    private var confirmContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let selected {
                    labeled("場所", selected.name)
                    if !selected.address.isEmpty {
                        labeled("住所", selected.address)
                    }
                }
                labeled("用事", editableTask)

                Text("近づいたときの通知は第3段階で追加します。今は予定として端末内に保存します。")
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
                    if candidates.count > 1 {
                        phase = .candidates
                    } else {
                        phase = .placeMethod
                    }
                }
                .font(.system(size: 17))
                .frame(maxWidth: .infinity)
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

    /// 場所欄が SavedPlace に一意マッチなら確認へ直行。複数なら候補。それ以外は場所の決め方。
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
            selected = results[0]
            phase = .confirm
        } else {
            phase = .candidates
        }
    }

    private func saveReminder() {
        guard let selected else { return }
        let reminder = Reminder(
            placeName: selected.name,
            address: selected.address,
            task: editableTask.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: selected.latitude,
            longitude: selected.longitude,
            rawUtterance: rawText
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
