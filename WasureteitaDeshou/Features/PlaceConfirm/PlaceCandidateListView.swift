import SwiftUI

struct PlaceCandidateListView: View {
    let candidates: [PlaceCandidate]
    let onSelect: (PlaceCandidate) -> Void
    let onPickOnMap: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(candidate.name)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.primary)
                                if candidate.id.hasPrefix("saved|") {
                                    Text("保存した場所")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color("BrandAccent"))
                                }
                            }
                            if !candidate.address.isEmpty {
                                Text(candidate.address)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            } header: {
                Text("候補から選ぶ")
                    .font(.system(size: 16, weight: .semibold))
            } footer: {
                Text("違う場所のときは地図で登録できます。")
                    .font(.system(size: 15))
            }

            Section {
                Button(action: onPickOnMap) {
                    Label("地図で場所を登録", systemImage: "map")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
        }
        .navigationTitle("場所の候補")
        .navigationBarTitleDisplayMode(.large)
    }
}
