import SwiftUI

/// One-time post-upgrade screen shown the first time a v4.x user opens v5.0.
/// Frames the multi-frame animation rollout positively rather than letting
/// users wonder why their pet suddenly moves differently.
///
/// Gated by `@AppStorage("v5UpgradeShown")` (fires exactly once per device)
/// AND a "this is an established user" signal — see `shouldPresent`. Fresh
/// v5.0 installs never see this screen.
struct V5UpgradeOnboarding: View {
    @AppStorage("v5UpgradeShown") private var shown: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Pre-rendered v5 image of the user's own pet — read from PetEngine so
    /// the preview shows MY pet's new walk frame, not a generic example.
    let petImage: CGImage?
    let petName: String?
    let onDismiss: () -> Void

    private var gradient: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.10, green: 0.18, blue: 0.32), Color(red: 0.06, green: 0.10, blue: 0.20)]
            : [Color(red: 0.78, green: 0.88, blue: 0.95), Color(red: 0.62, green: 0.78, blue: 0.92)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer().frame(height: 24)

                Text("v5_upgrade_title")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("v5_upgrade_subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                petPreview
                    .frame(width: 200, height: 200)

                if let petName, !petName.isEmpty {
                    Text(petName)
                        .font(.headline)
                }

                bulletList
                    .padding(.horizontal, 32)

                Spacer()

                Button {
                    shown = true
                    onDismiss()
                } label: {
                    Text("v5_upgrade_continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private var petPreview: some View {
        if let petImage {
            Image(decorative: petImage, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(20)
                .background(.thinMaterial, in: Circle())
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
                .frame(width: 200, height: 200)
                .background(.thinMaterial, in: Circle())
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 14) {
            bulletRow("figure.walk", "v5_upgrade_bullet_walk")
            bulletRow("wind", "v5_upgrade_bullet_idle")
            bulletRow("arrow.triangle.2.circlepath", "v5_upgrade_bullet_directions")
        }
    }

    private func bulletRow(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 24)
            Text(key)
                .font(.callout)
        }
    }
}

extension V5UpgradeOnboarding {
    /// Pure decision function. Three conditions:
    ///   • `v5UpgradeShown` flag is false (first time only)
    ///   • User is an established v4-and-earlier user — signal is either:
    ///       - `v4UpgradeShown` is true (they went through the v4 upgrade
    ///         screen, so definitely a v3.x→v4 migrator), OR
    ///       - `hasCompletedOnboarding` is true (they finished the initial
    ///         onboarding flow at some point, so they have history).
    /// Fresh v5.0 installs that haven't yet finished initial onboarding skip
    /// this screen entirely. The slight edge case — a fresh v5 install user
    /// who finishes onboarding and then re-launches — gets shown the screen
    /// once; harmless.
    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: "v5UpgradeShown") else { return false }
        let v4Seen = defaults.bool(forKey: "v4UpgradeShown")
        let onboardingDone = defaults.bool(forKey: "hasCompletedOnboarding")
        return v4Seen || onboardingDone
    }
}
