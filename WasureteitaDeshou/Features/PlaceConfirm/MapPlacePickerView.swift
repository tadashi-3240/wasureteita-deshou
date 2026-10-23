import MapKit
import SwiftUI

/// 検索で特定できないときの地図指定。タップ、または「いまの中央」で場所を決める。
/// 予定登録フローではピン確定後に呼び名（必須）を付けて確定する。
struct MapPlacePickerView: View {
    let initialCoordinate: CLLocationCoordinate2D?
    /// 内容確認の場所欄など、呼び名の初期候補
    var suggestedNickname: String = ""
    /// true なら呼び名必須（予定登録）。自宅設定は false。
    var requiresNickname: Bool = false
    let onConfirm: (PlaceCandidate) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var pin: CLLocationCoordinate2D?
    @State private var isResolving = false
    @State private var preview: PlaceCandidate?
    @State private var nickname: String = ""
    @State private var errorMessage: String?
    @State private var didSeedNickname = false

    private let search = PlaceSearchService()

    init(
        initialCoordinate: CLLocationCoordinate2D?,
        suggestedNickname: String = "",
        requiresNickname: Bool = false,
        onConfirm: @escaping (PlaceCandidate) -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        self.suggestedNickname = suggestedNickname
        self.requiresNickname = requiresNickname
        self.onConfirm = onConfirm
        let start = initialCoordinate
            ?? CLLocationCoordinate2D(latitude: 36.39, longitude: 139.06)
        let span = initialCoordinate == nil
            ? MKCoordinateSpan(latitudeDelta: 4.0, longitudeDelta: 4.0)
            : MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        _mapCenter = State(initialValue: start)
        _cameraPosition = State(
            initialValue: .region(MKCoordinateRegion(center: start, span: span))
        )
        let seed = suggestedNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        _nickname = State(initialValue: seed)
        _didSeedNickname = State(initialValue: !seed.isEmpty)
    }

    private var trimmedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConfirm: Bool {
        guard preview != nil, !isResolving else { return false }
        if requiresNickname {
            return !trimmedNickname.isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("地図をタップして場所を指定。ズームしてから「いまの中央を選ぶ」でも大丈夫です。")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let pin {
                        Marker(requiresNickname ? "登録する場所" : "指定した場所", coordinate: pin)
                    }
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    mapCenter = context.camera.centerCoordinate
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            if let coordinate = proxy.convert(event.location, from: .local) {
                                placePin(at: coordinate)
                            }
                        }
                )
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    placePin(at: mapCenter)
                } label: {
                    Text("いまの中央を選ぶ")
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                if let preview {
                    Text(preview.name)
                        .font(.system(size: 22, weight: .semibold))
                    if !preview.address.isEmpty {
                        Text(preview.address)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("場所を選ぶと住所が表示されます")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }

                if requiresNickname, preview != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("呼び名")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("例：水江の製油所", text: $nickname)
                            .font(.system(size: 22))
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                        if trimmedNickname.isEmpty {
                            Text("呼び名を入れると登録できます。次回からこの名前で一発登録できます。")
                                .font(.system(size: 15))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 4)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }

                Button {
                    confirmSelection()
                } label: {
                    if isResolving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        Text(requiresNickname ? "この場所で登録" : "この場所に決める")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccent"))
                .disabled(!canConfirm)
            }
            .padding(20)
            .background(Color(.systemBackground))
        }
        .navigationTitle(requiresNickname ? "地図で場所を登録" : "地図から指定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func placePin(at coordinate: CLLocationCoordinate2D) {
        pin = coordinate
        preview = nil
        errorMessage = nil
        isResolving = true
        Task {
            let candidate = await search.reverseGeocode(coordinate: coordinate)
            preview = candidate
            if requiresNickname, !didSeedNickname, trimmedNickname.isEmpty {
                // 場所欄が空のときだけ逆ジオの名前を仮入れ（編集可）
                let geoName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !geoName.isEmpty, geoName != "地図で選んだ場所" {
                    nickname = geoName
                }
            }
            isResolving = false
        }
    }

    private func confirmSelection() {
        guard let preview else { return }
        if requiresNickname {
            let name = trimmedNickname
            guard !name.isEmpty else {
                errorMessage = "呼び名を入力してください。"
                return
            }
            var named = preview
            named.name = name
            onConfirm(named)
            return
        }
        onConfirm(preview)
    }
}
