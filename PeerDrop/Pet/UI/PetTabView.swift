import SwiftUI

struct PetTabView: View {
    @EnvironmentObject var engine: PetEngine
    @State private var showNameAlert = false
    @State private var nameText = ""
    @State private var showWelcome = false
    private let welcomeFlag = PetWelcomeFlag()

    var body: some View {
        List {
            // MARK: - Profile Header
            Section {
                HStack(spacing: 16) {
                    SpriteImageView(image: engine.renderedImage, displaySize: 128)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        PetNameButton(name: engine.pet.name, showAlert: $showNameAlert, nameText: $nameText)
                        Text(engine.pet.level.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label(engine.pet.mood.displayName, systemImage: moodIcon)
                            .font(.caption)
                    }
                }

                // EXP progress bar + evolution status
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.evolutionProgress) {
                        HStack {
                            Text("EXP").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(engine.pet.experience) / \(EvolutionRequirement.for(engine.pet.level)?.requiredExperience ?? 999)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)

                    // Show age requirement hint when XP is met but age isn't
                    if let req = EvolutionRequirement.for(engine.pet.level) {
                        let xpMet = engine.pet.experience >= req.requiredExperience
                        let ageMet = Date().timeIntervalSince(engine.pet.birthDate) >= req.minimumAge
                        if xpMet && !ageMet {
                            let remainingHours = Int(ceil((req.minimumAge - Date().timeIntervalSince(engine.pet.birthDate)) / 3600))
                            Text(String(localized: "EXP is ready! Evolution in ~\(remainingHours)h"))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // MARK: - Food Inventory
            Section("食物庫存") {
                FoodInventoryRow(inventory: engine.pet.foodInventory)
            }

            // MARK: - Gene Info
            Section("基因資訊") {
                LabeledContent("體型", value: engine.pet.genome.body.rawValue)
                LabeledContent("眼睛", value: engine.pet.genome.eyes.rawValue)
                LabeledContent("花紋", value: engine.pet.genome.pattern.rawValue)
                LabeledContent("配色", value: "#\(engine.pet.genome.paletteIndex)")

                PersonalityBarsView(traits: engine.pet.genome.personalityTraits)
            }

            // MARK: - Social Diary
            SocialDiarySection(socialLog: engine.pet.socialLog)

            // MARK: - Stats
            Section("統計") {
                LabeledContent("年齡", value: "\(engine.pet.ageInDays) 天")
                LabeledContent("互動次數", value: "\(engine.pet.stats.totalInteractions)")
                LabeledContent("清理便便", value: "\(engine.pet.stats.poopsCleaned)")
                LabeledContent("遇見寵物", value: "\(engine.pet.stats.petsMet)")
                LabeledContent("吃過食物", value: "\(engine.pet.stats.foodsEaten)")
            }
        }
        .navigationTitle("我的寵物")
        .navigationBarTitleDisplayMode(.inline)
        .alert("幫寵物取個名字吧！", isPresented: $showNameAlert) {
            TextField("名字", text: $nameText)
            Button("確定") {
                let trimmed = nameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    engine.pet.name = trimmed
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("輸入寵物的名字")
        }
        // Welcome reveal fires on first PetTab open. .onAppear runs every
        // tab return, but markSeen() on dismiss persists, so subsequent
        // opens are no-op. Users who quit mid-welcome (without tapping CTA)
        // will see it again on next launch — intentional, since "didn't
        // finish reading" ≠ "saw the pet".
        //
        // I-1 fix: suppress for v3.x migrators (egg or past-egg). They
        // already see V4UpgradeOnboarding which is the appropriate v3→v4
        // reveal — PetWelcomeView's "you got a new pet companion" copy is
        // wrong for users whose pet existed before. Only fresh-install
        // users (migrationDoneAt == nil → never migrated) see the welcome.
        .onAppear {
            if PetTabView.shouldPresentWelcome(flag: welcomeFlag, pet: engine.pet) {
                showWelcome = true
            }
        }
        .fullScreenCover(isPresented: $showWelcome) {
            // Pass engine.renderedImage as prerenderedImage: this view is
            // already mounted (we're presenting from it), so engine's sprite
            // cache is warm — eliminates the 50-200ms first-render race in
            // PetWelcomeView.
            PetWelcomeView(pet: engine.pet, prerenderedImage: engine.renderedImage) {
                welcomeFlag.markSeen()
                showWelcome = false
            }
        }
    }

    private var moodIcon: String {
        switch engine.pet.mood {
        case .happy: return "face.smiling"
        case .curious: return "eyes"
        case .sleepy: return "moon.zzz"
        case .lonely: return "cloud.rain"
        case .excited: return "star"
        case .startled: return "exclamationmark.triangle"
        }
    }

    /// Pure decision function for whether the v4.0.1 welcome reveal should
    /// be presented on PetTab open. Two conditions must hold:
    ///   • the per-install flag `shouldShow` is true (first PetTab open).
    ///   • `pet.migrationDoneAt == nil` — i.e. this is a fresh-install pet,
    ///     not a v3.x migrator. v3.x migrators (egg or past-egg) get
    ///     `V4UpgradeOnboarding` instead, which is the appropriate
    ///     v3→v4 reveal; PetWelcomeView's "you got a new pet companion"
    ///     copy is wrong for users whose pet existed before.
    /// Pulled out as a static func so the gate logic is unit-testable
    /// without mounting a SwiftUI view.
    static func shouldPresentWelcome(flag: PetWelcomeFlag, pet: PetState) -> Bool {
        flag.shouldShow && pet.migrationDoneAt == nil
    }
}

// MARK: - PetNameButton

struct PetNameButton: View {
    let name: String?
    @Binding var showAlert: Bool
    @Binding var nameText: String

    var body: some View {
        Button {
            nameText = name ?? ""
            showAlert = true
        } label: {
            HStack(spacing: 4) {
                Text(name ?? "???")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - PersonalityBarsView

struct PersonalityBarsView: View {
    let traits: PersonalityTraits

    var body: some View {
        VStack(spacing: 6) {
            traitRow("獨立", value: traits.independence)
            traitRow("好奇", value: traits.curiosity)
            traitRow("活力", value: traits.energy)
            traitRow("膽小", value: traits.timidity)
            traitRow("調皮", value: traits.mischief)
        }
    }

    private func traitRow(_ label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .frame(width: 36, alignment: .leading)
            ProgressView(value: value)
                .tint(traitColor(value))
        }
    }

    private func traitColor(_ value: Double) -> Color {
        if value > 0.7 { return .orange }
        if value > 0.4 { return .blue }
        return .gray
    }
}

// MARK: - FoodInventoryRow

struct FoodInventoryRow: View {
    let inventory: FoodInventory

    var body: some View {
        HStack(spacing: 16) {
            ForEach(FoodType.allCases) { food in
                let count = inventory.count(of: food)
                VStack(spacing: 2) {
                    Text(food.emoji)
                        .font(.title2)
                        .draggable(food.rawValue)
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - SocialDiarySection

struct SocialDiarySection: View {
    let socialLog: [SocialEntry]

    private var revealed: [SocialEntry] {
        socialLog.filter(\.isRevealed)
    }

    private var lockedCount: Int {
        socialLog.filter { !$0.isRevealed }.count
    }

    var body: some View {
        Section("祕密日記") {
            if revealed.isEmpty {
                Text("還沒有解鎖的對話")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(revealed) { entry in
                    PetSecretChatRow(entry: entry)
                }
            }
            if lockedCount > 0 {
                Label("還有 \(lockedCount) 則未解鎖的對話...", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
