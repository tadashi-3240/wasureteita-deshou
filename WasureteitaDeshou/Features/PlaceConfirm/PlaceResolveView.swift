import CoreLocation
import SwiftUI

/// 「次へ」のあと: 場所／用事の表示 → MapKit 検索 → 一意／候補／地図。
struct PlaceResolveView: View {
    let rawText: String
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

    private let search = PlaceSearchService()

    enum Phase: Equatable {
        case review
        case searching
        case candidates
        case map
        case confirm
        case saved
    }

    init(rawText: String, onFinished: (() -> Void)? = nil) {
        self.rawText = rawText
        self.onFinished = onFinished
        let parsed = UtteranceParser.parse(rawText)
        _editablePlace = State(initialValue: parsed.placePhrase)
        _editableTask = State(initialValue: parsed.taskPhrase)
    }

    var body: some View {
        Group {
            switch phase {
            case .review, .searching:
                reviewContent
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
    }

    private var phaseNavigationTitle: String {
        switch phase {
        case .review, .searching: return "内容の確認"
        case .candidates: return "場所の候補"
        case .map: return "地図から指定"
        case .confirm: return "登録の確認"
        case .saved: return "登録完了"
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                        .disabled(phase == .searching)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("用事")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("例：牛乳を買う", text: $editableTask)
                        .font(.system(size: 22))
                        .textFieldStyle(.roundedBorder)
                        .disabled(phase == .searching)
                }

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
                             : "場所を検索して進む")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandAccent"))
                    .disabled(editableTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !editablePlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("検索せず地図から指定") {
                            phase = .map
                        }
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
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
                        phase = .map
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
            do {
                let results = try await search.search(
                    query: place,
                    near: near,
                    savedPlaces: savedPlaceStore.places
                )
                candidates = results
                if results.isEmpty {
                    phase = .map
                } else if results.count == 1 {
                    selected = results[0]
                    phase = .confirm
                } else {
                    phase = .candidates
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .review
            }
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
