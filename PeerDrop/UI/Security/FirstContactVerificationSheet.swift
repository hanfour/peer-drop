import SwiftUI

/// Sheet shown the first time an unknown peer sends a message via the relay.
/// The user must compare the fingerprint out-of-band (in person, phone, etc.)
/// before the X3DH session is established. Defends against MITM at first
/// contact — without this gate, Mallory can establish a session just by
/// initiating, and the user never sees the fingerprint.
struct FirstContactVerificationSheet: View {
    let pending: PendingFirstContact
    let onApprove: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric private var stackSpacing: CGFloat = 16
    @ScaledMetric private var headerSpacing: CGFloat = 12
    @ScaledMetric private var buttonRowSpacing: CGFloat = 12

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: stackSpacing) {
                HStack(spacing: headerSpacing) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.senderDisplayName)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Unknown Device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("This is the first message from this device. Compare the fingerprint below in person or over a trusted channel (call, Signal, etc.) before accepting — it's the only way to ensure no one is intercepting your connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(pending.fingerprint)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .accessibilityLabel(Text("Fingerprint"))
                    .accessibilityValue(Text(pending.fingerprint))

                Spacer()

                HStack(spacing: buttonRowSpacing) {
                    Button(role: .destructive) {
                        onReject()
                        dismiss()
                    } label: {
                        Text("Reject")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onApprove()
                        dismiss()
                    } label: {
                        Text("Accept & Trust")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle(Text("Verify first contact"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }
}

#if DEBUG
#Preview {
    FirstContactVerificationSheet(
        pending: PendingFirstContact(
            fingerprint: "AB12 CD34 EF56 7890 1234",
            senderDisplayName: "Alice's iPhone",
            senderIdentityKey: Data(repeating: 0, count: 32)
        ),
        onApprove: {},
        onReject: {}
    )
}
#endif
