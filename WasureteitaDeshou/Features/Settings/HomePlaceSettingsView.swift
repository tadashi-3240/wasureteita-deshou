import CoreLocation
import SwiftUI

/// 設定タブ内の「自宅を設定」。いまの位置 / 地図ピン。
struct HomePlaceSettingsView: View {
    @EnvironmentObject private var homeStore: HomePlaceStore

    @StateObject private var locationProvider = UserLocationProvider()

    @State private var nameText = "自宅"
    @State private var statusMessage: String?
    @State private var isCapturingLocation = false
    @State private var showMapPicker = false
    @State private var pendingMapSeed: CLLocationCoordinate2D?

    private let search = PlaceSearchService()

    var body: some View {
        List {
            Section {
                TextField("名前（例：自宅）", text: $nameText)
                    .font(.system(size: 20))

                if let home = homeStore.home {
                    LabeledContent("緯度") {
                        Text(String(format: "%.5f", home.latitude))
                            .font(.system(size: 16, design: .monospaced))
                    }
                    LabeledContent("経度") {
                        Text(String(format: "%.5f", home.longitude))
                            .font(.system(size: 16, design: .monospaced))
                    }
                    if !home.address.isEmpty {
                        LabeledContent("住所") {
                            Text(home.address)
                                .font(.system(size: 16))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    Text("まだ自宅は未設定です。いまの位置を使うか、地図でピンを置いてください。")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("自宅")
                    .font(.system(size: 16, weight: .semibold))
            }

            Section {
                Button {
                    Task { await captureCurrentLocationAsHome() }
                } label: {
                    if isCapturingLocation {
                        HStack {
                            ProgressView()
                            Text("位置を取得しています…")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    } else {
                        Text("いまの位置を自宅にする")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .disabled(isCapturingLocation)

                Button {
                    pendingMapSeed = homeStore.home?.coordinate ?? locationProvider.coordinate
                    showMapPicker = true
                } label: {
                    Text("地図からピンで指定")
                        .font(.system(size: 18, weight: .semibold))
                }

                if homeStore.home != nil {
                    Button(role: .destructive) {
                        homeStore.clear()
                        statusMessage = "自宅の設定を消しました。"
                    } label: {
                        Text("自宅の設定を消す")
                            .font(.system(size: 17))
                    }
                }
            } footer: {
                Text("位置の取得は「利用中のみ」で足ります。接近通知や滞在解除には、予定登録時に「常に」が推奨されます。")
                    .font(.system(size: 14))
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("自宅を設定")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if let home = homeStore.home {
                nameText = home.name
            }
            locationProvider.requestWhenInUseIfNeeded()
        }
        .navigationDestination(isPresented: $showMapPicker) {
            MapPlacePickerView(
                initialCoordinate: pendingMapSeed,
                onConfirm: { candidate in
                    applyCandidateAsHome(candidate)
                    showMapPicker = false
                }
            )
        }
    }

    private func captureCurrentLocationAsHome() async {
        statusMessage = nil
        isCapturingLocation = true
        defer { isCapturingLocation = false }

        locationProvider.requestWhenInUseIfNeeded()
        guard let coordinate = await locationProvider.currentCoordinate() else {
            statusMessage = "いまの位置が取れませんでした。位置情報を「利用中のみ」以上にして、もう一度試してください。"
            return
        }

        let resolved = await search.reverseGeocode(coordinate: coordinate)
        let place = HomePlace(
            name: resolvedName(),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: resolved.address
        )
        homeStore.save(place)
        statusMessage = "いまの位置を自宅にしました。"
    }

    private func applyCandidateAsHome(_ candidate: PlaceCandidate) {
        let place = HomePlace(
            name: resolvedName(),
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            address: candidate.address
        )
        homeStore.save(place)
        statusMessage = "地図で選んだ場所を自宅にしました。"
    }

    private func resolvedName() -> String {
        let t = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "自宅" : t
    }
}

#Preview {
    NavigationStack {
        HomePlaceSettingsView()
    }
    .environmentObject(HomePlaceStore())
}
