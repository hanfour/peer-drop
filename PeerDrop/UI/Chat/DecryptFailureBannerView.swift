import SwiftUI

/// Surfaced inside `ChatView` when consecutive decrypt failures from the
/// focused peer exceed the threshold defined on `ConnectionManager`. Tells
/// the user that their peer's identity key may have changed and prompts
/// them to verify the fingerprint out-of-band before trusting further
/// messages. Both actions clear the banner; "Dismiss" also resets the
/// per-peer failure counter so we don't immediately re-nag.
struct DecryptFailureBannerView: View {
    let displayName: String
    let onVerify: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text("Can't decrypt messages from \(displayName)")
                    .font(.subheadline.bold())
                Text("Their identity key may have changed. Verify the fingerprint to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(action: onVerify) {
                        Text("Verify")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
