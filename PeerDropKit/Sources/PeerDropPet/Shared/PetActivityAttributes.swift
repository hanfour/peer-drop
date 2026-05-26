#if os(iOS)
import ActivityKit

@available(iOS 16.2, *)
public struct PetActivityAttributes: ActivityAttributes {
    public let petName: String
    public let bodyType: BodyGene
    public let eyeType: EyeGene
    public let patternType: PatternGene
    public let paletteIndex: Int

    public init(petName: String, bodyType: BodyGene, eyeType: EyeGene, patternType: PatternGene, paletteIndex: Int) {
        self.petName = petName; self.bodyType = bodyType; self.eyeType = eyeType
        self.patternType = patternType; self.paletteIndex = paletteIndex
    }

    public struct ContentState: Codable, Hashable {
        public let pose: IslandPose
        public let mood: PetMood
        public let level: PetLevel
        public let expProgress: Double
        public init(pose: IslandPose, mood: PetMood, level: PetLevel, expProgress: Double) {
            self.pose = pose; self.mood = mood; self.level = level; self.expProgress = expProgress
        }
    }
}
#endif // os(iOS)
