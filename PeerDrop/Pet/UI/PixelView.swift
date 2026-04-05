import SwiftUI

struct PixelView: View {
    let grid: PixelGrid
    let palette: ColorPalette
    let displaySize: CGFloat

    var body: some View {
        Canvas { context, size in
            let pixelSize = size.width / CGFloat(grid.size)
            for y in 0..<grid.size {
                for x in 0..<grid.size {
                    let index = grid.pixels[y][x]
                    guard index != 0, let color = palette.color(for: index) else { continue }
                    let rect = CGRect(
                        x: CGFloat(x) * pixelSize,
                        y: CGFloat(y) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
    }
}
