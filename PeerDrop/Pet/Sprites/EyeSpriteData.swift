enum EyeSpriteData {
    /// Eye overlay sprites, keyed by gene. Each is a small 2D UInt8 array.
    static let sprites: [EyeGene: [[UInt8]]] = [
        .dot:   [[5,0,0,0,5]],               // simple dot pupils, 5px apart
        .round: [[5,5,0,0,5,5],[5,4,0,0,5,4]],  // 2x2 eyes with highlight
        .line:  [[5,5,0,0,5,5]],             // squint line
        .dizzy: [[5,0,5,0,5,0,5],[0,5,0,0,0,5,0]],  // X-shaped dizzy
    ]

    /// Mood-specific eye overrides
    static let moods: [PetMood: [[UInt8]]] = [
        .happy:    [[0,5,0,0,0,5,0],[5,0,5,0,5,0,5]],  // ^_^
        .sleepy:   [[5,5,0,0,5,5]],   // horizontal line
        .startled: [[5,5,0,0,5,5],[5,5,0,0,5,5],[0,0,0,0,0,0,0]], // wide open
    ]
}
