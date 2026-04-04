import SwiftUI

struct PixelView: View {
    let grid: PixelGrid
    let displaySize: CGFloat

    var body: some View {
        Canvas { context, size in
            let pixelSize = size.width / CGFloat(grid.size)
            for y in 0..<grid.size {
                for x in 0..<grid.size {
                    if grid.pixels[y][x] {
                        let rect = CGRect(x: CGFloat(x) * pixelSize, y: CGFloat(y) * pixelSize,
                                          width: pixelSize, height: pixelSize)
                        context.fill(Path(rect), with: .color(.primary))
                    }
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
    }
}
