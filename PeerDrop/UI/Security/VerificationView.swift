import SwiftUI

struct VerificationView: View {
    let peerName: String
    let safetyNumber: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Verify Identity")
                .font(.title2.bold())

            Text(String(localized: "Confirm the safety number matches \(peerName)'s screen"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(safetyNumber)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(4)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 32) {
                VStack {
                    Image(systemName: "heart")
                        .font(.title)
                        .foregroundStyle(.pink)
                    Text(String(localized: "Your Pet"))
                        .font(.caption)
                }
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                VStack {
                    Image(systemName: "heart")
                        .font(.title)
                        .foregroundStyle(.pink)
                    Text(peerName)
                        .font(.caption)
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Label(String(localized: "Numbers Match"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: onCancel) {
                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
    }
}
