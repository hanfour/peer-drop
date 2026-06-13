import SwiftUI
import PeerDropPet

/// Sidebar "Pet" detail pane.
///
/// Audit round 25 brought this to feature parity with the iOS PetTabView:
/// naming, tap-to-feed, evolution progress, mood, gene info and stats —
/// previously the Mac pet was view-only (sprite + level). The iOS
/// components live inside the iOS-excluded PetTabView.swift, so these are
/// Mac-native sections built on the same shared model APIs
/// (`displayName`, `PetPalettes`, `FoodType`, `PetEngine.feedDirectly`).
///
/// Reads `PetEngine.renderedImage` (CGImage?) directly; the engine
/// republishes it on every animator tick / interaction / evolve.
struct PetSectionView: View {
    @EnvironmentObject var petEngine: PetEngine
    @State private var showNameAlert = false
    @State private var nameText = ""
    @State private var feedMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PetSpriteView(size: 200)
                header
                evolutionSection
                foodSection
                geneSection
                statsSection
            }
            .padding(24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "幫寵物取個名字吧！"), isPresented: $showNameAlert) {
            TextField(String(localized: "名字"), text: $nameText)
            Button(String(localized: "確定")) {
                let trimmed = nameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { petEngine.pet.name = trimmed }
            }
            Button(String(localized: "取消"), role: .cancel) { }
        }
    }

    // MARK: - Header (name + level + mood)

    private var header: some View {
        VStack(spacing: 6) {
            Button {
                nameText = petEngine.pet.name ?? ""
                showNameAlert = true
            } label: {
                HStack(spacing: 6) {
                    if let name = petEngine.pet.name, !name.isEmpty {
                        Text(name).font(.title2.bold())
                    } else {
                        Text(String(localized: "Tap to name"))
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "pencil").font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Text(petEngine.pet.level.displayName)
                    .foregroundStyle(.secondary)
                Label(petEngine.pet.mood.displayName, systemImage: moodIcon)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: - Evolution progress

    @ViewBuilder private var evolutionSection: some View {
        if let req = EvolutionRequirement.for(petEngine.pet.level) {
            let elapsedDays = Int(Date().timeIntervalSince(petEngine.pet.birthDate) / 86400)
            let targetDays = Int(req.minimumAge / 86400)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: petEngine.evolutionProgress) {
                        HStack {
                            Text(String(localized: "Age"))
                            Spacer()
                            Text("\(elapsedDays) / \(targetDays) days")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tint(.green)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Food + feeding

    private var foodSection: some View {
        GroupBox(String(localized: "食物庫存")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 24) {
                    ForEach(FoodType.allCases) { food in
                        let count = petEngine.pet.foodInventory.count(of: food)
                        Button {
                            feed(food)
                        } label: {
                            VStack(spacing: 2) {
                                Text(food.emoji).font(.title)
                                    .opacity(count > 0 ? 1 : 0.35)
                                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                    }
                    Spacer()
                }
                Text(feedMessage ?? String(localized: "Tap a treat to feed your pet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: - Gene info

    private var geneSection: some View {
        GroupBox(String(localized: "基因資訊")) {
            VStack(spacing: 8) {
                LabeledContent(String(localized: "體型"), value: petEngine.pet.genome.body.displayName)
                LabeledContent(String(localized: "眼睛"), value: petEngine.pet.genome.eyes.displayName)
                LabeledContent(String(localized: "花紋"), value: petEngine.pet.genome.pattern.displayName)
                LabeledContent(String(localized: "配色")) {
                    Circle()
                        .fill(paletteColor(petEngine.pet.genome.paletteIndex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
                }
                Divider()
                personalityBars
            }
            .padding(6)
        }
    }

    private var personalityBars: some View {
        let t = petEngine.pet.genome.personalityTraits
        return VStack(spacing: 5) {
            traitRow(String(localized: "獨立"), t.independence)
            traitRow(String(localized: "好奇"), t.curiosity)
            traitRow(String(localized: "活力"), t.energy)
            traitRow(String(localized: "膽小"), t.timidity)
            traitRow(String(localized: "調皮"), t.mischief)
        }
    }

    private func traitRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 40, alignment: .leading)
            ProgressView(value: value).tint(traitColor(value))
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        GroupBox(String(localized: "統計")) {
            VStack(spacing: 8) {
                LabeledContent(String(localized: "年齡"), value: String(localized: "\(petEngine.pet.ageInDays) 天"))
                LabeledContent(String(localized: "互動次數"), value: "\(petEngine.pet.stats.totalInteractions)")
                LabeledContent(String(localized: "清理便便"), value: "\(petEngine.pet.stats.poopsCleaned)")
                LabeledContent(String(localized: "遇見寵物"), value: "\(petEngine.pet.stats.petsMet)")
                LabeledContent(String(localized: "吃過食物"), value: "\(petEngine.pet.stats.foodsEaten)")
            }
            .padding(6)
        }
    }

    // MARK: - Helpers

    /// Direct feed (Mac has no floating pet to walk to dropped food) with a
    /// transient reason when refused.
    private func feed(_ type: FoodType) {
        let message: String
        switch petEngine.feedDirectly(type) {
        case .fed:        message = String(localized: "Yum! 🍽️")
        case .onCooldown: message = String(localized: "Your pet isn't hungry yet")
        case .outOfStock: message = String(localized: "You're out of that treat")
        }
        withAnimation { feedMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { withAnimation { if feedMessage == message { feedMessage = nil } } }
        }
    }

    private var moodIcon: String {
        switch petEngine.pet.mood {
        case .happy: return "face.smiling"
        case .curious: return "eyes"
        case .sleepy: return "moon.zzz"
        case .lonely: return "cloud.rain"
        case .excited: return "star"
        case .startled: return "exclamationmark.triangle"
        }
    }

    private func paletteColor(_ index: Int) -> Color {
        PetPalettes.all.indices.contains(index) ? PetPalettes.all[index].primary : .gray
    }

    private func traitColor(_ value: Double) -> Color {
        if value > 0.7 { return .orange }
        if value > 0.4 { return .blue }
        return .gray
    }
}

/// Reusable sprite view — used by the sidebar Pet section (200pt) and
/// by MenuBarContent's mini-sprite slot (60pt).
///
/// Pixel-perfect rendering via `.interpolation(.none)`: PetEngine
/// renders the v5 multi-frame sprite at the source pixel grid and we
/// must NOT smooth-scale when displaying at integer multiples. The
/// `scaledToFit()` modifier keeps aspect ratio while honouring the
/// outer `.frame(width:height:)`.
struct PetSpriteView: View {
    let size: CGFloat
    @EnvironmentObject var petEngine: PetEngine

    var body: some View {
        Group {
            if let cgImage = petEngine.renderedImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                // First-launch / pre-render placeholder. PetEngine's
                // updateRenderedImage() is async (SpriteService is an
                // actor) so renderedImage stays nil for ~one frame
                // after init.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .frame(width: size, height: size)
    }
}
