import SwiftUI

/// Reusable bottom sheet layout for peer-related actions.
/// Shows peer avatar, name, subtitle, optional middle content, and action buttons.
struct PeerActionSheet<MiddleContent: View>: View {
    let peerName: String
    let subtitle: String
    let primaryLabel: String
    let primaryColor: Color
    let secondaryLabel: String
    let secondaryColor: Color?
    let middleContent: MiddleContent
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(
        peerName: String,
        subtitle: String,
        primaryLabel: String,
        primaryColor: Color = .accentColor,
        secondaryLabel: String,
        secondaryColor: Color? = nil,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping () -> Void,
        @ViewBuilder middleContent: () -> MiddleContent = { EmptyView() }
    ) {
        self.peerName = peerName
        self.subtitle = subtitle
        self.primaryLabel = primaryLabel
        self.primaryColor = primaryColor
        self.secondaryLabel = secondaryLabel
        self.secondaryColor = secondaryColor
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.middleContent = middleContent()
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            PeerAvatar(name: peerName)
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text(peerName)
                    .font(.title2.bold())

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(peerName), \(subtitle)")

            middleContent

            Spacer()

            VStack(spacing: 12) {
                Button(action: onPrimary) {
                    Text(primaryLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(primaryColor)
                .accessibilityIdentifier("sheet-primary-action")

                Button(action: onSecondary) {
                    Text(secondaryLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(secondaryColor)
                .accessibilityIdentifier("sheet-secondary-action")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
    }
}
