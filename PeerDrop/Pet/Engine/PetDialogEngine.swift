import Foundation

final class PetDialogEngine {

    // MARK: - Templates

    /// Dialogue templates. Currently single shared pool; v4.0.x may add level-specific variations (TODO).
    private let dialogueTemplates: [PetMood: [String]] = [
        .happy:    ["嘿！", "咿呀～", "嗯嗯！", "哇！", "呀哈！"],
        .curious:  ["嗯？", "呀？", "噢？", "嗯嗯？"],
        .sleepy:   ["呼...嚕...", "嗯...", "呼嚕..."],
        .lonely:   ["嗚...", "嗯嗚...", "哼..."],
        .excited:  ["呀呀！", "嘿嘿！", "噢噢！", "耶！"],
        .startled: ["呀！！", "嗚哇！", "啊！"]
    ]

    // MARK: - Public API

    /// Generate a single line of dialogue for the given level and mood.
    func generate(level: PetLevel, mood: PetMood) -> String? {
        switch level {
        case .baby, .adult, .elder:
            guard let pool = dialogueTemplates[mood], !pool.isEmpty else { return nil }
            return pool.randomElement()
        }
    }

    /// Generate a private-chat dialogue between two pets.
    /// Returns at least 2 lines (mine, then partner), with a 50 % chance of a third line.
    func generatePrivateChat(
        myLevel: PetLevel,
        partnerLevel: PetLevel,
        myMood: PetMood,
        partnerMood: PetMood
    ) -> [DialogueLine] {
        var lines: [DialogueLine] = []

        // Line 1 — mine
        let myText = textForChat(level: myLevel, mood: myMood)
        lines.append(DialogueLine(speaker: "mine", text: myText))

        // Line 2 — partner
        let partnerText = textForChat(level: partnerLevel, mood: partnerMood)
        lines.append(DialogueLine(speaker: "partner", text: partnerText))

        // 50 % chance of a third line (mine again)
        if Bool.random() {
            let extraText = textForChat(level: myLevel, mood: myMood)
            lines.append(DialogueLine(speaker: "mine", text: extraText))
        }

        return lines
    }

    // MARK: - Helpers

    private func textForChat(level: PetLevel, mood: PetMood) -> String {
        switch level {
        case .baby, .adult, .elder:
            return dialogueTemplates[mood]?.randomElement() ?? "..."
        }
    }
}
