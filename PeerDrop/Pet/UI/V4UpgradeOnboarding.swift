import SwiftUI

/// One-time post-upgrade screen shown the first time a v3.x user opens v4.0.
/// Frames the visual change positively ("your pet got a glow-up") rather
/// than letting users wonder if their pet was replaced. Gated on
/// `@AppStorage("v4UpgradeShown")` so it shows exactly once.
struct V4UpgradeOnboarding: View {
    @AppStorage("v4UpgradeShown") private var shown: Bool = false
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

                if UserDefaults.standard.bool(forKey: "v4MigratedFromEgg") {
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

    /// Pure copy-builder for the upgrade subtitle. When `eggMigrated` is true
    /// (v3.x user whose pet was at .egg level — see PetStore.loadAndMigrate
    /// peeking at level=1), prepends a celebratory "孵化" line so the user
    /// understands the visual change as a hatch event rather than a silent
    /// promotion. Otherwise returns the generic v3→v4 upgrade copy.
    ///
    /// Kept independent of LocalizedStringKey so unit tests can assert on the
    /// raw character — the SwiftUI view uses the localised xcstrings key
    /// `v4_upgrade_egg_hatched` directly (Phase 6 wires the catalog entry).
    /// Until Phase 6 ships, NSLocalizedString falls back to the supplied
    /// `value:` (zh-Hant) when the key is missing, so the assertion on
    /// "孵化" passes both before and after the localisation work.
    static func message(for pet: PetState, eggMigrated: Bool) -> String {
        // pet param is currently unused — kept on the signature for Phase 6
        // when the egg-hatched copy will splice in a localised species name
        // ("你的蛋孵化了，是一隻 [species]！"). Today the species is implied by
        // the rendered sprite shown above the text.
        _ = pet
        let baseSubtitle = NSLocalizedString(
            "v4_upgrade_subtitle",
            value: "你的寵物迎來了 v4.0 的全新外觀。",
            comment: "v3→v4 upgrade subtitle, shown to all migrated users")
        guard eggMigrated else { return baseSubtitle }
        let hatched = NSLocalizedString(
            "v4_upgrade_egg_hatched",
            value: "你的蛋孵化了！",
            comment: "Extra line for v3.x users whose pet was at .egg level pre-upgrade")
        return "\(hatched)\n\n\(baseSubtitle)"
    }
}
