enum EyeSpriteData {
    /// Eye overlay sprites, keyed by gene. Each is a 2D UInt8 array (small, ~6x2).
    /// Indices: 5=accent (pupil), 4=highlight (sparkle)
    static let sprites: [EyeGene: [[UInt8]]] = [
        .dot:   [[5,0,0,0,0,5]],                          // 1px pupils, 6 apart
        .round: [[5,5,0,0,5,5],
                 [5,4,0,0,5,4]],                           // 2px eyes with highlight
        .line:  [[5,5,0,0,5,5]],                           // squint
        .dizzy: [[5,0,5,0,5,0],
                 [0,5,0,0,0,5]],                           // X pattern
    ]

    /// Mood-specific eye overrides
    static let moods: [PetMood: [[UInt8]]] = [
        .happy:    [[0,5,0,0,0,5,0],
                    [5,0,5,0,5,0,5]],                      // ^_^
        .sleepy:   [[5,5,0,0,5,5]],                        // — —
        .startled: [[5,5,0,0,5,5],
                    [5,5,0,0,5,5]],                        // O O
    ]
}
