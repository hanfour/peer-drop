import SwiftUI

/// One-time post-upgrade screen shown the first time a v3.x user opens v4.0.
/// Frames the visual change positively ("your pet got a glow-up") rather
/// than letting users wonder if their pet was replaced. Gated on
/// `@AppStorage("v4UpgradeShown")` so it shows exactly once.
struct V4UpgradeOnboarding: View {
    @AppStorage("v4UpgradeShown") private var shown: Bool = false
    @AppStorage("v4MigratedFromEgg") private var eggMigrated: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Pre-rendered v4.0 image of the user's own pet. Read from PetEngine —
    /// the personal connection ("MY pet looks like this now") is a stronger
    /// hook than a generic before/after.
    let petImage: CGImage?
    /// Pet's display name, shown above the preview if available.
    let petName: String?
    let onDismiss: () -> Void

    private var gradient: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.18, green: 0.13, blue: 0.36), Color(red: 0.10, green: 0.08, blue: 0.24)]
            : [Color(red: 0.95, green: 0.85, blue: 0.65), Color(red: 0.92, green: 0.72, blue: 0.55)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer().frame(height: 24)

                Text("v4_upgrade_title")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                if eggMigrated {
                    // Phase 5: v3.x users whose pet was at .egg level get a
                    // celebratory "孵化" line above the generic subtitle.
                    Text("v4_upgrade_egg_hatched")
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Text("v4_upgrade_subtitle")
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
                    // I4: clear the egg-migrated flag on dismiss so it's true
                    // ONLY between migration and the user acknowledging the
                    // upgrade screen. Stale flags would re-show the "孵化"
                    // copy if the upgrade screen were ever re-presented.
                    eggMigrated = false
                    onDismiss()
                } label: {
                    Text("v4_upgrade_continue")
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
            bulletRow("sparkles", "v4_upgrade_bullet_species")
            bulletRow("face.smiling", "v4_upgrade_bullet_mood")
            bulletRow("leaf.fill", "v4_upgrade_bullet_growth")
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

extension V4UpgradeOnboarding {
    /// Pure decision function for whether the upgrade screen should be
    /// presented. Two conditions must hold:
    ///   • `migrationDoneAt` is non-nil — signals the user actually had a
    ///     v3.x pet that just got migrated. Fresh v4.0 installs (which
    ///     never went through v3.x) skip the screen.
    ///   • the @AppStorage flag is false — first time only.
    /// Pulled out as a static func so the gate logic is unit-testable
    /// without instantiating a SwiftUI view.
    static func shouldPresent(
        for pet: PetState,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard pet.migrationDoneAt != nil else { return false }
        return !defaults.bool(forKey: "v4UpgradeShown")
    }
}
