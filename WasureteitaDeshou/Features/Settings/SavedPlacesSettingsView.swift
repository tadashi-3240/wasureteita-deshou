import SwiftUI

/// 設定「保存した場所」: 呼び名の編集・削除。
struct SavedPlacesSettingsView: View {
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore

    var body: some View {
        List {
            if savedPlaceStore.places.isEmpty {
                Section {
                    Text("まだありません。予定を登録すると、その場所が呼び名つきでここに残ります。次回の検索候補の先頭に出ます。")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(savedPlaceStore.places) { place in
                        NavigationLink {
                            SavedPlaceEditView(place: place)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(place.displayName)
                                    .font(.system(size: 18, weight: .semibold))
                                if !place.address.isEmpty {
                                    Text(place.address)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let id = savedPlaceStore.places[index].id
                            savedPlaceStore.delete(id: id)
                        }
                    }
                } header: {
                    Text("呼び名")
                        .font(.system(size: 16, weight: .semibold))
                } footer: {
                    Text("左にスワイプで削除。タップで呼び名を編集できます。自宅は別の「自宅を設定」です。")
                        .font(.system(size: 14))
                }
            }
        }
        .navigationTitle("保存した場所")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct SavedPlaceEditView: View {
    @EnvironmentObject private var savedPlaceStore: SavedPlaceStore
    @Environment(\.dismiss) private var dismiss

    let place: SavedPlace
    @State private var nameText: String
    @State private var statusMessage: String?

    init(place: SavedPlace) {
        self.place = place
        _nameText = State(initialValue: place.displayName)
    }

    var body: some View {
        List {
            Section {
                TextField("呼び名（例：水江の製油所）", text: $nameText)
                    .font(.system(size: 20))

                if !place.address.isEmpty {
                    LabeledContent("住所") {
                        Text(place.address)
                            .font(.system(size: 16))
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("緯度") {
                    Text(String(format: "%.5f", place.latitude))
                        .font(.system(size: 16, design: .monospaced))
                }
                LabeledContent("経度") {
                    Text(String(format: "%.5f", place.longitude))
                        .font(.system(size: 16, design: .monospaced))
                }
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
                    savedPlaceStore.delete(id: place.id)
                    dismiss()
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
        .navigationTitle("呼び名を編集")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    NavigationStack {
        SavedPlacesSettingsView()
    }
    .environmentObject(SavedPlaceStore())
}
