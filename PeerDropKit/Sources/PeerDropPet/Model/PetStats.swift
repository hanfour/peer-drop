public struct PetStats: Codable, Equatable {
    public var totalInteractions: Int = 0
    public var poopsCleaned: Int = 0
    public var petsMet: Int = 0
    public var foodsEaten: Int = 0
    public init(totalInteractions: Int = 0, poopsCleaned: Int = 0, petsMet: Int = 0, foodsEaten: Int = 0) {
        self.totalInteractions = totalInteractions; self.poopsCleaned = poopsCleaned
        self.petsMet = petsMet; self.foodsEaten = foodsEaten
    }
}
