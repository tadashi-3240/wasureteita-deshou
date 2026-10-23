import SwiftUI

/// 位置（Always）と通知の説明付き許可。
struct LocationNotifyPermissionView: View {
    @EnvironmentObject private var locationMonitor: LocationMonitor
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("近づいたら知らせるために")
                .font(.system(size: 26, weight: .bold))

            Text("指定した場所の近くに来たときにお知らせします。バックグラウンドでも動かすには、位置情報を「常に」許可し、通知をオンにしてください。距離は目安で、保証はしません。")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Label("位置情報（利用中 → 常に）", systemImage: "location.fill")
                Label("通知（バナーとサウンド）", systemImage: "bell.fill")
            }
            .font(.system(size: 18, weight: .medium))

            Spacer(minLength: 8)

            Button {
                Task {
                    _ = await ReminderNotifier().requestAuthorization()
                    locationMonitor.requestWhenInUse()
                    // When In Use の直後に Always を続けて促す
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    locationMonitor.requestAlways()
                    onContinue()
                }
            } label: {
                Text("許可して続ける")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccent"))

            Button("あとで") {
                onContinue()
            }
            .font(.system(size: 17))
            .frame(maxWidth: .infinity)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }
}
