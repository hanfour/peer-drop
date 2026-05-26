import Foundation

public struct BodyTemplate {
    public let pixels: [[Int]]
    public let eyeAnchor: (x: Int, y: Int)
    public let limbLeftAnchor: (x: Int, y: Int)
    public let limbRightAnchor: (x: Int, y: Int)
    public let patternOrigin: (x: Int, y: Int)
    public init(pixels: [[Int]], eyeAnchor: (x: Int, y: Int), limbLeftAnchor: (x: Int, y: Int), limbRightAnchor: (x: Int, y: Int), patternOrigin: (x: Int, y: Int)) {
        self.pixels = pixels; self.eyeAnchor = eyeAnchor; self.limbLeftAnchor = limbLeftAnchor
        self.limbRightAnchor = limbRightAnchor; self.patternOrigin = patternOrigin
    }
}

public struct EggTemplate {
    public let pixels: [[Int]]
    public let crackLeftPixels: [(x: Int, y: Int)]
    public let crackRightPixels: [(x: Int, y: Int)]
    public init(pixels: [[Int]], crackLeftPixels: [(x: Int, y: Int)], crackRightPixels: [(x: Int, y: Int)]) {
        self.pixels = pixels; self.crackLeftPixels = crackLeftPixels; self.crackRightPixels = crackRightPixels
    }
}

public struct LimbTemplate {
    public let left: [[Int]]
    public let right: [[Int]]
    public let leftOffset: (x: Int, y: Int)
    public let rightOffset: (x: Int, y: Int)
    public init(left: [[Int]], right: [[Int]], leftOffset: (x: Int, y: Int), rightOffset: (x: Int, y: Int)) {
        self.left = left; self.right = right; self.leftOffset = leftOffset; self.rightOffset = rightOffset
    }
}
