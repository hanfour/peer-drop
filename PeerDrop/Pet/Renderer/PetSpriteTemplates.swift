import Foundation

enum PetSpriteTemplates {

    // MARK: - Egg

    // Crack coordinates are offsets from the template origin (ox, oy),
    // NOT indices into the pixel array. Negative/overflow values place
    // cracks outside the egg shell on the final 32×32 grid.
    static let egg: [EggTemplate] = [
        // Frame 0: normal
        EggTemplate(
            pixels: [
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
            ],
            crackLeftPixels: [(-1, 6), (-1, 7), (0, 8)],
            crackRightPixels: [(14, 5), (14, 6), (13, 7)]
        ),
        // Frame 1: breathing (slightly taller)
        EggTemplate(
            pixels: [
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
            ],
            crackLeftPixels: [(-1, 6), (-1, 7), (0, 8)],
            crackRightPixels: [(14, 5), (14, 6), (13, 7)]
        ),
    ]

    // MARK: - Body

    // Body templates are identical across frames — bounce is applied via render offset.
    // Returned as [template, template] to maintain 2-frame API contract.
    static func body(for gene: BodyGene) -> [BodyTemplate] {
        let t: BodyTemplate
        switch gene {
        case .round: t = bodyRound
        case .square: t = bodySquare
        case .oval: t = bodyOval
        }
        return [t, t]
    }

