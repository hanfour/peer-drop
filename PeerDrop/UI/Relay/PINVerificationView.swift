import SwiftUI

struct PINVerificationView: View {
    let pin: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Verify PIN")
                    .font(.title2.bold())

                Text(pin)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .tracking(16)
                    .foregroundStyle(.primary)

                Text("Confirm this PIN matches the other device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        onConfirm()
                    } label: {
                        Text("PINs Match")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        onReject()
                    } label: {
                        Text("PINs Don't Match")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}
