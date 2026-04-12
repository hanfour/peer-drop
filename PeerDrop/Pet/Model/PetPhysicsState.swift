import CoreGraphics

struct PetPhysicsState {
    var position: CGPoint
    var velocity: CGVector
    var surface: PetSurface
    var facingRight: Bool = true
}

struct ScreenSurfaces {
    let ground: CGFloat
    let ceiling: CGFloat
    let leftWall: CGFloat
    let rightWall: CGFloat
    let dynamicIslandRect: CGRect

    #if DEBUG
    static func test(ground: CGFloat = 800, ceiling: CGFloat = 50,
                     leftWall: CGFloat = 0, rightWall: CGFloat = 400) -> ScreenSurfaces {
        ScreenSurfaces(ground: ground, ceiling: ceiling,
                       leftWall: leftWall, rightWall: rightWall,
                       dynamicIslandRect: CGRect(x: 120, y: 0, width: 160, height: 40))
    }
    #endif
}
