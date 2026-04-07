enum PatternSpriteData {
    /// Pattern overlays keyed by gene. Index 6 = pattern color slot.
    static let sprites: [PatternGene: [[UInt8]]] = [
        .stripe: [
            [6,6,6,6,6,6,6,6],
            [0,0,0,0,0,0,0,0],
            [6,6,6,6,6,6,6,6],
            [0,0,0,0,0,0,0,0],
            [6,6,6,6,6,6,6,6],
        ],
        .spot: [
            [0,6,0,0,0,0,6,0],
            [0,0,0,6,0,0,0,0],
            [6,0,0,0,0,6,0,0],
            [0,0,6,0,0,0,0,6],
            [0,0,0,0,6,0,0,0],
        ],
    ]
}
