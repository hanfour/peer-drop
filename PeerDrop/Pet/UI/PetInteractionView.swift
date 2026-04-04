import SwiftUI

struct PetInteractionView: View {
    @ObservedObject var engine: PetEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("狀態") {
                    HStack(spacing: 16) {
                        PixelView(grid: engine.renderedGrid, displaySize: 96)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.pet.name ?? "???").font(.headline)
                            Text("Lv.\(engine.pet.level.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                            Text("EXP: \(engine.pet.experience)").font(.caption)
                            Label(engine.pet.mood.displayName, systemImage: moodIcon).font(.caption)
                        }
                    }
                    ProgressView(value: engine.evolutionProgress) {
                        Text("進化進度").font(.caption2)
                    }.tint(.green)
                }
                Section("祕密日記") {
                    let revealed = engine.pet.socialLog.filter(\.isRevealed)
                    if revealed.isEmpty {
                        Text("還沒有解鎖的對話").foregroundStyle(.secondary)
                    } else {
                        ForEach(revealed) { entry in PetSecretChatRow(entry: entry) }
                    }
                    let unrevealedCount = engine.pet.socialLog.filter({ !$0.isRevealed }).count
                    if unrevealedCount > 0 {
                        Label("還有 \(unrevealedCount) 則未解鎖的對話...", systemImage: "lock.fill")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .navigationTitle("我的寵物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
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
}
