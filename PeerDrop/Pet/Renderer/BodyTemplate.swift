import Foundation

struct BodyTemplate {
    let pixels: [[Int]]
    let eyeAnchor: (x: Int, y: Int)
    let limbLeftAnchor: (x: Int, y: Int)
    let limbRightAnchor: (x: Int, y: Int)
    let patternOrigin: (x: Int, y: Int)
}

struct EggTemplate {
    let pixels: [[Int]]
    let crackLeftPixels: [(x: Int, y: Int)]
    let crackRightPixels: [(x: Int, y: Int)]
}

struct LimbTemplate {
    let left: [[Int]]
    let right: [[Int]]
    let leftOffset: (x: Int, y: Int)
    let rightOffset: (x: Int, y: Int)
}
