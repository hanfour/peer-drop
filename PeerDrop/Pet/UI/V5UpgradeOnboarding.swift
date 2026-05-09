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
    /// v5.0 effective ship date. Pets with `birthDate` before this are
    /// pre-v5 — their owners had no multi-frame animations to compare
    /// against, so the upgrade announcement makes sense. Pets created
    /// after this date are either fresh v5 installs or pets re-created
    /// on v5 (already see animations from day one), so the announcement
    /// would be confusing.
    ///
    /// **UPDATE BEFORE FINAL APP STORE SUBMISSION** — currently set to a
    /// 2026-09-01 placeholder. The actual cutoff should be a few days
    /// before v5.0 enters phased rollout so any TestFlight pets created
    /// during soak are correctly classified as "post-v5".
    static let v5ReleaseDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantFuture
    }()

    /// Pure decision function. Two conditions both must hold:
    ///   • `v5UpgradeShown` flag is false (first time only)
    ///   • User is an established v4-and-earlier user — signal is either:
    ///       - `v4UpgradeShown` is true (they went through the v4 upgrade
    ///         screen, so definitely a v3.x→v4 migrator), OR
    ///       - the user has a saved pet with `birthDate < v5ReleaseDate`
    ///         (pet was created on a pre-v5 version of the app).
    ///
    /// Why the birthDate signal: `hasCompletedOnboarding` was used in PR
    /// #30 as a proxy for "user has history", but it triggers for fresh
    /// v5 installs on the second launch (after they finish onboarding,
    /// then relaunch). Those users have no v4 baseline to compare, so the
    /// "Pets Got New Animations" copy reads as confusing. birthDate vs
    /// ship date is the cleaner signal: pets created on a v4 install are
    /// reliably pre-v5; fresh v5 pets always have post-v5 birthDates.
    static func shouldPresent(
        pet: PetState?,
        defaults: UserDefaults = .standard,
        v5ReleaseDate: Date = V5UpgradeOnboarding.v5ReleaseDate
    ) -> Bool {
        guard !defaults.bool(forKey: "v5UpgradeShown") else { return false }
        // Strongest signal: user explicitly went through the v3.x -> v4
        // upgrade flow. They're definitely an upgrader.
        if defaults.bool(forKey: "v4UpgradeShown") { return true }
        // Fallback: their pet was created before v5 shipped. Excludes both
        // fresh v5 installs (no saved pet, or post-v5 birthDate) and
        // post-v5 pet re-creations.
        guard let pet = pet else { return false }
        return pet.birthDate < v5ReleaseDate
    }
}
