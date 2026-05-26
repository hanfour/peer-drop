import CoreGraphics

public struct PetPhysicsState {
    public var position: CGPoint
    public var velocity: CGVector
    public var surface: PetSurface
    public var facingRight: Bool = true

    public init(position: CGPoint, velocity: CGVector, surface: PetSurface, facingRight: Bool = true) {
        self.position = position; self.velocity = velocity; self.surface = surface; self.facingRight = facingRight
    }
}

public struct ScreenSurfaces {
    public let ground: CGFloat
    public let ceiling: CGFloat
    public let leftWall: CGFloat
    public let rightWall: CGFloat
    public let dynamicIslandRect: CGRect

    public init(ground: CGFloat, ceiling: CGFloat, leftWall: CGFloat, rightWall: CGFloat, dynamicIslandRect: CGRect) {
        self.ground = ground; self.ceiling = ceiling; self.leftWall = leftWall
        self.rightWall = rightWall; self.dynamicIslandRect = dynamicIslandRect
    }

    #if DEBUG
    public static func test(ground: CGFloat = 800, ceiling: CGFloat = 50,
                     leftWall: CGFloat = 0, rightWall: CGFloat = 400) -> ScreenSurfaces {
        ScreenSurfaces(ground: ground, ceiling: ceiling,
                       leftWall: leftWall, rightWall: rightWall,
                       dynamicIslandRect: CGRect(x: 120, y: 0, width: 160, height: 40))
    }
    #endif
}
