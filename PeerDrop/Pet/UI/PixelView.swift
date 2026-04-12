import SwiftUI

struct SpriteImageView: View {
    let image: CGImage?
    let displaySize: CGFloat

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .frame(width: displaySize, height: displaySize)
        } else {
            Color.clear.frame(width: displaySize, height: displaySize)
        }
    }
}
