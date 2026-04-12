import ActivityKit

@available(iOS 16.1, *)
struct PetActivityAttributes: ActivityAttributes {
    let petName: String
    let bodyType: BodyGene

    struct ContentState: Codable, Hashable {
        let pose: IslandPose
        let mood: PetMood
        let level: PetLevel
        let expProgress: Double
    }
}