    // Round: ~18×16, hamster/owl style, large head ratio
    private static let bodyRound = BodyTemplate(
        pixels: [
            [0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0],
            [0,0,0,0,1,1,2,2,2,2,2,2,1,1,0,0,0,0],
            [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
            [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
            [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
            [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
            [1,2,2,2,2,5,2,2,2,2,2,2,5,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,2,3,3,3,3,3,3,2,2,2,2,2,1],
            [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
            [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
            [0,1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1,0],
            [0,1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1,0],
            [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
            [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
            [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        ],
        eyeAnchor: (x: 4, y: 4),
        limbLeftAnchor: (x: -3, y: 7),
        limbRightAnchor: (x: 18, y: 7),
        patternOrigin: (x: 6, y: 8)
    )

    // Square: ~16×15, block cat / robot style
    private static let bodySquare = BodyTemplate(
        pixels: [
            [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,5,2,2,2,2,2,2,5,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
            [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
            [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
            [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
            [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
        ],
        eyeAnchor: (x: 3, y: 3),
        limbLeftAnchor: (x: -3, y: 6),
        limbRightAnchor: (x: 16, y: 6),
        patternOrigin: (x: 5, y: 7)
    )

    // Oval: ~14×18, penguin/water drop style
    private static let bodyOval = BodyTemplate(
        pixels: [
            [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
            [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
            [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
            [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,5,2,2,2,2,5,2,2,2,1],
            [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
            [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
            [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
            [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
            [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
            [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
            [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
            [1,2,2,2,2,3,3,3,3,2,2,2,2,1],
            [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
            [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
            [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
            [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
        ],
        eyeAnchor: (x: 3, y: 3),
        limbLeftAnchor: (x: -3, y: 7),
        limbRightAnchor: (x: 14, y: 7),
        patternOrigin: (x: 3, y: 7)
    )

    // MARK: - Eyes

    static func eyes(for gene: EyeGene) -> [[Int]] {
        switch gene {
        case .dot: return eyesDot
        case .round: return eyesRound
        case .line: return eyesLine
        case .dizzy: return eyesDizzy
        }
    }

    static func eyesMood(_ mood: PetMood) -> [[Int]]? {
        switch mood {
        case .happy: return eyesHappy
        case .sleepy: return eyesSleepy
        case .startled: return eyesStartled
        default: return nil
        }
    }

    // Eyes are ~10×N (both eyes in one template)
    // Left eye at col 0-3, right eye at col 6-9

    // Dot: tiny 1px pupil (5) + 1px highlight (4)
    private static let eyesDot: [[Int]] = [
        [0,4,0,0,0,0,0,4,0,0],
        [0,5,0,0,0,0,0,5,0,0],
    ]

    // Round: 2px circle eyes with highlight
    private static let eyesRound: [[Int]] = [
        [0,5,5,0,0,0,0,5,5,0],
        [5,5,4,0,0,0,5,5,4,0],
        [0,5,5,0,0,0,0,5,5,0],
    ]

    // Line: squinting horizontal
    private static let eyesLine: [[Int]] = [
        [5,5,5,0,0,0,5,5,5,0],
    ]

    // Dizzy: X-shaped
    private static let eyesDizzy: [[Int]] = [
        [5,0,5,0,0,0,5,0,5,0],
        [0,5,0,0,0,0,0,5,0,0],
        [5,0,5,0,0,0,5,0,5,0],
    ]

    // Happy: inverted U arcs (^_^)
    private static let eyesHappy: [[Int]] = [
        [5,0,5,0,0,0,5,0,5,0],
        [0,5,0,0,0,0,0,5,0,0],
    ]

    // Sleepy: horizontal line + ZZZ
    private static let eyesSleepy: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,5],
        [0,0,0,0,0,0,0,0,5,0],
        [5,5,5,0,0,0,5,5,5,0],
    ]

    // Startled: large circle eyes, no highlight
    private static let eyesStartled: [[Int]] = [
        [0,5,5,0,0,0,0,5,5,0],
        [5,0,0,5,0,0,5,0,0,5],
        [5,0,0,5,0,0,5,0,0,5],
        [0,5,5,0,0,0,0,5,5,0],
    ]

    // MARK: - Limbs

    static func limbs(for gene: LimbGene, frame: Int) -> LimbTemplate? {
        switch gene {
        case .short: return frame % 2 == 0 ? limbsShortF0 : limbsShortF1
        case .long: return frame % 2 == 0 ? limbsLongF0 : limbsLongF1
        case .none: return nil
        }
    }

    // Short: small 3×4 stubs
    private static let limbsShortF0 = LimbTemplate(
        left:  [[1,2,2],[1,2,2],[1,2,2],[1,1,1]],
        right: [[2,2,1],[2,2,1],[2,2,1],[1,1,1]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 2)
    )
    private static let limbsShortF1 = LimbTemplate(
        left:  [[1,2,2],[1,2,2],[1,2,2],[1,1,1]],
        right: [[2,2,1],[2,2,1],[2,2,1],[1,1,1]],
        leftOffset: (x: 0, y: 2),
        rightOffset: (x: 0, y: 0)
    )

    // Long: diagonal lines (5×6)
    private static let limbsLongF0 = LimbTemplate(
        left:  [[0,0,1,2,2],[0,1,2,2,0],[1,2,2,0,0],[1,2,0,0,0],[1,2,0,0,0],[1,1,0,0,0]],
        right: [[2,2,1,0,0],[0,2,2,1,0],[0,0,2,2,1],[0,0,0,2,1],[0,0,0,2,1],[0,0,0,1,1]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 0)
    )
    private static let limbsLongF1 = LimbTemplate(
        left:  [[1,2,2,0,0],[0,1,2,2,0],[0,0,1,2,2],[0,0,1,2,0],[0,0,1,2,0],[0,0,1,1,0]],
        right: [[0,0,2,2,1],[0,2,2,1,0],[2,2,1,0,0],[0,2,1,0,0],[0,2,1,0,0],[0,1,1,0,0]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 0)
    )

    // MARK: - Pattern

    static func pattern(for gene: PatternGene) -> [[Int]]? {
        switch gene {
        case .stripe: return patternStripe
        case .spot: return patternSpot
        case .none: return nil
        }
    }

    // Stripe: horizontal lines using pattern color (6)
    private static let patternStripe: [[Int]] = [
        [6,6,6,6,6,6,6,6],
        [0,0,0,0,0,0,0,0],
        [6,6,6,6,6,6,6,6],
        [0,0,0,0,0,0,0,0],
        [6,6,6,6,6,6,6,6],
    ]

    // Spot: scattered dots
    private static let patternSpot: [[Int]] = [
        [0,0,6,0,0,0,0,0],
        [0,0,0,0,0,6,0,0],
        [0,0,0,0,0,0,0,0],
        [0,6,0,0,0,0,6,0],
        [0,0,0,0,6,0,0,0],
    ]
}
