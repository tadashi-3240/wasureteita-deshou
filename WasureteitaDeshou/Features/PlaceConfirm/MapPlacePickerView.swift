import MapKit
import SwiftUI

/// 検索で特定できないときの地図指定。タップ、または「いまの中央」で場所を決める。
struct MapPlacePickerView: View {
    let initialCoordinate: CLLocationCoordinate2D?
    let onConfirm: (PlaceCandidate) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var pin: CLLocationCoordinate2D?
    @State private var isResolving = false
    @State private var preview: PlaceCandidate?
    @State private var errorMessage: String?

    private let search = PlaceSearchService()

    init(
        initialCoordinate: CLLocationCoordinate2D?,
        onConfirm: @escaping (PlaceCandidate) -> Void
    ) {
        self.initialCoordinate = initialCoordinate
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
                        Marker("指定した場所", coordinate: pin)
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

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }

                Button {
                    guard let preview else { return }
                    onConfirm(preview)
                } label: {
                    if isResolving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        Text("この場所に決める")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccent"))
                .disabled(preview == nil || isResolving)
            }
            .padding(20)
            .background(Color(.systemBackground))
        }
        .navigationTitle("地図から指定")
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
            isResolving = false
        }
    }
}
