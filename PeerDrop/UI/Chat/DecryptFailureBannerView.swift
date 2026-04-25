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

    @ScaledMetric private var rowSpacing: CGFloat = 12
    @ScaledMetric private var contentSpacing: CGFloat = 4
    @ScaledMetric private var actionRowSpacing: CGFloat = 12
    @ScaledMetric private var actionRowTopPadding: CGFloat = 4
    @ScaledMetric private var bannerPadding: CGFloat = 12
    @ScaledMetric private var outerHPadding: CGFloat = 12
    @ScaledMetric private var outerTopPadding: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: rowSpacing) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: contentSpacing) {
                Text("Can't decrypt messages from \(displayName)")
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Their identity key may have changed. Verify the fingerprint to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: actionRowSpacing) {
                    Button(action: onVerify) {
                        Text("Verify")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }
                .padding(.top, actionRowTopPadding)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(bannerPadding)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, outerHPadding)
        .padding(.top, outerTopPadding)
    }
}
