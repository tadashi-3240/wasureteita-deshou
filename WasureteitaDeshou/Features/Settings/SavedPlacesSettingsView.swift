import MapKit
import SwiftUI

/// 設定「保存した場所」: SavedPlace だけの一覧。呼び名・住所・地図プレビュー、編集・削除。
struct SavedPlacesSettingsView: View {
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore
    @State private var showMapPreviews = true

    var body: some View {
        List {
            if savedPlaceStore.places.isEmpty {
                Section {
                    Text("まだありません。予定を登録すると、「金古のセブン」などの呼び名でここに残ります。次回の決定・検索で一意マッチします。")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } else {
                Section {
                    Toggle("地図プレビューを表示", isOn: $showMapPreviews)
                        .font(.system(size: 17))
                } footer: {
                    Text("一覧は登録した場所（SavedPlace）だけです。自宅は「自宅を設定」にあります。")
                        .font(.system(size: 14))
                }

                Section {
                    ForEach(savedPlaceStore.places) { place in
                        NavigationLink {
                            SavedPlaceEditView(place: place)
                        } label: {
                            SavedPlaceRow(place: place, showsMapPreview: showMapPreviews)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let id = savedPlaceStore.places[index].id
                            savedPlaceStore.delete(id: id)
                        }
                    }
                } header: {
                    Text("\(savedPlaceStore.places.count) 件")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("左にスワイプで削除。タップで呼び名の編集と地図確認ができます。")
                        .font(.system(size: 14))
                }
            }
        }
        .navigationTitle("保存した場所")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SavedPlaceRow: View {
    let place: SavedPlace
    let showsMapPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(place.displayName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)

            if !place.address.isEmpty {
                Text(place.address)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if showsMapPreview {
                SavedPlaceMapPreview(place: place, height: 120, interactive: false)
            }
        }
        .padding(.vertical, 6)
    }
}

struct SavedPlaceEditView: View {
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore
    @Environment(\.dismiss) private var dismiss

    let place: SavedPlace
    @State private var nameText: String
    @State private var statusMessage: String?
    @State private var showDeleteConfirm = false

    init(place: SavedPlace) {
        self.place = place
        _nameText = State(initialValue: place.displayName)
    }

    private var currentPlace: SavedPlace {
        savedPlaceStore.places.first(where: { $0.id == place.id }) ?? place
    }

    var body: some View {
        List {
            Section {
                SavedPlaceMapPreview(place: currentPlace, height: 220, interactive: false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            } header: {
                Text("地図")
                    .font(.system(size: 16, weight: .semibold))
            } footer: {
                Text("登録座標の確認用です。ピンの移動は予定一覧の編集から行えます。")
                    .font(.system(size: 14))
            }

            Section {
                TextField("呼び名（例：金古のセブン / 高崎のイオン）", text: $nameText)
                    .font(.system(size: 20))

                if !currentPlace.address.isEmpty {
                    LabeledContent("住所") {
                        Text(currentPlace.address)
                            .font(.system(size: 16))
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("住所") {
                        Text("なし")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("緯度") {
                    Text(String(format: "%.5f", currentPlace.latitude))
                        .font(.system(size: 16, design: .monospaced))
                }
                LabeledContent("経度") {
                    Text(String(format: "%.5f", currentPlace.longitude))
                        .font(.system(size: 16, design: .monospaced))
                }
            } header: {
                Text("場所")
                    .font(.system(size: 16, weight: .semibold))
            }

            Section {
                Button {
                    let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        statusMessage = "呼び名を入力してください。"
                        return
                    }
                    savedPlaceStore.updateDisplayName(id: place.id, displayName: trimmed)
                    statusMessage = "呼び名を保存しました。"
                } label: {
                    Text("呼び名を保存")
                        .font(.system(size: 18, weight: .semibold))
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("この場所を削除")
                        .font(.system(size: 17))
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("場所を編集")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("この場所を削除しますか？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                savedPlaceStore.delete(id: place.id)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(currentPlace.displayName)」を一覧から消します。予定そのものは消えません。")
        }
    }
}

/// SavedPlace 座標の読み取り専用 Map プレビュー。
private struct SavedPlaceMapPreview: View {
    let place: SavedPlace
    var height: CGFloat = 140
    var interactive: Bool = false

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: interactive ? .all : []) {
            Annotation(place.displayName.isEmpty ? "場所" : place.displayName, coordinate: place.coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: height >= 180 ? 34 : 28))
                    .foregroundStyle(Color("BrandAccent"))
                    .shadow(radius: 2, y: 1)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .allowsHitTesting(interactive)
        .accessibilityLabel("\(place.displayName)の地図")
    }
}

#Preview {
    NavigationStack {
        SavedPlacesSettingsView()
    }
    .environmentObject(SavedPlaceStore())
}
